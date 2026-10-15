-- 150_verify.sql -- post-auth smoke test for migration 150 (shop slot 1
-- pinned to the Card of the Day's set). One transaction, ROLLS BACK --
-- net effect zero (any stock/CotD creation inside is undone; the real
-- rows were already re-pinned by the migration's one-time fix).
-- Expected: SMOKE PASSED with slot1 == today's CotD set, slot2 != slot1.
begin;

do $$
declare
  acct uuid;
  tok  text := 'smoke150-token-00000001';
  r    jsonb;
  cotd text;
  s1   text;
  s2   text;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  r := public.cps_shop_status(tok);
  s1 := r->'slots'->0->>'set_id';
  s2 := r->'slots'->1->>'set_id';
  select set_id into cotd from cps.cotd_days
   where cotd_date = (now() at time zone 'America/Chicago')::date;

  raise notice 'CotD set: % | shop slot1: % | shop slot2: %', cotd, s1, s2;
  if cotd is null then raise exception 'SMOKE FAILED: no CotD row for today'; end if;
  if s1 <> cotd then raise exception 'SMOKE FAILED: slot1 (%) != CotD set (%)', s1, cotd; end if;
  if s2 = s1 then raise exception 'SMOKE FAILED: slot2 duplicates slot1 (%)', s1; end if;
  raise notice 'SMOKE PASSED: slot 1 sells the Card of the Day set; slot 2 is distinct';
end $$;

rollback;
