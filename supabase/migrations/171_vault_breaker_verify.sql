-- 171_vault_breaker_verify.sql — post-auth smoke test for migration 171
-- (Vault Breaker real economy, Sandbox phase). Run AFTER
-- 171_vault_breaker.sql, and ONLY on Franklin's go (house rule: the
-- bogus-token probe answers 28000 without auth; the post-auth body
-- needs this temp-session smoke before the build is called verified).
--
-- Runs ENTIRELY in one transaction and ROLLS BACK: the Muse admin
-- test account ('Admin Account') is fixtured in-transaction (planted
-- session, token balance set in-transaction), the real RPCs are
-- called with the planted token, boards are read back from
-- cps.vault_runs (the smoke runs as the database owner, like the SQL
-- editor) so picks can be played perfectly, and nothing persists —
-- no runs, packs, tokens, quest progress, notifications or sessions
-- survive the rollback.
--
-- PRECONDITION: the admin test account must not have a Vault Breaker
-- run open when this runs (finish or bust it in the Sandbox first) —
-- the smoke aborts with a clear message if one is active.
-- Expected: one NOTICE line, every check true.
begin;

do $$
declare
  admin_id uuid;
  atok     text := 'smoke171-admin-00000001';
  r        jsonb;
  run      jsonb;
  v_alarms int[];
  v_safe   int[];
  i        int;
  packs0   int;
  packs1   int;
  notif0   int;
  notif1   int;
  audience int;
