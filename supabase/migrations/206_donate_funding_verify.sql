-- =====================================================================
-- 206_donate_funding_verify.sql — post-migration smoke test.
-- Run AFTER 206_donate_funding.sql. Everything happens inside one
-- transaction that ROLLS BACK at the end: no fixture rows survive.
--
-- Fixtures (all relative to the current America/Chicago month):
--   A: $35 paid this month                     -> counts 3500
--   B: $30 paid this month, $7 later refunded  -> counts 2300
--   C: $58 paid LAST month                     -> counts 0 (reset)
--   D: $10 paid this month but excluded        -> counts 0
--   E: $10 TEST-mode payment this month        -> counts 0
-- Expected progress: raised_cents 5800, display_cents 5800,
-- fully_funded true. (Without B's refund it would still cap at the
-- goal; the refund is what makes the expected total exact.)
-- =====================================================================
begin;

insert into cps.donations
  (checkout_session_id, payment_intent_id, payment_link_id, amount_cents,
   refunded_cents, currency, livemode, excluded, paid_at)
values
  ('cs_verify_a', 'pi_verify_a', 'plink_verify', 3500,    0, 'usd', true,  false,
   (date_trunc('month', (now() at time zone 'America/Chicago')) + interval '1 day')
     at time zone 'America/Chicago'),
  ('cs_verify_b', 'pi_verify_b', 'plink_verify', 3000,  700, 'usd', true,  false,
   (date_trunc('month', (now() at time zone 'America/Chicago')) + interval '2 days')
     at time zone 'America/Chicago'),
  ('cs_verify_c', 'pi_verify_c', 'plink_verify', 5800,    0, 'usd', true,  false,
   (date_trunc('month', (now() at time zone 'America/Chicago')) - interval '1 day')
     at time zone 'America/Chicago'),
  ('cs_verify_d', 'pi_verify_d', 'plink_verify', 1000,    0, 'usd', true,  true,
   (date_trunc('month', (now() at time zone 'America/Chicago')) + interval '3 days')
     at time zone 'America/Chicago'),
  ('cs_verify_e', 'pi_verify_e', 'plink_verify', 1000,    0, 'usd', false, false,
   (date_trunc('month', (now() at time zone 'America/Chicago')) + interval '3 days')
     at time zone 'America/Chicago');

do $$
declare r jsonb := public.cps_donation_progress();
begin
  if (r->>'raised_cents')::bigint <> 5800 then
    raise exception 'raised_cents: expected 5800, got %', r;
  end if;
  if (r->>'display_cents')::bigint <> 5800 then
    raise exception 'display_cents: expected 5800, got %', r;
  end if;
  if (r->>'fully_funded')::boolean is not true then
    raise exception 'fully_funded: expected true, got %', r;
  end if;
  if (r->>'goal_cents')::int <> 5800 then
    raise exception 'goal_cents: expected 5800, got %', r;
  end if;
  raise notice '206 verify OK: %', r;
end $$;

rollback;
