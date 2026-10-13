-- =====================================================================
-- PackRipper -- verify for migration 137 (run AFTER 137).
-- =====================================================================

-- 1. The live definition carries the new pulled count.
select strpos(d, '''pulled''') > 0 as pulled_key_present,
       strpos(d, 'pack_openings') > 0 as reads_openings_ledger
from (
  select pg_get_functiondef(p.oid) as d
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cps_card_population'
) s;
-- expect: true / true

-- 2. Post-auth smoke test: plant a temporary session for the test
--    account, call the RPC for real, then clean up. Run in order.
insert into cps.sessions (account_id, token_hash, expires_at)
select id, cps.hash_text('pop-diag-token-137'), now() + interval '10 minutes'
from cps.accounts where display_name = 'Admin Account';

select public.cps_card_population('pop-diag-token-137', 'nascar-collection', 'brad-perez') as brad_perez;
-- expect (as of 2026-10-13; drifts as people play):
--   {"total": 5, "holos": 0, "pulled": 13}

delete from cps.sessions where token_hash = cps.hash_text('pop-diag-token-137');

-- 3. In the app afterwards: open any card -- "Times pulled" sits
--    right above "Currently existing". Brad Perez reads 13 / 5.
