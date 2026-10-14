-- =====================================================================
-- PackRipper — migration 144: Turn-In Reward for 100% (the finale)
-- Run AFTER 143. Extends migration 126's machinery; nothing else moves.
--
-- Franklin's call (2026-10-14, 'Let's go wild with it — 100% is a big
-- deal'): turning in EVERY card of a set now pays, one time per player
-- per set, automatically, on top of the trophy + the global completion
-- broadcast (migration 113, already live):
--
--   100% turned in  ->  100 random packs + 25 spin tickets
--
-- 'Random packs' (confirmed by Franklin): 100 separate pack credits,
-- each assigned to a random set, independently — duplicates possible.
-- The pool is every active set that has cards, excluding Jumbled.
-- Draws are aggregated per set for the grants ledger, under the same
-- ref style as every other turn-in grant ('<completed set>:100').
--
-- Same locked rules as 126: turned-in ONLY basis, no scaling by set
-- size, no claim button (the award RPC pays on state load; this file's
-- sweep backpays anyone already at 100%), admins ARE paid, disabled
-- accounts skipped, cps.turnin_rewards stays the source of truth.
--
-- What this file changes, exactly:
--   1. cps.turnin_rewards check constraint gains threshold 100.
--   2. cps.turnin_prize gains the 100 row (existing rows unchanged in
--      value; every row gains a 'random_packs' key, 0 below 100).
--   3. cps.pay_turnin_reward gains the random-pack grant block
--      (insertion-only vs 126's body — removing the added lines
--      reproduces 126 byte-for-byte).
--   4. public.cps_award_turnin_rewards: the threshold loop gains 100
--      (single-line change vs 126).
--   5. Backpay sweep for threshold 100 + two notifications (guarded
--      kinds 'turnin_100_live' / 'turnin_backpay_100', so a re-run can
--      never pay or announce twice).
--
-- WORDING: the two notification texts below are DRAFTS awaiting
-- Franklin's proofread, same as 126's were. (Site terminology is
-- 'spin tickets' throughout, so the drafts use that.)
-- =====================================================================

-- ------------------------------------------------------- 1. dedupe +100
-- Drop whatever check constraint(s) the table currently carries (126's
-- was inline/unnamed) and re-add the standard-named one with 100 in.
do $$
declare cn text;
begin
  for cn in
    select conname from pg_constraint
     where conrelid = 'cps.turnin_rewards'::regclass and contype = 'c'
  loop
    execute format('alter table cps.turnin_rewards drop constraint %I', cn);
  end loop;
  alter table cps.turnin_rewards
    add constraint turnin_rewards_threshold_check
    check (threshold in (25, 50, 75, 100));
end $$;

-- ---------------------------------------------------------- 2. prizes
create or replace function cps.turnin_prize(p_threshold int)
returns jsonb language sql immutable set search_path = cps, pg_temp as $$
  select case p_threshold
    when 25 then jsonb_build_object('tickets', 5,  'jumbled', 5, 'set_packs', 0,  'random_packs', 0)
    when 50 then jsonb_build_object('tickets', 10, 'jumbled', 5, 'set_packs', 0,  'random_packs', 0)
    when 75 then jsonb_build_object('tickets', 10, 'jumbled', 5, 'set_packs', 10, 'random_packs', 0)
    when 100 then jsonb_build_object('tickets', 25, 'jumbled', 0, 'set_packs', 0, 'random_packs', 100)
    else jsonb_build_object('tickets', 0, 'jumbled', 0, 'set_packs', 0, 'random_packs', 0)
  end;
$$;

-- ------------------------------------------------- 3. pay one threshold
create or replace function cps.pay_turnin_reward(
  p_account uuid, p_set text, p_threshold int, p_reason text)
returns jsonb language plpgsql set search_path = cps, pg_temp as $$
declare
  prize     jsonb := cps.turnin_prize(p_threshold);
  v_tickets int   := (prize ->> 'tickets')::int;
  v_jumbled int   := (prize ->> 'jumbled')::int;
  v_packs   int   := (prize ->> 'set_packs')::int;
  v_random  int   := coalesce((prize ->> 'random_packs')::int, 0);
  v_pool    text[];
  v_pool_n  int   := 0;
  rp        record;
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

  if v_random > 0 then
    -- Each pack is assigned to a random set, independently (duplicates
    -- possible): the pool is every active set with cards in it, minus
    -- Jumbled itself. The draw indexes a pre-built pool array with a
    -- per-row random() in the target list — the one shape Postgres
    -- cannot collapse into a single evaluation (an uncorrelated
    -- subquery draw, scalar OR lateral, is evaluated once and every
    -- pack lands on the same set; both failures proven on a stub
    -- cluster). Draws are aggregated so the grants ledger gets one
    -- row per set hit, all carrying this payment's ref.
    select array_agg(cs.id order by cs.id), count(*)
      into v_pool, v_pool_n
      from cps.card_sets cs
     where cs.active and cs.id <> 'jumbled'
       and exists (select 1 from cps.cards c where c.set_id = cs.id);
    if v_pool_n > 0 then
      for rp in
        select d.pick as set_id, count(*)::int as n
          from (select v_pool[1 + floor(random() * v_pool_n)::int] as pick
                  from generate_series(1, v_random)) d
         group by d.pick
      loop
        perform cps.add_packs(p_account, rp.set_id, rp.n, p_reason,
                              p_set || ':' || p_threshold, null);
      end loop;
    end if;
  end if;
  return jsonb_build_object('paid', true, 'threshold', p_threshold,
    'tickets', v_tickets, 'jumbled', v_jumbled, 'set_packs', v_packs,
    'random_packs', v_random);
