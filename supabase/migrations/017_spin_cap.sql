-- =====================================================================
-- 017_spin_cap.sql — the daily free spin is skipped while the player
-- holds 10 or more spins (admin grants are unaffected).
-- =====================================================================

-- (003's body, unchanged, plus the spins < 10 cap on the daily grant)
create or replace function public.cps_get_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
begin
  a := cps.auth(p_token);
  update cps.accounts set spins = spins + 1, last_daily_spin = today
    where id = a.id and coalesce(last_daily_spin, date '1970-01-01') < today and spins < 10;
  get diagnostics n = row_count;
  if n > 0 then
    insert into cps.spin_grants (account_id, spins, reason) values (a.id, 1, 'daily');
  end if;
  return cps.state_json(a.id);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
