-- =====================================================================
-- 175_vault_breaker_first_tile_safety.sql -- Vault Breaker: the first
-- tile of a run is always safe. (Run after 174.)
--
--   Franklin (2026-10-23): "Ship the first-tile safety" -- after the
--   design and its odds impact were put to him (reach chances rise:
--   e.g. Day Job 4 tiles 57.8% -> 65.7%, Inside Job 2 tiles 45.3% ->
--   66.7%; the client odds table is updated in the same ship).
--
--   What this does, and nothing else: re-issues ONLY
--   public.cps_vault_pick, from its live production body
--   (pg_proc.prosrc, read back 2026-10-23, byte-identical to the 174
--   definition), with exactly two insertions:
--     1. one local declaration (dest int), and
--     2. one block before the bust branch implementing first-tile
--        safety: when the run has zero cracked tiles and the picked
--        tile is an alarm, that one alarm is relocated to a uniformly
--        random tile that is not the picked tile, not already an
--        alarm and not already cracked; the updated alarms array is
--        persisted, and the pick then resolves as safe.
--   The alarm count never changes, the relocated alarm stays hidden
--   (alarms only leave the server once a run is over), and picks 2+
--   behave byte-for-byte as before. The relocation runs inside the
--   pick's existing transaction, under the run row's FOR UPDATE
--   lock, so a double-click cannot race it. Removing the two
--   inserted spans reproduces the live body byte-for-byte (proven at
--   build time); no other function is redefined.
--
--   Client side (same ship): js/vaultbreaker.js -- the Payouts &
--   odds reach chances move to the first-tile-safe math (plus a
--   "First tile is always safe." note in the dropdown), and a
--   "<- Back to Arcade" button mirroring Plinko/Roulette is added
--   (with its .vb-backrow rule in css/vaultbreaker.css).
-- =====================================================================

begin;

-- --- pick: crack one tile (175: first-tile safety) -------------------------
create or replace function public.cps_vault_pick(p_token text, p_tile int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  r      cps.vault_runs%rowtype;
  bal    int;
  dest   int;
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

  -- First-tile safety (migration 175): the first pick of a run
  -- can never be an alarm. If the picked tile was dealt as an
  -- alarm, quietly move that one alarm to a uniformly random tile
  -- that is not the picked tile, not already an alarm and not
  -- already cracked, then let the pick resolve as safe. The alarm
  -- count never changes, the moved alarm stays hidden, and picks
  -- 2+ behave exactly as before. This runs under the run row's
  -- FOR UPDATE lock above, so a double-click cannot race it.
  if coalesce(array_length(r.picks, 1), 0) = 0 and p_tile = any (r.alarms) then
    select t into dest
      from generate_series(0, 24) as t
     where t <> p_tile
       and t <> all (r.alarms)
       and t <> all (coalesce(r.picks, array[]::int[]))
     order by random()
     limit 1;
    update cps.vault_runs
       set alarms = array_remove(alarms, p_tile) || dest
     where id = r.id
     returning * into r;
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

commit;

notify pgrst, 'reload schema';
