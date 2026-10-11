-- =====================================================================
-- 059_sonny_hutchins.sql — Add Sonny Hutchins (uncommon) to the NASCAR set.
-- (Client data is in sets/nascar-collection.js; this adds the server row
-- so pack generation can roll him.)
-- =====================================================================

insert into cps.cards (set_id, card_id, num, name, rarity)
values ('nascar-collection', 'sonny-hutchins', 377, 'Sonny Hutchins', 'uncommon')
on conflict (set_id, card_id) do update
  set num = excluded.num,
      name = excluded.name,
      rarity = excluded.rarity;

update cps.card_sets
set card_count = 377, updated_at = now()
where id = 'nascar-collection';
