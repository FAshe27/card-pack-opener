-- 143_verify.sql — expect BOTH rows true.
select
  (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'cps_variant_owners') as owners_fn_exists,
  (select count(*) = 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'cps_variant_misprints') as misprints_fn_exists;
