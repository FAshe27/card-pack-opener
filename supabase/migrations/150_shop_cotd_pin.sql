-- =====================================================================
-- 150_shop_cotd_pin.sql -- Shop slot 1 = the Card of the Day's set.
-- Franklin's spec (2026-10-15):
--   * Slot 1 ($5, unlimited) always sells the set that today's Card of
--     the Day is in (cps.cotd_days for the Chicago date).
--   * Slot 2 ($5, unlimited) is never a duplicate of slot 1 -- its
--     existing rule (random active set, not Jumbled, not slot 1)
--     already guarantees this once slot 1 is pinned; unchanged.
-- cps.shop_ensure_stock body is 077's verbatim except the slot-1 pick.
-- Slot 3 (deal) may still coincide with slot 1, as before.
-- A one-time fix below re-pins the CURRENT cycle's stock row, so the
-- change is visible immediately instead of at the next restock.
-- =====================================================================

create or replace function cps.shop_ensure_stock()
returns cps.shop_stock language plpgsql set search_path = cps, pg_temp as $$
declare
  cs   timestamptz := cps.shop_cycle_start();
  row  cps.shop_stock;
  s1   text; s2 text; s3 text; s4 text;
begin
  select * into row from cps.shop_stock where cycle_start = cs;
  if found and row.slot4_set is not null then return row; end if;
  perform setseed(('x' || substr(md5(cs::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  -- 150: slot 1 always sells the set containing today's Card of the
  -- Day (cps.cotd_days, Chicago date). ensure_cotd_today() is
  -- idempotent -- it creates the day (and its one announcement) only
  -- if nobody has yet; the shop may simply be the day's first touch.
  perform cps.ensure_cotd_today();
  select set_id into s1 from cps.cotd_days
   where cotd_date = (now() at time zone 'America/Chicago')::date;
  if s1 is null then
    -- Defensive fallback (empty CotD pool): the pre-150 random pick.
    select id into s1 from cps.card_sets where active and id <> 'jumbled' order by random() limit 1;
  end if;
  select id into s2 from cps.card_sets where active and id <> 'jumbled' and id <> s1 order by random() limit 1;
  select id into s3 from cps.card_sets where active order by random() limit 1;
  select id into s4 from cps.card_sets where active order by random() limit 1;
  insert into cps.shop_stock (cycle_start, slot1_set, slot2_set, slot3_set, slot4_set)
  values (cs, s1, s2, s3, s4)
  on conflict (cycle_start) do update set slot4_set = excluded.slot4_set
  where cps.shop_stock.slot4_set is null;
  select * into row from cps.shop_stock where cycle_start = cs;
  return row;
end $$;

-- --- one-time: re-pin the live cycle's stock row ---------------------
do $$
declare
  cs     timestamptz := cps.shop_cycle_start();
  cotd   text;
  new_s2 text;
begin
  perform cps.ensure_cotd_today();
  select set_id into cotd from cps.cotd_days
   where cotd_date = (now() at time zone 'America/Chicago')::date;
  if cotd is null then
    raise notice '150: no Card of the Day row for today; live stock untouched';
    return;
  end if;
  if not exists (select 1 from cps.shop_stock where cycle_start = cs) then
    raise notice '150: no stock row for the current cycle yet; it will be created pinned';
    return;
  end if;
  -- If slot 2 currently duplicates the CotD set, re-pick it first
  -- (random active set, not Jumbled, not the CotD set).
  select id into new_s2 from cps.card_sets
   where active and id <> 'jumbled' and id <> cotd order by random() limit 1;
  update cps.shop_stock
     set slot2_set = case when slot2_set = cotd then coalesce(new_s2, slot2_set) else slot2_set end,
         slot1_set = cotd
   where cycle_start = cs;
  raise notice '150: live stock re-pinned -- slot 1 is now %', cotd;
end $$;

notify pgrst, 'reload schema';
