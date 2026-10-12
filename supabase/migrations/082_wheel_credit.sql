-- =====================================================================
-- 082_wheel_credit.sql — add Store Credit segments to wheels:
-- $5 on Wheel 1, $10 on Wheel 2, $20 on Wheel 3. All weight 1.
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
  t1 := nsets + 3 + 2;  -- w1: 2 gateways
  t2 := nsets + 3 + 4;  -- w2: 4 gateways
  t3 := nsets + 3 + 4;  -- w3: 4 gateways

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
    select (nsets + 3)::float,
           jsonb_build_object('key', 'credit:5', 'kind', 'credit',
             'credit', 5, 'label', '$5 Store Credit', 'weight', 1)
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
    select (nsets + 2 + 1)::float,
           jsonb_build_object('key', 'credit:10', 'kind', 'credit',
             'credit', 10, 'label', '$10 Store Credit', 'weight', 1)
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
    select (nsets + 2 + 1)::float,
           jsonb_build_object('key', 'credit:20', 'kind', 'credit',
             'credit', 20, 'label', '$20 Store Credit', 'weight', 1)
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

-- Update cps_spin_wheel to handle 'credit' kind
create or replace function public.cps_spin_wheel(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  res        jsonb;
  prize      jsonb;
  packs_now  int;
  tokens_now int;
  credit_now int;
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
    values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', prize ->> 'kind'));

  if prize ->> 'kind' = 'tokens' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, (prize ->> 'tokens')::int, 'wheel');
  elsif prize ->> 'kind' = 'credit' then
    update cps.accounts set store_credit = coalesce(store_credit, 0) + (prize ->> 'credit')::int
      where id = a.id returning store_credit into credit_now;
  else
    packs_now := cps.add_packs(a.id, prize ->> 'set_id', (prize ->> 'packs')::int, 'wheel', null, null);
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
    'tokens_won', (prize ->> 'tokens')::int,
    'tokens_now', tokens_now,
    'credit_won', (prize ->> 'credit')::int,
    'credit_now', credit_now,
    'spins_left', spins_now
  );
end $$;

notify pgrst, 'reload schema';
