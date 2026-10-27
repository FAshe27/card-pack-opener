-- =====================================================================
-- 206: Live monthly funding bar for the unlinked #donate page.
--
-- Franklin's decisions (2026-10-27):
--  * The bar counts GROSS donations toward the $58/month goal.
--    A donation that is later refunded stops counting (its refunded
--    amount is subtracted); Stripe processing fees are NOT deducted.
--  * The displayed total never exceeds the $58 goal, even when the
--    real month total is higher.
--  * The bar resets automatically every month (America/Chicago).
--  * At or above the goal, the client gilds the bar and shows
--    "Fully Funded for <Month>!".
--
-- What this migration does, and ONLY this:
--  * Config row donation_goal_cents = 5800 in cps.app_config.
--  * Private ledger cps.donations: one row per Stripe Checkout
--    Session (the primary key makes webhook retries / reconciliation
--    replays idempotent). Stores NO donor name, email, or card data —
--    only Stripe object ids, gross/refunded cents, currency, the
--    live-mode flag, and when it was paid. RLS on, no policies,
--    all grants revoked (the house deny-all pattern): the ONLY
--    writers are the Stripe webhook Edge Function (direct SQL with
--    the database role) and Franklin himself in the SQL editor.
--  * public.cps_donation_progress(): callable with the publishable
--    key, NO session token needed. Returns ONLY the aggregate for
--    the current America/Chicago month: {month_name, month_label,
--    goal_cents, raised_cents, display_cents, fully_funded}.
--    raised_cents is the true gross-minus-refunds total;
--    display_cents is raised_cents capped at the goal.
--
-- Franklin's $1 self-test (2026-10-27): if it is refunded in Stripe,
-- reconciliation records refunded_cents = amount_cents and it counts
-- $0. If it is NOT refunded and should not count, flip its row:
--   update cps.donations set excluded = true
--    where checkout_session_id = '<the test session id>';
-- =====================================================================

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('donation_goal_cents', '5800')          -- $58.00 monthly goal
on conflict (key) do nothing;

-- ---------------------------------------------------------------- ledger
create table if not exists cps.donations (
  checkout_session_id text primary key,            -- Stripe cs_... id (idempotency key)
  payment_intent_id   text,                        -- Stripe pi_... id (refund lookup)
  payment_link_id     text not null,               -- Stripe plink_... id it came through
  amount_cents        int  not null check (amount_cents >= 0),       -- gross amount paid
  refunded_cents      int  not null default 0
                      check (refunded_cents >= 0 and refunded_cents <= amount_cents),
  currency            text not null default 'usd',
  livemode            boolean not null default true,
  excluded            boolean not null default false,  -- manual corrections (e.g. self-test)
  paid_at             timestamptz not null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists donations_paid_at on cps.donations (paid_at);
create unique index if not exists donations_payment_intent
  on cps.donations (payment_intent_id) where payment_intent_id is not null;

alter table cps.donations enable row level security;
revoke all on table cps.donations from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on table cps.donations from anon, authenticated';
  end if;
end $$;

-- ------------------------------------------------------- progress (public)
-- Aggregate ONLY — no row-level donation data ever leaves through here.
create or replace function public.cps_donation_progress()
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  v_local  timestamp := (now() at time zone 'America/Chicago');
  v_start  timestamptz := (date_trunc('month', v_local) at time zone 'America/Chicago');
  v_end    timestamptz := ((date_trunc('month', v_local) + interval '1 month')
                           at time zone 'America/Chicago');
  v_goal   int := 5800;
  v_raised bigint := 0;
begin
  begin
    v_goal := coalesce((cps.cfg('donation_goal_cents')::text)::int, 5800);
  exception when others then
    v_goal := 5800;
  end;
  if v_goal is null or v_goal <= 0 then v_goal := 5800; end if;

  select coalesce(sum(greatest(amount_cents - refunded_cents, 0)), 0)
    into v_raised
    from cps.donations
   where livemode
     and not excluded
     and currency = 'usd'
     and paid_at >= v_start
     and paid_at <  v_end;

  return jsonb_build_object(
    'ok', true,
    'month_name',    to_char(v_local, 'FMMonth'),
    'month_label',   to_char(v_local, 'FMMonth YYYY'),
    'goal_cents',    v_goal,
    'raised_cents',  v_raised,
    'display_cents', least(v_raised, v_goal),
    'fully_funded',  v_raised >= v_goal);
end $$;

-- ---------------------------------------------------------------- grants
do $$ begin
  execute 'revoke all on function public.cps_donation_progress() from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_donation_progress() to anon, authenticated';
  end if;
end $$;

-- let the API pick up the new function right away
notify pgrst, 'reload schema';
