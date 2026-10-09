-- =====================================================================
-- 028_jumbled.sql — "Jumbled Mess" packs: 5 cards, each from a random set.
--   1. Inserts a card_sets row for 'jumbled' (active=false, so it stays out
--      of online_sets and the auto-generated wheel segments; it exists only
--      to satisfy pack_inventory's FK).
--   2. Rebuilds cps_open_pack (from 027's version — keeps no-admin-variants,
--      big_pulls, chase/variant announcements): p_set='jumbled' opens a
--      5-card pack where each card picks a random active set, rolls rarity
--      with that set's odds, and lands in that set's collection/stats.
--      Each card in the returned `cards` array carries its `set_id`.
--   3. cps.wheel_config: appends a "1 x Jumbled Mess" segment (weight 1) to
--      each wheel.
-- (Run after 027.)
-- =====================================================================

insert into cps.card_sets (id, name, code, pack, card_count, active)
values ('jumbled', 'Jumbled Mess', 'JUMBLED',
        '{"name":"Jumbled Mess","slots":[{"count":5,"label":"Jumbled cards","odds":{"common":1}}],"holo":{}}',
        0, false)
on conflict (id) do nothing;

create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text; chase_e record;
        -- jumbled additions
        is_jumbled boolean; active_sets text[]; rset text; rs cps.card_sets%rowtype; slot_odds jsonb;
        vset text; set_rec record; set_n int; set_h int; set_byr jsonb; set_best jsonb; set_bscore int;
        set_st cps.user_set_stats%rowtype; card_rec record; cscore int;
begin
  a := cps.auth(p_token);
  is_jumbled := (p_set = 'jumbled');

  if is_jumbled then
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = 'jumbled' for update;
    if coalesce(inv, 0) < 1 then raise exception 'No Jumbled Mess packs left.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = 'jumbled' returning packs into inv;
    select coalesce(array_agg(id order by id), '{}') into active_sets from cps.card_sets where active and id <> 'jumbled';
    if coalesce(array_length(active_sets, 1), 0) = 0 then raise exception 'No sets available for Jumbled Mess.'; end if;
  else
    select * into s from cps.card_sets where id = p_set and active;
    if not found then raise exception 'This set is not available online yet.'; end if;
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = p_set for update;
    if coalesce(inv, 0) < 1 then raise exception 'No packs left for this set.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = p_set returning packs into inv;

    select * into st from cps.user_set_stats where account_id = a.id and set_id = p_set for update;
    best_score := case when st.best is null then -1
                       else cps.rarity_rank((select rarity from cps.cards where set_id = p_set and card_id = st.best->>'id')) * 10
                            + case when (st.best->>'holo')::boolean then 5 else 0 end end;
    best_score := coalesce(best_score, -1);
  end if;

  -- Card loop. For jumbled we synthesize a 5-card slot list; each card then
  -- picks its own random set and uses that set's odds/holo rates.
  for slot in select value from jsonb_array_elements(
               case when is_jumbled
                    then '[{"count":5,"odds":{"common":1}}]'::jsonb
                    else s.pack->'slots' end) loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      if is_jumbled then
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        select * into rs from cps.card_sets where id = rset;
        slot_odds := rs.pack->'slots'->0->'odds';
      else
        rset := p_set;
        rs := s;
        slot_odds := slot->'odds';
      end if;

      x := cps.rand01(); acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot_odds) order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      select card_id into cid from cps.cards where set_id = rset and rarity = r and not ((rset || ':' || card_id) = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = rset and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', rset, r; end if;
      holo := cps.rand01() * 100 < coalesce((rs.pack->'holo'->>r)::float8, 0);
      picked := picked || (rset || ':' || cid);

      select count into prev_count from cps.collection where account_id = a.id and set_id = rset and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0;
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, rset, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      if not is_jumbled then
        sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
        if sc > best_score then
          best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
          best_changed := st.best is not null or best_changed;
        end if;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'set_id', rset, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  -- numbered variant lottery: 1% of packs; one random rare+ card becomes a variant
  -- (admins never mint variants — they can grant themselves packs)
  vserial := null;
  if not coalesce(a.is_admin, false) and cps.rand01() < 0.01 then
    select array_agg(t.idx) into vidx from (
      select (row_number() over ()) - 1 as idx
      from jsonb_array_elements(out) e
      where e->>'rarity' in ('rare','epic','legendary','chase')
    ) t;
    if vidx is not null and coalesce(array_length(vidx, 1), 0) > 0 then
      vi := vidx[1 + floor(cps.rand01() * array_length(vidx, 1))::int];
      vcid := out->vi->>'id';
      vset := out->vi->>'set_id';
      vx := cps.rand01();
      vtier := case when vx < 0.70 then 'rainbow' when vx < 0.90 then 'prism' when vx < 0.98 then 'obsidian' else 'oneofone' end;
      vtiers := case vtier
        when 'rainbow' then array['rainbow']
        when 'prism' then array['prism','rainbow']
        when 'obsidian' then array['obsidian','prism','rainbow']
        else array['oneofone','obsidian','prism','rainbow'] end;
      foreach vt in array vtiers loop
        vserial := cps.mint_variant(a.id, vset, vcid, vt);
        if vserial is not null then vtier := vt; exit; end if;
      end loop;
      if vserial is not null then
        out := (select jsonb_agg(case when t.rn = vi
            then t.e || jsonb_build_object('variant', vtier, 'serial', vserial)
            else t.e end order by t.rn)
          from (select e, (row_number() over ()) - 1 as rn from jsonb_array_elements(out) e) t);
        if vtier in ('prism','obsidian','oneofone','rainbow') then
          select kk.name into vcardname from cps.cards kk where kk.set_id = vset and kk.card_id = vcid;
          select ss.name into vtext from cps.card_sets ss where ss.id = vset;
          vtext := case vtier
            when 'oneofone' then '🌈 ' || a.display_name || ' pulled the One-of-One ' || vcardname || ' (' || vtext || ')!'
            when 'obsidian' then '🌈 ' || a.display_name || ' pulled Obsidian #' || vserial || '/5 ' || vcardname || ' (' || vtext || ')!'
            when 'rainbow' then '🌈 ' || a.display_name || ' pulled Rainbow #' || vserial || '/50 ' || vcardname || ' (' || vtext || ')!'
            else '🌈 ' || a.display_name || ' pulled Prism #' || vserial || '/10 ' || vcardname || ' (' || vtext || ')!'
          end;
          insert into cps.notifications (account_id, kind, text, target_view)
            select xx.id, 'variant_pull', vtext, 'collection'
            from cps.accounts xx where xx.id <> a.id and not xx.disabled;
        end if;
      end if;
    end if;
  end if;

  -- record big pulls + global chase announcements (everyone except the puller)
  for chase_e in select e from jsonb_array_elements(out) e where e->>'rarity' in ('legendary','chase') loop
    insert into cps.big_pulls (account_id, set_id, card_id, rarity)
      values (a.id, chase_e.e->>'set_id', chase_e.e->>'id', chase_e.e->>'rarity');
    if chase_e.e->>'rarity' = 'chase' then
      select kk.name into vcardname from cps.cards kk where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      select ss.name into vtext from cps.card_sets ss where ss.id = chase_e.e->>'set_id';
      vtext := '🎯 ' || a.display_name || ' pulled ' || vcardname || ' (Chase · ' || vtext || ')!';
      insert into cps.notifications (account_id, kind, text, target_view)
        select xx.id, 'chase_pull', vtext, 'collection'
        from cps.accounts xx where xx.id <> a.id and not xx.disabled;
    end if;
  end loop;

  -- daily quest bumps
  perform cps.quest_bump(a.id, 'open_packs', 1);
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
      perform cps.quest_bump(a.id, 'open_packs_set', 1, set_rec.sid);
    end loop;
  else
    perform cps.quest_bump(a.id, 'open_packs_set', 1, p_set);
  end if;
  if n_holo > 0 then
    perform cps.quest_bump(a.id, 'pull_holo', n_holo);
    perform cps.quest_bump(a.id, 'pull_holos_3', n_holo);
  end if;
  perform cps.quest_bump(a.id, 'pull_rare_plus',
    coalesce((by_r->>'rare')::int, 0) + coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_epic_plus',
    coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_legendary_plus',
    coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_chase', coalesce((by_r->>'chase')::int, 0));
  if vserial is not null then perform cps.quest_bump(a.id, 'pull_variant', 1); end if;

  -- per-set stats
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
      select count(*), coalesce(sum((e->>'holo')::int), 0)
        into set_n, set_h
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid;
      select coalesce(jsonb_object_agg(rkey, rcount), '{}') into set_byr from (
        select e->>'rarity' as rkey, count(*) as rcount
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid group by 1) t;
      -- best card of this set in this pack
      select e into card_rec from jsonb_array_elements(out) e
        where e->>'set_id' = set_rec.sid
        order by cps.rarity_rank(e->>'rarity') * 10 + case when (e->>'holo')::boolean then 5 else 0 end desc
        limit 1;
      set_best := null;
      if card_rec.e is not null then
        select * into set_st from cps.user_set_stats where account_id = a.id and set_id = set_rec.sid for update;
        set_bscore := case when set_st.best is null then -1
          else cps.rarity_rank((select rarity from cps.cards where set_id = set_rec.sid and card_id = set_st.best->>'id')) * 10
               + case when (set_st.best->>'holo')::boolean then 5 else 0 end end;
        set_bscore := coalesce(set_bscore, -1);
        cscore := cps.rarity_rank(card_rec.e->>'rarity') * 10 + case when (card_rec.e->>'holo')::boolean then 5 else 0 end;
        if cscore > set_bscore then
          set_best := jsonb_build_object('id', card_rec.e->>'id', 'holo', (card_rec.e->>'holo')::boolean, 'at', now());
        end if;
      end if;
      insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
        values (a.id, set_rec.sid, 1, set_n, set_h, set_byr, set_best)
        on conflict (account_id, set_id) do update set
          opened = cps.user_set_stats.opened + 1,
          pulled = cps.user_set_stats.pulled + excluded.pulled,
          holos  = cps.user_set_stats.holos + excluded.holos,
          by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                        select key, sum(value::int) as total from (
                          select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                          union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
          best = coalesce(excluded.best, cps.user_set_stats.best);
    end loop;
  else
    insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
      values (a.id, p_set, 1, jsonb_array_length(out), n_holo, by_r, new_best)
      on conflict (account_id, set_id) do update set
        opened = cps.user_set_stats.opened + 1,
        pulled = cps.user_set_stats.pulled + excluded.pulled,
        holos  = cps.user_set_stats.holos + excluded.holos,
        by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                      select key, sum(value::int) as total from (
                        select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                        union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
        best = coalesce(excluded.best, cps.user_set_stats.best);
  end if;

  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'set_id', e->>'set_id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e));

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out,
    'best', case when is_jumbled then null
                else (select best from cps.user_set_stats where account_id = a.id and set_id = p_set) end,
    'new_best', (not is_jumbled) and best_changed and new_best is not null);
end $$;

-- --- wheel: add a "1 x Jumbled Mess" segment to each wheel -------------------
create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;

  -- Wheel 1: 1 pack per set + 1 Jumbled Mess + gateway to wheel 2 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w1 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 1, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 1, 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
  ) x;

  -- Wheel 2: 2 packs per set + 1 Jumbled Mess + back to w1 + gateway to w3 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 1, 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
  ) x;

  -- Wheel 3: 3 packs per set + 1 Jumbled Mess + back to w1 + back to w2 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 1, 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Back to second wheel', 'weight', 1)
  ) x;

  return jsonb_build_object('wheels', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'name', 'Prize Wheel',  'segments', w1),
    jsonb_build_object('id', 'w2', 'name', 'Double Wheel', 'segments', w2),
    jsonb_build_object('id', 'w3', 'name', 'Triple Wheel', 'segments', w3)
  ));
end $$;
