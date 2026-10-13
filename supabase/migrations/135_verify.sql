-- =====================================================================
-- 135_verify.sql — post-auth smoke test for 135_shop_tokens.sql.
-- Run AFTER 135, in the SQL editor. Uses a planted temp session on the
-- Muse test account ('Admin Account') — the only way to exercise the
-- post-auth bodies (bogus-token probes die inside cps.auth).
--
-- Expected: step 2 shows slot 6 (kind 'token', price 1, limit 20);
-- step 4 returns ok / kind 'token' with tokens_now = step-3 tokens + 1
-- and store_credit one lower; step 5's buy ERRORS with
-- 'Limit reached (20 per restock).' — that error is the PASS.
-- =====================================================================

-- Step 0: clear any stale diag session from an earlier run
delete from cps.sessions where token_hash = cps.hash_text('shop-token-diag-2026');

-- Step 1: plant the temp session
insert into cps.sessions (account_id, token_hash, expires_at)
select id, cps.hash_text('shop-token-diag-2026'), now() + interval '10 minutes'
from cps.accounts where display_name = 'Admin Account';

-- Step 2: status — slot 6 must be present with kind token / price 1 / limit 20
select s as slot6
from public.cps_shop_status('shop-token-diag-2026') as j,
     jsonb_array_elements(j -> 'slots') as s
where s ->> 'slot' = '6';

-- Step 3: make sure the test account can afford the smoke buy; note balances
update cps.accounts set store_credit = greatest(store_credit, 3)
where display_name = 'Admin Account';
select store_credit, game_tokens
from cps.accounts where display_name = 'Admin Account';

-- Step 4: smoke buy — expect {"ok": true, "kind": "token", ...}
select public.cps_shop_buy('shop-token-diag-2026', 6) as smoke_buy;

-- Step 5: limit check — fill this cycle's slot-6 count to the cap, then
-- the next buy MUST raise 'Limit reached (20 per restock).'
-- (The filler replaces the test account's real slot-6 count for this
-- cycle only; step 6 removes it. Test account only — harmless.)
insert into cps.shop_purchases (account_id, cycle_start, slot, count)
select a.id, (select max(cycle_start) from cps.shop_stock), 6, 20
from cps.accounts a where a.display_name = 'Admin Account'
on conflict (account_id, cycle_start, slot)
do update set count = 20;

select public.cps_shop_buy('shop-token-diag-2026', 6) as limit_buy;
-- ^^^ EXPECT AN ERROR HERE: 'Limit reached (20 per restock).'
-- If the editor stops at that error, run steps 6-7 manually.

-- Step 6: remove the filler count rows
delete from cps.shop_purchases p
using cps.accounts a
where p.account_id = a.id and a.display_name = 'Admin Account'
  and p.slot = 6
  and p.cycle_start = (select max(cycle_start) from cps.shop_stock);

-- Step 7: always remove the temp session
delete from cps.sessions where token_hash = cps.hash_text('shop-token-diag-2026');
