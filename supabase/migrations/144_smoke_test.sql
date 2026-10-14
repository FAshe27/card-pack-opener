-- 144_smoke_test.sql — post-auth smoke test for migration 144.
-- One transaction, ROLLS BACK. Plants a session for the Muse test
-- account, completes the smallest set it hasn't been paid 100% for
-- (inserted turn-ins roll back too), and calls the REAL award RPC.
-- Run AFTER 144_turnin_reward_100.sql.
-- Expected: one row, all five checks true.
begin;

do $$
declare
  acct  uuid;
  tok   text := 'smoke144-token-00000001';
  v_set text;
  spins_before int;
  spins_after  int;
  r     jsonb;
  r2    jsonb;
  row100 jsonb;
  ok_prize_row    boolean := false;
  ok_spins        boolean := false;
  ok_random_total boolean := false;
  ok_random_spread boolean := false;
  ok_idempotent   boolean := false;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;

  -- smallest active set (with cards, not Jumbled) where this account
  -- has not already been paid the 100% prize
  select s.id into v_set
    from cps.card_sets s
   where s.active and s.id <> 'jumbled'
     and exists (select 1 from cps.cards c where c.set_id = s.id)
     and not exists (select 1 from cps.turnin_rewards tr
                      where tr.account_id = acct and tr.set_id = s.id
                        and tr.threshold = 100)
   order by (select count(*) from cps.cards c where c.set_id = s.id)
   limit 1;
  if v_set is null then raise exception 'No unpaid-100 set exists for the test account'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  -- complete the set on paper (rolls back with everything else)
  insert into cps.turn_ins (account_id, set_id, card_id)
  select acct, set_id, card_id from cps.cards where set_id = v_set
  on conflict do nothing;

  select spins into spins_before from cps.accounts where id = acct;

  r := public.cps_award_turnin_rewards(tok, v_set);

  -- 1) the 100 row is in the payment, with Franklin's amounts
  select e into row100 from jsonb_array_elements(r -> 'paid') e
   where (e ->> 'threshold')::int = 100;
  ok_prize_row := row100 is not null
    and (row100 ->> 'tickets')::int = 25
    and (row100 ->> 'random_packs')::int = 100;

  -- 2) spins rose by exactly the tickets across all rows just paid
  select spins into spins_after from cps.accounts where id = acct;
  ok_spins := spins_after - spins_before = (
    select coalesce(sum((e ->> 'tickets')::int), 0)
      from jsonb_array_elements(r -> 'paid') e);

  -- 3) the random grants for this payment total exactly 100 packs,
  --    all inside the legal pool, and 4) they spread over 2+ sets
  ok_random_total := (
    select coalesce(sum(packs), 0) from cps.pack_grants
     where account_id = acct and reason = 'turnin_reward'
       and ref = v_set || ':100') = 100
    and not exists (
      select 1 from cps.pack_grants
       where account_id = acct and reason = 'turnin_reward'
         and ref = v_set || ':100'
         and set_id not in (select id from cps.card_sets
                             where active and id <> 'jumbled'));
  ok_random_spread := (
    select count(distinct set_id) from cps.pack_grants
     where account_id = acct and reason = 'turnin_reward'
       and ref = v_set || ':100') >= 2;

  -- 5) a second call pays nothing (dedupe holds)
  r2 := public.cps_award_turnin_rewards(tok, v_set);
  ok_idempotent := jsonb_array_length(r2 -> 'paid') = 0;

  if not (ok_prize_row and ok_spins and ok_random_total
          and ok_random_spread and ok_idempotent) then
    raise exception 'SMOKE FAILED: prize_row=% spins=% random_total=% random_spread=% idempotent=% (set=%)',
      ok_prize_row, ok_spins, ok_random_total, ok_random_spread, ok_idempotent, v_set;
  end if;

  create temp table smoke144_result on commit drop as
  select ok_prize_row as prize_row_25_and_100,
         ok_spins as spins_match_payment,
         ok_random_total as random_total_100_in_pool,
         ok_random_spread as random_spread_2plus_sets,
         ok_idempotent as second_call_pays_nothing,
         v_set as set_used;
end $$;

select * from smoke144_result;

rollback;
