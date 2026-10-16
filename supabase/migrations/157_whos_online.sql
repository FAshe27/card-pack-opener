-- =====================================================================
-- 157_whos_online.sql — Admin panel: "Who's Online" box.
-- Run AFTER 156. No schema change, no existing function rebuilt.
--
-- Presence source: cps.sessions.last_used_at (exists since 001).
-- cps.auth already stamps it, but only once per hour — too coarse to
-- say who is online NOW. So:
--   * public.cps_heartbeat — the client calls it every 60s while a
--     player is logged in; it validates the session via cps.auth and
--     force-stamps that session's last_used_at. Every other RPC also
--     counts as activity through auth's own (hourly-throttled) stamp,
--     and any real action in the last hour leaves a trail the 5-minute
--     window + heartbeat keeps fresh while the player is around.
--   * public.cps_admin_online_now — admin-gated (cps.auth(p_token,
--     true), the 018 pattern). One row per account whose freshest
--     session was seen within 5 minutes: display name, admin flag,
--     seconds since last seen, live session count, and a coarse
--     device label from the freshest session's user_agent.
-- "Online" is approximate by design: a player who closes their tab
-- fades off the list within 5 minutes; no logout hook needed.
-- =====================================================================

create or replace function public.cps_heartbeat(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  update cps.sessions set last_used_at = now()
   where token_hash = cps.hash_text(p_token);
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.cps_heartbeat(text) to anon;

create or replace function public.cps_admin_online_now(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  v_list  jsonb;
begin
  a := cps.auth(p_token, true);

  with fresh as (
    select ac.id,
           ac.display_name,
           ac.is_admin,
           max(s.last_used_at) as seen,
           count(*)::int as devices,
           (array_agg(s.user_agent order by s.last_used_at desc))[1] as ua
      from cps.sessions s
      join cps.accounts ac on ac.id = s.account_id
     where s.last_used_at > now() - interval '5 minutes'
       and s.expires_at > now()
     group by ac.id, ac.display_name, ac.is_admin
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'name', f.display_name,
           'is_admin', f.is_admin,
           'is_me', f.id = a.id,
           'seconds_ago', floor(extract(epoch from (now() - f.seen)))::int,
           'devices', f.devices,
           'device', case
             when f.ua ilike '%iphone%' then 'iPhone'
             when f.ua ilike '%ipad%' then 'iPad'
             when f.ua ilike '%android%' then 'Android'
             when f.ua ilike '%windows%' then 'Windows'
             when f.ua ilike '%macintosh%' or f.ua ilike '%mac os%' then 'Mac'
             when f.ua ilike '%linux%' then 'Linux'
             else '' end
         ) order by f.seen desc), '[]'::jsonb)
    into v_list
    from fresh f;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_list), 'online', v_list);
end $$;

grant execute on function public.cps_admin_online_now(text) to anon;

notify pgrst, 'reload schema';
