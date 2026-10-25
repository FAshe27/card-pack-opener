-- 183_perf_batch.sql
-- EXECUTED 2026-10-25 via the Supabase connector on Franklin's go
-- ("Push the client and run migration 183"). UX audit round 3
-- (performance batch). Rollback-verified beforehand on the live DB
-- (old vs new identical on fixtures, payload 1,362,802 -> 1,119,227
-- bytes on the largest account). Client shipped first (commit
-- 5b9003d2) with dual-shape turn_ins ingestion.
--
-- Four parts, all server-side:
-- 1. cps.state_json: the turn_ins block changes wire shape from a flat
--    array of [set_id, card_id] pairs to a per-set map
--    {set_id: [card_id, ...]}. Same information, ~280 KB smaller on the
--    largest account (539 KB -> ~258 KB of a 1.35 MB state). The client
--    ships FIRST with dual-shape ingestion, so old and new payloads
--    both parse during the transition.
-- 2. cps_milestone_sync: short-circuit when the account's turn-ins
--    count matches the snapshot's stored count (turn-ins are
--    insert-only, so an unchanged count means completions cannot have
--    changed). Adds cps.milestone_snapshots.ti_count.
-- 3. public.cps_turn_in_all_sets: set-based rewrite of the
--    row-at-a-time loop (per-row lock + variants count + update +
--    insert). Classification arithmetic is byte-for-byte the original
--    logic, including its precedence (plain copy first, holo only when
--    asked, variants/vaulted copies count as unavailable).
-- 4. NEW public.cps_game_state: returns the caller's active High/Low
--    run (if any) so the client can resume it after a page reload —
--    High/Low was the only arcade game that forfeited the run.

