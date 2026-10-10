-- =====================================================================
-- 038_new_daily_quests.sql -- 6 new daily quests (20 total).
--   Easy: open_jumbled, pull_dupe, pull_holo_common, pull_letter
--   Medium: pull_3_sets
--   Hard: pull_2_holos_pack
-- (Run after 037.)
-- =====================================================================

-- --- quest tiers ------------------------------------------------------------
create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done',
                             'pull_3_sets') then 'medium'
              else 'hard' end $$;

-- --- quest targets ----------------------------------------------------------
create or replace function cps.quest_target(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_key when 'open_packs' then 3 when 'open_packs_set' then 2 when 'pull_holos_3' then 3
    when 'pull_3_sets' then 3 when 'pull_2_holos_pack' then 2 else 1 end $$;

-- --- quest titles -----------------------------------------------------------
create or replace function cps.quest_title(p_key text, p_meta jsonb) returns text
language plpgsql set search_path = cps, pg_temp as $$
declare sname text;
begin
  if p_key = 'open_packs_set' then
    select s.name into sname from cps.card_sets s where s.id = p_meta->>'set_id';
    return 'Open 2 ' || coalesce(sname, 'set') || ' packs';
  end if;
  if p_key = 'pull_letter' then
    return 'Pull a card with "' || coalesce(p_meta->>'letter', '?') || '" in the name';
  end if;
  return case p_key
    when 'open_packs' then 'Open 3 packs'
    when 'spin_wheel' then 'Spin the wheel'
    when 'dupe_trade' then 'Trade in duplicates'
    when 'pull_holo' then 'Pull a holo card'
    when 'pull_rare_plus' then 'Pull a Rare or better'
    when 'pull_epic_plus' then 'Pull an Epic or better'
    when 'gift_card' then 'Gift a card to a friend'
    when 'trade_done' then 'Complete a trade'
    when 'pull_legendary_plus' then 'Pull a Legendary or better'
    when 'pull_chase' then 'Pull a Chase card'
    when 'pull_variant' then 'Pull a numbered variant'
    when 'wheel_big_win' then 'Win 3+ packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    else p_key end;
end $$;

-- --- assign: add 6 new quests -----------------------------------------------
create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  k text; sid text; vletter text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  -- deterministic featured set per account per day
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select id into sid from cps.card_sets where active order by random() limit 1;
  -- deterministic random letter per account per day (A-Z)
  perform setseed(('x' || substr(md5('letter' || p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select chr(65 + floor(random() * 26)::int) into vletter;
  foreach k in array array['open_packs','open_packs_set','spin_wheel','dupe_trade',
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $$;


-- --- open_pack rebuild with new quest hooks ------------------------------------
create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text; chase_e record;
        vletter text;
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
    select coalesce(array_agg(id order by id), '{}') into active_sets from cps.card_sets where active and id <> 'jumbled' and not coalesce(exclude_from_jumbled, false);
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
        -- Jumbled Mess: guaranteed uncommon or better (it's a special pack!).
        -- First 4 cards use boosted wild odds (no commons); 5th uses the set's
        -- "rare or better" slot.
        if i <= 4 then
          slot_odds := '{"uncommon": 62, "rare": 26, "epic": 10, "legendary": 2}'::jsonb;
        else
          slot_odds := coalesce(rs.pack->'slots'->3->'odds',
                                '{"rare": 81.8, "epic": 14, "legendary": 4, "chase": 0.2}'::jsonb);
        end if;
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
        -- numbered variants qualify for Latest big pull
        insert into cps.big_pulls (account_id, set_id, card_id, rarity, variant_tier, variant_serial)
          values (a.id, vset, vcid,
                  (select kk.rarity from cps.cards kk where kk.set_id = vset and kk.card_id = vcid),
                  vtier, vserial);
        end if;
      end if;
    end if;
  end if;

  -- record big pulls: Chase cards only (Legendary no longer qualifies) + global chase announcements
  for chase_e in select e from jsonb_array_elements(out) e where e->>'rarity' = 'chase' loop
    insert into cps.big_pulls (account_id, set_id, card_id, rarity)
      values (a.id, chase_e.e->>'set_id', chase_e.e->>'id', 'chase');
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

  -- --- 6 new daily quests -------------------------------------------------
  -- open_jumbled
  if is_jumbled then perform cps.quest_bump(a.id, 'open_jumbled', 1); end if;
  -- pull_dupe, pull_holo_common, pull_letter (per-card)
  select q.meta->>'letter' into vletter
  from cps.daily_quests q
  where q.account_id = a.id
    and q.day = (now() at time zone 'America/Chicago')::date
    and q.quest_key = 'pull_letter';
  for chase_e in select e from jsonb_array_elements(out) e loop
    if not coalesce((chase_e.e->>'new')::boolean, true) then
      perform cps.quest_bump(a.id, 'pull_dupe', 1);
    end if;
    if chase_e.e->>'rarity' = 'common' and coalesce((chase_e.e->>'holo')::boolean, false) then
      perform cps.quest_bump(a.id, 'pull_holo_common', 1);
    end if;
    if vletter is not null then
      select kk.name into vcardname from cps.cards kk
      where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      if vcardname ilike '%' || vletter || '%' then
        perform cps.quest_bump(a.id, 'pull_letter', 1);
      end if;
    end if;
  end loop;
  -- pull_2_holos_pack
  if n_holo >= 2 then perform cps.quest_bump(a.id, 'pull_2_holos_pack', 1); end if;
  -- pull_3_sets: track distinct home sets in meta
  for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
    update cps.daily_quests q
    set meta = jsonb_build_object('sets',
              (select coalesce(jsonb_agg(distinct sx), '[]'::jsonb)
               from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                     union select set_rec.sid as sx) sub)),
        progress = (select count(distinct sx)
                    from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                          union select set_rec.sid as sx) sub),
        done = (select count(distinct sx) >= 3
                from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                      union select set_rec.sid as sx) sub)
    where q.account_id = a.id
      and q.day = (now() at time zone 'America/Chicago')::date
      and q.quest_key = 'pull_3_sets'
      and q.claimed_at is null;
  end loop;

  -- per-set stats
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
      select count(*), coalesce(sum(case when (e->>'holo')::boolean then 1 else 0 end), 0)
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
