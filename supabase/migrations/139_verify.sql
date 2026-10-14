-- 139_verify.sql — run AFTER 139_bounty_escrow_holo_clamp.sql.
-- 1) The clamp is live in cps_post_bounty: expect clamp_live = true.
select position('least(holo_count - r.holo_qty' in p.prosrc) > 0 as clamp_live
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'cps_post_bounty';

-- 2) Franklin's Oklahoma City Thunder row — the shape that broke posting
--    (expect holo_count = count: every copy is a holo).
select a.display_name, cl.count, cl.holo_count, cl.vaulted_count, cl.vaulted_holo
from cps.collection cl
join cps.accounts a on a.id = cl.account_id
where cl.set_id = 'nba' and cl.card_id like '%oklahoma%';

-- 3) The failed attempts left nothing behind: expect 0 open Pennsylvania
--    bounties and no orphan escrow rows from them.
select count(*) as open_pennsylvania_bounties
from cps.bounties
where status = 'open' and want_card = 'pennsylvania';
