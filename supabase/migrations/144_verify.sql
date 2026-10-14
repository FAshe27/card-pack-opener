-- =====================================================================
-- PackRipper — migration 144 VERIFY (read-only; run any time after 144)
-- =====================================================================

-- 1. The dedupe table now accepts threshold 100 (expect the check to
--    list 25, 50, 75, 100):
select pg_get_constraintdef(oid) as turnin_rewards_check
  from pg_constraint
 where conrelid = 'cps.turnin_rewards'::regclass and contype = 'c';

-- 2. The whole prize table (expect 100 -> tickets 25, random_packs 100;
--    25/50/75 values unchanged from 126, random_packs 0):
select cps.turnin_prize(25)  as prize_25,
       cps.turnin_prize(50)  as prize_50,
       cps.turnin_prize(75)  as prize_75,
       cps.turnin_prize(100) as prize_100;

-- 3. Every 100% payment so far, with the tickets it granted
--    (one row per player per completed set; should be none before
--    anyone completes a set, then exactly one per completion):
select r.account_id, a.display_name, r.set_id, r.paid_at,
       (select g.spins from cps.spin_grants g
         where g.account_id = r.account_id
           and g.ref = r.set_id || ':100'
           and g.reason like 'turnin_reward%') as tickets_paid
  from cps.turnin_rewards r
  join cps.accounts a on a.id = r.account_id
 where r.threshold = 100
 order by r.paid_at;

-- 4. Random packs per 100% payment (every group must total exactly 100,
--    spread across several sets):
select ref, reason, count(*) as grant_rows, sum(packs) as total_packs
  from cps.pack_grants
 where ref like '%:100' and reason like 'turnin_reward%'
 group by ref, reason
 order by ref;

-- 5. Notification counts (announcement = number of live accounts at run
--    time; backpay notes = players who were already at 100%):
select kind, count(*) from cps.notifications
 where kind in ('turnin_100_live', 'turnin_backpay_100')
 group by kind;
