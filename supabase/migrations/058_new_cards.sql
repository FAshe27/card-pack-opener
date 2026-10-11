-- =====================================================================
-- 058_new_cards.sql — Add Alan Trammell (MLB, epic) and Sonny Hutchins
-- (NASCAR, uncommon).
-- (Client data: sets/mlb-additions.js and sets/nascar-collection.js; this
-- adds the server rows so pack generation can roll them.)
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

insert into cps.cards (set_id, card_id, num, name, rarity)
values ('nascar-collection', 'sonny-hutchins', 377, 'Sonny Hutchins', 'uncommon')
on conflict (set_id, card_id) do update
  set num = excluded.num,
      name = excluded.name,
      rarity = excluded.rarity;

update cps.card_sets
set card_count = 377, updated_at = now()
where id = 'nascar-collection';
