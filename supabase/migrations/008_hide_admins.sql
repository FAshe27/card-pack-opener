-- =====================================================================
-- 008_hide_admins.sql — admin accounts no longer appear in the public
-- player list (they're managers, not players).
-- =====================================================================

create or replace function public.cps_list_players(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id,
      'display_name', x.display_name,
      'is_me', x.id = a.id,
      'favorites', (select count(*) from cps.favorites where account_id = x.id),
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0)
    ) order by x.display_name)
    from cps.accounts x where not x.disabled and not x.is_admin), '[]');
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
