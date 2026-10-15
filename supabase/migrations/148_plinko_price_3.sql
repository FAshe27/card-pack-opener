-- 148_plinko_price_3.sql
-- Plinko price change (Franklin, 2026-10-14): a drop now costs 3 tokens
-- (was 2). One-line change inside cps_plinko_drop: cost_each 2 -> 3.
-- Built from migration 147's production body — the automated diff proof
-- shows this function differs from 147's by EXACTLY that one line
-- (parameter validation, charge, roll loop, ledger and payouts are
-- byte-identical). Prizes are unchanged. The ledger column default is
-- aligned for tidiness (every insert passes cost explicitly anyway).
-- Client side ships with this: CONFIG.cost 3 + the Arcade tile tag
-- '3 🪙 a drop'.
-- Run in the Supabase SQL editor.

create or replace function public.cps_plinko_drop(p_token text, p_drops int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  bal         int;
  cost_each   int := 3;
  total_cost  int;
  steps       int[];
  rights      int;
  prize       int[];
  d           int;
  i           int;
  rset        text;
  active_sets text[];
  tot_tokens  int := 0;
  tot_pr      int := 0;
  tot_pj      int := 0;
  results     jsonb := '[]';
begin
  a := cps.auth(p_token);
  if p_drops is null or p_drops not in (1, 10) then
    raise exception 'Drops must be 1 or 10.';
  end if;
  total_cost := cost_each * p_drops;

  -- lock the account row and charge the full cost up front
  select coalesce(game_tokens, 0) into bal from cps.accounts
    where id = a.id for update;
  if bal < total_cost then raise exception 'Not enough tokens.'; end if;
  update cps.accounts set game_tokens = bal - total_cost where id = a.id;
  bal := bal - total_cost;

  for d in 1..p_drops loop
    -- roll the path: 8 steps of -1 (left) / +1 (right); bin = rights
    steps := '{}';
    rights := 0;
    for i in 1..8 loop
      if cps.rand01() < 0.5 then
        steps := steps || (-1);
      else
        steps := steps || 1;
        rights := rights + 1;
      end if;
    end loop;
    prize := cps.plinko_prize(rights);

    insert into cps.plinko_drops
      (account_id, bin, steps, cost, tokens_back, packs_random, packs_jumbled)
    values
      (a.id, rights, steps, cost_each, prize[1], prize[2], prize[3]);

    -- pay packs for this drop (jumbled in one grant, random per pack)
    if prize[3] > 0 then
      perform cps.add_packs(a.id, 'jumbled', prize[3], 'plinko_win',
        'bin_' || (rights + 1), null);
    end if;
    if prize[2] > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for plinko prizes.';
      end if;
      for i in 1..prize[2] loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'plinko_win',
          'bin_' || (rights + 1), null);
      end loop;
    end if;

    tot_tokens := tot_tokens + prize[1];
    tot_pr := tot_pr + prize[2];
    tot_pj := tot_pj + prize[3];
    results := results || jsonb_build_object(
      'steps', to_jsonb(steps), 'bin', rights,
      'tokens', prize[1], 'pr', prize[2], 'pj', prize[3]);
  end loop;

  -- pay token-back winnings
  if tot_tokens > 0 then
    update cps.accounts set game_tokens = game_tokens + tot_tokens
      where id = a.id;
    bal := bal + tot_tokens;
  end if;

  return jsonb_build_object(
    'tokens_now', bal,
    'results', results,
    'totals', jsonb_build_object(
      'tokens', tot_tokens, 'pr', tot_pr, 'pj', tot_pj));
end $$;

-- keep the ledger default in step (inserts always pass cost explicitly)
alter table cps.plinko_drops alter column cost set default 3;

notify pgrst, 'reload schema';
