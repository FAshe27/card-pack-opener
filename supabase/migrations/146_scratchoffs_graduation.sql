-- =====================================================================
-- 146_scratchoffs_graduation.sql -- Scratchoffs goes PUBLIC.
--   Franklin approved the launch after the 2026-10-14 final Sandbox
--   test (buy / scratch / refresh-resume / claim-once all verified on
--   real tokens). This migration removes ONLY the admin-only gate from
--   migration 129's three RPCs (state / buy / claim) so any signed-in
--   player can play. Every function below is 129's body byte-for-byte
--   with exactly one line removed:
--     if not a.is_admin then raise exception 'Admin only.'; end if;
--   Nothing else changes: the server still decides and stores the
--   ticket at purchase, scratching is reveal-only, claim pays exactly
--   once, and all costs/prizes stay as 129 set them.
--   Plinko is NOT graduated by this file — it keeps its admin gate
--   (migration 145) and stays in the Sandbox.
-- =====================================================================

create or replace function public.cps_scratch_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
  t   cps.scratch_tickets%rowtype;
begin
  a := cps.auth(p_token);
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  select * into t from cps.scratch_tickets
    where account_id = a.id and not claimed
    order by created_at desc limit 1;
  return jsonb_build_object(
    'tokens_now', bal,
    'ticket', case when t.id is null then null
                   else cps.scratch_ticket_json(t) end
  );
end $$;

create or replace function public.cps_scratch_buy(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  bal     int;
  cost    int;
  t       cps.scratch_tickets%rowtype;
  outcome text;
  prize   int[];
begin
  a := cps.auth(p_token);

  select * into t from cps.scratch_tickets
    where account_id = a.id and not claimed
    order by created_at desc limit 1;
  if t.id is not null then
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'ticket', cps.scratch_ticket_json(t),
      'tokens_now', bal,
      'resumed', true
    );
  end if;

  cost := cps.scratch_cost(p_tier);
  if cost is null then raise exception 'Unknown scratch ticket tier.'; end if;

  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < cost then
    raise exception 'Not enough game tokens (need %).', cost;
  end if;
  update cps.accounts set game_tokens = game_tokens - cost where id = a.id;

  outcome := cps.scratch_roll_outcome();
  prize := cps.scratch_prize(p_tier, outcome);
  insert into cps.scratch_tickets
    (account_id, tier, outcome, cells, packs_random, packs_jumbled)
  values
    (a.id, p_tier, outcome, cps.scratch_make_cells(outcome), prize[1], prize[2])
  returning * into t;

  return jsonb_build_object(
    'ticket', cps.scratch_ticket_json(t),
    'tokens_now', bal - cost,
    'resumed', false
  );
end $$;

create or replace function public.cps_scratch_claim(p_token text, p_ticket uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  t           cps.scratch_tickets%rowtype;
  bal         int;
  active_sets text[];
  grants      jsonb := '[]';
  i           int;
  rset        text;
begin
  a := cps.auth(p_token);

  select * into t from cps.scratch_tickets
    where id = p_ticket and account_id = a.id for update;
  if t.id is null then raise exception 'Ticket not found.'; end if;

  if not t.claimed then
    if t.packs_jumbled > 0 then
      perform cps.add_packs(a.id, 'jumbled', t.packs_jumbled, 'scratch_win', t.outcome, null);
    end if;
    if t.packs_random > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for scratch prizes.';
      end if;
      for i in 1..t.packs_random loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'scratch_win', t.outcome, null);
        grants := grants || jsonb_build_object('set_id', rset, 'packs', 1);
      end loop;
    end if;
    update cps.scratch_tickets
      set claimed = true, claimed_at = now() where id = t.id;
  end if;

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'win',           t.outcome is not null,
    'outcome',       t.outcome,
    'packs_random',  t.packs_random,
    'packs_jumbled', t.packs_jumbled,
    'grants',        grants,
    'already_claimed', t.claimed,
    'tokens_now',    bal
  );
end $$;

-- --- verification (run after executing) ----------------------------------
-- A bogus-token probe of cps_scratch_state should still answer
-- 28000 'Not logged in' (auth first); a NON-admin account can now
-- call all three RPCs without 'Admin only.'.

notify pgrst, 'reload schema';
