-- 176_wheel_categories.sql
-- Prize Wheel category redesign (Franklin, 2026-10-23; ship authorized by him
-- the same day, SQL-review gate waived for this ship only).
--
-- What changes:
--   * Per-set wheel slices are replaced by 8 category slices. A category
--     slice's weight is the number of ACTIVE sets in it, so every individual
--     set stays exactly equally likely. Any active set missing from the
--     category map falls back to Curiosities, so the wheel can never drop
--     a set or break when a new set ships.
--   * One Bonus slice (weight 3) per wheel replaces the old tokens slice,
--     the credit slice AND the dedicated Jumbled slice. Bonus resolves a
--     server-side sub-roll, equal fifths among: Jumbled packs 1/3/5,
--     Store Credit $5/$10/$15, Spin Tickets 2/4/6, Arcade Tokens 5/15/25,
--     Random Packs 2/4/6 (Prize/Double/Triple values). Random Packs are
--     pack credits each assigned to a uniformly random ACTIVE regular set
--     (never Jumbled), duplicates possible.
--   * Hop slices keep today's counts/directions but weigh 1.5 each, so
--     cps.roll_wheel now sums weights as numeric (the old ::int casts
--     error on '1.5' with 22P02).
--   * New prize kinds from roll_wheel: 'tickets' (spin tickets, granted
--     through spin_grants by the spin wrappers) and 'random_packs'
--     (carries a concrete packs_by_set the wrappers grant via add_packs,
--     so single- and multi-spin aggregation keeps working).
-- Rebuild bases: the live bodies of cps.wheel_config, cps.roll_wheel,
-- public.cps_spin_wheel and public.cps_spin_wheel_multi as of 2026-10-23
-- (captured read-only via pg_get_functiondef before this ship).

-- ---------------------------------------------------------------------------
-- Helper: build one wheel's segment array.
-- ---------------------------------------------------------------------------
create or replace function cps.wheel_segments(p_wheel text, p_mult int)
returns jsonb
language plpgsql
stable
set search_path to 'cps', 'pg_temp'
as $function$
declare
  result jsonb;
