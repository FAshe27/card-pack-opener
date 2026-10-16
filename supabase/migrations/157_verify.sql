-- =====================================================================
-- 157_verify.sql — post-run smoke test for 157_whos_online.sql.
-- Plants two players + an admin with known session tokens, exercises
-- cps_heartbeat + cps_admin_online_now, and ROLLS BACK: run the whole
-- file as one script; nothing persists. Expect the final row:
--   PASS | heartbeat + online list behave
-- =====================================================================

begin;

do $$
declare
  v_admin   uuid;
  v_player  uuid;
  v_stale   uuid;
  v_before  timestamptz;
  v_after   timestamptz;
  r         jsonb;
  v_names   text;
  v_err     text;
begin
  insert into cps.accounts (username_hash, username_hint, display_name, is_admin)
    values (cps.hash_text('verify_online_admin'), 've…(19)', 'Verify Admin', true)
    returning id into v_admin;
  insert into cps.accounts (username_hash, username_hint, display_name, is_admin)
    values (cps.hash_text('verify_online_player'), 've…(20)', 'Verify Player', false)
    returning id into v_player;
  insert into cps.accounts (username_hash, username_hint, display_name, is_admin)
    values (cps.hash_text('verify_online_stale'), 've…(19)', 'Verify Stale', false)
    returning id into v_stale;

  -- admin: fresh session. player: seen 4 minutes ago (inside window,
  -- but heartbeat should pull it to ~now). stale: seen 30 min ago.
  insert into cps.sessions (token_hash, account_id, expires_at, last_used_at, user_agent)
    values (cps.hash_text('verify-online-admin-token'), v_admin, now() + interval '7 days', now(), 'Mozilla/5.0 (Windows NT 10.0) Chrome/124.0');
  insert into cps.sessions (token_hash, account_id, expires_at, last_used_at, user_agent)
    values (cps.hash_text('verify-online-player-token'), v_player, now() + interval '7 days', now() - interval '4 minutes', 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1');
  insert into cps.sessions (token_hash, account_id, expires_at, last_used_at, user_agent)
    values (cps.hash_text('verify-online-stale-token'), v_stale, now() + interval '7 days', now() - interval '30 minutes', 'Mozilla/5.0');

  -- 1) heartbeat stamps the player's session fresh
  select last_used_at into v_before from cps.sessions where account_id = v_player;
  r := public.cps_heartbeat('verify-online-player-token');
  if r->>'ok' is distinct from 'true' then raise exception 'FAIL: heartbeat did not return ok'; end if;
  select last_used_at into v_after from cps.sessions where account_id = v_player;
  if v_after <= v_before then raise exception 'FAIL: heartbeat did not advance last_used_at'; end if;

  -- 2) admin list: player + admin in, stale out, payload sane
  r := public.cps_admin_online_now('verify-online-admin-token');
  select string_agg(x->>'name', ',') into v_names from jsonb_array_elements(r->'online') x;
  if v_names is null or position('Verify Player' in v_names) = 0 then raise exception 'FAIL: player missing from online list (%)', v_names; end if;
  if position('Verify Admin' in v_names) = 0 then raise exception 'FAIL: admin missing from online list (%)', v_names; end if;
  if position('Verify Stale' in v_names) > 0 then raise exception 'FAIL: stale account listed as online'; end if;
  if (r->>'count')::int <> 2 then raise exception 'FAIL: count should be 2, got %', r->>'count'; end if;
  if not exists (select 1 from jsonb_array_elements(r->'online') x
                  where x->>'name' = 'Verify Player' and x->>'device' = 'iPhone'
                    and (x->>'seconds_ago')::int < 60) then
    raise exception 'FAIL: player row payload wrong: %', r->'online';
  end if;
  if not exists (select 1 from jsonb_array_elements(r->'online') x
                  where x->>'name' = 'Verify Admin' and (x->>'is_me')::boolean) then
    raise exception 'FAIL: admin row should carry is_me';
  end if;

  -- 3) non-admin is refused (42501)
  begin
    r := public.cps_admin_online_now('verify-online-player-token');
    raise exception 'FAIL: non-admin was allowed into cps_admin_online_now';
  exception when insufficient_privilege then
    v_err := '42501 ok';
  end;

  -- 4) bogus token is refused at auth (28000)
  begin
    r := public.cps_heartbeat('bogus-token-that-is-long-enough');
    raise exception 'FAIL: bogus token passed heartbeat';
  exception when sqlstate '28000' then
    v_err := v_err || ' / 28000 ok';
  end;

  raise notice 'checks passed: %', v_err;
end $$;

select 'PASS' as result, 'heartbeat + online list behave' as detail;

rollback;
