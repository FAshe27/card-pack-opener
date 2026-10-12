-- =====================================================================
-- 098_shop_stable.sql — D-M1: shop_cycle_start() immutable→stable.
-- The function calls now() but was declared IMMUTABLE, allowing the
-- planner to constant-fold/cache the cycle boundary across calls.
-- =====================================================================

DO $$
BEGIN
  EXECUTE 'ALTER FUNCTION cps.shop_cycle_start() STABLE';
  RAISE NOTICE 'shop_cycle_start volatility set to STABLE';
EXCEPTION WHEN undefined_function THEN
  RAISE NOTICE 'cps.shop_cycle_start() does not exist, skipping';
WHEN OTHERS THEN
  RAISE NOTICE 'Could not alter shop_cycle_start: %', SQLERRM;
END $$;

notify pgrst, 'reload schema';