begin
  with catdef(key, name, icon, color, ord) as (
    values
      ('animals',       'Animals',             '🐾', '#43aa8b', 1),
      ('world',         'World & Nature',      '🌍', '#3d8bfd', 2),
      ('sports',        'Sports & Racing',     '🏆', '#e63946', 3),
      ('gaming',        'Gaming',              '🎮', '#7c5cff', 4),
      ('entertainment', 'Entertainment',       '🎬', '#f372b5', 5),
      ('food',          'Food & Drink',        '🍔', '#ffb020', 6),
      ('machines',      'Machines & Transport','🚗', '#8d99ae', 7),
      ('curiosities',   'Curiosities',         '🔮', '#2ec4b6', 8)
  ),
  setmap(set_id, cat) as (
    values
      ('birdwatching','animals'), ('sea','animals'), ('aquariums','animals'),
      ('dogs','animals'), ('insects','animals'), ('reptiles','animals'),
      ('wild-mammals','animals'), ('dinosaurs','animals'),
      ('countries','world'), ('states','world'), ('world-cities','world'),
      ('world-landmarks','world'), ('nps','world'), ('natural-wonders','world'),
      ('water','world'), ('plants','world'), ('gems-minerals','world'),
      ('mlb','sports'), ('nba-collection','sports'), ('nfl-collection','sports'),
      ('formula-1-collection','sports'), ('nascar-collection','sports'), ('indy','sports'),
      ('acrs','gaming'), ('minecraft','gaming'), ('mkrt','gaming'),
      ('pokemon','gaming'), ('skyrim','gaming'), ('stardew-valley','gaming'),
      ('zelda','gaming'),
      ('movies-pack-images','entertainment'), ('tv-shows','entertainment'),
      ('disney','entertainment'), ('pixar','entertainment'), ('spongebob','entertainment'),
      ('star-wars','entertainment'), ('hero','entertainment'), ('stage','entertainment'),
      ('music-pack','entertainment'), ('works-of-art','entertainment'),
      ('beverages','food'), ('cereals','food'), ('candy','food'),
      ('fast-food','food'), ('iconic-dishes','food'),
      ('civilian-aircraft','machines'), ('aircraft','machines'), ('us-navy','machines'),
      ('cars','machines'), ('motorcycles','machines'), ('trains','machines'), ('hwy','machines'),
      ('space','curiosities'), ('technology-collection','curiosities'), ('periodic','curiosities'),
      ('cryptids','curiosities'), ('calendar','curiosities'), ('playing','curiosities'),
      ('gas','curiosities'), ('coasters','curiosities'), ('theme-parks','curiosities')
  ),
  members as (
    select coalesce(m.cat, 'curiosities') as cat,
           jsonb_agg(cs.id order by cs.id) as sets,
           count(*)::int as n
      from cps.card_sets cs
      left join setmap m on m.set_id = cs.id
     where cs.active
     group by coalesce(m.cat, 'curiosities')
  ),
  gotos(src, key, target, label, ord) as (
    values
      ('w1', 'goto:w2a', 'w2', 'Go to second wheel',   2.5),
      ('w1', 'goto:w2b', 'w2', 'Go to second wheel',   7.5),
      ('w2', 'goto:w1a', 'w1', 'Back to first wheel',  1.5),
      ('w2', 'goto:w3a', 'w3', 'Go to third wheel',    4.5),
      ('w2', 'goto:w1b', 'w1', 'Back to first wheel',  6.5),
      ('w2', 'goto:w3b', 'w3', 'Go to third wheel',    7.5),
      ('w3', 'goto:w1a', 'w1', 'Back to first wheel',  1.5),
      ('w3', 'goto:w2a', 'w2', 'Back to second wheel', 4.5),
      ('w3', 'goto:w1b', 'w1', 'Back to first wheel',  6.5),
      ('w3', 'goto:w2b', 'w2', 'Back to second wheel', 7.5)
  ),
  segs(ord, seg) as (
    select c.ord::float,
           jsonb_build_object('key', 'cat:' || c.key, 'kind', 'category',
             'category', c.key, 'label', c.name, 'icon', c.icon, 'color', c.color,
             'packs', p_mult, 'weight', mb.n, 'sets', mb.sets)
      from catdef c
      join members mb on mb.cat = c.key
    union all
    select case p_wheel when 'w1' then 8.6 else 3.5 end,
           jsonb_build_object('key', 'bonus', 'kind', 'bonus',
             'label', 'BONUS', 'icon', '⭐', 'color', '#ffd60a', 'weight', 3)
    union all
    select g.ord,
           jsonb_build_object('key', g.key, 'kind', 'goto', 'wheel', g.target,
             'label', g.label, 'weight', 1.5)
      from gotos g
     where g.src = p_wheel
  )
  select coalesce(jsonb_agg(seg order by ord), '[]'::jsonb) into result from segs;
  return result;
end $function$;

-- ---------------------------------------------------------------------------
-- cps.wheel_config: same signature/shape as live, segments now come from
-- cps.wheel_segments (categories + Bonus + hops).
-- ---------------------------------------------------------------------------
create or replace function cps.wheel_config()
returns jsonb
language plpgsql
stable
set search_path to 'cps', 'pg_temp'
as $function$
begin
  return jsonb_build_object('wheels', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'name', 'Prize Wheel',  'segments', cps.wheel_segments('w1', 1)),
    jsonb_build_object('id', 'w2', 'name', 'Double Wheel', 'segments', cps.wheel_segments('w2', 2)),
    jsonb_build_object('id', 'w3', 'name', 'Triple Wheel', 'segments', cps.wheel_segments('w3', 3))
  ));
end $function$;

-- ---------------------------------------------------------------------------
-- cps.roll_wheel: based on the live body. Changes:
--   * total / r / acc are numeric and weights are summed as ::numeric
--     (decimal hop weight 1.5 must not error).
--   * 'category' segments resolve a uniform random member set server-side
--     and return the usual packs prize plus category fields.
--   * 'bonus' segments resolve the equal-fifths sub-roll server-side and
--     return a terminal prize: packs (Jumbled), credit, tickets, tokens,
--     or random_packs with a concrete packs_by_set.
--   * Hop records gain 'category', 'bonus_prize' and 'prize_set_id' so the
--     client can aim its sub-wheel at the server-decided outcome.
--   * Legacy packs/tokens/credit segment kinds still resolve exactly as
--     before (rollback-config compatibility).
-- ---------------------------------------------------------------------------
create or replace function cps.roll_wheel()
returns jsonb
language plpgsql
set search_path to 'cps', 'pg_temp'
as $function$
declare
  cfg      jsonb := cps.wheel_config();
  hops     jsonb := '[]'::jsonb;
  wid      text  := 'w1';
  w        jsonb;
  segs     jsonb;
  total    numeric;
  r        numeric;
  acc      numeric;
  seg      jsonb;
  s        jsonb;
  guard    int := 0;
  prize    jsonb;
  chosen   text;
  members  jsonb;
  widx     int;
  broll    int;
  bamt     int;
  bset     text;
  by_set   jsonb;
  act_ids  text[];
  i        int;
