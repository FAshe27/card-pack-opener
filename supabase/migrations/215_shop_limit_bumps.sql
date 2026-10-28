-- 215_shop_limit_bumps.sql
-- Franklin's call (2026-10-28): raise two Shop per-restock caps —
--   slot 3 (Deal pack, $2 Store Credit):    5  -> 10 per restock
--   slot 4 (Mystery pack, $1 Store Credit): 10 -> 20 per restock
-- The caps live in exactly three functions (status display, single
-- buy, buy-all); all three are rebuilt from their LIVE bodies with
-- only the limit literals changed (back-diff proven). Prices, the
-- 12h restock cycle and all other slots are untouched. The client
-- renders limits from cps_shop_status, so no client change is
-- needed; Buy All totals follow automatically ($20 / $20 per cycle).

CREATE OR REPLACE FUNCTION public.cps_shop_status(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
      jsonb_build_object('slot', 3, 'set_id', stock.slot3_set, 'price', 2, 'bought', p3, 'limit', 10, 'mystery', false, 'kind', 'pack'),
      jsonb_build_object('slot', 4, 'set_id', null, 'price', 1, 'bought', p4, 'limit', 20, 'mystery', true, 'kind', 'pack'),
      jsonb_build_object('slot', 5, 'set_id', null, 'price', 3, 'bought', p5, 'limit', 15, 'mystery', false, 'kind', 'ticket'),
      jsonb_build_object('slot', 6, 'set_id', null, 'price', 1, 'bought', p6, 'limit', 20, 'mystery', false, 'kind', 'token')
    ),
    'history', hist
  );
end $function$;

CREATE OR REPLACE FUNCTION public.cps_shop_buy(p_token text, p_slot integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
  lim := case when p_slot = 3 then 10 when p_slot = 4 then 20 when p_slot = 5 then 15 when p_slot = 6 then 20 else null end;
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
  perform cps.quest_bump(a.id, 'buy_shop_pack');
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', v_set, price);
  select coalesce(sum(pi.packs), 0) into packs_now
    from cps.pack_inventory pi where pi.account_id = a.id and pi.set_id = v_set;
  return jsonb_build_object('ok', true, 'kind', 'pack',
                            'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed_set', case when p_slot = 4 then v_set else null end,
                            'set_id', v_set,
                            'packs_now', packs_now);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_shop_buy_all(p_token text, p_slot integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a         cps.accounts%rowtype;
  stock     cps.shop_stock;
  cs        timestamptz;
  v_set     text;
  price     int;
  lim       int;
  bought    int := 0;
  remaining int;
  total     int;
  v_rolled  text[] := '{}';
  v_set_roll text;
  v_revealed jsonb := null;
  v_packs   jsonb := '[]'::jsonb;
  packs_now int;
  i         int;
begin
  if p_slot not in (3, 4, 5, 6) then
    raise exception 'Buy all is only for limited items.';
  end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  v_set := case p_slot when 3 then stock.slot3_set else null end;
  price := case p_slot when 3 then 2 when 4 then 1 when 5 then 3 when 6 then 1 end;
  lim   := case p_slot when 3 then 10 when 4 then 20 when 5 then 15 when 6 then 20 end;

  select coalesce(sum(count), 0) into bought from cps.shop_purchases
    where account_id = a.id and cycle_start = cs and slot = p_slot;
  remaining := lim - coalesce(bought, 0);
  if remaining <= 0 then
    raise exception 'Limit reached (% per restock).', lim;
  end if;
  total := price * remaining;
  -- All-or-nothing: never a partial buy, never a partial charge.
  if a.store_credit < total then
    raise exception 'Not enough Store Credit.';
  end if;

  update cps.accounts set store_credit = store_credit - total where id = a.id;
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, remaining)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + remaining;

  if p_slot = 5 then
    update cps.accounts set spins = spins + remaining where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'ticket', null, price from generate_series(1, remaining);
    return jsonb_build_object('ok', true, 'kind', 'ticket', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'spins_now', (select spins from cps.accounts where id = a.id));
  end if;

  if p_slot = 6 then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + remaining where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'token', null, price from generate_series(1, remaining);
    return jsonb_build_object('ok', true, 'kind', 'token', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'tokens_now', (select coalesce(game_tokens, 0) from cps.accounts where id = a.id));
  end if;

  perform cps.quest_bump(a.id, 'buy_shop_pack');
  if p_slot = 3 then
    perform cps.add_packs(a.id, v_set, remaining, 'shop_buy', cs::text, null);
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'pack', v_set, price from generate_series(1, remaining);
    select coalesce(sum(pi.packs), 0) into packs_now
      from cps.pack_inventory pi where pi.account_id = a.id and pi.set_id = v_set;
    v_packs := jsonb_build_array(jsonb_build_object('set_id', v_set, 'packs_now', packs_now));
    return jsonb_build_object('ok', true, 'kind', 'pack', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'set_id', v_set,
                              'packs', v_packs,
                              'packs_now', packs_now);
  end if;

  -- Slot 4 (Mystery): the set rolls fresh per pack, exactly like a
  -- single cps_shop_buy call per pack (149) — pool is any active set.
  for i in 1..remaining loop
    select id into v_set_roll from cps.card_sets where active order by random() limit 1;
    v_rolled := array_append(v_rolled, v_set_roll);
    perform cps.add_packs(a.id, v_set_roll, 1, 'shop_buy', cs::text, null);
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'pack', v_set_roll, price);
  end loop;
  select jsonb_agg(jsonb_build_object('set_id', g.set_id, 'count', g.n) order by g.n desc, g.set_id)
    into v_revealed
    from (select u as set_id, count(*)::int as n from unnest(v_rolled) as u group by u) g;
  select jsonb_agg(jsonb_build_object('set_id', g.set_id, 'packs_now',
      (select coalesce(sum(pi.packs), 0) from cps.pack_inventory pi
        where pi.account_id = a.id and pi.set_id = g.set_id)))
    into v_packs
    from (select distinct u as set_id from unnest(v_rolled) as u) g;
  return jsonb_build_object('ok', true, 'kind', 'pack', 'slot', p_slot,
                            'count', remaining, 'total', total,
                            'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed', coalesce(v_revealed, '[]'::jsonb),
                            'packs', coalesce(v_packs, '[]'::jsonb));
end $function$;
