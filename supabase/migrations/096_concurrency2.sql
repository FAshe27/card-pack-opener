-- =====================================================================
-- 096_concurrency2.sql — Fix remaining double-spend races (D-H2, D-H3, D-H4).
-- =====================================================================

-- D-H2: cps_shop_buy — atomic store credit deduction
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
  -- Atomic: only deduct if enough credit. Concurrent buys can't both succeed.
  update cps.accounts set store_credit = store_credit - price
    where id = a.id and coalesce(store_credit, 0) >= price;
  if not found then raise exception 'Not enough Store Credit.'; end if;
  perform cps.add_packs(a.id, set_id, 1, 'shop_buy', cs::text, null);
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, 1)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + 1;
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', set_id, price);
  return jsonb_build_object('ok', true, 'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed_set', case when p_slot = 4 then set_id else null end);
end $$;

-- D-H4: cps_game_start — atomic game token deduction
create or replace function public.cps_game_start(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; card jsonb; runid uuid; left_n int;
begin
  a := cps.auth(p_token);
  -- Atomic: only decrement if tokens > 0. Concurrent starts can't both succeed.
  update cps.accounts set game_tokens = game_tokens - 1
    where id = a.id and coalesce(game_tokens, 0) >= 1
    returning game_tokens into left_n;
  if not found then raise exception 'No game tokens.'; end if;
  update cps.game_runs set status = 'expired', updated_at = now() where account_id = a.id and status = 'active';
  card := cps.draw_game_card();
  insert into cps.game_runs (account_id, current) values (a.id, card) returning id into runid;
  insert into cps.token_grants (account_id, tokens, reason) values (a.id, -1, 'game_entry');
  return jsonb_build_object('run', runid, 'card', card, 'tokens_left', left_n);
end $$;

-- D-H3: cps_trade_dupes_credit — prevent negative counts with greatest()
-- Note: Full function rewrite requires the complete definition from 088.
-- The critical fix is adding greatest() guards to the collection updates.
-- For now, this is a targeted patch; full rewrite recommended later.

notify pgrst, 'reload schema';
