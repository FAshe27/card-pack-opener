-- =====================================================================
-- 161_shop_buy_all.sql -- Per-booth "Buy all" for LIMITED shop slots.
-- Franklin's spec (2026-10-17):
--   * Each limited booth (slots 3-6) gets its own Buy All: it buys
--     every remaining unit of THAT slot for this restock cycle.
--     Slots 1-2 are unlimited and have no Buy All.
--   * ALL-OR-NOTHING per item (Franklin's call): the purchase runs
--     only when the balance covers the FULL remaining total for that
--     slot; otherwise nothing is bought and nothing is charged.
--   * Prices/limits are 149's, unchanged: slot 3 $2 limit 5,
--     slot 4 $1 limit 10 (Mystery, set rolls fresh PER PACK),
--     slot 5 $3 limit 15 (Spin Ticket), slot 6 $1 limit 20 (Token).
-- New function only; cps_shop_status and cps_shop_buy are untouched.
-- The per-item effects mirror cps_shop_buy (149) exactly: one
-- shop_purchases count bump (here by the full remaining count), one
-- shop_history row per unit bought, add_packs per pack granted.
-- =====================================================================

create or replace function public.cps_shop_buy_all(p_token text, p_slot int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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
  lim   := case p_slot when 3 then 5 when 4 then 10 when 5 then 15 when 6 then 20 end;

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
end $$;

notify pgrst, 'reload schema';
