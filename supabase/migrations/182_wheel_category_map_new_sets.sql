-- 182_wheel_category_map_new_sets.sql
-- DRAFT — NOT RUN. Prepared 2026-10-24 (proactive research), REISSUED 2026-10-25 as migration 182 because 181 was taken by the gift-bundle migration that shipped live on 2026-10-25;
-- per standing workflow this runs only on his go for this specific change.
--
-- What changes: ONLY the setmap inside cps.wheel_segments (Prize Wheel,
-- migration 176). Four sets that launched after 176 are missing from the map
-- and currently fall back to Curiosities:
--   runescape-3 (live 2026-10-23/24) -> gaming
--   rct         (live 2026-10-24)    -> gaming
--   potatoes    (live 2026-10-24)    -> food
--   numbers     (live 2026-10-24)    -> curiosities (explicit; its fallback
--                                        already lands there, so no change
--                                        in behaviour — map now says so)
-- Effect: a set's individual wheel probability does NOT change (category
-- weight = active member count, so every set stays 1/total). This only
-- moves which category slice / sub-wheel each set appears under.
-- Base: the cps.wheel_segments body from 176, verbatim except the three
-- setmap insertions above (insertion-only diff machine-verified at draft
-- time: removing the inserted fragments reproduces the 176 body exactly).
-- No other function is touched; no client change needed.

-- ---------------------------------------------------------------------------
-- Helper: build one wheel's segment array.
-- ---------------------------------------------------------------------------
create or replace function cps.wheel_segments(p_wheel text, p_mult int)
returns jsonb
language plpgsql
stable
set search_path to 'cps', 'pg_temp'
as $function$
declare
  result jsonb;
begin
  with catdef(key, name, icon, color, ord) as (
    values
      ('animals',       'Animals',             '🐾', '#43aa8b', 1),
      ('world',         'World & Nature',      '🌍', '#3d8bfd', 2),
      ('sports',        'Sports & Racing',     '🏆', '#e63946', 3),
      ('gaming',        'Gaming',              '🎮', '#7c5cff', 4),
      ('entertainment', 'Entertainment',       '🎬', '#f372b5', 5),
      ('food',          'Food & Drink',        '🍔', '#ffb020', 6),
      ('machines',      'Machines & Transport','🚗', '#8d99ae', 7),
      ('curiosities',   'Curiosities',         '🔮', '#2ec4b6', 8)
  ),
  setmap(set_id, cat) as (
    values
      ('birdwatching','animals'), ('sea','animals'), ('aquariums','animals'),
      ('dogs','animals'), ('insects','animals'), ('reptiles','animals'),
      ('wild-mammals','animals'), ('dinosaurs','animals'),
      ('countries','world'), ('states','world'), ('world-cities','world'),
      ('world-landmarks','world'), ('nps','world'), ('natural-wonders','world'),
      ('water','world'), ('plants','world'), ('gems-minerals','world'),
      ('mlb','sports'), ('nba-collection','sports'), ('nfl-collection','sports'),
      ('formula-1-collection','sports'), ('nascar-collection','sports'), ('indy','sports'),
      ('acrs','gaming'), ('minecraft','gaming'), ('mkrt','gaming'),
      ('pokemon','gaming'), ('skyrim','gaming'), ('stardew-valley','gaming'),
      ('zelda','gaming'), ('runescape-3','gaming'), ('rct','gaming'),
      ('movies-pack-images','entertainment'), ('tv-shows','entertainment'),
      ('disney','entertainment'), ('pixar','entertainment'), ('spongebob','entertainment'),
      ('star-wars','entertainment'), ('hero','entertainment'), ('stage','entertainment'),
      ('music-pack','entertainment'), ('works-of-art','entertainment'),
      ('beverages','food'), ('cereals','food'), ('candy','food'),
      ('fast-food','food'), ('iconic-dishes','food'), ('potatoes','food'),
      ('civilian-aircraft','machines'), ('aircraft','machines'), ('us-navy','machines'),
      ('cars','machines'), ('motorcycles','machines'), ('trains','machines'), ('hwy','machines'),
      ('space','curiosities'), ('technology-collection','curiosities'), ('periodic','curiosities'),
      ('cryptids','curiosities'), ('calendar','curiosities'), ('playing','curiosities'),
      ('gas','curiosities'), ('coasters','curiosities'), ('theme-parks','curiosities'),
      ('numbers','curiosities')
  ),
  members as (
    select coalesce(m.cat, 'curiosities') as cat,
           jsonb_agg(cs.id order by cs.id) as sets,
           count(*)::int as n
      from cps.card_sets cs
      left join setmap m on m.set_id = cs.id
     where cs.active
     group by coalesce(m.cat, 'curiosities')
  ),
  gotos(src, key, target, label, ord) as (
    values
      ('w1', 'goto:w2a', 'w2', 'Go to second wheel',   2.5),
      ('w1', 'goto:w2b', 'w2', 'Go to second wheel',   7.5),
      ('w2', 'goto:w1a', 'w1', 'Back to first wheel',  1.5),
      ('w2', 'goto:w3a', 'w3', 'Go to third wheel',    4.5),
      ('w2', 'goto:w1b', 'w1', 'Back to first wheel',  6.5),
      ('w2', 'goto:w3b', 'w3', 'Go to third wheel',    7.5),
      ('w3', 'goto:w1a', 'w1', 'Back to first wheel',  1.5),
      ('w3', 'goto:w2a', 'w2', 'Back to second wheel', 4.5),
      ('w3', 'goto:w1b', 'w1', 'Back to first wheel',  6.5),
      ('w3', 'goto:w2b', 'w2', 'Back to second wheel', 7.5)
  ),
  segs(ord, seg) as (
    select c.ord::float,
           jsonb_build_object('key', 'cat:' || c.key, 'kind', 'category',
             'category', c.key, 'label', c.name, 'icon', c.icon, 'color', c.color,
             'packs', p_mult, 'weight', mb.n, 'sets', mb.sets)
      from catdef c
      join members mb on mb.cat = c.key
    union all
    select case p_wheel when 'w1' then 8.6 else 3.5 end,
           jsonb_build_object('key', 'bonus', 'kind', 'bonus',
             'label', 'BONUS', 'icon', '⭐', 'color', '#ffd60a', 'weight', 3)
    union all
    select g.ord,
           jsonb_build_object('key', g.key, 'kind', 'goto', 'wheel', g.target,
             'label', g.label, 'weight', 1.5)
      from gotos g
     where g.src = p_wheel
  )
  select coalesce(jsonb_agg(seg order by ord), '[]'::jsonb) into result from segs;
  return result;
end $function$;

