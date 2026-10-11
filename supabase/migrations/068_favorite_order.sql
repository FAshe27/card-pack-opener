-- =====================================================================
-- 068_favorite_order.sql — manual ordering for profile favorites.
-- Adds a position column; profiles return favorites in position order.
-- =====================================================================

alter table cps.favorites add column if not exists position int;

-- Backfill: existing favorites get positions in created_at order (0,1,2...)
do $$
declare
  acct uuid;
  r record;
  n int;
begin
  for acct in select account_id from cps.favorites group by account_id loop
    n := 0;
    for r in select set_id, card_id from cps.favorites
             where account_id = acct order by created_at loop
      update cps.favorites set position = n
        where account_id = acct and set_id = r.set_id and card_id = r.card_id;
      n := n + 1;
    end loop;
  end loop;
end $$;

-- New favorites go at the end.
create or replace function public.cps_toggle_favorite(p_token text, p_set text, p_card text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  n   int;
  did boolean;
  pos int;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.cards where set_id = p_set and card_id = p_card) then
    raise exception 'Card not found.';
  end if;
  if not exists (select 1 from cps.collection
                  where account_id = a.id and set_id = p_set and card_id = p_card and count > 0) then
    raise exception 'You can only favorite cards you own.';
  end if;
  if exists (select 1 from cps.favorites where account_id = a.id and set_id = p_set and card_id = p_card) then
    delete from cps.favorites where account_id = a.id and set_id = p_set and card_id = p_card;
    did := false;
  else
    select count(*) into n from cps.favorites where account_id = a.id;
    if n >= 20 then raise exception 'You can only favorite 20 cards. Unfavorite one first.'; end if;
    select coalesce(max(position), -1) + 1 into pos from cps.favorites where account_id = a.id;
    insert into cps.favorites (account_id, set_id, card_id, position) values (a.id, p_set, p_card, pos);
    did := true;
  end if;
  select count(*) into n from cps.favorites where account_id = a.id;
  return jsonb_build_object('favorited', did, 'count', n);
end $$;

-- Reorder favorites. p_order is a JSON array of {set_id, card_id} in the desired order.
create or replace function public.cps_reorder_favorites(p_token text, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  it  jsonb;
  i   int := 0;
begin
  a := cps.auth(p_token);
  if jsonb_typeof(p_order) != 'array' then raise exception 'Order must be an array.'; end if;
  for it in select * from jsonb_array_elements(p_order) loop
    if not exists (select 1 from cps.favorites
                    where account_id = a.id
                      and set_id = it ->> 'set_id'
                      and card_id = it ->> 'card_id') then
      raise exception 'Not a favorite: %', it ->> 'card_id';
    end if;
  end loop;
  for it in select * from jsonb_array_elements(p_order) loop
    update cps.favorites set position = i
      where account_id = a.id and set_id = it ->> 'set_id' and card_id = it ->> 'card_id';
    i := i + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', i);
end $$;

-- Profiles return favorites in manual position order (032 base + order change).
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
              order by f.position, f.created_at)
            from cps.favorites f where f.account_id = tgt.id), '[]'),
    'collection', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', c.set_id, 'card_id', c.card_id, 'n', c.count, 'h', c.holo_count,
                'variants', coalesce((select jsonb_agg(jsonb_build_object(
                                        'tier', v.tier, 'serial', v.serial)
                                      order by v.serial)
                                    from cps.variants v
                                    where v.account_id = tgt.id
                                      and v.set_id = c.set_id
                                      and v.card_id = c.card_id), '[]'))
              order by c.set_id, c.card_id)
            from cps.collection c where c.account_id = tgt.id and c.count > 0), '[]'),
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

notify pgrst, 'reload schema';
