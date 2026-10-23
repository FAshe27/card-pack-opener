-- =====================================================================
-- 174_vault_breaker_phase_b.sql -- Vault Breaker Phase B: remove the
-- Phase A admin gate. (Run after 173.)
--
--   Franklin (2026-10-22): "Can you test Vault Breaker some? And if
--   it's good - switch it to live!" Phase A testing passed, so the
--   game goes public in the Arcade.
--
--   What this does, and nothing else: re-issues the four public vault
--   RPCs from migration 171 with the Phase A gate line
--     if not a.is_admin then raise exception 'Admin only.'; end if;
--   removed from each one (4 lines total, one per RPC). Every other
--   line is byte-identical to 171's definitions, which were read back
--   from the production database (pg_proc.prosrc, verbatim match)
--   before this file was built; the deletion-only diff is proven.
--   Auth (cps.auth) still runs first in every RPC; non-admin players
--   simply stop hitting the Phase A gate. The Plinko 147 /
--   Scratchoffs 146 graduation shape.
--
--   Client side of Phase B (same ship): vaultbreaker.js registration
--   flipped to status 'public' + noTab: true, and the Arcade lobby
--   teaser tile swapped for a live tile opening sbx-vaultbreaker.
-- =====================================================================

begin;

-- --- state: balance + prize tables + any active run (resume) ------------
create or replace function public.cps_vault_state(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
  r   cps.vault_runs%rowtype;
begin
  a := cps.auth(p_token);
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  return jsonb_build_object(
    'tokens_now', bal,
    'cost', 3,
    'tables', cps.vault_all_tables(),
    'run', case when r.id is null then null
                else cps.vault_run_json(r, bal) end
  );
end $$;

-- --- start: charge 3 tokens, deal the board server-side -----------------
-- An already-active run is resumed and returned, never double-charged
-- (the Scratchoffs buy pattern), so a client retry is always safe.
create or replace function public.cps_vault_start(p_token text, p_mode int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  bal    int;
  r      cps.vault_runs%rowtype;
  alarms int[];
begin
  a := cps.auth(p_token);
  if p_mode is null or p_mode not in (3, 5, 8) then
    raise exception 'Pick a vault: 3, 5 or 8 alarms.';
  end if;

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  if r.id is not null then
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'tokens_now', bal,
      'run', cps.vault_run_json(r, bal),
      'resumed', true
    );
  end if;

  -- lock the account row and charge the entry up front
  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < 3 then
    raise exception 'Not enough game tokens (need 3).';
  end if;
  update cps.accounts set game_tokens = game_tokens - 3 where id = a.id;
  bal := bal - 3;

  -- deal: p_mode distinct tiles out of 0..24, stored sorted
  select array_agg(x order by x) into alarms from (
    select t as x from generate_series(0, 24) as t
     order by cps.rand01() limit p_mode
  ) s;

  insert into cps.vault_runs (account_id, mode, alarms)
  values (a.id, p_mode, alarms)
  returning * into r;

  return jsonb_build_object(
    'tokens_now', bal,
    'run', cps.vault_run_json(r, bal),
    'resumed', false
  );
end $$;

-- --- pick: crack one tile -------------------------------------------------
create or replace function public.cps_vault_pick(p_token text, p_tile int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  r      cps.vault_runs%rowtype;
  bal    int;
  settle jsonb := null;
begin
  a := cps.auth(p_token);
  if p_tile is null or p_tile < 0 or p_tile > 24 then
    raise exception 'Bad tile.';
  end if;

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1 for update;
  if r.id is null then raise exception 'No active Vault Breaker run.'; end if;
  if p_tile = any (r.picks) then
    raise exception 'That tile is already cracked.';
  end if;

  if p_tile = any (r.alarms) then
    update cps.vault_runs
       set status = 'busted', ended_at = now()
     where id = r.id
     returning * into r;
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'run', cps.vault_run_json(r, bal),
      'tokens_now', bal
    );
  end if;

  update cps.vault_runs
     set picks = picks || p_tile, depth = depth + 1
   where id = r.id
   returning * into r;

  if r.depth >= 25 - r.mode then
    -- last safe tile cracked: full clear auto-banks the top tier
    settle := cps.vault_settle(a, r.id);
    select * into r from cps.vault_runs where id = r.id;
  end if;

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'run', cps.vault_run_json(r, bal),
    'tokens_now', bal,
    'grants', coalesce(settle -> 'grants', '[]'::jsonb)
  );
end $$;

-- --- cash out: bank the highest tier reached ------------------------------
create or replace function public.cps_vault_cashout(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  r      cps.vault_runs%rowtype;
  bal    int;
  settle jsonb;
begin
  a := cps.auth(p_token);

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  if r.id is null then raise exception 'No active Vault Breaker run.'; end if;

  settle := cps.vault_settle(a, r.id); -- raises below the first tier
  select * into r from cps.vault_runs where id = r.id;
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'run', cps.vault_run_json(r, bal),
    'tokens_now', bal,
    'grants', settle -> 'grants'
  );
end $$;
commit;

notify pgrst, 'reload schema';
