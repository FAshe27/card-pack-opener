-- =====================================================================
-- 100_shop_packs_now.sql — U-H1: Return set_id and packs_now from cps_shop_buy.
-- The client needs to update local pack inventory without a full refresh.
-- =====================================================================

create or replace function public.cps_shop_buy(p_token text, p_slot int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  set_id text;
  price  int;
  bought int := 0;
  lim    int := null;
  packs_now int;
begin
  if p_slot not in (1, 2, 3, 4) then raise exception 'Bad slot.'; end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  set_id := case p_slot when 1 then stock.slot1_set when 2 then stock.slot2_set
            when 3 then stock.slot3_set else stock.slot4_set end;
  price := case p_slot when 1 then 5 when 2 then 5 when 3 then 2 else 1 end;
  lim := case when p_slot = 3 then 3 when p_slot = 4 then 1 else null end;
  if lim is not null then
    select count into bought from cps.shop_purchases
      where account_id = a.id and cycle_start = cs and slot = p_slot;
    if coalesce(bought, 0) >= lim then
      raise exception 'Limit reached (% per restock).', lim;
    end if;
  end if;
  if a.store_credit < price then raise exception 'Not enough Store Credit.'; end if;
  update cps.accounts set store_credit = store_credit - price where id = a.id;
  perform cps.add_packs(a.id, set_id, 1, 'shop_buy', cs::text, null);
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, 1)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + 1;
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', set_id, price);
  -- Get the new pack count for this set
  select coalesce(sum(packs), 0) into packs_now
    from cps.pack_inventory where account_id = a.id and set_id = set_id;
  return jsonb_build_object('ok', true, 'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed_set', case when p_slot = 4 then set_id else null end,
                            'set_id', set_id,
                            'packs_now', packs_now);
end $$;

notify pgrst, 'reload schema';
