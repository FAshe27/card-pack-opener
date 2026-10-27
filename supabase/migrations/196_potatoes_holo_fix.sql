-- 196: Potatoes holo fix (odds audit 2026-10-27).
-- Potatoes was the only active set whose server pack JSON had no 'holo' key.
-- cps_open_pack reads the rate as coalesce((pack->'holo'->>rarity)::float8, 0),
-- so the set dealt 0% holos at every rarity while the client (registry defaults)
-- displayed the standard rates. Give the server row the standard holo table.
-- Forward-only: existing cards are unaffected; future Potatoes pulls can be holo.
update cps.card_sets
set pack = jsonb_set(pack, '{holo}',
  '{"common":1,"uncommon":1.5,"rare":3,"epic":5,"legendary":7.5,"chase":12.5}'::jsonb)
where id = 'potatoes';
