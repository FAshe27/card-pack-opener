-- =====================================================================
-- 077_shop_mystery.sql — Slot 4: Mystery Pack ($1, 1/player/cycle, obscured).
-- =====================================================================

alter table cps.shop_stock add column if not exists slot4_set text;

-- Update ensure_stock to pick slot 4 (any set, can match others).
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
  select id into s1 from cps.card_sets where active and id <> 'jumbled' order by random() limit 1;
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

-- Update status: slot 4 is obscured (mystery).
create or replace function public.cps_shop_status(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  p1 int := 0; p2 int := 0; p3 int := 0; p4 int := 0;
  hist   jsonb;
begin
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  select count into p1 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 1;
  select count into p2 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 2;
  select count into p3 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 3;
  select count into p4 from cps.shop_purchases where account_id = a.id and cycle_start = cs and slot = 4;
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
      jsonb_build_object('slot', 1, 'set_id', stock.slot1_set, 'price', 5, 'bought', coalesce(p1, 0), 'limit', null, 'mystery', false),
      jsonb_build_object('slot', 2, 'set_id', stock.slot2_set, 'price', 5, 'bought', coalesce(p2, 0), 'limit', null, 'mystery', false),
      jsonb_build_object('slot', 3, 'set_id', stock.slot3_set, 'price', 2, 'bought', coalesce(p3, 0), 'limit', 3, 'mystery', false),
      jsonb_build_object('slot', 4, 'set_id', null, 'price', 1, 'bought', coalesce(p4, 0), 'limit', 1, 'mystery', true)
    ),
    'history', hist
  );
end $$;

-- Update buy: handle slot 4 (mystery, 1 per cycle, reveals on purchase).
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
  if a.store_credit < price then raise exception 'Not enough Store Credit.'; end if;
  update cps.accounts set store_credit = store_credit - price where id = a.id;
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

notify pgrst, 'reload schema';
