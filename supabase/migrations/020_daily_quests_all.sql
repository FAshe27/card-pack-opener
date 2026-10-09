-- =====================================================================
-- 020_daily_quests_all.sql — assign the FULL quest list every day.
-- Replaces the 5-quest draw from 019: every quest is available daily and
-- resets at America/Chicago midnight. (Run after 019.)
-- =====================================================================

create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  k text; sid text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  -- deterministic featured set per account per day
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select id into sid from cps.card_sets where active order by random() limit 1;
  foreach k in array array['open_packs','open_packs_set','spin_wheel','dupe_trade',
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid) else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

notify pgrst, 'reload schema';
