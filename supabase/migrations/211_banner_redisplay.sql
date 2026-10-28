-- =====================================================================
-- 211: Banner redisplay interval — a "redisplay every [xx] minutes"
-- option for the announcement banner (209). The banner stays
-- dismissible, but when Franklin sets an interval, a player's
-- dismissal only lasts that long: once it elapses, the banner comes
-- back on their next status poll (within a minute) and stays in the
-- rotation — dismiss, wait, see it again — until the banner is
-- turned off or edited (an edit/re-save still re-shows it
-- immediately via the 209 version bump).
--
-- Franklin's ask (2026-10-27): "Can we get a 'redisplay every [xx]
-- minutes' box? I want the banner to be dismissable but if I have
-- something important up there, I'd like it to be there more than
-- enough for it to be seen and remembered."
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * One new config row in cps.app_config: banner_redisplay_minutes
--    (jsonb integer, default 0 = never redisplay — the 209
--    behaviour, so nothing changes for a banner Franklin leaves
--    at 0).
--  * Internal helper cps.banner_redisplay_minutes() (never raises —
--    fail-open: any error or missing row reads as 0; the value is
--    clamped to 0..10080 = one week).
--  * cps.banner_obj() gains ONE added key: 'redisplay_minutes'.
--    Every existing key is unchanged; the live 209 client ignores
--    the extra key, and the updated client defaults to 0 when the
--    key is absent — the two sides are safe in either ship order.
--  * public.cps_admin_set_banner is REPLACED with a 6-parameter
--    version (new last parameter p_redisplay_minutes integer
--    default 0). The old 5-parameter function is DROPPED first so
--    there is exactly one setter and no overload ambiguity (the
--    AGENTS.md overload lesson). The updated client sends all six
--    values; a straggler old client calling with the original five
--    named arguments still works — the missing parameter takes its
--    default.
--  * NOTHING else is touched: no cps.auth change, no change to
--    cps_site_status, no session changes.
--
-- EMERGENCY OFF (unchanged from 209):
--   update cps.app_config set value = 'false'::jsonb
--     where key = 'banner_enabled';
-- =====================================================================

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('banner_redisplay_minutes', '0')
on conflict (key) do nothing;

-- ------------------------------------------------------- internal helper
-- Fail-open by construction: never raises.
create or replace function cps.banner_redisplay_minutes() returns integer
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := cps.cfg('banner_redisplay_minutes') #>> '{}';
  exception when others then
    v := null;
  end;
  return least(10080, greatest(0, coalesce(nullif(v, '')::integer, 0)));
end $$;

revoke execute on function cps.banner_redisplay_minutes() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function cps.banner_redisplay_minutes() from anon, authenticated';
  end if;
end $$;

-- ------------------------------------------- banner object (209 + key)
-- Verbatim 209 body with ONE addition, marked [211 ADD]: the final
-- 'redisplay_minutes' key. Removing the marked segment reproduces
-- the 209 body byte-for-byte (validation/check_sql_211.py).
create or replace function cps.banner_obj() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  return jsonb_build_object(
    'enabled', cps.banner_on() and btrim(cps.banner_text()) <> '',
    'text', cps.banner_text(),
    'style', cps.banner_style(),
    'dismissible', cps.banner_dismissible(),
    'version', cps.banner_version(),
    -- [211 ADD] how long a dismissal lasts (0 = until edited/off)
    'redisplay_minutes', cps.banner_redisplay_minutes());
    -- [/211 ADD]
end $$;

-- ------------------------------------------------------------- admin setter
-- Drop the 209 5-parameter setter FIRST: exactly one setter exists
-- after this migration, no overload ambiguity.
drop function if exists public.cps_admin_set_banner(text, boolean, text, text, boolean);

create or replace function public.cps_admin_set_banner(p_token text, p_enabled boolean, p_text text default '', p_style text default 'info', p_dismissible boolean default true, p_redisplay_minutes integer default 0)
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
    ('banner_version', to_jsonb(v_version)),
    ('banner_redisplay_minutes', to_jsonb(least(10080, greatest(0, coalesce(p_redisplay_minutes, 0)))))
  on conflict (key) do update set value = excluded.value;
  return cps.banner_obj();
end $$;

-- ---------------------------------------------------------------- grants
do $$ begin
  execute 'revoke all on function public.cps_admin_set_banner(text, boolean, text, text, boolean, integer) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_admin_set_banner(text, boolean, text, text, boolean, integer) to anon, authenticated';
  end if;
end $$;

-- let the API pick up the changed functions right away
notify pgrst, 'reload schema';
