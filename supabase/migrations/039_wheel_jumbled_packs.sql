-- =====================================================================
-- 039_wheel_jumbled_packs.sql — Jumbled Mess wheel segments match the wheel
-- multiplier (1x/2x/3x) instead of hardcoded 1x.
-- (Run after 038.)
-- =====================================================================

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

  -- Wheel 2: 2 packs per set + 2 Jumbled Mess + back to w1 + gateway to w3 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 2, 'weight', 1)
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
  ) x;

  -- Wheel 3: 3 packs per set + 3 Jumbled Mess + back to w1 + back to w2 (all weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 1) as seg from unnest(set_ids) s
    union all
    select 0, jsonb_build_object('key', 'packs:jumbled', 'kind', 'packs',
             'set_id', 'jumbled', 'packs', 3, 'weight', 1)
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
