-- =====================================================================
-- 075_shop.sql — Store Credit currency and rotating Shop (Sandbox).
--
--   Currency: store_credit (int) on cps.accounts. Display as $X.
--   Stock: 3 pack slots, global (same for everyone), restock every 12h
--          at midnight/noon America/Chicago.
--     Slot 1: random active set (not Jumbled), $5, unlimited buys
--     Slot 2: random active set (not Jumbled, not Slot 1), $5, unlimited
--     Slot 3: random set (Jumbled allowed, can match 1/2), $2, max 3/player/cycle
--   Expandable: item_type column ('pack' now; 'tickets'/'tokens' later).
-- =====================================================================

-- --- store credit on accounts -------------------------------------------
alter table cps.accounts add column if not exists store_credit int not null default 0;

-- --- shop stock (one row per 12h cycle, global) ---------------------------
create table if not exists cps.shop_stock (
  cycle_start timestamptz primary key,
  slot1_set   text not null,
  slot2_set   text not null,
  slot3_set   text not null,
  created_at  timestamptz not null default now()
);

-- --- per-player purchase counts per cycle (for slot 3 limit) --------------
create table if not exists cps.shop_purchases (
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  cycle_start timestamptz not null,
  slot        int not null check (slot in (1, 2, 3)),
  count       int not null default 0,
  primary key (account_id, cycle_start, slot)
);

-- --- purchase history ------------------------------------------------------
create table if not exists cps.shop_history (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  purchased_at timestamptz not null default now(),
  cycle_start timestamptz not null,
  slot        int not null,
  item_type   text not null default 'pack',  -- expandable: 'tickets', 'tokens', ...
  set_id      text,
  price       int not null
);
create index if not exists shop_history_acct_idx on cps.shop_history (account_id, purchased_at desc);

-- --- cycle helpers ---------------------------------------------------------
-- Returns the current 12h cycle start (midnight or noon America/Chicago).
create or replace function cps.shop_cycle_start()
returns timestamptz language sql immutable set search_path = cps, pg_temp as $$
  select case
    when (now() at time zone 'America/Chicago')::time < '12:00'::time
    then date_trunc('day', now() at time zone 'America/Chicago') at time zone 'America/Chicago'
    else (date_trunc('day', now() at time zone 'America/Chicago') + interval '12 hours') at time zone 'America/Chicago'
  end $$;

-- Seconds until next restock.
create or replace function cps.shop_seconds_to_restock()
returns int language sql stable set search_path = cps, pg_temp as $$
  select extract(epoch from (cps.shop_cycle_start() + interval '12 hours' - now()))::int $$;

-- Ensure stock exists for the current cycle (deterministic random).
create or replace function cps.shop_ensure_stock()
returns cps.shop_stock language plpgsql set search_path = cps, pg_temp as $$
declare
  cs   timestamptz := cps.shop_cycle_start();
  row  cps.shop_stock;
  s1   text; s2 text; s3 text;
begin
  select * into row from cps.shop_stock where cycle_start = cs;
  if found then return row; end if;
  -- deterministic seed from cycle start
  perform setseed(('x' || substr(md5(cs::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  -- slot 1: random active set, not jumbled
  select id into s1 from cps.card_sets where active and id <> 'jumbled' order by random() limit 1;
  -- slot 2: random active set, not jumbled, not slot 1
  select id into s2 from cps.card_sets where active and id <> 'jumbled' and id <> s1 order by random() limit 1;
  -- slot 3: random active set (jumbled allowed, can match 1/2)
  select id into s3 from cps.card_sets where active order by random() limit 1;
  insert into cps.shop_stock (cycle_start, slot1_set, slot2_set, slot3_set)
  values (cs, s1, s2, s3)
  on conflict (cycle_start) do nothing;
  select * into row from cps.shop_stock where cycle_start = cs;
  return row;
end $$;

-- --- shop status ------------------------------------------------------------
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
  select coalesce(jsonb_agg(jsonb_build_object(
      'slot', h.slot, 'set_id', h.set_id, 'price', h.price,
      'purchased_at', h.purchased_at
    ) order by h.purchased_at desc), '[]'::jsonb)
    into hist from cps.shop_history h
    where h.account_id = a.id order by h.purchased_at desc limit 20;
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

-- --- buy from the shop -------------------------------------------------------
create or replace function public.cps_shop_buy(p_token text, p_slot int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  set_id text;
  price  int;
  bought int := 0;
begin
  if p_slot not in (1, 2, 3) then raise exception 'Bad slot.'; end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  set_id := case p_slot when 1 then stock.slot1_set when 2 then stock.slot2_set else stock.slot3_set end;
  price := case when p_slot = 3 then 2 else 5 end;
  -- slot 3 limit: 3 per player per cycle
  if p_slot = 3 then
    select count into bought from cps.shop_purchases
      where account_id = a.id and cycle_start = cs and slot = 3;
    if coalesce(bought, 0) >= 3 then raise exception 'Deal limit reached (3 per restock).'; end if;
  end if;
  if a.store_credit < price then raise exception 'Not enough Store Credit.'; end if;
  -- deduct + grant pack + record
  update cps.accounts set store_credit = store_credit - price where id = a.id;
  perform cps.add_packs(a.id, set_id, 1, 'shop_buy', cs::text, null);
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, 1)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + 1;
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', set_id, price);
  return jsonb_build_object('ok', true, 'store_credit', (select store_credit from cps.accounts where id = a.id));
end $$;

notify pgrst, 'reload schema';
