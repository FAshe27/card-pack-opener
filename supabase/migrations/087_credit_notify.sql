-- =====================================================================
-- 087_credit_notify.sql — Add notifications for Store Credit gifts.
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
  perform cps.notify(p_account, 'gift_credit',
    'You''ve been gifted $' || p_credit || ' in Store Credit!', 'shop');
  return jsonb_build_object('ok', true, 'credit_now', credit_now);
end $$;

create or replace function public.cps_admin_grant_credit_all(p_token text, p_credit int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  n int := 0;
  r record;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  for r in select id from cps.accounts where not is_admin and not disabled loop
    update cps.accounts set store_credit = greatest(0, store_credit + p_credit)
      where id = r.id;
    perform cps.notify(r.id, 'gift_credit',
      'You''ve been gifted $' || p_credit || ' in Store Credit!', 'shop');
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'players', n);
end $$;

notify pgrst, 'reload schema';
