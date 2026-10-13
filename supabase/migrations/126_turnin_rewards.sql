-- =====================================================================
-- PackRipper — migration 126: Turn-In Rewards (25% / 50% / 75%)
-- Run AFTER 125.
--
-- Franklin's locked design (2026-10-13):
--   * Basis is TURNED IN only, per set — never merely owned.
--   * 25% turned in  ->  5 spin tickets + 5 Jumbled Mess packs
--     50% turned in  -> 10 spin tickets + 5 Jumbled Mess packs
--     75% turned in  -> 10 spin tickets + 10 packs of that set
--                        + 5 Jumbled Mess packs
--   * One time per player per set per threshold. NO scaling by set size.
--   * NO claim button: prizes are granted automatically the moment the
--     server sees a threshold passed (client calls the award RPC after
--     every state load; see js/turninrewards.js). The congrats pop-up is
--     only the announcement — the prize lands on the server whether or
--     not the pop-up is ever seen. cps.turnin_rewards is the source of
--     truth for what has been paid; a passed-but-unpaid threshold stays
--     owed until a later state load pays it.
--   * 100% is NOT in this migration — trophy case + 100% prize are a
--     separate pass (Franklin, tomorrow). Notification 1 still names
--     100% (his call): no collection can be at 100% yet, as not enough
--     cards have been pulled for anyone to have turned in a whole set.
--   * BACKPAY: the DO block at the bottom pays every already-passed
--     threshold in full, then sends two notifications (Franklin's
--     approved wording, verbatim):
--       1. to EVERY player — the update announcement;
--       2. to each backpaid player only — aggregated totals only, no
--          per-set breakdown: "Backpay: Because of your progress with
--          turning in collections, you've been given: …"
--     Both sends are guarded, and the sweep is keyed on the dedupe
--     table, so re-running this file can never pay or announce twice.
--   * Admins ARE paid like everyone else (they had to turn the cards
--     in too); disabled accounts are skipped throughout.
--
-- Threshold math: a threshold is passed when
--   turned_in_count >= ceil(total_cards * threshold / 100)
-- computed in integer arithmetic as (total * threshold + 99) / 100.
-- =====================================================================

-- ---------------------------------------------------------------- dedupe
create table if not exists cps.turnin_rewards (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id     text not null references cps.card_sets(id) on delete cascade,
  threshold  int  not null check (threshold in (25, 50, 75)),
  paid_at    timestamptz not null default now(),
  primary key (account_id, set_id, threshold)
);

-- ---------------------------------------------------------------- prizes
-- The whole reward table lives in this one function.
create or replace function cps.turnin_prize(p_threshold int)
returns jsonb language sql immutable set search_path = cps, pg_temp as $$
  select case p_threshold
    when 25 then jsonb_build_object('tickets', 5,  'jumbled', 5, 'set_packs', 0)
    when 50 then jsonb_build_object('tickets', 10, 'jumbled', 5, 'set_packs', 0)
    when 75 then jsonb_build_object('tickets', 10, 'jumbled', 5, 'set_packs', 10)
    else jsonb_build_object('tickets', 0, 'jumbled', 0, 'set_packs', 0)
  end;
$$;

-- Pay ONE threshold to ONE account, exactly once. The dedupe row is
-- inserted first; if it already exists, nothing is granted. Internal
-- only (no public wrapper) — callers are the award RPC and the backpay
-- sweep below. Returns what was actually granted.
create or replace function cps.pay_turnin_reward(
  p_account uuid, p_set text, p_threshold int, p_reason text)
returns jsonb language plpgsql set search_path = cps, pg_temp as $$
declare
  prize     jsonb := cps.turnin_prize(p_threshold);
  v_tickets int   := (prize ->> 'tickets')::int;
  v_jumbled int   := (prize ->> 'jumbled')::int;
  v_packs   int   := (prize ->> 'set_packs')::int;
  ins       int   := 0;
begin
  insert into cps.turnin_rewards (account_id, set_id, threshold)
  values (p_account, p_set, p_threshold)
  on conflict do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then
    return jsonb_build_object('paid', false, 'threshold', p_threshold);
  end if;

  if v_tickets > 0 then
    update cps.accounts set spins = spins + v_tickets where id = p_account;
    insert into cps.spin_grants (account_id, spins, reason, ref)
    values (p_account, v_tickets, p_reason, p_set || ':' || p_threshold);
  end if;
  if v_jumbled > 0 then
    perform cps.add_packs(p_account, 'jumbled', v_jumbled, p_reason,
                          p_set || ':' || p_threshold, null);
  end if;
  if v_packs > 0 then
    perform cps.add_packs(p_account, p_set, v_packs, p_reason,
                          p_set || ':' || p_threshold, null);
  end if;

  return jsonb_build_object('paid', true, 'threshold', p_threshold,
    'tickets', v_tickets, 'jumbled', v_jumbled, 'set_packs', v_packs);
end $$;

