-- =====================================================================
-- 069_wheel_full_config.sql — restore the complete wheel configuration:
-- pack segments + Jumbled Mess + token segments + gateways, ALL weight 1
-- (equal odds). Wheel 1 gets two w2 gateways, positioned opposite each other.
-- Token labels use the "N x 🪙 Arcade Tokens" pattern.
-- =====================================================================

create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
  nsets int;
  tot1 int;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;
  nsets := coalesce(array_length(set_ids, 1), 0);
  -- w1 total segments: packs(n) + jumbled(1) + tokens(1) + gateways(2)
  tot1 := nsets + 4;

  -- Wheel 1: 1 pack per set + 1 Jumbled + 3 tokens + 2 gateways (opposite)
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
           jsonb_build_object('key', 'tokens:3', 'kind', 'tokens',
             'tokens', 3, 'label', '3 x 🪙 Arcade Tokens', 'weight', 1)
      where nsets > 0
    union all
    -- two gateways, geometrically opposite (tot/4 apart from each quarter)
    select (tot1 / 4)::float,
           jsonb_build_object('key', 'goto:w2a', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
      where nsets > 0
    union all
    select (tot1 / 4 + tot1 / 2)::float,
           jsonb_build_object('key', 'goto:w2b', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
      where nsets > 0
  ) x;

  -- Wheel 2: 2 packs per set + 2 Jumbled + 7 tokens + back to w1 + gateway to w3
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 2, 'weight', 1)
    union all
    select 0, jsonb_build_object('key', 'tokens:7', 'kind', 'tokens',
             'tokens', 7, 'label', '7 x 🪙 Arcade Tokens', 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
  ) x;

  -- Wheel 3: 3 packs per set + 3 Jumbled + 10 tokens + back to w1 + back to w2
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 3, 'weight', 1)
    union all
    select 0, jsonb_build_object('key', 'tokens:10', 'kind', 'tokens',
             'tokens', 10, 'label', '10 x 🪙 Arcade Tokens', 'weight', 1)
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

notify pgrst, 'reload schema';
