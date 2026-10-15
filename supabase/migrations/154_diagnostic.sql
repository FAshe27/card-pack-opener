-- =====================================================================
-- 154_diagnostic.sql -- READ-ONLY. Run any time (before or after
-- 154) to see the Ron Dennis One-of-One's provenance as production
-- actually recorded it. Expected, per Franklin's report:
--   Query 1 (who pulled it, from cps.big_pulls): one row -- Molly
--   Query 2 (who owns the variants row now):     one row -- Franklin
--   Query 3 (what 153's helper returns today):   NULL before 154
--             (that NULL is bug (b)); 'Molly' after 154 runs.
-- =====================================================================

select a.display_name as puller, bp.set_id, bp.card_id,
       bp.variant_tier, bp.variant_serial, bp.pulled_at
  from cps.big_pulls bp
  join cps.accounts a on a.id = bp.account_id
 where bp.set_id = 'formula-1-collection'
   and bp.card_id = 'ron-dennis'
   and bp.variant_tier = 'oneofone';

select a.display_name as current_owner, v.set_id, v.card_id,
       v.tier, v.serial, v.pulled_at
  from cps.variants v
  join cps.accounts a on a.id = v.account_id
 where v.set_id = 'formula-1-collection'
   and v.card_id = 'ron-dennis'
   and v.tier = 'oneofone';

select cps.variant_puller('formula-1-collection', 'ron-dennis',
                          'oneofone', 1) as helper_says_puller;
