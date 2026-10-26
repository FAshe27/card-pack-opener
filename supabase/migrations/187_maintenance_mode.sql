-- =====================================================================
-- 187: Maintenance mode — a full-screen block for players while big
-- pushes/migrations happen, enforced server-side, with an admin
-- bypass and an admin-panel toggle.
--
-- Franklin's go (2026-10-25): "Build it and push the maintenance
-- screen — would definitely want to use it for big future pushes."
-- Standing rule still applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * Config rows in cps.app_config: maintenance_enabled (jsonb
--    boolean, default false), maintenance_message (jsonb string,
--    default ''), maintenance_eta (jsonb string, default '').
--  * Internal helpers cps.maintenance_on() / _message() / _eta()
--    (never raise — fail-open: any error or missing row reads as
--    maintenance OFF).
--  * public.cps_site_status(p_token default null): callable with the
--    publishable key, NO session required. Returns
--    {maintenance, message, eta, is_admin}. is_admin is true only
--    when p_token resolves directly against cps.sessions /
--    cps.accounts to a live non-disabled ADMIN session. It does NOT
--    call cps.auth (it must work DURING maintenance, for everyone,
--    including logged-out visitors). Any error => maintenance:false.
--  * public.cps_admin_set_maintenance(p_token, p_enabled, p_message,
--    p_eta): admin-only via cps.auth(p_token, true) — admins bypass
--    maintenance, so this works while maintenance is on. Upserts
--    the three config keys (message capped at 500 chars, ETA at
--    200) and returns the new status object.
--  * ONE surgical edit: cps.auth gains a single inserted block
--    (marked [187 INSERT]) after the disabled-account check: while
--    maintenance is on, a NON-admin account raises
--    'MAINTENANCE: <configured message>' with errcode P0001. That is
--    the backstop — every token RPC fails closed for non-admins.
--    The client treats cps_site_status as the primary UX truth.
--    Errcode choice is deliberate: cloud.js maps ONLY 28000 to its
--    'auth' error kind, and app.js CLEARS the session token on auth
--    errors. P0001 maps to a plain server error, so a blocked
--    player's token survives and they are still logged in the
--    moment maintenance lifts. No other existing function is
--    touched — cps_login in particular is unchanged: logging in
--    still works during maintenance; the follow-up get_state call
--    is what blocks non-admins (and cps_logout never calls cps.auth
--    at all — verified in 001 — so log out works throughout).
--
-- The cps.auth text below is assembled verbatim from 001_core.sql
-- on GitHub main (ba61f2aa) by validation/build_187.py; cps.auth has
-- exactly one definition across all migrations (001; none of
-- 002-186 redefine it). check_sql.py proves the insertion-only diff.
--
-- EMERGENCY OFF (any time, SQL editor / connector, no client push
-- needed):
--   update cps.app_config set value = 'false'::jsonb
--     where key = 'maintenance_enabled';
-- =====================================================================

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('maintenance_enabled', 'false'),
  ('maintenance_message', '""'),
  ('maintenance_eta', '""')
on conflict (key) do nothing;

-- ------------------------------------------------------- internal helpers
-- Fail-open by construction: these never raise.
create or replace function cps.maintenance_on() returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  begin
    return coalesce(cps.cfg('maintenance_enabled'), 'false'::jsonb) = 'true'::jsonb;
  exception when others then
    return false;
  end;
end $$;

create or replace function cps.maintenance_message() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare m text;
begin
  begin
    m := cps.cfg('maintenance_message') #>> '{}';
  exception when others then
    m := null;
  end;
  return coalesce(nullif(btrim(m), ''), 'We''re making some improvements. Back soon!');
end $$;

create or replace function cps.maintenance_eta() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := cps.cfg('maintenance_eta') #>> '{}';
  exception when others then
    v := null;
  end;
  return coalesce(v, '');
end $$;

revoke execute on function cps.maintenance_on() from public;
revoke execute on function cps.maintenance_message() from public;
revoke execute on function cps.maintenance_eta() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function cps.maintenance_on() from anon, authenticated';
    execute 'revoke execute on function cps.maintenance_message() from anon, authenticated';
    execute 'revoke execute on function cps.maintenance_eta() from anon, authenticated';
  end if;
