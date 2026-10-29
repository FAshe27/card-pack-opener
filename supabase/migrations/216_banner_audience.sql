-- =====================================================================
-- 216: Banner audience — a per-banner "who is this for?" choice
-- (209 banner system, 211 redisplay interval). Franklin picks the
-- audience in the Admin panel when he saves a banner:
--   'everyone' — every visitor, exactly the 209/211 behaviour.
--   'unlinked' — ONLY logged-in players who have not linked a
--                Google account yet (S.account.oauth_linked ===
--                false). Linked players and logged-out visitors
--                never see it.
--
-- Franklin's asks (2026-10-29): "Can we create a pop-up message for
-- anyone who doesn't have their Google account linked? … It would
-- be awesome if that banner can only show to people without Google
-- linked" → his pick on the presented options: "Add an audience
-- choice per banner" → and his lifecycle note: "We can remove the
-- audience choice after migration is done."
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- CAMPAIGN TOOL / RETIREMENT: the 'unlinked' audience exists for
-- the Google-login migration campaign (the live banner below is
-- that campaign's reminder). Once the migration is complete, the
-- audience choice can be retired — Franklin saves the banner with
-- audience Everyone (or turns it off), and an optional follow-up
-- cleanup migration can drop banner_audience, the banner_obj key
-- and the setter parameter. That cleanup is deliberately NOT
-- built here.
--
-- What this does, and ONLY this:
--  * One new config row in cps.app_config: banner_audience (jsonb
--    string, default 'everyone' — so every existing banner and
--    every legacy save behaves exactly as today).
--  * Internal helper cps.banner_audience() (never raises —
--    fail-open: any error, missing row or unrecognised value
--    reads as 'everyone', the wider audience — a targeting bug
--    can never hide a banner Franklin meant for everyone, e.g. a
--    maintenance warning).
--  * cps.banner_obj() gains ONE added key: 'audience'. Every
--    existing key is unchanged; the live 211 client ignores the
--    extra key and defaults to 'everyone', and the updated client
--    treats a missing key as 'everyone' — the two sides are safe
--    in either ship order.
--  * public.cps_admin_set_banner is REPLACED with a 7-parameter
--    version (new last parameter p_audience text default
--    'everyone'). The old 6-parameter function is DROPPED first
--    so there is exactly one setter and no overload ambiguity
--    (the AGENTS.md overload lesson). The updated client sends
--    all seven values; a straggler old client calling with the
--    previous six named arguments still works — the audience
--    takes its 'everyone' default on that save.
--  * INITIALIZATION (final block, clearly marked): the CURRENT
--    live banner — the Google-link campaign reminder — gets
--    audience 'unlinked', because that is Franklin's stated goal
--    for it. It is a plain config UPDATE, NOT a setter call, so
--    banner_version is NOT bumped (stays 12): nobody who
--    dismissed v12 is re-shown anything; the only change is that
--    linked players and logged-out visitors stop seeing it.
--    Strike that block before running if the current banner
--    should stay 'everyone'.
--  * NOTHING else is touched: no cps.auth change, no change to
--    cps_site_status (the audience rides the existing 'banner'
--    key), no session changes.
--
-- EMERGENCY OFF (unchanged from 209):
--   update cps.app_config set value = 'false'::jsonb
--     where key = 'banner_enabled';
-- =====================================================================

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('banner_audience', '"everyone"')
on conflict (key) do nothing;

-- ------------------------------------------------------- internal helper
-- Fail-open by construction: never raises; anything unexpected
-- reads as 'everyone'.
create or replace function cps.banner_audience() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare v text;
begin
  begin
    v := lower(coalesce(cps.cfg('banner_audience') #>> '{}', 'everyone'));
  exception when others then
    v := 'everyone';
  end;
  return case when v in ('everyone', 'unlinked') then v else 'everyone' end;
end $$;

revoke execute on function cps.banner_audience() from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function cps.banner_audience() from anon, authenticated';
  end if;
end $$;

-- ------------------------------------------- banner object (211 + key)
-- Verbatim 211 body with ONE addition, marked [216 ADD]: the final
-- 'audience' key. Removing the marked segment (and restoring the
-- comma after banner_redisplay_minutes() to the closing paren)
-- reproduces the 211 body byte-for-byte
-- (validation/check_sql_216.py).
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
    'redisplay_minutes', cps.banner_redisplay_minutes(),
    -- [/211 ADD]
    -- [216 ADD] who this banner is for ('everyone' | 'unlinked')
    'audience', cps.banner_audience());
    -- [/216 ADD]
end $$;

-- ------------------------------------------------------------- admin setter
-- Drop the 211 6-parameter setter FIRST: exactly one setter exists
-- after this migration, no overload ambiguity.
drop function if exists public.cps_admin_set_banner(text, boolean, text, text, boolean, integer);

create or replace function public.cps_admin_set_banner(p_token text, p_enabled boolean, p_text text default '', p_style text default 'info', p_dismissible boolean default true, p_redisplay_minutes integer default 0, p_audience text default 'everyone')
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
        v_style text;
        v_audience text;
        v_version integer;
begin
  a := cps.auth(p_token, true);
  v_style := case when lower(coalesce(p_style, '')) in ('info', 'warning', 'urgent')
                  then lower(p_style) else 'info' end;
  v_audience := case when lower(coalesce(p_audience, '')) in ('everyone', 'unlinked')
                     then lower(p_audience) else 'everyone' end;
  v_version := cps.banner_version() + 1;
  insert into cps.app_config (key, value) values
    ('banner_enabled', to_jsonb(coalesce(p_enabled, false))),
    ('banner_text', to_jsonb(left(coalesce(p_text, ''), 200))),
    ('banner_style', to_jsonb(v_style)),
    ('banner_dismissible', to_jsonb(coalesce(p_dismissible, true))),
    ('banner_version', to_jsonb(v_version)),
    ('banner_redisplay_minutes', to_jsonb(least(10080, greatest(0, coalesce(p_redisplay_minutes, 0))))),
    ('banner_audience', to_jsonb(v_audience))
  on conflict (key) do update set value = excluded.value;
  return cps.banner_obj();
end $$;

-- ---------------------------------------------------------------- grants
do $$ begin
  execute 'revoke all on function public.cps_admin_set_banner(text, boolean, text, text, boolean, integer, text) from public';
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_admin_set_banner(text, boolean, text, text, boolean, integer, text) to anon, authenticated';
  end if;
end $$;

-- ================== [216 INIT — STRIKE THIS BLOCK TO SKIP] ==================
-- The CURRENT live banner is the Google-link campaign reminder;
-- Franklin's stated goal is that it show only to players who have
-- not linked Google yet. Plain UPDATE — deliberately NOT a setter
-- call — so banner_version is NOT bumped (stays 12) and dismissed
-- v12 banners are not re-shown to anyone.
update cps.app_config set value = '"unlinked"'::jsonb
  where key = 'banner_audience';
-- ================= [/216 INIT] =================

-- let the API pick up the changed functions right away
notify pgrst, 'reload schema';
