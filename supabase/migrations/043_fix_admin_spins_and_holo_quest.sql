-- =====================================================================
-- 043_fix_admin_spins_and_holo_quest.sql — two approved fixes
-- A. Daily 3-ticket grant skips admins (was granting to everyone <10).
-- B. "Pull 2 holos in one pack" quest: target 1 (one qualifying pack
--    completes it; the hook already fires once per qualifying pack).
-- (Run after 042.)
-- =====================================================================

-- Fix A: rebuild cps_get_state with the admin exclusion
create or replace function public.cps_get_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
begin
  a := cps.auth(p_token);
  update cps.accounts set spins = spins + 3, last_daily_spin = today
    where id = a.id and coalesce(last_daily_spin, date '1970-01-01') < today and spins < 10
      and not coalesce(a.is_admin, false);
  get diagnostics n = row_count;
  if n > 0 then
    insert into cps.spin_grants (account_id, spins, reason) values (a.id, 3, 'daily');
  end if;
  return cps.state_json(a.id);
end $$;

-- Fix B: quest target 1 for pull_2_holos_pack
create or replace function cps.quest_target(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_key when 'open_packs' then 3 when 'open_packs_set' then 2 when 'pull_holos_3' then 3
    when 'pull_3_sets' then 3 when 'pull_2_holos_pack' then 1 else 1 end $$;

-- apply to today's already-assigned uncompleted rows
update cps.daily_quests
set target = 1
where quest_key = 'pull_2_holos_pack'
  and day = (now() at time zone 'America/Chicago')::date
  and not done;

notify pgrst, 'reload schema';