begin
  select id into admin_id from cps.accounts where display_name = 'Admin Account';
  if admin_id is null then raise exception 'Muse test account (Admin Account) not found'; end if;
  if exists (select 1 from cps.vault_runs where account_id = admin_id and status = 'active') then
    raise exception 'SMOKE ABORT: the admin test account has a Vault Breaker run open — finish it first';
  end if;

  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text(atok), admin_id, now() + interval '1 hour');

  -- deterministic in-transaction balance (rolls back)
  update cps.accounts set game_tokens = 10 where id = admin_id;
  select coalesce(sum(packs), 0) into packs0 from cps.pack_inventory where account_id = admin_id;
  select count(*) into notif0 from cps.notifications where kind = 'vault_win';
  select count(*) into audience from cps.accounts
   where id <> admin_id and not coalesce(disabled, false);

  -- 1) gates: a non-admin session must hear 'Admin only.' ----------

  -- (a second planted session on a real non-admin player)
  insert into cps.sessions (token_hash, account_id, expires_at)
  select cps.hash_text('smoke171-player-0000001'), p.id, now() + interval '1 hour'
    from cps.accounts p
   where p.id <> admin_id and not p.is_admin and not coalesce(p.disabled, false)
   order by p.display_name limit 1;
  begin
    perform public.cps_vault_state('smoke171-player-0000001');
    raise exception 'SMOKE FAIL: non-admin reached vault_state';
  exception when others then
    if sqlerrm <> 'Admin only.' then
      raise exception 'SMOKE FAIL: non-admin error was %', sqlerrm; end if;
  end;

  -- 2) state: no run, tables handed over ------------------------------
  r := public.cps_vault_state(atok);
  if (r ->> 'tokens_now')::int <> 10 then raise exception 'SMOKE FAIL state balance'; end if;
  if r -> 'run' <> 'null'::jsonb then raise exception 'SMOKE FAIL state run not null'; end if;
  if jsonb_array_length(r -> 'tables' -> '3') <> 7
     or jsonb_array_length(r -> 'tables' -> '5') <> 7
     or jsonb_array_length(r -> 'tables' -> '8') <> 6
    then raise exception 'SMOKE FAIL state tables'; end if;

  -- 3) start mode 5 (charge 3), resume is free, bust ends it -----------
  r := public.cps_vault_start(atok, 5);
  if (r ->> 'tokens_now')::int <> 7 then raise exception 'SMOKE FAIL start charge'; end if;
  if r -> 'run' -> 'alarms' <> 'null'::jsonb then
    raise exception 'SMOKE FAIL: alarms leaked while the run is active'; end if;
  r := public.cps_vault_start(atok, 5);
  if not (r ->> 'resumed')::boolean then raise exception 'SMOKE FAIL resume flag'; end if;
  if (r ->> 'tokens_now')::int <> 7 then raise exception 'SMOKE FAIL resume double-charge'; end if;
  select alarms into v_alarms from cps.vault_runs
   where account_id = admin_id and status = 'active';
  if array_length(v_alarms, 1) <> 5 then raise exception 'SMOKE FAIL board size'; end if;
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  r := public.cps_vault_pick(atok, v_safe[1]);
  if (r -> 'run' ->> 'depth')::int <> 1 then raise exception 'SMOKE FAIL pick depth'; end if;
  r := public.cps_vault_pick(atok, v_alarms[1]);
  if (r -> 'run' ->> 'status') <> 'busted' then raise exception 'SMOKE FAIL bust'; end if;
  if jsonb_array_length(r -> 'run' -> 'alarms') <> 5 then
    raise exception 'SMOKE FAIL: board not revealed on bust'; end if;

  -- 4) refund-tier cash-out banks 3 tokens and bumps the quest --------
  r := public.cps_vault_start(atok, 3);
  if (r ->> 'tokens_now')::int <> 4 then raise exception 'SMOKE FAIL second charge'; end if;
  select alarms into v_alarms from cps.vault_runs
   where account_id = admin_id and status = 'active';
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  for i in 1..4 loop
    r := public.cps_vault_pick(atok, v_safe[i]);
  end loop;
  r := public.cps_vault_cashout(atok);
  if (r ->> 'tokens_now')::int <> 7 then raise exception 'SMOKE FAIL refund'; end if;
  if r -> 'run' -> 'banked' <> '{"tokens":3,"pr":0,"pj":0}'::jsonb then
    raise exception 'SMOKE FAIL banked'; end if;
  if not exists (select 1 from cps.daily_quests
                  where account_id = admin_id and quest_key = 'vault_cashout' and done)
    then raise exception 'SMOKE FAIL: vault_cashout quest not bumped'; end if;

  -- 5) full clear (mode 3): auto-banks 50 + 25 and announces ----------
  r := public.cps_vault_start(atok, 3);
  select alarms into v_alarms from cps.vault_runs
   where account_id = admin_id and status = 'active';
  select array_agg(x) into v_safe from generate_series(0, 24) x where x <> all (v_alarms);
  for i in 1..22 loop
    r := public.cps_vault_pick(atok, v_safe[i]);
  end loop;
  if (r -> 'run' ->> 'status') <> 'cashed' then raise exception 'SMOKE FAIL full clear status'; end if;
  if not (r -> 'run' ->> 'full')::boolean then raise exception 'SMOKE FAIL full flag'; end if;
  if r -> 'run' -> 'banked' <> '{"tokens":0,"pr":50,"pj":25}'::jsonb then
    raise exception 'SMOKE FAIL full clear banked'; end if;
  if not (r -> 'run' ->> 'announced')::boolean then raise exception 'SMOKE FAIL announced'; end if;
  select coalesce(sum(packs), 0) into packs1 from cps.pack_inventory where account_id = admin_id;
  if packs1 - packs0 <> 75 then
    raise exception 'SMOKE FAIL pack delta %', packs1 - packs0; end if;
  select count(*) into notif1 from cps.notifications where kind = 'vault_win';
  if notif1 - notif0 <> audience then
    raise exception 'SMOKE FAIL announcement audience % <> %', notif1 - notif0, audience; end if;
  if not exists (select 1 from cps.notifications
                  where kind = 'vault_win'
                    and text like '%FULL-CLEARED the Day Job vault%'
                    and text like '%50 random packs + 25 Jumbled packs%')
    then raise exception 'SMOKE FAIL announcement text'; end if;
  if exists (select 1 from cps.notifications
              where kind = 'vault_win' and account_id = admin_id)
    then raise exception 'SMOKE FAIL: winner got their own announcement'; end if;

  -- 6) insufficient funds ----------------------------------------------
  update cps.accounts set game_tokens = 2 where id = admin_id;
  begin
    perform public.cps_vault_start(atok, 3);
    raise exception 'SMOKE FAIL: start accepted with 2 tokens';
  exception when others then
    if sqlerrm <> 'Not enough game tokens (need 3).' then
      raise exception 'SMOKE FAIL funds error was %', sqlerrm; end if;
  end;

  raise notice 'SMOKE 171 PASS: gates, state, start/resume/bust, refund cash-out + quest, full clear + announcement, funds — all checks true (rolling back)';
end $$;

rollback;
