-- =====================================================================
-- 011_multi_trade.sql — multi-card trades, up to 10 cards per side.
--
-- Replaces the single-card schema from 010 (it launched today; no live
-- offers exist yet, so the table is rebuilt cleanly).
--
--   cps.trade_offers      : header (who, status, timestamps)
--   cps.trade_offer_items : line items (offer_id, side, set_id, card_id, holo, qty)
--   cps_propose_trade     : p_offer / p_want are jsonb arrays of
--                           {set, card, holo}; 1-10 cards per side
--   cps_respond_trade     : atomic multi-card swap
--   cps_cancel_trade      : unchanged
--   cps_list_trades       : returns offer_items / want_items arrays
-- =====================================================================

drop table if exists cps.trade_offers cascade;

create table cps.trade_offers (
  id           uuid primary key default gen_random_uuid(),
  from_account uuid not null references cps.accounts(id) on delete cascade,
  to_account   uuid not null references cps.accounts(id) on delete cascade,
  status       text not null default 'pending'
                 check (status in ('pending','accepted','declined','cancelled','expired')),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  expires_at   timestamptz not null default now() + interval '7 days',
  check (from_account <> to_account)
);
create table cps.trade_offer_items (
  offer_id uuid not null references cps.trade_offers(id) on delete cascade,
  side     text not null check (side in ('offer','want')),
  set_id   text not null,
  card_id  text not null,
  holo     boolean not null default false,
  qty      int not null default 1 check (qty >= 1)
);
create index idx_trade_offers_from   on cps.trade_offers(from_account, status);
create index idx_trade_offers_to     on cps.trade_offers(to_account, status);
create index idx_trade_offers_expiry on cps.trade_offers(status, expires_at);
create index idx_trade_items_offer    on cps.trade_offer_items(offer_id, side);

-- --- validate one side's item list against the owner's collection --------
create or replace function cps.trade_check_side(p_owner uuid, p_items jsonb, p_label text)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  total int;
  r     record;
  c     cps.collection%rowtype;
begin
  if jsonb_typeof(p_items) <> 'array' then
    raise exception '% must be a list of cards.', p_label;
  end if;
  total := (select count(*) from jsonb_array_elements(p_items));
  if total < 1 or total > 10 then
    raise exception '% must have between 1 and 10 cards.', p_label;
  end if;
  for r in
    select t.set_id, t.card_id,
           sum(case when t.holo then 1 else 0 end)::int as holo_qty,
           sum(case when t.holo then 0 else 1 end)::int as plain_qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo
          from jsonb_array_elements(p_items) j) t
    group by t.set_id, t.card_id
  loop
    if r.set_id is null or r.card_id is null then
      raise exception 'Bad card in the % list.', p_label;
    end if;
    select * into c from cps.collection
      where account_id = p_owner and set_id = r.set_id and card_id = r.card_id;
    if not found or c.count < r.holo_qty + r.plain_qty
       or c.holo_count < r.holo_qty
       or c.count - c.holo_count < r.plain_qty then
      raise exception 'Not enough copies for a card in the % list.', p_label;
    end if;
  end loop;
end $$;

-- --- insert aggregated line items ----------------------------------------
create or replace function cps.trade_insert_items(p_offer uuid, p_side text, p_items jsonb)
returns void language sql set search_path = cps, pg_temp as $$
  insert into cps.trade_offer_items (offer_id, side, set_id, card_id, holo, qty)
  select p_offer, p_side, t.set_id, t.card_id, t.holo, count(*)::int
  from (select j->>'set' as set_id, j->>'card' as card_id,
               coalesce((j->>'holo')::boolean, false) as holo
        from jsonb_array_elements(p_items) j) t
  group by t.set_id, t.card_id, t.holo;
$$;

