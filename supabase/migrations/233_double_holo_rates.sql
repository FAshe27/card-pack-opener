-- 233: Double all holo rates (Franklin's call, 2026-11-18)
-- Every set's pack JSON carries the standard table (verified by census
-- 2026-11-18: all 81 rows identical), so this doubles each rarity's
-- rate in place: common 1->2, uncommon 1.5->3, rare 3->6, epic 5->10,
-- legendary 7.5->15, chase 12.5->25. cps_open_pack reads these values
-- on every pull, so the change takes effect immediately.
update cps.card_sets
set pack = jsonb_set(pack, '{holo}', jsonb_build_object(
  'common',    (pack->'holo'->>'common')::float8 * 2,
  'uncommon',  (pack->'holo'->>'uncommon')::float8 * 2,
  'rare',      (pack->'holo'->>'rare')::float8 * 2,
  'epic',      (pack->'holo'->>'epic')::float8 * 2,
  'legendary', (pack->'holo'->>'legendary')::float8 * 2,
  'chase',     (pack->'holo'->>'chase')::float8 * 2));
