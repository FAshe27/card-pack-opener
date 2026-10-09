-- =====================================================================
-- 009_fav_holo.sql — profile favorites now say whether the owner has a
-- holo copy, so favorites render holographic in profiles.
-- =====================================================================

create or replace function public.cps_get_profile(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  tgt cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into tgt from cps.accounts where id = p_account and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  return jsonb_build_object(
    'id', tgt.id,
    'display_name', tgt.display_name,
    'is_me', tgt.id = a.id,
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', f.set_id,
                'card_id', f.card_id,
                'holo', coalesce((select c.holo_count > 0 from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = f.set_id
                                    and c.card_id = f.card_id), false))
              order by f.created_at)
            from cps.favorites f where f.account_id = tgt.id), '[]'),
    'sets', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', s.id,
                'set_name', s.name,
                'unique', (select count(*) from cps.collection c
                            where c.account_id = tgt.id and c.set_id = s.id and c.count > 0),
                'total', (select count(*) from cps.cards k where k.set_id = s.id))
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
