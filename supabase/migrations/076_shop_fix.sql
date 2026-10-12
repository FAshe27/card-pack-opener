-- =====================================================================
-- 076_shop_fix.sql — fix the purchase history query in cps_shop_status.
-- The ORDER BY on a non-aggregated column conflicted with jsonb_agg.
-- =====================================================================

create or replace function public.cps_shop_status(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  p1 int := 0; p2 int := 0; p3 int := 0;
  hist   jsonb;
begin
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  select count into p1 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 1;
  select count into p2 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 2;
  select count into p3 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 3;
  select coalesce(jsonb_agg(x.obj order by x.purchased_at desc), '[]'::jsonb)
    into hist from (
      select jsonb_build_object(
          'slot', h.slot, 'set_id', h.set_id, 'price', h.price,
          'purchased_at', h.purchased_at
        ) as obj, h.purchased_at
      from cps.shop_history h
      where h.account_id = a.id
      order by h.purchased_at desc limit 20
    ) x;
  return jsonb_build_object(
    'store_credit', a.store_credit,
    'cycle_start', cs,
    'seconds_to_restock', cps.shop_seconds_to_restock(),
    'slots', jsonb_build_array(
      jsonb_build_object('slot', 1, 'set_id', stock.slot1_set, 'price', 5, 'bought', coalesce(p1, 0), 'limit', null),
      jsonb_build_object('slot', 2, 'set_id', stock.slot2_set, 'price', 5, 'bought', coalesce(p2, 0), 'limit', null),
      jsonb_build_object('slot', 3, 'set_id', stock.slot3_set, 'price', 2, 'bought', coalesce(p3, 0), 'limit', 3)
    ),
    'history', hist
  );
end $$;

notify pgrst, 'reload schema';
