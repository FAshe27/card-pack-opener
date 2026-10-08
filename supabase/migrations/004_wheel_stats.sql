-- =====================================================================
-- 004_wheel_stats.sql — expose total spins used per account in the admin list.
-- Requires 003_wheel.sql (uses cps.spin_grants).
-- =====================================================================

create or replace function public.cps_admin_list_accounts(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'display_name', x.display_name, 'hint', x.username_hint, 'is_admin', x.is_admin, 'disabled', x.disabled,
      'created_at', x.created_at, 'last_login_at', x.last_login_at,
      'packs', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = x.id), '{}'),
      'spins', x.spins,
      'spins_done', (select count(*) from cps.spin_grants where account_id = x.id and reason = 'wheel'),
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0),
      'opened', coalesce((select sum(opened) from cps.user_set_stats where account_id = x.id), 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x), '[]');
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
