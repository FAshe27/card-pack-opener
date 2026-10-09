-- =====================================================================
-- 026_global_stats_and_chase_alerts.sql
--   1. cps_global_pull_stats(): total cards pulled by all users + per-rarity
--      counters (for the Stats screen "All players" box).
--   2. Chase pulls now trigger a global notification (like numbered variants).
--   3. Rainbow numbered pulls join the global variant announcements.
-- (Run after 025.)
-- =====================================================================

create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text; chase_e record;
begin
  a := cps.auth(p_token);
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

  for slot in select value from jsonb_array_elements(s.pack->'slots') loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      x := cps.rand01(); acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot->'odds') order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      select card_id into cid from cps.cards where set_id = p_set and rarity = r and not (card_id = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = p_set and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', p_set, r; end if;
      holo := cps.rand01() * 100 < coalesce((s.pack->'holo'->>r)::float8, 0);
      picked := picked || cid;

      select count into prev_count from cps.collection where account_id = a.id and set_id = p_set and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0;
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, p_set, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
      if sc > best_score then
        best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
        best_changed := st.best is not null or best_changed;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  -- numbered variant lottery: 1% of packs; one random rare+ card becomes a variant
  vserial := null;
  if cps.rand01() < 0.01 then
    select array_agg(t.idx) into vidx from (
      select (row_number() over ()) - 1 as idx
      from jsonb_array_elements(out) e
      where e->>'rarity' in ('rare','epic','legendary','chase')
    ) t;
    if vidx is not null and coalesce(array_length(vidx, 1), 0) > 0 then
      vi := vidx[1 + floor(cps.rand01() * array_length(vidx, 1))::int];
      vcid := out->vi->>'id';
      vx := cps.rand01();
      vtier := case when vx < 0.70 then 'rainbow' when vx < 0.90 then 'prism' when vx < 0.98 then 'obsidian' else 'oneofone' end;
      vtiers := case vtier
        when 'rainbow' then array['rainbow']
        when 'prism' then array['prism','rainbow']
        when 'obsidian' then array['obsidian','prism','rainbow']
        else array['oneofone','obsidian','prism','rainbow'] end;
      foreach vt in array vtiers loop
        vserial := cps.mint_variant(a.id, p_set, vcid, vt);
        if vserial is not null then vtier := vt; exit; end if;
      end loop;
      if vserial is not null then
        out := (select jsonb_agg(case when t.rn = vi
            then t.e || jsonb_build_object('variant', vtier, 'serial', vserial)
            else t.e end order by t.rn)
          from (select e, (row_number() over ()) - 1 as rn from jsonb_array_elements(out) e) t);
        if vtier in ('prism','obsidian','oneofone','rainbow') then
          select kk.name into vcardname from cps.cards kk where kk.set_id = p_set and kk.card_id = vcid;
          vtext := case vtier
            when 'oneofone' then '🌈 ' || a.display_name || ' pulled the One-of-One ' || vcardname || ' (' || s.name || ')!'
            when 'obsidian' then '🌈 ' || a.display_name || ' pulled Obsidian #' || vserial || '/5 ' || vcardname || ' (' || s.name || ')!'
            when 'rainbow' then '🌈 ' || a.display_name || ' pulled Rainbow #' || vserial || '/50 ' || vcardname || ' (' || s.name || ')!'
            else '🌈 ' || a.display_name || ' pulled Prism #' || vserial || '/10 ' || vcardname || ' (' || s.name || ')!'
          end;
          insert into cps.notifications (account_id, kind, text, target_view)
            select xx.id, 'variant_pull', vtext, 'collection'
            from cps.accounts xx where xx.id <> a.id and not xx.disabled;
        end if;
      end if;
    end if;
  end if;

  -- global chase announcements (everyone except the puller)
  for chase_e in select e from jsonb_array_elements(out) e where e->>'rarity' = 'chase' loop
    select kk.name into vcardname from cps.cards kk where kk.set_id = p_set and kk.card_id = chase_e.e->>'id';
    vtext := '🎯 ' || a.display_name || ' pulled ' || vcardname || ' (Chase · ' || s.name || ')!';
    insert into cps.notifications (account_id, kind, text, target_view)
      select xx.id, 'chase_pull', vtext, 'collection'
      from cps.accounts xx where xx.id <> a.id and not xx.disabled;
  end loop;

  -- daily quest bumps
  perform cps.quest_bump(a.id, 'open_packs', 1);
  perform cps.quest_bump(a.id, 'open_packs_set', 1, p_set);
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
  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e));

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out,
    'best', (select best from cps.user_set_stats where account_id = a.id and set_id = p_set), 'new_best', best_changed and new_best is not null);
end $$;

-- --- global pull stats -------------------------------------------------------------
-- (p_token overload coexists with the old zero-arg version; PostgREST routes by args)
create or replace function public.cps_global_pull_stats(p_token text)
returns jsonb language sql security definer set search_path = cps, pg_temp as $$
  with agg as (
    select coalesce(sum(pulled), 0) as pulled,
           coalesce(sum(holos), 0) as holos
    from cps.user_set_stats
  ), rar as (
    select v.key as rarity, sum((v.value)::int) as n
    from cps.user_set_stats, jsonb_each_text(by_rarity) as v(key, value)
    group by v.key
  )
  select jsonb_build_object(
    'pulled', (select pulled from agg),
    'holos', (select holos from agg),
    'by_rarity', coalesce((select jsonb_object_agg(rarity, n) from rar), '{}'::jsonb)
  );
$$;

grant execute on function public.cps_global_pull_stats() to anon;

-- let the API pick up the changes right away
notify pgrst, 'reload schema';
