-- =====================================================================
-- 007_favorites.sql — card favorites (max 20 per account) + public player
-- profiles. Favorites are visible to all logged-in users.
-- =====================================================================

create table if not exists cps.favorites (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id     text not null,
  card_id    text not null,
  created_at timestamptz not null default now(),
  primary key (account_id, set_id, card_id),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);
create index if not exists favorites_account_idx on cps.favorites (account_id, created_at);

-- Toggle a favorite. Only cards the player owns can be favorited; max 20.
create or replace function public.cps_toggle_favorite(p_token text, p_set text, p_card text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  n   int;
  did boolean;
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
    insert into cps.favorites (account_id, set_id, card_id) values (a.id, p_set, p_card);
    did := true;
  end if;
  select count(*) into n from cps.favorites where account_id = a.id;
  return jsonb_build_object('favorited', did, 'count', n);
end $$;

-- Public player list (any logged-in user).
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
    from cps.accounts x where not x.disabled), '[]');
end $$;

-- Public profile: favorites + per-set completion (any logged-in user).
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
    'favorites', coalesce((select jsonb_agg(jsonb_build_object('set_id', f.set_id, 'card_id', f.card_id)
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

-- state_json now also carries the player's own favorites.
create or replace function cps.state_json(p_account uuid) returns jsonb
language sql stable set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from cps.pack_openings o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config(),
    'favorites', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id) order by created_at)
                           from cps.favorites where account_id = p_account), '[]')
  )
$$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';

-- anon key needs execute rights on the new functions
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_toggle_favorite(text, text, text) to anon;
    grant execute on function public.cps_list_players(text) to anon;
    grant execute on function public.cps_get_profile(text, uuid) to anon;
  end if;
end $$;
