-- =====================================================================
-- 149_shop_mystery_roll.sql -- Mystery pack rolls per buy + limit bumps.
-- Franklin's spec (2026-10-15):
--   * Slot 4 (Mystery pack, $1): the set is rolled fresh at purchase
--     time -- per buyer, per buy -- not fixed for the whole cycle and
--     not the same for everyone. Limit 1 -> 10 per restock cycle.
--   * Slot 3 (discounted pack, $2): limit 3 -> 5 per restock cycle.
--     Its set still rotates per cycle; prices unchanged.
-- Bodies are 135's verbatim except the marked hunks (status: the two
-- limit literals; buy: the lim case + the slot-4 roll block).
-- shop_ensure_stock still fills slot4_set; nothing reads it after this.
-- =====================================================================

create or replace function public.cps_shop_status(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  p1 int := 0; p2 int := 0; p3 int := 0; p4 int := 0; p5 int := 0; p6 int := 0;
  hist   jsonb;
begin
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  select coalesce(sum(count), 0) into p1 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 1;
  select coalesce(sum(count), 0) into p2 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 2;
  select coalesce(sum(count), 0) into p3 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 3;
  select coalesce(sum(count), 0) into p4 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 4;
  select coalesce(sum(count), 0) into p5 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 5;
  select coalesce(sum(count), 0) into p6 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 6;
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
      jsonb_build_object('slot', 1, 'set_id', stock.slot1_set, 'price', 5, 'bought', p1, 'limit', null, 'mystery', false, 'kind', 'pack'),
      jsonb_build_object('slot', 2, 'set_id', stock.slot2_set, 'price', 5, 'bought', p2, 'limit', null, 'mystery', false, 'kind', 'pack'),
      jsonb_build_object('slot', 3, 'set_id', stock.slot3_set, 'price', 2, 'bought', p3, 'limit', 5, 'mystery', false, 'kind', 'pack'),
      jsonb_build_object('slot', 4, 'set_id', null, 'price', 1, 'bought', p4, 'limit', 10, 'mystery', true, 'kind', 'pack'),
      jsonb_build_object('slot', 5, 'set_id', null, 'price', 3, 'bought', p5, 'limit', 15, 'mystery', false, 'kind', 'ticket'),
      jsonb_build_object('slot', 6, 'set_id', null, 'price', 1, 'bought', p6, 'limit', 20, 'mystery', false, 'kind', 'token')
    ),
    'history', hist
  );
end $$;

create or replace function public.cps_shop_buy(p_token text, p_slot int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  v_set  text;
  price  int;
  bought int := 0;
  lim    int := null;
  packs_now int;
begin
  if p_slot not in (1, 2, 3, 4, 5, 6) then raise exception 'Bad slot.'; end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  v_set := case p_slot when 1 then stock.slot1_set when 2 then stock.slot2_set
            when 3 then stock.slot3_set when 4 then stock.slot4_set else null end;
  if p_slot = 4 then
    -- 149: the Mystery pack rolls its set at purchase time -- per buyer,
    -- per buy -- instead of the cycle-wide stock.slot4_set (which
    -- shop_ensure_stock still fills; it is simply no longer used).
    -- Pool unchanged: any active set, Jumbled included.
    select id into v_set from cps.card_sets where active order by random() limit 1;
  end if;
  price := case p_slot when 1 then 5 when 2 then 5 when 3 then 2 when 4 then 1 when 6 then 1 else 3 end;
  lim := case when p_slot = 3 then 5 when p_slot = 4 then 10 when p_slot = 5 then 15 when p_slot = 6 then 20 else null end;
  if lim is not null then
    select coalesce(sum(count), 0) into bought from cps.shop_purchases
      where account_id = a.id and cycle_start = cs and slot = p_slot;
    if coalesce(bought, 0) >= lim then
      raise exception 'Limit reached (% per restock).', lim;
    end if;
  end if;
  if a.store_credit < price then raise exception 'Not enough Store Credit.'; end if;
  update cps.accounts set store_credit = store_credit - price where id = a.id;
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, 1)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + 1;
  if p_slot = 5 then
    update cps.accounts set spins = spins + 1 where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'ticket', null, price);
    return jsonb_build_object('ok', true, 'kind', 'ticket',
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'spins_now', (select spins from cps.accounts where id = a.id));
  end if;
  if p_slot = 6 then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + 1 where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'token', null, price);
    return jsonb_build_object('ok', true, 'kind', 'token',
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'tokens_now', (select coalesce(game_tokens, 0) from cps.accounts where id = a.id));
  end if;
  perform cps.add_packs(a.id, v_set, 1, 'shop_buy', cs::text, null);
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', v_set, price);
  select coalesce(sum(pi.packs), 0) into packs_now
    from cps.pack_inventory pi where pi.account_id = a.id and pi.set_id = v_set;
  return jsonb_build_object('ok', true, 'kind', 'pack',
                            'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed_set', case when p_slot = 4 then v_set else null end,
                            'set_id', v_set,
                            'packs_now', packs_now);
end $$;

notify pgrst, 'reload schema';
