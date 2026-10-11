-- =====================================================================
-- 058_alan_trammell.sql — Add Alan Trammell (epic) to the MLB set.
-- (Client data lives in sets/mlb-additions.js; this adds the server row
-- so pack generation can roll him.)
-- =====================================================================

insert into cps.cards (set_id, card_id, num, name, rarity)
values ('mlb', 'alan-trammell', 381, 'Alan Trammell', 'epic')
on conflict (set_id, card_id) do update
  set num = excluded.num,
      name = excluded.name,
      rarity = excluded.rarity;

update cps.card_sets
set card_count = 381, updated_at = now()
where id = 'mlb';
