-- =====================================================================
-- PackRipper — migration 162: SPIN ALL for the Prize Wheel.
-- Run AFTER 161 (shop buy-all). No dependency on 162_verify.
--
-- Rebuilds public.cps_spin_wheel_multi from migration 128's body
-- VERBATIM except for exactly two changes:
--
--   1. CAP: the per-call spin count clamp rises from 10 to 1000, so
--      a "Spin all" button can pass the player's whole ticket
--      balance in one call. (p_count still defaults to 10 when null
--      and still floors at 1; the all-or-nothing ticket check is
--      unchanged — if the balance can't cover the CLAMPED count,
--      the call raises and nothing is spent.)
--
--   2. RESPONSE TRIM: 'results' now carries ONLY the final spin's
--      {hops, prize} instead of every spin's. The client animates
--      just the last result's hop chain and reads everything else
--      from the aggregated totals (packs_by_set / tokens_won /
--      credit_won / packs_now), which are UNCHANGED. At hundreds of
--      spins the old shape returned megabytes of hop chains nobody
--      reads. Client compatibility: js/wheel.js reads only
--      results[results.length - 1], which is still the last spin.
--
-- Everything else — atomic up-front decrement, per-spin roll_wheel,
-- prize application, spin_grants / token_grants ledger rows,
-- add_packs calls, and both quest bumps per spin — is byte-for-byte
-- 128's logic. The single-spin public.cps_spin_wheel is NOT touched.
-- =====================================================================

create or replace function public.cps_spin_wheel_multi(p_token text, p_count int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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
    'credit_now', credit_now
  );
end $$;

grant execute on function public.cps_spin_wheel_multi(text, int) to anon;

notify pgrst, 'reload schema';
