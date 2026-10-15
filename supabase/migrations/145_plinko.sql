-- =====================================================================
-- 145_plinko.sql -- Plinko: real economy (Sandbox, admin-only phase).
--   Plinko graduates from fake test tokens to the real economy, the same
--   way Scratchoffs did in 129: real game tokens in, real packs out,
--   with the SERVER deciding every drop. Still a Sandbox 'testing'
--   item: every RPC raises unless the caller is an admin. Dropping the
--   admin gate is the separate graduation step, later.
--
--   Game shape (unchanged from the prototype Franklin tuned):
--     2 tokens per drop; Drop 1 or Drop 10 per call. 8 peg rows, the
--     chip falls left/right 50/50 per row, so the 9 bins land with
--     binomial odds C(8,k)/256 (centre 70/256, edges 1/256 each).
--     The server rolls the 8 steps, stores the drop in cps.plinko_drops
--     and pays at once; the client only animates the path it is given.
--
--   Prizes by bin (left to right) -- must match CONFIG.bins in
--   js/plinko.js; the server is authoritative:
--     bin 0 / 8: 20 random packs        bin 4:    1 random pack
--     bin 1 / 7: 3 random + 3 jumbled   bin 3 / 5: 3 tokens back
--     bin 2 / 6: 1 jumbled pack
--   Random packs are granted one at a time to a random active set
--   (cps.add_packs, reason 'plinko_win'), exactly like scratch wins.
--   Every RPC takes p_token (client always sends one).
-- =====================================================================

-- --- drop ledger -------------------------------------------------------
create table if not exists cps.plinko_drops (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references cps.accounts(id) on delete cascade,
  bin           int not null check (bin between 0 and 8),
  steps         int[] not null,
  cost          int not null default 2,
  tokens_back   int not null default 0,
  packs_random  int not null default 0,
  packs_jumbled int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists cps_plinko_drops_account_idx
  on cps.plinko_drops (account_id, created_at desc);

-- --- prize table: returns [tokens_back, packs_random, packs_jumbled] ---
create or replace function cps.plinko_prize(p_bin int) returns int[]
language plpgsql immutable set search_path = cps, pg_temp as $$
begin
  case p_bin
    when 0, 8 then return array[0, 20, 0];
    when 1, 7 then return array[0, 3, 3];
    when 2, 6 then return array[0, 0, 1];
    when 3, 5 then return array[3, 0, 0];
    when 4    then return array[0, 1, 0];
    else raise exception 'Bad bin %', p_bin;
  end case;
end $$;

-- --- state: current real token balance ---------------------------------
create or replace function public.cps_plinko_state(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object('tokens', bal);
end $$;

-- --- drop ----------------------------------------------------------------
-- Charges 2 tokens per drop up front, rolls every drop server-side,
-- pays token-back + packs immediately, and returns the paths so the
-- client can animate exactly what the server decided.
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
  if not a.is_admin then raise exception 'Admin only.'; end if;
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
-- select cps.plinko_prize(0), cps.plinko_prize(4), cps.plinko_prize(8);
--   -> {0,20,0} {0,1,0} {0,20,0}
-- select * from cps.plinko_drops order by created_at desc limit 10;

notify pgrst, 'reload schema';