begin
  loop
    guard := guard + 1;
    if guard > 25 then raise exception 'Wheel chain too long.'; end if;
    select v into w from jsonb_array_elements(cfg -> 'wheels') v where v ->> 'id' = wid;
    if w is null then raise exception 'Unknown wheel: %', wid; end if;
    segs := w -> 'segments';
    select coalesce(sum((x ->> 'weight')::numeric), 0) into total
      from jsonb_array_elements(segs) x;
    if total <= 0 then raise exception 'Wheel % has no segments.', wid; end if;
    r := cps.rand01() * total;
    acc := 0;
    seg := null;
    for s in select value from jsonb_array_elements(segs) loop
      acc := acc + (s ->> 'weight')::numeric;
      if r < acc then seg := s; exit; end if;
    end loop;
    if seg is null then raise exception 'Wheel roll failed.'; end if;

    prize := null;
    chosen := null;

    if seg ->> 'kind' = 'category' then
      members := seg -> 'sets';
      chosen := members ->> (floor(cps.rand01() * jsonb_array_length(members))::int);
      prize := jsonb_build_object('kind', 'packs', 'set_id', chosen,
                                  'packs', (seg ->> 'packs')::int,
                                  'category', seg ->> 'category',
                                  'category_label', seg ->> 'label');
    elsif seg ->> 'kind' = 'bonus' then
      widx := case wid when 'w1' then 1 when 'w2' then 2 else 3 end;
      broll := floor(cps.rand01() * 5)::int;  -- equal fifths
      if broll = 0 then
        bamt := (array[1, 3, 5])[widx];
        prize := jsonb_build_object('kind', 'packs', 'set_id', 'jumbled',
                                    'packs', bamt, 'bonus', true, 'bonus_prize', 'jumbled');
        chosen := 'jumbled';
      elsif broll = 1 then
        bamt := (array[5, 10, 15])[widx];
        prize := jsonb_build_object('kind', 'credit', 'credit', bamt,
                                    'bonus', true, 'bonus_prize', 'credit');
      elsif broll = 2 then
        bamt := (array[2, 4, 6])[widx];
        prize := jsonb_build_object('kind', 'tickets', 'tickets', bamt,
                                    'bonus', true, 'bonus_prize', 'tickets');
      elsif broll = 3 then
        bamt := (array[5, 15, 25])[widx];
        prize := jsonb_build_object('kind', 'tokens', 'tokens', bamt,
                                    'bonus', true, 'bonus_prize', 'tokens');
      else
        bamt := (array[2, 4, 6])[widx];
        select coalesce(array_agg(id order by id), '{}') into act_ids
          from cps.card_sets where active and id <> 'jumbled';
        by_set := '{}'::jsonb;
        for i in 1..bamt loop
          bset := act_ids[1 + floor(cps.rand01() * coalesce(array_length(act_ids, 1), 1))::int];
          if bset is not null then
            by_set := jsonb_set(by_set, array[bset],
              to_jsonb(coalesce((by_set ->> bset)::int, 0) + 1));
          end if;
        end loop;
        prize := jsonb_build_object('kind', 'random_packs', 'packs', bamt,
                                    'packs_by_set', by_set,
                                    'bonus', true, 'bonus_prize', 'random');
      end if;
    elsif seg ->> 'kind' = 'packs' then
      prize := jsonb_build_object('kind', 'packs', 'set_id', seg ->> 'set_id',
                                  'packs', (seg ->> 'packs')::int);
      chosen := seg ->> 'set_id';
    elsif seg ->> 'kind' = 'tokens' then
      prize := jsonb_build_object('kind', 'tokens',
                                  'tokens', (seg ->> 'tokens')::int);
    elsif seg ->> 'kind' = 'credit' then
      prize := jsonb_build_object('kind', 'credit',
                                  'credit', (seg ->> 'credit')::int);
    end if;

    hops := hops || jsonb_build_object(
      'wheel', wid, 'key', seg ->> 'key', 'kind', seg ->> 'kind',
      'set_id', seg -> 'set_id', 'packs', (seg ->> 'packs')::int,
      'tokens', (seg ->> 'tokens')::int,
      'credit', (seg ->> 'credit')::int,
      'label', seg ->> 'label', 'goto_wheel', seg ->> 'wheel',
      'category', seg ->> 'category',
      'bonus_prize', prize ->> 'bonus_prize',
      'prize_set_id', chosen);

    if prize is not null then
      return jsonb_build_object('hops', hops, 'prize', prize);
    end if;
    wid := seg ->> 'wheel';
  end loop;