end $$;

-- ------------------------------------------------------------- award RPC
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

  foreach th in array array[25, 50, 75, 100] loop
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
-- BACKPAY SWEEP + NOTIFICATIONS for threshold 100 (one-time; guarded)
-- =====================================================================
do $$
declare
  acct     record;
  st       record;
  total    int;
  turned   int;
  res      jsonb;
  any_paid boolean;
  tot_t    int;
  tot_r    int;
  parts    text[];
  items    text;
begin
  -- Announcement: the 100% prize is live, to every live account.
  -- Guarded by kind: a re-run never announces a second time.
  if not exists (select 1 from cps.notifications where kind = 'turnin_100_live') then
    insert into cps.notifications (account_id, kind, text, target_view)
    select id, 'turnin_100_live',
      'NEW: The 100% Turn-In Reward is here! Turn in every card in a set and you''ll earn 100 random packs + 25 spin tickets — on top of the trophy. It''s one time per player, per set, and it''s granted automatically. If you''d already completed a set, you''ve been backpaid. Good luck out there!',
      'collection'
    from cps.accounts where not disabled;
  end if;

  -- The sweep: pay threshold 100 wherever a set is already fully
  -- turned in. Keyed on the dedupe table via pay_turnin_reward, so
  -- nobody can be paid twice.
  for acct in
    select id from cps.accounts where not disabled order by created_at
  loop
    any_paid := false;
    tot_t := 0;
    tot_r := 0;

    for st in
      select id, name from cps.card_sets
      where active and id <> 'jumbled' order by id
    loop
      select count(*) into total from cps.cards where set_id = st.id;
      if total = 0 then continue; end if;
      select count(*) into turned
        from cps.turn_ins where account_id = acct.id and set_id = st.id;
      if turned < total then continue; end if;

      res := cps.pay_turnin_reward(acct.id, st.id, 100, 'turnin_reward_backpay');
      if (res ->> 'paid')::boolean then
        any_paid := true;
        tot_t := tot_t + (res ->> 'tickets')::int;
        tot_r := tot_r + (res ->> 'random_packs')::int;
      end if;
    end loop;

    -- Backpay note: only players actually backpaid in this run, and
    -- never a second one. Aggregated totals only, like 126's.
    if any_paid and not exists (
      select 1 from cps.notifications
      where account_id = acct.id and kind = 'turnin_backpay_100') then
      parts := '{}';
      if tot_t > 0 then parts := parts || (tot_t || ' spin tickets'); end if;
      if tot_r > 0 then parts := parts || (tot_r || ' random packs'); end if;
      if array_length(parts, 1) = 1 then
        items := parts[1];
      elsif array_length(parts, 1) = 2 then
        items := parts[1] || ' and ' || parts[2];
      else
        items := array_to_string(parts[1:array_length(parts, 1) - 1], ', ')
              || ', and ' || parts[array_length(parts, 1)];
      end if;
      perform cps.notify(acct.id, 'turnin_backpay_100',
        'Backpay: Because you''d already turned in a complete collection, you''ve been given: '
        || items || '. Enjoy your spoils!', 'collection');
    end if;
  end loop;
end $$;

-- =====================================================================
-- VERIFY (read-only; safe to run any time after this migration)
--   -- the dedupe table now accepts 100:
--   select pg_get_constraintdef(oid) from pg_constraint
--     where conrelid = 'cps.turnin_rewards'::regclass and contype = 'c';
--   -- the prize table, whole:
--   select cps.turnin_prize(25), cps.turnin_prize(50),
--          cps.turnin_prize(75), cps.turnin_prize(100);
--   -- every 100% payment ever made, and what it granted in tickets:
--   select r.account_id, r.set_id, r.paid_at,
--          (select g.spins from cps.spin_grants g
--            where g.account_id = r.account_id
--              and g.ref = r.set_id || ':100'
--              and g.reason like 'turnin_reward%') as tickets_paid
--     from cps.turnin_rewards r where r.threshold = 100;
--   -- random packs granted per 100% payment (should total 100 each):
--   select ref, reason, sum(packs) from cps.pack_grants
--     where ref like '%:100' and reason like 'turnin_reward%'
--     group by ref, reason;
--   select count(*) from cps.notifications where kind = 'turnin_100_live';
--   select count(*) from cps.notifications where kind = 'turnin_backpay_100';
-- =====================================================================
