-- 161_verify.sql -- post-auth smoke test for migration 161 (shop Buy all).
-- Runs ENTIRELY in one transaction and ROLLS BACK: a session is planted
-- for the Muse test account ('Admin Account'), the real RPC is
-- called, and nothing persists (no credit spent, no packs granted).
-- Expected: completes with 'SMOKE PASSED' and all checks true.
begin;

do $$
declare
  acct     uuid;
  tok      text := 'smoke161-token-00000001';
  r        jsonb;
  st       jsonb;
  rem6     int;
  rem4     int;
  credit0  int;
  tokens0  int;
  tokens1  int;
  bought6  int;
  reveal_n int;
  ok_unlimited_blocked boolean := false;
  ok_allornothing      boolean := false;
  ok_buyall_tokens     boolean := false;
  ok_limit_after       boolean := false;
  ok_mystery_grouped   boolean := false;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  st := public.cps_shop_status(tok);
  rem6 := (st->'slots'->5->>'limit')::int - (st->'slots'->5->>'bought')::int;
  rem4 := (st->'slots'->3->>'limit')::int - (st->'slots'->3->>'bought')::int;
  if rem6 <= 0 then raise exception 'smoke needs token headroom on the test account'; end if;

  -- 1) Unlimited slots are rejected
  begin
    r := public.cps_shop_buy_all(tok, 1);
  exception when raise_exception then
    ok_unlimited_blocked := (SQLERRM = 'Buy all is only for limited items.');
  end;

  -- 2) All-or-nothing: one dollar short buys NOTHING and charges NOTHING
  update cps.accounts set store_credit = rem6 - 1 where id = acct;
  begin
    r := public.cps_shop_buy_all(tok, 6);
  exception when raise_exception then
    ok_allornothing := (SQLERRM = 'Not enough Store Credit.');
  end;
  select store_credit into credit0 from cps.accounts where id = acct;
  st := public.cps_shop_status(tok);
  bought6 := (st->'slots'->5->>'bought')::int;
  ok_allornothing := ok_allornothing and credit0 = rem6 - 1
    and bought6 = (st->'slots'->5->>'limit')::int - rem6;

  -- 3) Buy all tokens: exact count, exact charge, limit then reached
  update cps.accounts set store_credit = 500 where id = acct;
  select coalesce(game_tokens, 0) into tokens0 from cps.accounts where id = acct;
  r := public.cps_shop_buy_all(tok, 6);
  select coalesce(game_tokens, 0) into tokens1 from cps.accounts where id = acct;
  select store_credit into credit0 from cps.accounts where id = acct;
  ok_buyall_tokens := (r->>'count')::int = rem6 and (r->>'total')::int = rem6
    and tokens1 = tokens0 + rem6 and credit0 = 500 - rem6;
  begin
    r := public.cps_shop_buy_all(tok, 6);
  exception when raise_exception then
    ok_limit_after := (SQLERRM like 'Limit reached%');
  end;

  -- 4) Mystery buy-all (if headroom): revealed groups sum to the count
  if rem4 > 0 then
    r := public.cps_shop_buy_all(tok, 4);
    select coalesce(sum((e->>'count')::int), 0) into reveal_n
      from jsonb_array_elements(r->'revealed') e;
    ok_mystery_grouped := reveal_n = rem4 and (r->>'count')::int = rem4;
  else
    ok_mystery_grouped := true;
    raise notice 'mystery already maxed on test account; grouped check skipped';
  end if;

  r := jsonb_build_object(
    'unlimited_slot_blocked', ok_unlimited_blocked,
    'all_or_nothing_no_charge', ok_allornothing,
    'buy_all_tokens_exact', ok_buyall_tokens,
    'limit_reached_after', ok_limit_after,
    'mystery_revealed_grouped', ok_mystery_grouped
  );
  if not (ok_unlimited_blocked and ok_allornothing and ok_buyall_tokens
          and ok_limit_after and ok_mystery_grouped) then
    raise exception 'SMOKE FAILED: %', r;
  end if;
  raise notice 'SMOKE PASSED: %', r;
end $$;

rollback;
