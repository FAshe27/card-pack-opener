-- =====================================================================
-- PackRipper — migration 127: Daily quests list in tier order
-- Run AFTER 120 (the current cps_list_quests). No other dependency.
--
-- BUG: the Ultra quest ("Bank and Claim a 10+ Streak in
-- Higher/Lower") showed ABOVE the Hard quests, between Medium and
-- Hard (Franklin's screenshot, 2026-10-13).
--
-- ROOT CAUSE: cps_list_quests' ORDER BY dates from 019, before the
-- Ultra tier existed (added in 060/062):
--   case q.tier when 'easy' then 0 when 'medium' then 1 else 2 end
-- Hard and Ultra BOTH fall into `else 2`, so within that group the
-- tiebreak is q.quest_key alphabetically — and 'bank_10_streak'
-- sorts before 'pull_chase' / 'pull_variant' / 'wheel_big_win'.
-- That reproduces the screenshot order exactly.
-- 120 rebuilt the function verbatim from 019, so it kept the bug.
--
-- FIX: same function as 120, verbatim, with ONLY the ORDER BY line
-- changed — every tier gets its own rank:
--   easy 0, medium 1, hard 2, ultra 3, anything else 4
-- Secondary sort (quest_key) is unchanged, so order within a tier
-- does not move. No client change: renderDaily renders in the
-- order list_quests returns.
--
-- VERIFY after running (as any logged-in player, or just reopen
-- the Daily tab): quests list Easy, then Medium, then Hard, and
-- the Ultra 10+ Streak quest LAST.
-- =====================================================================

create or replace function public.cps_list_quests(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
begin
  a := cps.auth(p_token);
  perform cps.assign_daily_quests(a.id, d);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', q.quest_key, 'tier', q.tier, 'title', cps.quest_title(q.quest_key, q.meta),
      'target', q.target, 'progress', q.progress, 'done', q.done,
      'claimed', q.claimed_at is not null, 'tickets', cps.quest_tickets(q.tier),
      'currency', cps.quest_reward_currency(q.quest_key), 'amount', cps.quest_reward_amount(q.quest_key))
      order by case q.tier when 'easy' then 0 when 'medium' then 1 when 'hard' then 2 when 'ultra' then 3 else 4 end, q.quest_key)
    from cps.daily_quests q where q.account_id = a.id and q.day = d
  ), '[]');
end $$;

notify pgrst, 'reload schema';
