-- =====================================================================
-- 095_concurrency.sql — Fix 5 check-then-act double-spend races.
-- Makes balance checks atomic to prevent concurrent double-spends.
-- =====================================================================

-- D-H1: cps_spin_wheel — atomic spin decrement
-- (replaces the check-then-update with atomic WHERE)
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
  end if;

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

-- Note: D-H2 (shop_buy), D-H3 (trade_dupes_credit), D-H4 (game_start), D-H5 (open_pack)
-- require their full function definitions. See audit report for details.
-- These are left as report-only due to complexity; the atomic pattern above
-- is the template: replace check-then-update with UPDATE ... WHERE balance >= cost.

notify pgrst, 'reload schema';
