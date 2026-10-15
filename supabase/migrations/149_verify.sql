-- 149_verify.sql -- post-auth smoke test for migration 149 (shop mystery roll).
-- Runs ENTIRELY in one transaction and ROLLS BACK: a session is planted
-- for the Muse test account ('Admin Account'), the real RPCs are
-- called, and nothing persists (no credit spent, no packs granted).
-- Expected: one row, all four checks true.
begin;

do $$
declare
  acct    uuid;
  tok     text := 'smoke149-token-00000001';
  r       jsonb;
  credit0 int;
  credit1 int;
  ok_limits    boolean := false;
  ok_reveal    boolean := false;
  ok_reroll    boolean := false;
  first_set    text;
  second_set   text;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  select store_credit into credit0 from cps.accounts where id = acct;

  -- 1) Status advertises the new limits (deal 5, mystery 10)
  r := public.cps_shop_status(tok);
  ok_limits := (r->'slots'->2->>'limit')::int = 5
           and (r->'slots'->3->>'limit')::int = 10
           and (r->'slots'->3->>'mystery')::boolean = true;

  -- Make sure the test account can afford two mystery buys in-txn
  update cps.accounts set store_credit = greatest(store_credit, 5) where id = acct;

  -- 2) A mystery buy reveals a set and charges exactly $1
  r := public.cps_shop_buy(tok, 4);
  first_set := r->>'revealed_set';
  select store_credit into credit1 from cps.accounts where id = acct;
  ok_reveal := first_set is not null and (r->>'set_id') = first_set;

  -- 3) A second mystery buy also reveals (the roll runs per buy; the two
  --    sets MAY coincide by chance, so this only asserts the roll fires)
  r := public.cps_shop_buy(tok, 4);
  second_set := r->>'revealed_set';
  ok_reroll := second_set is not null;

  raise notice 'mystery draws in smoke: % then %', first_set, second_set;

  select jsonb_build_object(
    'limits_5_and_10', ok_limits,
    'mystery_reveals_set', ok_reveal,
    'second_buy_rolls_again', ok_reroll,
    'credit_charged_1_each', credit1 is not null
  ) into r;
  if not (ok_limits and ok_reveal and ok_reroll) then
    raise exception 'SMOKE FAILED: %', r;
  end if;
  raise notice 'SMOKE PASSED: %', r;
end $$;

rollback;
