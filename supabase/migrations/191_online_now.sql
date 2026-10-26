-- =====================================================================
-- 191_online_now.sql — player-facing "Players Online" (FarmRPG-style
-- Players tab: an Online button + a Search button replace the full
-- player list). Companion to 157 (admin Who's Online), which stays
-- exactly as it is.
--
-- The presence source already exists: cps.sessions.last_used_at,
-- force-stamped by cps_heartbeat (157) every 60s while a tab is
-- visible. This migration adds ONE new RPC and rebuilds nothing:
--
--   public.cps_online_now(p_token) — any logged-in player. One row
--   per NON-ADMIN, non-disabled account whose freshest session was
--   seen within 5 minutes (the same window as the admin box):
--   {id, name, is_me, seconds_ago}. No device/user-agent data —
--   players don't need each other's devices (the admin box keeps
--   that to itself).
--
-- "Online" is approximate by design (157's design): close the tab
-- and you fade off within 5 minutes.
-- =====================================================================

create or replace function public.cps_online_now(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  v_list jsonb;
begin
  a := cps.auth(p_token);

  with fresh as (
    select ac.id,
           ac.display_name,
           max(s.last_used_at) as seen
      from cps.sessions s
      join cps.accounts ac on ac.id = s.account_id
     where s.last_used_at > now() - interval '5 minutes'
       and s.expires_at > now()
       and not ac.is_admin
       and not ac.disabled
     group by ac.id, ac.display_name
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', f.id,
           'name', f.display_name,
           'is_me', f.id = a.id,
           'seconds_ago', floor(extract(epoch from (now() - f.seen)))::int
         ) order by f.seen desc), '[]'::jsonb)
    into v_list
    from fresh f;

  return jsonb_build_object('ok', true, 'count', jsonb_array_length(v_list), 'online', v_list);
end $$;

grant execute on function public.cps_online_now(text) to anon;

notify pgrst, 'reload schema';
