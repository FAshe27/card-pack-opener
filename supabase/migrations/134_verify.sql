-- =====================================================================
-- Verify for migration 134 (read-only — run AFTER 134, SQL editor)
-- =====================================================================

-- 1) The live cps_open_pack body now uses WITH ORDINALITY in the
--    variant lottery (expect: true). The old row_number() version
--    should be gone from the lottery (the one remaining row_number()
--    in the body is the unrelated, correct pack_openings rebuild).
select pg_get_functiondef('public.cps_open_pack(text, text)'::regprocedure)
         like '%with ordinality as o(e, ord)%' as fix_live;

-- 2) The two index expressions, old vs fixed, on a synthetic standard
--    pack (5 Commons, 2 Uncommons, a Rare in the wild slot, a Chase in
--    the guaranteed slot). Pure SELECT — touches no game state.
--    Expect: old_buggy_idx = {0,1}  -> points at the two COMMONS
--            fixed_idx     = {7,8}  -> the Rare (index 7) and Chase (8)
with pack as (
  select '[{"id":"c1","rarity":"common"},{"id":"c2","rarity":"common"},
           {"id":"c3","rarity":"common"},{"id":"c4","rarity":"common"},
           {"id":"c5","rarity":"common"},{"id":"u1","rarity":"uncommon"},
           {"id":"u2","rarity":"uncommon"},{"id":"r1","rarity":"rare"},
           {"id":"ch1","rarity":"chase"}]'::jsonb as out
)
select
  (select array_agg(t.idx) from (
     select (row_number() over ()) - 1 as idx
     from jsonb_array_elements(out) e
     where e->>'rarity' in ('rare','epic','legendary','chase')) t) as old_buggy_idx,
  (select array_agg(t.idx) from (
     select (o.ord - 1)::int as idx
     from jsonb_array_elements(out) with ordinality as o(e, ord)
     where o.e->>'rarity' in ('rare','epic','legendary','chase')) t) as fixed_idx
from pack;
