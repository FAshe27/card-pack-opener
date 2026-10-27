// =====================================================================
// stripe-donations — Supabase Edge Function for the #donate funding bar.
//
// Two jobs, one endpoint (deploy with JWT verification OFF — Stripe's
// webhook cannot send a Supabase token; the Stripe signature IS the
// authentication on POST, and GET only triggers a throttled reconcile
// and returns aggregate counts):
//
//   POST  Stripe webhook receiver. Verifies the Stripe-Signature
//         header against STRIPE_WEBHOOK_SECRET, then records paid
//         donations from Franklin's Payment Link into cps.donations
//         and keeps refunded_cents current. Idempotent: the ledger's
//         primary key is the Checkout Session id, and Stripe retries
//         simply re-upsert the same row.
//
//   GET ?reconcile=1
//         Self-healing sweep, throttled to once per 2 minutes via
//         cps.app_config. Re-reads this month's Checkout Sessions for
//         the Payment Link from the Stripe API (restricted read-only
//         key) plus this month's refunds, and upserts them all — so a
//         missed webhook can never permanently skew the bar. The
//         #donate page pokes this (fire-and-forget) when it loads.
//
// Secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_WEBHOOK_SECRET   whsec_... from the Stripe webhook endpoint
//   STRIPE_RESTRICTED_KEY   rk_live_... read-only: Payment Links,
//                           Checkout Sessions, Charges, PaymentIntents,
//                           Refunds
//   STRIPE_PAYMENT_LINK_ID  optional plink_... — when unset, the link
//                           is found by matching its public URL against
//                           the account's Payment Links.
// SUPABASE_DB_URL is injected by Supabase automatically.
//
// Gross counting (Franklin, 2026-10-27): amount_cents is what the
// supporter paid; refunded_cents is subtracted when a refund happens;
// Stripe's processing fees are never deducted here.
// =====================================================================

import postgres from "npm:postgres@3.4.5";

const PAYMENT_LINK_URL =
  Deno.env.get("STRIPE_PAYMENT_LINK_URL") ??
  "https://donate.stripe.com/eVqcMX0XL4Jx34a4ha3gk01";
const LINK_SLUG = PAYMENT_LINK_URL.split("/").pop() ?? "";
const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const RESTRICTED_KEY = Deno.env.get("STRIPE_RESTRICTED_KEY") ?? "";
const RECONCILE_EVERY_MS = 120_000;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, apikey, content-type, x-client-info",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS },
  });
}

function db() {
  const url = Deno.env.get("SUPABASE_DB_URL");
  if (!url) throw new Error("SUPABASE_DB_URL is not set");
  // Transaction-pooler friendly: no prepared statements, one connection.
  return postgres(url, { prepare: false, max: 1 });
}

// ---------------------------------------------------------- Stripe API
async function stripeGet(
  path: string,
  params: Record<string, string> = {},
): Promise<any> {
  if (!RESTRICTED_KEY) throw new Error("STRIPE_RESTRICTED_KEY is not set");
  const url = new URL("https://api.stripe.com/v1/" + path);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url, {
    headers: { Authorization: "Bearer " + RESTRICTED_KEY },
  });
  const data = await res.json();
  if (!res.ok) {
    throw new Error(
      "Stripe API " + path + " -> " + res.status + " " +
        (data?.error?.message ?? ""),
    );
  }
  return data;
}

let cachedLinkId: string | null = Deno.env.get("STRIPE_PAYMENT_LINK_ID") ??
  null;

async function paymentLinkId(): Promise<string> {
  if (cachedLinkId) return cachedLinkId;
  const list = await stripeGet("payment_links", { limit: "100" });
  const match = (list.data ?? []).find(
    (l: any) => typeof l.url === "string" && l.url.endsWith("/" + LINK_SLUG),
  );
  if (!match) {
    throw new Error("Payment Link not found for slug " + LINK_SLUG);
  }
  cachedLinkId = match.id;
  return match.id;
}

// ------------------------------------------------------ webhook verify
function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyStripeSignature(
  payload: string,
  header: string,
  secret: string,
): Promise<void> {
  const fields = new Map<string, string[]>();
  for (const part of header.split(",")) {
    const idx = part.indexOf("=");
    if (idx < 0) continue;
    const k = part.slice(0, idx).trim();
    const v = part.slice(idx + 1).trim();
    fields.set(k, [...(fields.get(k) ?? []), v]);
  }
  const timestamp = fields.get("t")?.[0];
  const signatures = fields.get("v1") ?? [];
  if (!timestamp || signatures.length === 0) {
    throw new Error("Malformed Stripe-Signature header");
  }
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) {
    throw new Error("Stripe-Signature timestamp outside tolerance");
  }
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(timestamp + "." + payload),
  );
  const expected = hex(mac);
  if (!signatures.some((s) => timingSafeEqual(s, expected))) {
    throw new Error("Stripe-Signature verification failed");
  }
}

