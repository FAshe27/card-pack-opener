-- =====================================================================
-- 081_admin_credit_all.sql — Admin grant Store Credit to all players.
-- =====================================================================

create or replace function public.cps_admin_grant_credit_all(p_token text, p_credit int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  n int;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  update cps.accounts set store_credit = greatest(0, store_credit + p_credit)
    where not is_admin;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'players', n);
end $$;

notify pgrst, 'reload schema';
