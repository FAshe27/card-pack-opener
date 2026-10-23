-- 175_vault_breaker_verify.sql — post-auth smoke test for migration
-- 175 (Vault Breaker first-tile safety). Run AFTER
-- 175_vault_breaker_first_tile_safety.sql, on Franklin's go.
--
-- Plants temp sessions (in-transaction) on a real non-admin account
-- and a real admin account, sets deterministic in-transaction
-- balances, FORCES the non-admin's dealt board so the first pick is
-- a known alarm (the smoke runs as the database owner, so it may
-- rewrite cps.vault_runs.alarms in-transaction), plays the real RPCs
-- and ROLLS BACK: no runs, packs, tokens, quest progress,
-- notifications or sessions persist.
--
-- PRECONDITION: the picked accounts must not have a Vault Breaker
-- run open (the smoke aborts with a clear message otherwise).
-- Expected: one NOTICE line, every check true.
begin;

do $$
declare
  pid      uuid;  -- a real non-admin player
  aid      uuid;  -- a real admin
  ptok     text := 'smoke175-player-0000001';
  atok     text := 'smoke175-admin-00000001';
  r        jsonb;
  v_dealt  int[];
  v_forced int[];
  v_now    int[];
  v_safe   int[];
  x        int;
  added    int[];
  removed  int[];
  dupes    boolean;
  i        int;
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

  -- 1) state still answers for the non-admin -------------------------
  r := public.cps_vault_state(ptok);
  if (r ->> 'tokens_now')::int <> 50 then raise exception 'SMOKE FAIL state balance'; end if;
  if r -> 'run' <> 'null'::jsonb then raise exception 'SMOKE FAIL state run not null'; end if;

  -- 2) FIRST PICK IS A KNOWN ALARM -> must resolve safe, relocated ----
  r := public.cps_vault_start(ptok, 3);
  if (r ->> 'tokens_now')::int <> 47 then raise exception 'SMOKE FAIL start charge'; end if;
  select alarms into v_dealt from cps.vault_runs
   where account_id = pid and status = 'active';
  if array_length(v_dealt, 1) <> 3 then raise exception 'SMOKE FAIL board size'; end if;
  select min(t) into x from generate_series(0, 24) t where t <> all (v_dealt);
  v_forced := array[x] || v_dealt[1:2];
  update cps.vault_runs set alarms = v_forced
   where account_id = pid and status = 'active';

  r := public.cps_vault_pick(ptok, x);
  if (r -> 'run' ->> 'status') <> 'active' then
    raise exception 'SMOKE FAIL: first-alarm pick busted (status %)', r -> 'run' ->> 'status'; end if;
  if (r -> 'run' ->> 'depth')::int <> 1 then raise exception 'SMOKE FAIL first pick depth'; end if;
  if r -> 'run' -> 'alarms' <> 'null'::jsonb then
    raise exception 'SMOKE FAIL: alarms leaked while the run is active'; end if;
  select alarms into v_now from cps.vault_runs
   where account_id = pid and status = 'active';
  if array_length(v_now, 1) <> 3 then raise exception 'SMOKE FAIL: alarm count changed'; end if;
  if x = any (v_now) then raise exception 'SMOKE FAIL: picked tile still an alarm'; end if;
  select (count(*) <> count(distinct u)) into dupes from unnest(v_now) u;
  if dupes then raise exception 'SMOKE FAIL: duplicate alarms after relocation'; end if;
  removed := array(select unnest(v_forced) except select unnest(v_now));
  if removed <> array[x] then raise exception 'SMOKE FAIL: removed set % ', removed; end if;
  added := array(select unnest(v_now) except select unnest(v_forced));
  if coalesce(array_length(added, 1), 0) <> 1 then
    raise exception 'SMOKE FAIL: relocated set %', added; end if;
  if added[1] = x or added[1] = any (v_forced) then
    raise exception 'SMOKE FAIL: alarm relocated onto an invalid tile'; end if;

  -- 3) SECOND PICK on a known alarm -> BUSTS, reveal keeps first safe -
  r := public.cps_vault_pick(ptok, v_now[1]);
  if (r -> 'run' ->> 'status') <> 'busted' then raise exception 'SMOKE FAIL: pick 2 did not bust'; end if;
  if jsonb_array_length(r -> 'run' -> 'alarms') <> 3 then
    raise exception 'SMOKE FAIL: bust reveal count'; end if;
  if r -> 'run' -> 'alarms' @> jsonb_build_array(x) then
    raise exception 'SMOKE FAIL: first tile shows as alarm in the reveal'; end if;
  if (r ->> 'tokens_now')::int <> 47 then raise exception 'SMOKE FAIL: bust moved tokens'; end if;

  -- 4) no-active-run + insufficient funds errors unchanged ------------
  begin
    perform public.cps_vault_pick(ptok, 0);
    raise exception 'SMOKE FAIL: pick accepted with no active run';
  exception when others then
    if sqlerrm <> 'No active Vault Breaker run.' then
      raise exception 'SMOKE FAIL no-run error was %', sqlerrm; end if;
  end;
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
  select alarms into v_dealt from cps.vault_runs
   where account_id = aid and status = 'active';
  select array_agg(t) into v_safe from generate_series(0, 24) t where t <> all (v_dealt);
  for i in 1..4 loop
    r := public.cps_vault_pick(atok, v_safe[i]);
  end loop;
  r := public.cps_vault_cashout(atok);
  if (r ->> 'tokens_now')::int <> 10 then raise exception 'SMOKE FAIL admin refund'; end if;
  if r -> 'run' -> 'banked' <> '{"tokens":3,"pr":0,"pj":0}'::jsonb then
    raise exception 'SMOKE FAIL admin banked'; end if;

  raise notice 'SMOKE 175 PASS: forced first-alarm pick resolved safe with relocation (count/set exact), pick-2 alarm busted with first tile safe in reveal, error paths unchanged, admin regression exact (rolling back)';
end $$;

rollback;