// ------------------------------------------------------------- ledger
type Sql = ReturnType<typeof db>;

async function upsertDonation(
  sql: Sql,
  d: {
    sessionId: string;
    paymentIntentId: string | null;
    paymentLinkId: string;
    amountCents: number;
    refundedCents: number;
    currency: string;
    livemode: boolean;
    paidAt: Date;
  },
): Promise<void> {
  await sql`
    insert into cps.donations
      (checkout_session_id, payment_intent_id, payment_link_id, amount_cents,
       refunded_cents, currency, livemode, paid_at, updated_at)
    values
      (${d.sessionId}, ${d.paymentIntentId}, ${d.paymentLinkId}, ${d.amountCents},
       ${d.refundedCents}, ${d.currency}, ${d.livemode}, ${d.paidAt}, now())
    on conflict (checkout_session_id) do update set
      payment_intent_id = excluded.payment_intent_id,
      payment_link_id   = excluded.payment_link_id,
      amount_cents      = excluded.amount_cents,
      refunded_cents    = greatest(cps.donations.refunded_cents,
                                   excluded.refunded_cents),
      currency          = excluded.currency,
      livemode          = excluded.livemode,
      paid_at           = excluded.paid_at,
      updated_at        = now()`;
}

async function recordSession(sql: Sql, session: any): Promise<void> {
  const linkId = await paymentLinkId();
  if (session.payment_link !== linkId) return; // not our donation link
  if (session.mode !== "payment") return;
  if (session.payment_status !== "paid") return;
  if (!session.id || typeof session.amount_total !== "number") return;

  // Current refund total rides along when we can read the charge.
  let refunded = 0;
  const pi = typeof session.payment_intent === "string"
    ? session.payment_intent
    : null;
  if (pi && RESTRICTED_KEY) {
    try {
      const intent = await stripeGet("payment_intents/" + pi);
      const chargeId = typeof intent.latest_charge === "string"
        ? intent.latest_charge
        : intent.latest_charge?.id;
      if (chargeId) {
        const charge = await stripeGet("charges/" + chargeId);
        refunded = charge.amount_refunded ?? 0;
      }
    } catch (_) {
      // Refund lookup is best-effort here; the charge.refunded webhook
      // and the reconcile sweep keep refunded_cents honest.
    }
  }

  await upsertDonation(sql, {
    sessionId: session.id,
    paymentIntentId: pi,
    paymentLinkId: linkId,
    amountCents: session.amount_total,
    refundedCents: refunded,
    currency: session.currency ?? "usd",
    livemode: !!session.livemode,
    paidAt: new Date((session.created ?? 0) * 1000),
  });
}

async function handleWebhook(req: Request): Promise<Response> {
  if (!WEBHOOK_SECRET) return json({ error: "webhook secret unset" }, 500);
  const payload = await req.text();
  const signature = req.headers.get("stripe-signature") ?? "";
  try {
    await verifyStripeSignature(payload, signature, WEBHOOK_SECRET);
  } catch (e) {
    return json({ error: String(e) }, 400);
  }

  const event = JSON.parse(payload);
  const obj = event?.data?.object ?? {};
  const sql = db();
  try {
    switch (event.type) {
      case "checkout.session.completed":
      case "checkout.session.async_payment_succeeded":
        await recordSession(sql, obj);
        break;
      case "checkout.session.async_payment_failed":
        // Never counted (we only record paid sessions) — remove just in
        // case a state change ever landed a row early.
        if (obj.id) {
          await sql`delete from cps.donations
                     where checkout_session_id = ${obj.id}`;
        }
        break;
      case "charge.refunded":
        if (obj.payment_intent) {
          await sql`update cps.donations
                       set refunded_cents = ${obj.amount_refunded ?? 0},
                           updated_at = now()
                     where payment_intent_id = ${obj.payment_intent}`;
        }
        break;
      case "charge.dispute.closed":
        // A lost dispute claws the money back like a full refund.
        if (obj.payment_intent && obj.status === "lost") {
          await sql`update cps.donations
                       set refunded_cents = amount_cents, updated_at = now()
                     where payment_intent_id = ${obj.payment_intent}`;
        }
        break;
      default:
        break; // everything else: acknowledge and ignore
    }
  } catch (e) {
    console.error("webhook handling failed", event.type, e);
    return json({ error: "handler failed" }, 500); // Stripe will retry
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
  }
  return json({ received: true });
}