end $function$;

-- ---------------------------------------------------------------------------
-- public.cps_spin_wheel: live body + two new prize branches.
--   * 'tickets': spins credited back through spin_grants (reason
--     'wheel_bonus'), spins_now refreshed so spins_left includes the grant.
--   * 'random_packs': each entry of packs_by_set granted via add_packs.
-- Return object gains 'tickets_won' and 'packs_by_set' (null otherwise).
-- ---------------------------------------------------------------------------
create or replace function public.cps_spin_wheel(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'cps', 'pg_temp'
as $function$
declare
  a          cps.accounts%rowtype;
  res        jsonb;
  prize      jsonb;
  packs_now  int;
  tokens_now int;
  credit_now int;
  spins_now  int;
  k          text;
begin
  a := cps.auth(p_token);

  -- Atomic: only decrement if spins > 0. Concurrent calls can't both succeed.
  update cps.accounts set spins = spins - 1 where id = a.id and coalesce(spins, 0) > 0
    returning spins into spins_now;
  if not found then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', prize ->> 'kind'));

  if prize ->> 'kind' = 'tokens' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, (prize ->> 'tokens')::int, 'wheel');
  elsif prize ->> 'kind' = 'credit' then
    update cps.accounts set store_credit = coalesce(store_credit, 0) + (prize ->> 'credit')::int
      where id = a.id returning store_credit into credit_now;
  elsif prize ->> 'kind' = 'packs' then
    perform cps.add_packs(a.id, (prize ->> 'set_id'), (prize ->> 'packs')::int, 'wheel', null, null);
    select packs into packs_now from cps.pack_inventory where account_id = a.id and set_id = (prize ->> 'set_id');
  elsif prize ->> 'kind' = 'tickets' then
    update cps.accounts set spins = coalesce(spins, 0) + (prize ->> 'tickets')::int
      where id = a.id returning spins into spins_now;
    insert into cps.spin_grants (account_id, spins, reason, ref)
      values (a.id, (prize ->> 'tickets')::int, 'wheel_bonus', 'bonus:tickets');
  elsif prize ->> 'kind' = 'random_packs' then
    for k in select jsonb_object_keys(prize -> 'packs_by_set') loop
      perform cps.add_packs(a.id, k, (prize -> 'packs_by_set' ->> k)::int, 'wheel', null, null);
    end loop;
  end if;

  perform cps.quest_bump(a.id, 'spin_wheel', 1);
  if coalesce((prize ->> 'packs')::int, 0) >= 3 then
    perform cps.quest_bump(a.id, 'wheel_big_win', 1);
  end if;

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'packs_by_set', prize -> 'packs_by_set',
    'tokens_won', (prize ->> 'tokens')::int,
    'tokens_now', tokens_now,
    'credit_won', (prize ->> 'credit')::int,
    'credit_now', credit_now,
    'tickets_won', (prize ->> 'tickets')::int,
    'spins_left', spins_now
  );
end $function$;

-- ---------------------------------------------------------------------------
-- public.cps_spin_wheel_multi: live body + the same two prize branches.
--   * 'tickets' accumulate into tot_tickets and spins_now is refreshed per
--     grant, so the returned spins_left includes every ticket won.
--   * 'random_packs' merge into by_set / packs_now_map per set, so the
--     aggregated summary and per-set pack counts keep working.
-- Return object gains 'tickets_won'.
-- ---------------------------------------------------------------------------
create or replace function public.cps_spin_wheel_multi(p_token text, p_count integer)
returns jsonb
language plpgsql
security definer
set search_path to 'cps', 'pg_temp'
as $function$
declare
  a             cps.accounts%rowtype;
  n             int := least(greatest(coalesce(p_count, 10), 1), 1000);
  res           jsonb;
  prize         jsonb;
  results       jsonb := '[]'::jsonb;
  by_set        jsonb := '{}'::jsonb;
  packs_now_map jsonb := '{}'::jsonb;
  tot_tokens    int := 0;
  tot_credit    int := 0;
  tot_tickets   int := 0;
  tokens_now    int;
  credit_now    int;
  spins_now     int;
  pn            int;
  i             int;
  k             text;
