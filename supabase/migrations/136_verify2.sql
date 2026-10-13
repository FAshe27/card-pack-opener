-- =====================================================================
-- PackRipper -- verify for migration 136, v2 (run AFTER 136).
-- v1's first query used a bare 'public.cps_open_pack'::regprocedure
-- cast, which Postgres rejects (22P02: a regprocedure literal needs
-- the argument list). This version looks the function up by name
-- instead. Checks 2 and 3 are unchanged from v1.
-- =====================================================================

-- 1. cps_open_pack: the lottery fix KEPT and everything 134 lost RESTORED.
--    All four columns must come back true.
select
  strpos(d, 'with ordinality') > 0          as lottery_fix_kept,
  strpos(d, '''tier'', vtier') > 0            as variant_meta_restored,
  strpos(d, 'pulled a one-of-one') > 0        as oneofone_wording_restored,
  strpos(d, '(e->>''credit'') is null') > 0   as openings_filter_restored
from (
  select pg_get_functiondef(p.oid) as d
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'cps_open_pack'
) s;

-- 2. Exactly one cps.notif_visible (the new 4-arg one) -- no stale overload.
select count(*) as notif_visible_versions
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'cps' and p.proname = 'notif_visible';
-- expect: 1

-- 3. The filter itself, on the exact announcements from Franklin's bell.
--    Rainbow OFF must hide them even though their rows carry no meta.
select cps.notif_visible('{"rainbow": false}'::jsonb, 'variant_pull', null,
  '🌈 Amanda pulled Rainbow #12/50 Gettysburg (US National Parks)!') as gettysburg_visible_when_off;
-- expect: false
select cps.notif_visible('{"rainbow": false}'::jsonb, 'variant_pull', null,
  '🌈 Amanda pulled Rainbow #40/50 Northern Cardinal (Birdwatching)!') as cardinal_visible_when_off;
-- expect: false
select cps.notif_visible('{"rainbow": true}'::jsonb, 'variant_pull', null,
  '🌈 Amanda pulled Rainbow #12/50 Gettysburg (US National Parks)!') as gettysburg_visible_when_on;
-- expect: true

-- 4. In the app afterwards: bell -> Settings -> Rainbow off -> reopen the
--    bell: Amanda's two Rainbow announcements are gone (badge drops too).
--    Turn Rainbow back on and they reappear. Open any pack: variant and
--    Chase announcements are clickable again and obey their toggles.
