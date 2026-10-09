-- =====================================================================
-- 018_grant_packs_all.sql — admin grants packs of a set to every
-- non-admin, non-disabled player at once (e.g. when a new set drops).
-- Each recipient gets the usual "You've been gifted N packs (Set)!"
-- notification.
-- =====================================================================

create or replace function public.cps_admin_grant_packs_all(p_token text, p_set text, p_packs int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; n int := 0; r record; set_name text;
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.card_sets where id = p_set) then raise exception 'That set is not on the server yet.'; end if;
  if p_packs is null or p_packs < 1 or p_packs > 999 then raise exception 'Packs must be between 1 and 999.'; end if;
  select s.name into set_name from cps.card_sets s where s.id = p_set;
  for r in select id from cps.accounts where not is_admin and not disabled loop
    perform cps.add_packs(r.id, p_set, p_packs, 'admin_grant_all', null, a.id);
    perform cps.notify(r.id, 'gift_pack',
      'You''ve been gifted ' || case when p_packs = 1 then 'a pack' else p_packs || ' packs' end ||
      ' (' || coalesce(set_name, p_set) || ')!', 'packs');
    n := n + 1;
  end loop;
  return jsonb_build_object('set_id', p_set, 'packs_each', p_packs, 'players', n);
end $$;

grant execute on function public.cps_admin_grant_packs_all(text, text, int) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
