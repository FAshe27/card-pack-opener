-- Migration 223: the SPIN x10 path kept the old wheel_big_win threshold.
--
-- Migration 219 eased the daily quest 'Win 2 or more packs from one spin'
-- in public.cps_spin_wheel — but cps_spin_wheel_multi is a separate
-- implementation with its own copy of the bump, and it still required
-- >= 3 packs. Every double won through a x10 batch therefore counted for
-- nothing (singles worked: Patty claimed today). One token: >= 3 -> >= 2,
-- matching the single-spin function and the quest's title.
--
-- Backfill (same migration): today's board — every player with a wheel
-- double today whose quest is still unfinished gets the bump they earned
-- (Franklin, Frank III, Cory, Tyler, Ciera at draft time; the statement
-- derives the set from the ledgers, so it covers exactly the evidence).

CREATE OR REPLACE FUNCTION public.cps_spin_wheel_multi(p_token text, p_count integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
    if coalesce((prize ->> 'packs')::int, 0) >= 2 then
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

-- Backfill: one bump per affected player (quest_bump caps at target).
select cps.quest_bump(x.account_id, 'wheel_big_win', 1)
from (
  select distinct g.account_id
  from cps.pack_grants g
  join cps.daily_quests q
    on q.account_id = g.account_id
   and q.day = (now() at time zone 'America/Chicago')::date
   and q.quest_key = 'wheel_big_win'
   and not q.done and q.claimed_at is null
  where g.reason = 'wheel' and g.packs >= 2
    and g.at >= (date_trunc('day', now() at time zone 'America/Chicago') at time zone 'America/Chicago')
) x;