begin
  a := cps.auth(p_token);

  -- Atomic: all N tickets up front, or none (095's pattern, generalized).
  update cps.accounts set spins = spins - n where id = a.id and coalesce(spins, 0) >= n
    returning spins into spins_now;
  if not found then
    raise exception 'You need % spin tickets for this. Earn more from daily quests!', n;
  end if;

  for i in 1..n loop
    res := cps.roll_wheel();
    prize := res -> 'prize';

    insert into cps.spin_grants (account_id, spins, reason, ref)
      values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', prize ->> 'kind'));

    if prize ->> 'kind' = 'tokens' then
      update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
        where id = a.id returning game_tokens into tokens_now;
      insert into cps.token_grants (account_id, tokens, reason)
        values (a.id, (prize ->> 'tokens')::int, 'wheel');
      tot_tokens := tot_tokens + (prize ->> 'tokens')::int;
    elsif prize ->> 'kind' = 'credit' then
      update cps.accounts set store_credit = coalesce(store_credit, 0) + (prize ->> 'credit')::int
        where id = a.id returning store_credit into credit_now;
      tot_credit := tot_credit + (prize ->> 'credit')::int;
    elsif prize ->> 'kind' = 'packs' then
      perform cps.add_packs(a.id, (prize ->> 'set_id'), (prize ->> 'packs')::int, 'wheel', null, null);
      select packs into pn from cps.pack_inventory where account_id = a.id and set_id = (prize ->> 'set_id');
      packs_now_map := jsonb_set(packs_now_map, array[prize ->> 'set_id'], to_jsonb(pn));
      by_set := jsonb_set(by_set, array[prize ->> 'set_id'],
        to_jsonb(coalesce((by_set ->> (prize ->> 'set_id'))::int, 0) + (prize ->> 'packs')::int));
    elsif prize ->> 'kind' = 'tickets' then
      update cps.accounts set spins = coalesce(spins, 0) + (prize ->> 'tickets')::int
        where id = a.id returning spins into spins_now;
      insert into cps.spin_grants (account_id, spins, reason, ref)
        values (a.id, (prize ->> 'tickets')::int, 'wheel_bonus', 'bonus:tickets');
      tot_tickets := tot_tickets + (prize ->> 'tickets')::int;
    elsif prize ->> 'kind' = 'random_packs' then
      for k in select jsonb_object_keys(prize -> 'packs_by_set') loop
        perform cps.add_packs(a.id, k, (prize -> 'packs_by_set' ->> k)::int, 'wheel', null, null);
        select packs into pn from cps.pack_inventory where account_id = a.id and set_id = k;
        packs_now_map := jsonb_set(packs_now_map, array[k], to_jsonb(pn));
        by_set := jsonb_set(by_set, array[k],
          to_jsonb(coalesce((by_set ->> k)::int, 0) + (prize -> 'packs_by_set' ->> k)::int));
      end loop;
    end if;

    perform cps.quest_bump(a.id, 'spin_wheel', 1);
    if coalesce((prize ->> 'packs')::int, 0) >= 3 then
      perform cps.quest_bump(a.id, 'wheel_big_win', 1);
    end if;

    -- 162: keep ONLY the latest spin's result (the client animates
    -- just the last hop chain); totals above carry the full picture.
    results := jsonb_build_array(jsonb_build_object('hops', res -> 'hops', 'prize', prize));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'spins_used', n,
    'spins_left', spins_now,
    'results', results,
    'packs_by_set', by_set,
    'packs_now', packs_now_map,
    'tokens_won', tot_tokens,
    'tokens_now', tokens_now,
    'credit_won', tot_credit,
    'credit_now', credit_now,
    'tickets_won', tot_tickets
  );
end $function$;

notify pgrst, 'reload schema';