-- ------------------------------------------------------------- award RPC
-- Client calls this after state load for any set that might have passed
-- a threshold. The server recounts turn-ins itself — a client-supplied
-- count is never trusted. Pays EVERY passed-but-unpaid threshold for
-- the set in one call, so one bulk turn-in that jumps 20% -> 80% pays
-- all three at once. Quiet no-op (never an error) for unknown/inactive
-- sets and for sets with nothing owed, so a client set that isn't
-- seeded server-side yet is harmless.
create or replace function public.cps_award_turnin_rewards(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  sname   text;
  total   int;
  turned  int;
  need    int;
  th      int;
  res     jsonb;
  paid    jsonb := '[]'::jsonb;
begin
  a := cps.auth(p_token);

  if p_set is null or p_set = 'jumbled' then
    return jsonb_build_object('ok', true, 'paid', paid);
  end if;
  select name into sname from cps.card_sets where id = p_set and active;
  if sname is null then
    return jsonb_build_object('ok', true, 'paid', paid);
  end if;

  select count(*) into total from cps.cards where set_id = p_set;
  if total = 0 then
    return jsonb_build_object('ok', true, 'paid', paid);
  end if;
  select count(*) into turned
    from cps.turn_ins where account_id = a.id and set_id = p_set;

  foreach th in array array[25, 50, 75] loop
    need := (total * th + 99) / 100;
    if turned >= need then
      res := cps.pay_turnin_reward(a.id, p_set, th, 'turnin_reward');
      if (res ->> 'paid')::boolean then paid := paid || res; end if;
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'set', p_set, 'set_name', sname,
    'turned', turned, 'total', total, 'paid', paid);
end $$;

notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_award_turnin_rewards(text, text) to anon;
  end if;
end $$;

-- =====================================================================
-- BACKPAY SWEEP + NOTIFICATIONS (one-time; all guarded, safe to re-run)
-- =====================================================================
do $$
declare
  acct     record;
  st       record;
  th       int;
  total    int;
  turned   int;
  need     int;
  res      jsonb;
  any_paid boolean;
  tot_t    int;
  tot_j    int;
  sparts   text[];
  parts    text[];
  items    text;
begin
  -- Notification 1: the update announcement, to every live account.
  -- Guarded by kind: a re-run never announces a second time.
  if not exists (select 1 from cps.notifications where kind = 'turnin_rewards') then
    insert into cps.notifications (account_id, kind, text, target_view)
    select id, 'turnin_rewards',
      'NEW: Turn-In Rewards! You can now earn rewards for turning in cards in a set - at 25%, 50%, 75%, and 100% completion of a set. Rewards are one time per player, per set, and you don''t need to claim them — they''re granted automatically. If you''d already passed any of these when this launched, you''ve been backpaid. Enjoy your spoils!',
      'collection'
    from cps.accounts where not disabled;
  end if;

  -- The sweep: pay every already-passed threshold, per account.
  for acct in
    select id from cps.accounts where not disabled order by created_at
  loop
    any_paid := false;
    tot_t := 0;
    tot_j := 0;
    sparts := '{}';

    for st in
      select id, name from cps.card_sets
      where active and id <> 'jumbled' order by id
    loop
      select count(*) into total from cps.cards where set_id = st.id;
      if total = 0 then continue; end if;
      select count(*) into turned
        from cps.turn_ins where account_id = acct.id and set_id = st.id;
      if turned = 0 then continue; end if;

      foreach th in array array[25, 50, 75] loop
        need := (total * th + 99) / 100;
        if turned >= need then
          res := cps.pay_turnin_reward(acct.id, st.id, th, 'turnin_reward_backpay');
          if (res ->> 'paid')::boolean then
            any_paid := true;
            tot_t := tot_t + (res ->> 'tickets')::int;
            tot_j := tot_j + (res ->> 'jumbled')::int;
            if (res ->> 'set_packs')::int > 0 then
              sparts := sparts || ((res ->> 'set_packs')::int || ' ' || st.name || ' packs');
            end if;
          end if;
        end if;
      end loop;
    end loop;

    -- Notification 2: only players actually backpaid in this run, and
    -- never a second one. Aggregated totals only (Franklin's wording).
    if any_paid and not exists (
      select 1 from cps.notifications
      where account_id = acct.id and kind = 'turnin_backpay') then
      -- aggregated totals in a fixed order: tickets, jumbled, set packs
      parts := '{}';
      if tot_t > 0 then parts := parts || (tot_t || ' spin tickets'); end if;
      if tot_j > 0 then parts := parts || (tot_j || ' Jumbled Mess packs'); end if;
      parts := parts || sparts;
      if array_length(parts, 1) = 1 then
        items := parts[1];
      elsif array_length(parts, 1) = 2 then
        items := parts[1] || ' and ' || parts[2];
      else
        items := array_to_string(parts[1:array_length(parts, 1) - 1], ', ')
              || ', and ' || parts[array_length(parts, 1)];
      end if;
      perform cps.notify(acct.id, 'turnin_backpay',
        'Backpay: Because of your progress with turning in collections, you''ve been given: '
        || items || '.', 'collection');
    end if;
  end loop;
end $$;

-- =====================================================================
-- VERIFY (read-only; safe to run any time after this migration)
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and proname = 'cps_award_turnin_rewards';
--   -- one row per threshold ever paid, with how it was paid:
--   select threshold, count(*) as payments,
--          sum((select g.spins from cps.spin_grants g
--               where g.account_id = r.account_id and g.ref = r.set_id || ':' || r.threshold
--                 and g.reason like 'turnin_reward%')) as tickets_paid
--     from cps.turnin_rewards r group by threshold order by threshold;
--   -- backpay audit: grants written by the sweep
--   select reason, count(*), sum(packs) from cps.pack_grants
--     where reason = 'turnin_reward_backpay' group by reason;
--   select count(*) from cps.notifications where kind = 'turnin_rewards';
--   select count(*) from cps.notifications where kind = 'turnin_backpay';
-- =====================================================================
