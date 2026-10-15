-- =====================================================================
-- 147_plinko_graduation.sql -- Plinko goes PUBLIC.
--   Franklin approved the launch on 2026-10-14 after the final Sandbox
--   test on real tokens (every drop reconciled) and the mobile play
--   test. This migration removes ONLY the admin-only gate from
--   migration 145's two RPCs (state / drop) so any signed-in player
--   can play. Every function below is 145's body byte-for-byte with
--   exactly one line removed:
--     if not a.is_admin then raise exception 'Admin only.'; end if;
--   Nothing else changes: the server still rolls every drop itself,
--   charges 2 tokens per drop up front, stores each drop in
--   cps.plinko_drops, and pays the tuned bin prizes exactly as 145
--   set them. (Same graduation shape as 146 for Scratchoffs.)
-- =====================================================================

create or replace function public.cps_plinko_state(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
begin
  a := cps.auth(p_token);
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object('tokens', bal);
end $$;

create or replace function public.cps_plinko_drop(p_token text, p_drops int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  bal         int;
  cost_each   int := 2;
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

-- --- verification (run after executing) ----------------------------------
-- A bogus-token probe of cps_plinko_state should still answer
-- 28000 'Not logged in' (auth first); a NON-admin account can now
-- call both RPCs without 'Admin only.'.

notify pgrst, 'reload schema';