end $$;

-- -------------------------------------- cps.auth: surgical rebuild (001)
-- Assembled from the verbatim 001 body; the ONLY change is the block
-- between the [187 INSERT] markers. Removing it reproduces 001
-- byte-for-byte (validation/check_sql.py).
create or replace function cps.auth(p_token text, p_admin boolean default false) returns cps.accounts
language plpgsql volatile set search_path = cps, pg_temp as $$
declare s cps.sessions%rowtype; a cps.accounts%rowtype;
begin
  if p_token is null or length(p_token) < 20 then raise exception 'Not logged in' using errcode = '28000'; end if;
  select * into s from cps.sessions where token_hash = cps.hash_text(p_token);
  if not found or s.expires_at < now() then raise exception 'Session expired. Please log in again.' using errcode = '28000'; end if;
  select * into a from cps.accounts where id = s.account_id;
  if not found or a.disabled then raise exception 'This account is disabled.' using errcode = '28000'; end if;
  -- [187 INSERT] Maintenance mode: while maintenance_enabled is on,
  -- non-admin accounts stop HERE, in the one function every token RPC
  -- resolves through. Admins always pass (push / test / recovery path).
  -- Fail-open: missing or unreadable config reads as OFF
  -- (cps.maintenance_on never raises). Errcode P0001 is deliberate:
  -- cloud.js maps only 28000 to its auth error kind (which CLEARS the
  -- session token); P0001 lands as a plain server error, so a blocked
  -- player's session is never cleared and they are still logged in
  -- when the flag lifts.
  if not a.is_admin and cps.maintenance_on() then
    raise exception 'MAINTENANCE: %', cps.maintenance_message()
      using errcode = 'P0001';
  end if;
  -- [/187 INSERT]
  if p_admin and not a.is_admin then raise exception 'Admin only' using errcode = '42501'; end if;
  if s.last_used_at < now() - interval '1 hour' then
    update cps.sessions set last_used_at = now() where token_hash = s.token_hash;
  end if;
  return a;
end $$;

-- ---------------------------------------------------------------- status
-- Callable with the publishable key, with or without a session.
-- Never calls cps.auth. Fail-safe: any error => maintenance false.
create or replace function public.cps_site_status(p_token text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare v_on boolean := false; v_admin boolean := false;
        s cps.sessions%rowtype; a cps.accounts%rowtype;
begin
  begin
    v_on := cps.maintenance_on();
  exception when others then
    v_on := false;
  end;
  begin
    if p_token is not null and length(p_token) >= 20 then
      select * into s from cps.sessions where token_hash = cps.hash_text(p_token);
      if found and s.expires_at >= now() then
        select * into a from cps.accounts where id = s.account_id;
        if found and not a.disabled and a.is_admin then v_admin := true; end if;
      end if;
    end if;
  exception when others then
    v_admin := false;
  end;
  return jsonb_build_object(
    'maintenance', v_on,
    'message', cps.maintenance_message(),
    'eta', cps.maintenance_eta(),
    'is_admin', v_admin);
end $$;

-- ------------------------------------------------------------- admin toggle
create or replace function public.cps_admin_set_maintenance(p_token text, p_enabled boolean, p_message text default '', p_eta text default '')
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  insert into cps.app_config (key, value) values
    ('maintenance_enabled', to_jsonb(coalesce(p_enabled, false))),
    ('maintenance_message', to_jsonb(left(coalesce(p_message, ''), 500))),
    ('maintenance_eta', to_jsonb(left(coalesce(p_eta, ''), 200)))
  on conflict (key) do update set value = excluded.value;
  return jsonb_build_object(
    'maintenance', cps.maintenance_on(),
    'message', cps.maintenance_message(),
    'eta', cps.maintenance_eta(),
    'is_admin', true);
end $$;

-- ---------------------------------------------------------------- grants
do $$ begin
  execute 'revoke all on function public.cps_site_status(text) from public';
  execute 'revoke all on function public.cps_admin_set_maintenance(text, boolean, text, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_site_status(text) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_set_maintenance(text, boolean, text, text) to anon, authenticated';
  end if;
end $$;

-- let the API pick up the new functions right away
notify pgrst, 'reload schema';
