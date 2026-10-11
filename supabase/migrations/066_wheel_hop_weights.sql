-- =====================================================================
-- 066_wheel_hop_weights.sql — wheel-hop gateways get the same weight as a
-- pack segment on their wheel (equal odds + equal visual width).
-- =====================================================================

create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
  nsets int;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;
  nsets := coalesce(array_length(set_ids, 1), 0);

  -- Wheel 1: packs weight 3, both gateways weight 3 (opposite each other)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w1 from (
    with ranked as (
      select s, row_number() over (order by s) as rn
      from unnest(set_ids) s
    )
    select rn::float as ord,
           jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 1, 'weight', 3) as seg
      from ranked
    union all
    select (nsets / 2) + 0.5,
           jsonb_build_object('key', 'goto:w2a', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 3)
      where nsets > 0
    union all
    select (nsets + 1)::float,
           jsonb_build_object('key', 'goto:w2b', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 3)
      where nsets > 0
  ) x;

  -- Wheel 2: packs weight 2, both gateways weight 2
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 2) as seg from unnest(set_ids) s
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 2)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 2)
  ) x;

  -- Wheel 3: packs weight 2, both gateways weight 2
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 2) as seg from unnest(set_ids) s
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 2)
    union all
    select 2, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Back to second wheel', 'weight', 2)
  ) x;

  return jsonb_build_object('wheels', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'name', 'Prize Wheel',  'segments', w1),
    jsonb_build_object('id', 'w2', 'name', 'Double Wheel', 'segments', w2),
    jsonb_build_object('id', 'w3', 'name', 'Triple Wheel', 'segments', w3)
  ));
end $$;

notify pgrst, 'reload schema';
