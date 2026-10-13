-- =====================================================================
-- PackRipper -- verify for migration 138 (run AFTER 138).
-- =====================================================================

-- 1. The quest helpers know the new key, with the right prize.
select cps.quest_tier('market_trade')            as tier,      -- medium
       cps.quest_title('market_trade', '{}')     as title,     -- Buy or sell a card in the Market
       cps.quest_reward_currency('market_trade') as currency,  -- ticket
       cps.quest_reward_amount('market_trade')   as amount,    -- 2
       cps.quest_target('market_trade')          as target;    -- 1

-- 2. Both Market completion points carry the hook.
select strpos(d, 'market_trade') > 0 as trade_accept_hooked
from (select pg_get_functiondef(p.oid) as d
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'cps_trade_accept') s;
-- expect: true
select strpos(d, 'market_trade') > 0 as claim_bounty_hooked
from (select pg_get_functiondef(p.oid) as d
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = 'cps_claim_bounty') s;
-- expect: true

-- 3. End-to-end: assigning TOMORROW's dailies for the test account
--    includes the new quest (today's rows are already assigned and,
--    per the 074 precedent, don't change). Then clean up.
select cps.assign_daily_quests(
  (select id from cps.accounts where display_name = 'Admin Account'),
  ((now() at time zone 'America/Chicago')::date + 1));
select quest_key, tier, target from cps.daily_quests
 where account_id = (select id from cps.accounts where display_name = 'Admin Account')
   and day = ((now() at time zone 'America/Chicago')::date + 1)
   and quest_key = 'market_trade';
-- expect: one row -- market_trade / medium / 1
delete from cps.daily_quests
 where account_id = (select id from cps.accounts where display_name = 'Admin Account')
   and day = ((now() at time zone 'America/Chicago')::date + 1);

-- 4. In the app tomorrow: the Daily list includes "Buy or sell a
--    card in the Market" (Medium, 2 tickets). It completes for BOTH
--    sides when a Trading Post offer is accepted or a bounty is
--    claimed.
