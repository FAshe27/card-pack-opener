-- =====================================================================
-- 037_daily_three_spins.sql — the daily free spin grant becomes 3 tickets
-- (was 1). Still skipped while the player holds 10+ spins.
-- (Run after 036.)
-- =====================================================================

create or replace function public.cps_get_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
begin
  a := cps.auth(p_token);
  update cps.accounts set spins = spins + 3, last_daily_spin = today
    where id = a.id and coalesce(last_daily_spin, date '1970-01-01') < today and spins < 10;
  get diagnostics n = row_count;
  if n > 0 then
    insert into cps.spin_grants (account_id, spins, reason) values (a.id, 3, 'daily');
  end if;
  return cps.state_json(a.id);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