-- --- propose --------------------------------------------------------------
create or replace function public.cps_propose_trade(
  p_token text, p_to uuid, p_offer jsonb, p_want jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  tgt    cps.accounts%rowtype;
  new_id uuid;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot trade with yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  perform cps.trade_check_side(a.id, p_offer, 'Your offer');
  perform cps.trade_check_side(tgt.id, p_want, 'Their side');

  if (select count(*) from cps.trade_offers
        where from_account = a.id and status = 'pending') >= 10 then
    raise exception 'You have too many pending offers (max 10).';
  end if;

  insert into cps.trade_offers (from_account, to_account)
    values (a.id, tgt.id) returning id into new_id;
  perform cps.trade_insert_items(new_id, 'offer', p_offer);
  perform cps.trade_insert_items(new_id, 'want', p_want);
  return jsonb_build_object('id', new_id);
end $$;

-- --- respond (accept / decline) -------------------------------------------
create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  r   record;
  c   cps.collection%rowtype;
  giver uuid;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.to_account <> a.id then raise exception 'This offer is not for you.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  if o.expires_at < now() then
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    raise exception 'This offer has expired.';
  end if;

  if not p_accept then
    update cps.trade_offers set status = 'declined', decided_at = now() where id = o.id;
    return jsonb_build_object('status', 'declined');
  end if;

  -- verify every line first (deterministic lock order: no deadlocks), then move cards
  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
    group by 1, 2, 3, 4 order by 1, 2, 3, 4
  loop
    select * into c from cps.collection
      where account_id = r.giver and set_id = r.set_id and card_id = r.card_id for update;
    if not found or c.count < r.qty
       or (r.holo and c.holo_count < r.qty)
       or (not r.holo and c.count - c.holo_count < r.qty) then
      update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
      raise exception 'A card in this trade is no longer available.';
    end if;
  end loop;

  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           (case when i.side = 'offer' then o.to_account else o.from_account end) as receiver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
    group by 1, 2, 3, 4, 5 order by 1, 3, 4, 5
  loop
    perform cps.transfer_card(r.giver, r.receiver, r.set_id, r.card_id, r.holo, r.qty, o.id::text);
  end loop;

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  return jsonb_build_object('status', 'accepted');
end $$;

-- --- cancel (offerer) -------------------------------------------------------
create or replace function public.cps_cancel_trade(p_token text, p_offer uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  o cps.trade_offers%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer;
  if not found then raise exception 'Offer not found.'; end if;
  if o.from_account <> a.id then raise exception 'Only the offerer can cancel.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  update cps.trade_offers set status = 'cancelled', decided_at = now() where id = o.id;
  return jsonb_build_object('status', 'cancelled');
end $$;

-- --- list (both directions, pending first) ----------------------------------
create or replace function public.cps_list_trades(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  -- lazy expiry
  update cps.trade_offers set status = 'expired', decided_at = now()
    where status = 'pending' and expires_at < now();
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id,
      'direction', case when o.from_account = a.id then 'outgoing' else 'incoming' end,
      'other_id', case when o.from_account = a.id then o.to_account else o.from_account end,
      'other_name', case when o.from_account = a.id then t.display_name else f.display_name end,
      'offer_items', coalesce((select jsonb_agg(jsonb_build_object(
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty)
                      order by set_id, card_id, holo)
                    from cps.trade_offer_items where offer_id = o.id and side = 'offer'), '[]'),
      'want_items', coalesce((select jsonb_agg(jsonb_build_object(
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty)
                      order by set_id, card_id, holo)
                    from cps.trade_offer_items where offer_id = o.id and side = 'want'), '[]'),
      'status', o.status,
      'created_at', o.created_at, 'expires_at', o.expires_at)
    order by (o.status = 'pending') desc, coalesce(o.decided_at, o.created_at) desc)
    from cps.trade_offers o
    join cps.accounts f on f.id = o.from_account
    join cps.accounts t on t.id = o.to_account
    where (o.from_account = a.id or o.to_account = a.id)
      and o.created_at > now() - interval '30 days'), '[]');
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
