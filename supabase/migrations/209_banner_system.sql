-- =====================================================================
-- 209: Banner system — a slim across-the-top announcement line that
-- Franklin can write, style and toggle from the Admin panel, shown
-- live to every active player (e.g. in the run-up to a maintenance
-- window: "Heads up — PackRipper goes down for a tune-up tonight
-- around 9 PM Central").
--
-- Franklin's ask (2026-10-27): "Can we build a banner system? An
-- across-the-top line of text that I can customize and toggle in
-- the admin panel to send out info to active users (like, leading
-- up to a maintenance window)?"
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * Config rows in cps.app_config: banner_enabled (jsonb boolean,
--    default false), banner_text (jsonb string, default ''),
--    banner_style (jsonb string, default 'info'; one of
--    info / warning / urgent), banner_dismissible (jsonb boolean,
--    default true), banner_version (jsonb integer, default 0 —
--    bumped on EVERY admin save, so editing or re-toggling the
--    banner re-shows it to players who dismissed the old one).
--  * Internal helpers cps.banner_on() / _text() / _style() /
--    _dismissible() / _version() / _obj() (never raise — fail-open:
--    any error or missing row reads as banner OFF, exactly like
--    the maintenance helpers in 187).
--  * public.cps_site_status (187) gains ONE added key: its return
--    object now also carries 'banner' => cps.banner_obj(). Every
--    existing key (maintenance / message / eta / is_admin) is
--    byte-for-byte unchanged, so the live maintenance client keeps
--    working untouched. The banner client reuses this same status
--    RPC and its 60-second poll — active players see a new banner
--    within about a minute, no reload needed.
--  * public.cps_admin_set_banner(p_token, p_enabled, p_text,
--    p_style, p_dismissible): admin-only via cps.auth(p_token,
--    true). Upserts the five config keys (text capped at 200
--    chars, style whitelisted server-side) and returns the new
--    banner object.
--  * NOTHING else is touched. cps.auth is NOT rebuilt (no
--    enforcement here — a banner is information, not a block), no
--    session is touched, and the banner never gates anything.
--
-- EMERGENCY OFF (any time, SQL editor / connector, no client push
-- needed):
--   update cps.app_config set value = 'false'::jsonb
--     where key = 'banner_enabled';
-- =====================================================================

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('banner_enabled', 'false'),
  ('banner_text', '""'),
  ('banner_style', '"info"'),
  ('banner_dismissible', 'true'),
  ('banner_version', '0')
on conflict (key) do nothing;

-- ------------------------------------------------------- internal helpers
-- Fail-open by construction: these never raise.
create or replace function cps.banner_on() returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  begin
    return coalesce(cps.cfg('banner_enabled'), 'false'::jsonb) = 'true'::jsonb;
  exception when others then
    return false;
  end;
end $$;

create or replace function cps.banner_text() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := cps.cfg('banner_text') #>> '{}';
  exception when others then
    v := null;
  end;
  return coalesce(v, '');
end $$;

create or replace function cps.banner_style() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := lower(coalesce(cps.cfg('banner_style') #>> '{}', 'info'));
  exception when others then
    v := 'info';
  end;
  return case when v in ('info', 'warning', 'urgent') then v else 'info' end;
end $$;

create or replace function cps.banner_dismissible() returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  begin
    return coalesce(cps.cfg('banner_dismissible'), 'true'::jsonb) = 'true'::jsonb;
  exception when others then
    return true;
  end;
end $$;

create or replace function cps.banner_version() returns integer
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := cps.cfg('banner_version') #>> '{}';
  exception when others then
    v := null;
  end;
  return coalesce(nullif(v, '')::integer, 0);
end $$;

-- The one object both the status RPC and the admin setter return.
-- enabled is ANDed with "there is text to show": a banner toggled
-- on with empty text shows nothing, anywhere.
create or replace function cps.banner_obj() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  return jsonb_build_object(
    'enabled', cps.banner_on() and btrim(cps.banner_text()) <> '',
    'text', cps.banner_text(),
    'style', cps.banner_style(),
    'dismissible', cps.banner_dismissible(),
    'version', cps.banner_version());
end $$;

revoke execute on function cps.banner_on() from public;
revoke execute on function cps.banner_text() from public;
revoke execute on function cps.banner_style() from public;
revoke execute on function cps.banner_dismissible() from public;
revoke execute on function cps.banner_version() from public;
revoke execute on function cps.banner_obj() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function cps.banner_on() from anon, authenticated';
    execute 'revoke execute on function cps.banner_text() from anon, authenticated';
    execute 'revoke execute on function cps.banner_style() from anon, authenticated';
    execute 'revoke execute on function cps.banner_dismissible() from anon, authenticated';
    execute 'revoke execute on function cps.banner_version() from anon, authenticated';
    execute 'revoke execute on function cps.banner_obj() from anon, authenticated';
  end if;
end $$;

-- ------------------------------------------------- status (187 + banner)
-- Verbatim 187 body with ONE addition, marked [209 ADD]: the final
-- 'banner' key in the returned object. Removing the marked segment
-- reproduces the 187 body byte-for-byte (validation/check_sql.py).
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
    'is_admin', v_admin,
    -- [209 ADD] the banner object rides the same status poll
    'banner', cps.banner_obj());
    -- [/209 ADD]
end $$;

-- ------------------------------------------------------------- admin setter
create or replace function public.cps_admin_set_banner(p_token text, p_enabled boolean, p_text text default '', p_style text default 'info', p_dismissible boolean default true)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
        v_style text;
        v_version integer;
begin
  a := cps.auth(p_token, true);
  v_style := case when lower(coalesce(p_style, '')) in ('info', 'warning', 'urgent')
                  then lower(p_style) else 'info' end;
  v_version := cps.banner_version() + 1;
  insert into cps.app_config (key, value) values
    ('banner_enabled', to_jsonb(coalesce(p_enabled, false))),
    ('banner_text', to_jsonb(left(coalesce(p_text, ''), 200))),
    ('banner_style', to_jsonb(v_style)),
    ('banner_dismissible', to_jsonb(coalesce(p_dismissible, true))),
    ('banner_version', to_jsonb(v_version))
  on conflict (key) do update set value = excluded.value;
  return cps.banner_obj();
end $$;

-- ---------------------------------------------------------------- grants
do $$ begin
  execute 'revoke all on function public.cps_site_status(text) from public';
  execute 'revoke all on function public.cps_admin_set_banner(text, boolean, text, text, boolean) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_site_status(text) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_set_banner(text, boolean, text, text, boolean) to anon, authenticated';
  end if;
end $$;

-- let the API pick up the new/changed functions right away
notify pgrst, 'reload schema';
