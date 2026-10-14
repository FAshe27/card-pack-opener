-- 142_verify.sql — run AFTER 142_dupe_tiers.sql; every row should say true.
select
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) like '%array[''epic'']; rate := 4%') as epic_only_4_per_batch,
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) like '%array[''legendary'']; rate := 2%') as legendary_2_per_batch,
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) like '%array[''chase'']; rate := 1%') as chase_1_per_batch,
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) like '%dollars := 2%') as chase_pays_2_dollars,
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) like '%trades * dollars%') as credit_uses_dollars,
  (pg_get_functiondef('public.cps_trade_dupes_credit(text,text)'::regprocedure) not like '%''epic'',''legendary'',''chase''%') as no_pooling_left;