-- ------------------------------------------------------------ part 1
create or replace function cps.state_json(p_account uuid)
 returns jsonb
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value || jsonb_build_object('at', (extract(epoch from o.opened_at) * 1000)::bigint) as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from (select o0.account_id, o0.set_id, o0.opened_at, o0.cards
                          from (select o1.account_id, o1.set_id, o1.opened_at, o1.cards,
                                       coalesce(sum(jsonb_array_length(o1.cards)) over (partition by o1.set_id order by o1.opened_at desc, o1.id desc), 0)
                                         - jsonb_array_length(o1.cards) as prior_cards
                                  from cps.pack_openings o1
                                 where o1.account_id = p_account and o1.opened_at > now() - interval '120 days') o0
                         where o0.prior_cards < 36) o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config(),
    'favorites', coalesce((select jsonb_agg(jsonb_build_array(u.set_id, u.card_id) order by vo.position nulls last, u.set_id, u.card_id)
                           from (select set_id, card_id from cps.collection where account_id = p_account and vaulted_count > 0
                                 union
                                 select set_id, card_id from cps.variants where account_id = p_account and vaulted) u
                           left join cps.vault_order vo
                             on vo.account_id = p_account and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'turn_ins', coalesce((select jsonb_object_agg(g.set_id, g.ids)
                           from (select set_id, jsonb_agg(card_id order by card_id) as ids
                                   from cps.turn_ins where account_id = p_account
                                  group by set_id) g), '{}')
  )
$function$;

-- ------------------------------------------------------------ part 2
alter table cps.milestone_snapshots
  add column if not exists ti_count bigint;

create or replace function public.cps_milestone_sync(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'cps', 'pg_temp'
as $function$
declare
  a            cps.accounts%rowtype;
  v_rar        jsonb;
  v_full       jsonb;
  v_old_rar    jsonb;
  v_old_full   jsonb;
  v_fresh_rar  jsonb := '[]'::jsonb;
  v_fresh_full jsonb := '[]'::jsonb;
  k            text;
  v_cnt        bigint;
  v_snap_cnt   bigint;
begin
  a := cps.auth(p_token);

  -- Short-circuit (183): turn-ins are insert-only, so if the account's
  -- turn-ins count still matches the snapshot's, no completion can
  -- have changed and the two aggregation passes below cannot find
  -- anything fresh. One indexed count replaces them.
  select count(*) into v_cnt from cps.turn_ins where account_id = a.id;
  select ti_count into v_snap_cnt from cps.milestone_snapshots where account_id = a.id;
  if v_snap_cnt is not null and v_cnt = v_snap_cnt then
    return jsonb_build_object('ok', true, 'baseline', false,
      'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
  end if;

  -- Current completions, computed server-side.
  select coalesce(jsonb_object_agg(key, true), '{}'::jsonb) into v_rar
    from (
      select t.set_id || ':' || t.rarity as key
        from (select set_id, rarity, count(*) as n
                from cps.cards group by set_id, rarity) t
        join (select ti.set_id, c.rarity, count(*) as n
                from cps.turn_ins ti
                join cps.cards c
                  on c.set_id = ti.set_id and c.card_id = ti.card_id
               where ti.account_id = a.id
               group by ti.set_id, c.rarity) u
          on u.set_id = t.set_id and u.rarity = t.rarity
       where u.n >= t.n
    ) s;

  select coalesce(jsonb_object_agg(set_id, true), '{}'::jsonb) into v_full
    from (
      select t.set_id
        from (select set_id, count(*) as n
                from cps.cards group by set_id) t
        join (select set_id, count(*) as n
                from cps.turn_ins
               where account_id = a.id
               group by set_id) u
          on u.set_id = t.set_id
       where u.n >= t.n
    ) s;

  -- First ever sync for this account: silent baseline (global).
  insert into cps.milestone_snapshots (account_id, rar, full_sets, ti_count)
  values (a.id, v_rar, v_full, v_cnt)
  on conflict (account_id) do nothing;
  if found then
    return jsonb_build_object('ok', true, 'baseline', true,
      'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
  end if;

  -- Lock the snapshot row so concurrent devices serialize: the first
  -- caller advances the snapshot, later callers diff against the
  -- advanced snapshot and see nothing fresh.
  select rar, full_sets into v_old_rar, v_old_full
    from cps.milestone_snapshots
   where account_id = a.id
   for update;

  for k in select * from jsonb_object_keys(v_rar) loop
    if not (v_old_rar ? k) then
      v_fresh_rar := v_fresh_rar || jsonb_build_object(
        'set', split_part(k, ':', 1), 'rarity', split_part(k, ':', 2));
    end if;
  end loop;
  for k in select * from jsonb_object_keys(v_full) loop
    if not (v_old_full ? k) then
      v_fresh_full := v_fresh_full || to_jsonb(k);
    end if;
  end loop;

  update cps.milestone_snapshots
     set rar = v_rar, full_sets = v_full, ti_count = v_cnt, updated_at = now()
   where account_id = a.id;

  return jsonb_build_object('ok', true, 'baseline', false,
    'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
end $function$;

-- ------------------------------------------------------------ part 3
create or replace function public.cps_turn_in_all_sets(p_token text, p_include_holos boolean)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'cps', 'pg_temp'
as $function$
declare
  a    cps.accounts%rowtype;
  turned int := 0;
  skipped_holo int := 0;
  skipped_locked int := 0;
  sets_hit text[] := '{}';
  sid text;
  paid jsonb;
  by_set jsonb := '{}'::jsonb;
begin
  a := cps.auth(p_token);
  /* Set-based rewrite (183). The original loop re-read every candidate
     row FOR UPDATE and classified it with fresh values; this version
     classifies from one statement snapshot with the identical
     arithmetic and precedence, then applies one UPDATE + one INSERT.
     The UPDATE re-checks count >= 1 on the live row so a concurrent
     same-account action cannot drive a count negative; in that rare
     race the row is simply left for the next sweep (the original
     would have processed the other device's leftovers too). */
  with vn as (
    select set_id, card_id, count(*)::int as n
      from cps.variants where account_id = a.id group by set_id, card_id
  ),
  cls as (
    select c.set_id, c.card_id,
      case
        when c.count - c.vaulted_count - coalesce(vn.n, 0) < 1 then 'locked'
        when (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) >= 1 then 'plain'
        when coalesce(p_include_holos, false) then 'holo'
        else 'holo_skip'
      end as action
    from cps.collection c
    left join vn on vn.set_id = c.set_id and vn.card_id = c.card_id
    where c.account_id = a.id and c.count > 0
      and not exists (select 1 from cps.turn_ins t
                       where t.account_id = a.id and t.set_id = c.set_id and t.card_id = c.card_id)
  ),
  upd as (
    update cps.collection c
       set count = c.count - 1,
           holo_count = c.holo_count - (case when cls.action = 'holo' then 1 else 0 end)
      from cls
     where c.account_id = a.id and c.set_id = cls.set_id and c.card_id = cls.card_id
       and cls.action in ('plain', 'holo')
       and c.count >= 1
     returning c.set_id, c.card_id, cls.action
  ),
  ins as (
    insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
    select a.id, u.set_id, u.card_id, 'bulk', (u.action = 'holo') from upd u
    returning set_id
  )
  select
    (select count(*) from ins)::int,
    (select count(*) from cls where action = 'holo_skip')::int,
    (select count(*) from cls where action = 'locked')::int,
    coalesce((select array_agg(distinct set_id) from ins), '{}')
  into turned, skipped_holo, skipped_locked, sets_hit;

  foreach sid in array sets_hit loop
    paid := cps.award_turnin_rewards_for(a.id, sid);
    if jsonb_array_length(paid) > 0 then
      by_set := by_set || jsonb_build_object(sid, paid);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked,
                            'turnin_rewards_by_set', by_set);
end $function$;

-- ------------------------------------------------------------ part 4
create or replace function public.cps_game_state(p_token text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'cps', 'pg_temp'
as $function$
declare
  a   cps.accounts%rowtype;
  run cps.game_runs%rowtype;
begin
  a := cps.auth(p_token);
  select * into run from cps.game_runs
   where account_id = a.id and status = 'active'
   order by updated_at desc
   limit 1;
  if run.id is null then
    return jsonb_build_object('run', null);
  end if;
  return jsonb_build_object('run', run.id, 'card', run.current,
                            'streak', run.streak, 'bank', coalesce(run.bank, '[]'::jsonb));
end $function$;
