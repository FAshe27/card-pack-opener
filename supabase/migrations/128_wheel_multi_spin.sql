-- =====================================================================
-- PackRipper — migration 128: SPIN x10 for the Prize Wheel + a fix
-- Run AFTER 095 (live cps_spin_wheel) and 094 (live cps.roll_wheel).
--
-- 1. NEW cps_spin_wheel_multi(p_token, p_count): one call simulates
--    up to 10 spins atomically (all tickets up front or none), each
--    spin rolled and applied exactly like a single spin — same
--    ledger rows, same quest bumps — returning every result plus
--    aggregated totals for the client's summary popup.
--
-- 2. RESTORED quest bump: 019/067/082's cps_spin_wheel bumped the
--    'spin_wheel' daily quest on every spin; 095's concurrency
--    rebuild dropped it, so that quest has not progressed from
--    spinning since. cps_spin_wheel below is 095 verbatim + the
--    one restored line (mirroring 067's placement); the multi
--    function bumps it once per simulated spin as well.
-- =====================================================================

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

-- --- NEW: cps_spin_wheel_multi — one call, N spins (1..10), all-or-nothing.
-- Mirrors cps_spin_wheel's per-spin steps exactly (atomic decrement up
-- front, roll_wheel per spin, same prize application, same ledger rows,
-- same quest bumps) and returns every spin's hops+prize for the client
-- to animate/summarize, plus aggregated totals and final balances.
create or replace function public.cps_spin_wheel_multi(p_token text, p_count int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a             cps.accounts%rowtype;
  n             int := least(greatest(coalesce(p_count, 10), 1), 10);
  res           jsonb;
  prize         jsonb;
  results       jsonb := '[]'::jsonb;
  by_set        jsonb := '{}'::jsonb;
  packs_now_map jsonb := '{}'::jsonb;
  tot_tokens    int := 0;
  tot_credit    int := 0;
  tokens_now    int;
  credit_now    int;
  spins_now     int;
  pn            int;
  i             int;
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
    end if;

    perform cps.quest_bump(a.id, 'spin_wheel', 1);
    if coalesce((prize ->> 'packs')::int, 0) >= 3 then
      perform cps.quest_bump(a.id, 'wheel_big_win', 1);
    end if;

    results := results || jsonb_build_object('hops', res -> 'hops', 'prize', prize);
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
    'credit_now', credit_now
  );
end $$;

grant execute on function public.cps_spin_wheel_multi(text, int) to anon;

notify pgrst, 'reload schema';
