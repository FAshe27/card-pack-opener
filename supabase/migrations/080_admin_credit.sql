-- =====================================================================
-- 080_admin_credit.sql — Admin grant for Store Credit.
-- =====================================================================

create or replace function public.cps_admin_grant_credit(p_token text, p_account uuid, p_credit int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  credit_now int;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  update cps.accounts set store_credit = greatest(0, store_credit + p_credit)
    where id = p_account;
  select store_credit into credit_now from cps.accounts where id = p_account;
  return jsonb_build_object('ok', true, 'credit_now', credit_now);
end $$;

notify pgrst, 'reload schema';
