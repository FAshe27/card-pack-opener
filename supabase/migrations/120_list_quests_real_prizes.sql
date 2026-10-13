-- =====================================================================
-- PackRipper \u2014 migration 120: Dailies list shows the REAL prize
-- Run AFTER 086 (the reward helpers) \u2014 no dependency on 116-119.
-- Rebuilds public.cps_list_quests from 019 verbatim plus two fields
-- per quest: 'currency' and 'amount', taken from the SAME helpers
-- cps_claim_quest pays with (cps.quest_reward_currency /
-- cps.quest_reward_amount). Until now the list only exposed
-- 'tickets' (a per-tier ticket count), so the five token-paying
-- quests displayed the wrong prize AND the wrong amount:
--   pull_token_slip  showed \U0001F39F\uFE0F1 ticket \u2014 pays 3 tokens
--   win_3_rounds     showed \U0001F39F\uFE0F1 ticket \u2014 pays 3 tokens
--   win_slots        showed \U0001F39F\uFE0F1 ticket \u2014 pays 5 tokens
--   bank_5_streak    showed \U0001F39F\uFE0F2 tickets \u2014 pays 5 tokens
--   bank_10_streak   showed \U0001F39F\uFE0F5 tickets \u2014 pays 15 tokens
-- 'tickets' stays in the payload for backward compatibility.
-- Insertion-only vs 019 (proofed); the client renders currency-aware
-- prizes from these fields, so display and payout share one source.
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
      order by case q.tier when 'easy' then 0 when 'medium' then 1 else 2 end, q.quest_key)
    from cps.daily_quests q where q.account_id = a.id and q.day = d
  ), '[]');
end $$;

notify pgrst, 'reload schema';
