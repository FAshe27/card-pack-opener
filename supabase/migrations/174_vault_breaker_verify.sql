-- 174_vault_breaker_verify.sql — post-auth smoke test for migration
-- 174 (Vault Breaker Phase B: admin gate removed). Run AFTER
-- 174_vault_breaker_phase_b.sql, on Franklin's go.
--
-- The point of Phase B: a NON-ADMIN player can now play. This smoke
-- plants temp sessions (in-transaction) on a real non-admin account
-- and a real admin account, sets deterministic in-transaction
-- balances, plays the real RPCs (boards are read back from
-- cps.vault_runs — the smoke runs as the database owner) and ROLLS
-- BACK: no runs, packs, tokens, quest progress, notifications or
-- sessions persist.
--
-- PRECONDITION: the picked accounts must not have a Vault Breaker
-- run open (the smoke aborts with a clear message otherwise).
-- Expected: one NOTICE line, every check true.
begin;

do $$
declare
  pid      uuid;  -- a real non-admin player
  aid      uuid;  -- a real admin
  ptok     text := 'smoke174-player-0000001';
  atok     text := 'smoke174-admin-00000001';
  r        jsonb;
  v_alarms int[];
  v_safe   int[];
  i        int;
  packs0   int;
  packs1   int;
begin
  select id into pid from cps.accounts p
   where not p.is_admin and not coalesce(p.disabled, false)
     and not exists (select 1 from cps.vault_runs vr
                      where vr.account_id = p.id and vr.status = 'active')
   order by p.display_name limit 1;
  if pid is null then raise exception 'SMOKE ABORT: no suitable non-admin account'; end if;
  select id into aid from cps.accounts p
   where p.is_admin and not coalesce(p.disabled, false)
     and not exists (select 1 from cps.vault_runs vr
                      where vr.account_id = p.id and vr.status = 'active')
   order by p.display_name limit 1;
  if aid is null then raise exception 'SMOKE ABORT: no suitable admin account'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text(ptok), pid, now() + interval '1 hour'),
    (cps.hash_text(atok), aid, now() + interval '1 hour');

  -- deterministic in-transaction balances (both roll back)
  update cps.accounts set game_tokens = 50 where id = pid;
  update cps.accounts set game_tokens = 10 where id = aid;
  select coalesce(sum(packs), 0) into packs0 from cps.pack_inventory where account_id = pid;

  -- 1) NON-ADMIN state: works now (this raised 'Admin only.' pre-174)
  r := public.cps_vault_state(ptok);
  if (r ->> 'tokens_now')::int <> 50 then raise exception 'SMOKE FAIL state balance'; end if;
  if r -> 'run' <> 'null'::jsonb then raise exception 'SMOKE FAIL state run not null'; end if;
  if jsonb_array_length(r -> 'tables' -> '3') <> 7
     or jsonb_array_length(r -> 'tables' -> '5') <> 7
     or jsonb_array_length(r -> 'tables' -> '8') <> 6
    then raise exception 'SMOKE FAIL state tables'; end if;

  -- 2) NON-ADMIN start mode 5 (charge 3), resume free, bust ends it --
  r := public.cps_vault_start(ptok, 5);
  if (r ->> 'tokens_now')::int <> 47 then raise exception 'SMOKE FAIL start charge'; end if;
  if r -> 'run' -> 'alarms' <> 'null'::jsonb then
    raise exception 'SMOKE FAIL: alarms leaked while the run is active'; end if;
  r := public.cps_vault_start(ptok, 5);
  if not (r ->> 'resumed')::boolean then raise exception 'SMOKE FAIL resume flag'; end if;
  if (r ->> 'tokens_now')::int <> 47 then raise exception 'SMOKE FAIL resume double-charge'; end if;
  select alarms into v_alarms from cps.vault_runs
   where account_id = pid and status = 'active';
  if array_length(v_alarms, 1) <> 5 then raise exception 'SMOKE FAIL board size'; end if;
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  r := public.cps_vault_pick(ptok, v_safe[1]);
  if (r -> 'run' ->> 'depth')::int <> 1 then raise exception 'SMOKE FAIL pick depth'; end if;
  r := public.cps_vault_pick(ptok, v_alarms[1]);
  if (r -> 'run' ->> 'status') <> 'busted' then raise exception 'SMOKE FAIL bust'; end if;
  if jsonb_array_length(r -> 'run' -> 'alarms') <> 5 then
    raise exception 'SMOKE FAIL: board not revealed on bust'; end if;

  -- 3) NON-ADMIN pack-tier cash-out: banks 3 Jumbled, bumps quest ----
  r := public.cps_vault_start(ptok, 3);
  if (r ->> 'tokens_now')::int <> 44 then raise exception 'SMOKE FAIL second charge'; end if;
  select alarms into v_alarms from cps.vault_runs
   where account_id = pid and status = 'active';
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  for i in 1..6 loop
    r := public.cps_vault_pick(ptok, v_safe[i]);
  end loop;
  r := public.cps_vault_cashout(ptok);
  if r -> 'run' -> 'banked' <> '{"tokens":0,"pr":0,"pj":3}'::jsonb then
    raise exception 'SMOKE FAIL banked'; end if;
  if (r ->> 'tokens_now')::int <> 44 then raise exception 'SMOKE FAIL pack tier moved tokens'; end if;
  select coalesce(sum(packs), 0) into packs1 from cps.pack_inventory where account_id = pid;
  if packs1 - packs0 <> 3 then
    raise exception 'SMOKE FAIL pack delta %', packs1 - packs0; end if;
  if (select packs from cps.pack_inventory where account_id = pid and set_id = 'jumbled') is null
    then raise exception 'SMOKE FAIL: jumbled grant missing'; end if;
  if not exists (select 1 from cps.daily_quests
                  where account_id = pid and quest_key = 'vault_cashout' and done)
    then raise exception 'SMOKE FAIL: vault_cashout quest not bumped'; end if;

  -- 4) NON-ADMIN insufficient funds -----------------------------------
  update cps.accounts set game_tokens = 2 where id = pid;
  begin
    perform public.cps_vault_start(ptok, 3);
    raise exception 'SMOKE FAIL: start accepted with 2 tokens';
  exception when others then
    if sqlerrm <> 'Not enough game tokens (need 3).' then
      raise exception 'SMOKE FAIL funds error was %', sqlerrm; end if;
  end;

  -- 5) ADMIN regression: refund-tier flow still exact ------------------
  r := public.cps_vault_start(atok, 3);
  if (r ->> 'tokens_now')::int <> 7 then raise exception 'SMOKE FAIL admin charge'; end if;
  select alarms into v_alarms from cps.vault_runs
   where account_id = aid and status = 'active';
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  for i in 1..4 loop
    r := public.cps_vault_pick(atok, v_safe[i]);
  end loop;
  r := public.cps_vault_cashout(atok);
  if (r ->> 'tokens_now')::int <> 10 then raise exception 'SMOKE FAIL admin refund'; end if;
  if r -> 'run' -> 'banked' <> '{"tokens":3,"pr":0,"pj":0}'::jsonb then
    raise exception 'SMOKE FAIL admin banked'; end if;

  raise notice 'SMOKE 174 PASS: non-admin state/start/resume/bust, pack-tier cash-out + quest, funds; admin regression — all checks true (rolling back)';
end $$;

rollback;
