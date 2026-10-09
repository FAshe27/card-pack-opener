-- =====================================================================
-- 022_halve_holo.sql — halve holo rates for all sets already in the DB.
-- (The client default in js/registry.js was halved in the same commit;
--  new set syncs pick it up automatically. Run after 021.)
-- =====================================================================

update cps.card_sets
set pack = jsonb_set(pack, '{holo}',
  '{"common":1,"uncommon":1.5,"rare":3,"epic":5,"legendary":7.5,"chase":12.5}'::jsonb);

notify pgrst, 'reload schema';
