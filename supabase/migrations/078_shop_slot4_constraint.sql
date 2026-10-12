-- =====================================================================
-- 078_shop_slot4_constraint.sql — allow slot 4 in shop_purchases.
-- =====================================================================

alter table cps.shop_purchases drop constraint shop_purchases_slot_check;
alter table cps.shop_purchases add constraint shop_purchases_slot_check
  check (slot in (1, 2, 3, 4));

notify pgrst, 'reload schema';
