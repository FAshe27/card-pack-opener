-- =====================================================================
-- 051_wheel_token_segments.sql — Arcade token segments on the prize wheels:
-- 3 tokens on wheel 1, 7 on wheel 2, 10 on wheel 3 (all weight 1).
-- (Run after 050.)
-- =====================================================================

create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;

  -- Wheel 1: 1 pack per set + 1 Jumbled Mess + 3 Arcade tokens + gateway to wheel 2 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w1 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 1, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 1, 'weight', 1)
    union all
    select 0, jsonb_build_object('key', 'tokens:3', 'kind', 'tokens',
             'tokens', 3, 'label', '3 Arcade tokens', 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
  ) x;

  -- Wheel 2: 2 packs per set + 2 Jumbled Mess + 7 Arcade tokens + back to w1 + gateway to w3 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 2, 'weight', 1)
    union all
    select 0, jsonb_build_object('key', 'tokens:7', 'kind', 'tokens',
             'tokens', 7, 'label', '7 Arcade tokens', 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
  ) x;

  -- Wheel 3: 3 packs per set + 3 Jumbled Mess + 10 Arcade tokens + back to w1 + back to w2 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 3, 'weight', 1)
    union all
    select 0, jsonb_build_object('key', 'tokens:10', 'kind', 'tokens',
             'tokens', 10, 'label', '10 Arcade tokens', 'weight', 1)
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

-- roll_wheel: token segments end the chain like pack segments do.
create or replace function cps.roll_wheel() returns jsonb
language plpgsql volatile set search_path = cps, pg_temp as $$
declare
  cfg   jsonb := cps.wheel_config();
  hops  jsonb := '[]'::jsonb;
  wid   text  := 'w1';
  w     jsonb;
  segs  jsonb;
  total int;
  r     int;
  acc   int;
  seg   jsonb;
  s     jsonb;
  guard int := 0;
begin
  loop
    guard := guard + 1;
    if guard > 25 then raise exception 'Wheel chain too long.'; end if;
    select v into w from jsonb_array_elements(cfg -> 'wheels') v where v ->> 'id' = wid;
    if w is null then raise exception 'Unknown wheel: %', wid; end if;
    segs := w -> 'segments';
    select coalesce(sum((x ->> 'weight')::int), 0) into total
      from jsonb_array_elements(segs) x;
    if total <= 0 then raise exception 'Wheel % has no segments.', wid; end if;
    r := floor(cps.rand01() * total)::int;
    acc := 0;
    seg := null;
    for s in select value from jsonb_array_elements(segs) loop
      acc := acc + (s ->> 'weight')::int;
      if r < acc then seg := s; exit; end if;
    end loop;
    if seg is null then raise exception 'Wheel roll failed.'; end if;
    hops := hops || jsonb_build_object(
      'wheel', wid, 'key', seg ->> 'key', 'kind', seg ->> 'kind',
      'set_id', seg -> 'set_id', 'packs', (seg ->> 'packs')::int,
      'tokens', (seg ->> 'tokens')::int,
      'label', seg ->> 'label', 'goto_wheel', seg ->> 'wheel');
    if seg ->> 'kind' = 'packs' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('kind', 'packs', 'set_id', seg ->> 'set_id',
                                    'packs', (seg ->> 'packs')::int));
    elsif seg ->> 'kind' = 'tokens' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('kind', 'tokens',
                                    'tokens', (seg ->> 'tokens')::int));
    end if;
    wid := seg ->> 'wheel';
  end loop;
end $$;

-- spin_wheel: awards Arcade tokens when the prize is a token segment.
create or replace function public.cps_spin_wheel(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  res        jsonb;
  prize      jsonb;
  packs_now  int;
  tokens_now int;
  spins_now  int;
begin
  a := cps.auth(p_token);
  if coalesce(a.spins, 0) < 1 then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  update cps.accounts set spins = spins - 1 where id = a.id
    returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', 'tokens'));

  if prize ->> 'kind' = 'tokens' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, (prize ->> 'tokens')::int, 'wheel');
  else
    packs_now := cps.add_packs(a.id, prize ->> 'set_id', (prize ->> 'packs')::int, 'wheel', null, null);
  end if;

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'tokens_won', (prize ->> 'tokens')::int,
    'tokens_now', tokens_now,
    'spins_left', spins_now
  );
end $$;

notify pgrst, 'reload schema';
