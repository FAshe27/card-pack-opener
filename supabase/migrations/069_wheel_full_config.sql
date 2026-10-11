-- =====================================================================
-- 069_wheel_full_config.sql — complete wheel configuration:
-- pack segments + Jumbled Mess + token segments (5/10/15) + gateways.
-- EVERY slot is weight 1 (equal odds). Each wheel has TWO of every hop
-- gateway, positioned opposite each other.
-- Token labels use the "N x 🪙 Arcade Tokens" pattern.
-- =====================================================================

create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
  nsets int;
  t1 int; t2 int; t3 int;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;
  nsets := coalesce(array_length(set_ids, 1), 0);
  -- totals: packs(n) + jumbled(1) + tokens(1) + gateways
  t1 := nsets + 2 + 2;  -- w1: 2 gateways
  t2 := nsets + 2 + 4;  -- w2: 4 gateways
  t3 := nsets + 2 + 4;  -- w3: 4 gateways

  -- Wheel 1: 1 pack/set + 1 Jumbled + 5 tokens + 2x "Go to second wheel" (opposite)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w1 from (
    with ranked as (
      select s, row_number() over (order by s) as rn
      from unnest(set_ids) s
    )
    select rn::float as ord,
           jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 1, 'weight', 1) as seg
      from ranked
    union all
    select (nsets + 1)::float,
           jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 1, 'weight', 1)
      where nsets > 0
    union all
    select (nsets + 2)::float,
           jsonb_build_object('key', 'tokens:5', 'kind', 'tokens',
             'tokens', 5, 'label', '5 x 🪙 Arcade Tokens', 'weight', 1)
      where nsets > 0
    union all
    select (t1 / 4)::float,
           jsonb_build_object('key', 'goto:w2a', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t1 / 4 + t1 / 2)::float,
           jsonb_build_object('key', 'goto:w2b', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
      where nsets > 0
  ) x;

  -- Wheel 2: 2 packs/set + 2 Jumbled + 10 tokens +
  --          2x "Back to first wheel" (opposite) + 2x "Go to third wheel" (opposite)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    with ranked as (
      select s, row_number() over (order by s) as rn
      from unnest(set_ids) s
    )
    select rn::float as ord,
           jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 1) as seg
      from ranked
    union all
    select (nsets + 1)::float,
           jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 2, 'weight', 1)
      where nsets > 0
    union all
    select (nsets + 2)::float,
           jsonb_build_object('key', 'tokens:10', 'kind', 'tokens',
             'tokens', 10, 'label', '10 x 🪙 Arcade Tokens', 'weight', 1)
      where nsets > 0
    union all
    select 0::float,
           jsonb_build_object('key', 'goto:w1a', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t2 / 2)::float,
           jsonb_build_object('key', 'goto:w1b', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t2 / 4)::float,
           jsonb_build_object('key', 'goto:w3a', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t2 / 4 + t2 / 2)::float,
           jsonb_build_object('key', 'goto:w3b', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
      where nsets > 0
  ) x;

  -- Wheel 3: 3 packs/set + 3 Jumbled + 15 tokens +
  --          2x "Back to first wheel" (opposite) + 2x "Back to second wheel" (opposite)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    with ranked as (
      select s, row_number() over (order by s) as rn
      from unnest(set_ids) s
    )
    select rn::float as ord,
           jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 1) as seg
      from ranked
    union all
    select (nsets + 1)::float,
           jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 3, 'weight', 1)
      where nsets > 0
    union all
    select (nsets + 2)::float,
           jsonb_build_object('key', 'tokens:15', 'kind', 'tokens',
             'tokens', 15, 'label', '15 x 🪙 Arcade Tokens', 'weight', 1)
      where nsets > 0
    union all
    select 0::float,
           jsonb_build_object('key', 'goto:w1a', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t3 / 2)::float,
           jsonb_build_object('key', 'goto:w1b', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t3 / 4)::float,
           jsonb_build_object('key', 'goto:w2a', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Back to second wheel', 'weight', 1)
      where nsets > 0
    union all
    select (t3 / 4 + t3 / 2)::float,
           jsonb_build_object('key', 'goto:w2b', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Back to second wheel', 'weight', 1)
      where nsets > 0
  ) x;

  return jsonb_build_object('wheels', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'name', 'Prize Wheel',  'segments', w1),
    jsonb_build_object('id', 'w2', 'name', 'Double Wheel', 'segments', w2),
    jsonb_build_object('id', 'w3', 'name', 'Triple Wheel', 'segments', w3)
  ));
end $$;

notify pgrst, 'reload schema';