// ---------------------------------------------------------- reconcile
// Epoch seconds for midnight America/Chicago on a given UTC date's
// Chicago calendar day. Display correctness never depends on this —
// the SQL progress function applies the authoritative month window —
// this only bounds the Stripe API scan.
export function chicagoMidnightEpoch(fromUtcMs: number, addMonths: number): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/Chicago",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(new Date(fromUtcMs));
  const get = (t: string) =>
    Number(parts.find((p) => p.type === t)?.value ?? "0");
  let year = get("year");
  let month = get("month") - 1 + addMonths;
  year += Math.floor(month / 12);
  month = ((month % 12) + 12) % 12;

  const offsetMs = (utcMs: number) => {
    const p = new Intl.DateTimeFormat("en-US", {
      timeZone: "America/Chicago",
      hour12: false,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    }).formatToParts(new Date(utcMs));
    const g = (t: string) => Number(p.find((x) => x.type === t)?.value ?? "0");
    const asUtc = Date.UTC(
      g("year"),
      g("month") - 1,
      g("day"),
      g("hour") % 24,
      g("minute"),
      g("second"),
    );
    return asUtc - utcMs;
  };

  let utc = Date.UTC(year, month, 1);
  utc -= offsetMs(utc);
  utc = Date.UTC(year, month, 1) - offsetMs(utc);
  return Math.floor(utc / 1000);
}

async function reconcile(force = false): Promise<Record<string, unknown>> {
  const sql = db();
  try {
    if (!force) {
      const rows = await sql`
        select value from cps.app_config
         where key = 'donation_last_reconcile'`;
      const last = Number(rows[0]?.value ?? 0);
      if (Date.now() - last < RECONCILE_EVERY_MS) {
        return { ok: true, reconciled: false, reason: "throttled" };
      }
    }

    const linkId = await paymentLinkId();
    const gte = chicagoMidnightEpoch(Date.now(), 0);
    const lt = chicagoMidnightEpoch(Date.now(), 1);

    let seen = 0;
    let startingAfter: string | undefined;
    for (;;) {
      const page: any = await stripeGet("checkout/sessions", {
        payment_link: linkId,
        "created[gte]": String(gte),
        "created[lt]": String(lt),
        limit: "100",
        ...(startingAfter ? { starting_after: startingAfter } : {}),
      });
      for (const session of page.data ?? []) {
        seen++;
        await recordSession(sql, session);
      }
      if (!page.has_more || (page.data ?? []).length === 0) break;
      startingAfter = page.data[page.data.length - 1].id;
    }

    // Refunds that landed this month against earlier donations: refresh
    // the affected rows' refunded_cents from their charges.
    const refunds: any = await stripeGet("refunds", {
      "created[gte]": String(gte),
      limit: "100",
    });
    for (const refund of refunds.data ?? []) {
      if (refund.status !== "succeeded" || !refund.charge) continue;
      const charge = await stripeGet("charges/" + refund.charge);
      if (charge.payment_intent) {
        await sql`update cps.donations
                     set refunded_cents = ${charge.amount_refunded ?? 0},
                         updated_at = now()
                   where payment_intent_id = ${charge.payment_intent}`;
      }
    }

    await sql`
      insert into cps.app_config (key, value)
      values ('donation_last_reconcile', ${String(Date.now())}::jsonb)
      on conflict (key) do update set value = excluded.value`;

    return { ok: true, reconciled: true, sessions_seen: seen };
  } finally {
    await sql.end({ timeout: 5 }).catch(() => {});
  }
}

// ---------------------------------------------------------------- main
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }
  try {
    if (req.method === "POST") return await handleWebhook(req);
    if (req.method === "GET") {
      const url = new URL(req.url);
      if (url.searchParams.get("reconcile") === "1") {
        return json(await reconcile());
      }
      return json({ ok: true, service: "stripe-donations" });
    }
    return json({ error: "method not allowed" }, 405);
  } catch (e) {
    console.error(e);
    return json({ error: "internal" }, 500);
  }
});
