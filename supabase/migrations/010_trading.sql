-- =====================================================================
-- 010_trading.sql — two-way card trading between players.
--
--   cps.trade_offers   : pending/decided trade offers
--   cps_propose_trade  : offer one of your cards for one of theirs
--   cps_respond_trade  : recipient accepts or declines (atomic swap)
--   cps_cancel_trade   : offerer cancels a pending offer
--   cps_list_trades    : your offers, both directions, pending first
--   cps_get_profile    : extended with full collection (for the trade picker)
--
-- Cards are NOT locked while an offer is pending; ownership is re-verified
-- at accept time and a stale offer expires instead of half-completing.
-- =====================================================================

-- --- offers table -------------------------------------------------------
create table if not exists cps.trade_offers (
  id           uuid primary key default gen_random_uuid(),
  from_account uuid not null references cps.accounts(id) on delete cascade,
  to_account   uuid not null references cps.accounts(id) on delete cascade,
  offer_set    text not null,
  offer_card   text not null,
  offer_holo   boolean not null default false,
  want_set     text not null,
  want_card    text not null,
  want_holo    boolean not null default false,
  status       text not null default 'pending'
                 check (status in ('pending','accepted','declined','cancelled','expired')),
  created_at   timestamptz not null default now(),
  decided_at   timestamptz,
  expires_at   timestamptz not null default now() + interval '7 days',
  check (from_account <> to_account)
);
create index if not exists idx_trade_offers_from   on cps.trade_offers(from_account, status);
create index if not exists idx_trade_offers_to     on cps.trade_offers(to_account, status);
create index if not exists idx_trade_offers_expiry on cps.trade_offers(status, expires_at);

-- --- propose ------------------------------------------------------------
create or replace function public.cps_propose_trade(
  p_token text, p_to uuid,
  p_offer_set text, p_offer_card text, p_offer_holo boolean,
  p_want_set text, p_want_card text, p_want_holo boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  tgt    cps.accounts%rowtype;
  oc     cps.collection%rowtype;
  wc     cps.collection%rowtype;
  new_id uuid;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot trade with yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  -- offerer must own the offered card
  select * into oc from cps.collection
    where account_id = a.id and set_id = p_offer_set and card_id = p_offer_card;
  if not found or oc.count < 1
     or (p_offer_holo and oc.holo_count < 1)
     or (not p_offer_holo and oc.count - oc.holo_count < 1) then
    raise exception 'You do not have that card to offer.';
  end if;

  -- recipient must own the wanted card (keeps offers actionable)
  select * into wc from cps.collection
    where account_id = tgt.id and set_id = p_want_set and card_id = p_want_card;
  if not found or wc.count < 1
     or (p_want_holo and wc.holo_count < 1)
     or (not p_want_holo and wc.count - wc.holo_count < 1) then
    raise exception 'They do not have that card to trade.';
  end if;

  if (select count(*) from cps.trade_offers
        where from_account = a.id and status = 'pending') >= 10 then
    raise exception 'You have too many pending offers (max 10).';
  end if;

  insert into cps.trade_offers
      (from_account, to_account, offer_set, offer_card, offer_holo,
       want_set, want_card, want_holo)
    values (a.id, tgt.id, p_offer_set, p_offer_card, coalesce(p_offer_holo,false),
            p_want_set, p_want_card, coalesce(p_want_holo,false))
    returning id into new_id;
  return jsonb_build_object('id', new_id);
end $$;

-- --- respond (accept / decline) -------------------------------------------
create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  oc  cps.collection%rowtype;
  wc  cps.collection%rowtype;
  ok_offer boolean;
  ok_want  boolean;
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

  -- re-verify both sides still own their cards (cards are not locked)
  select * into oc from cps.collection
    where account_id = o.from_account and set_id = o.offer_set and card_id = o.offer_card for update;
  ok_offer := found and oc.count >= 1
    and ((o.offer_holo and oc.holo_count >= 1) or (not o.offer_holo and oc.count - oc.holo_count >= 1));
  select * into wc from cps.collection
    where account_id = o.to_account and set_id = o.want_set and card_id = o.want_card for update;
  ok_want := found and wc.count >= 1
    and ((o.want_holo and wc.holo_count >= 1) or (not o.want_holo and wc.count - wc.holo_count >= 1));

  if not ok_offer or not ok_want then
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    raise exception 'A card in this trade is no longer available.';
  end if;

  -- atomic swap, both legs logged against the offer
  perform cps.transfer_card(o.from_account, o.to_account, o.offer_set, o.offer_card, o.offer_holo, 1, o.id::text);
  perform cps.transfer_card(o.to_account, o.from_account, o.want_set, o.want_card, o.want_holo, 1, o.id::text);
  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  return jsonb_build_object('status', 'accepted');
end $$;

-- --- cancel (offerer) -----------------------------------------------------
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

-- --- list (both directions, pending first) --------------------------------
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
      'offer_set', o.offer_set, 'offer_card', o.offer_card, 'offer_holo', o.offer_holo,
      'want_set', o.want_set,   'want_card', o.want_card,   'want_holo', o.want_holo,
      'status', o.status,
      'created_at', o.created_at, 'expires_at', o.expires_at)
    order by (o.status = 'pending') desc, coalesce(o.decided_at, o.created_at) desc)
    from cps.trade_offers o
    join cps.accounts f on f.id = o.from_account
    join cps.accounts t on t.id = o.to_account
    where (o.from_account = a.id or o.to_account = a.id)
      and o.created_at > now() - interval '30 days'), '[]');
end $$;

-- --- get_profile: add full collection for the trade card picker ------------
create or replace function public.cps_get_profile(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  tgt cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into tgt from cps.accounts where id = p_account and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  return jsonb_build_object(
    'id', tgt.id,
    'display_name', tgt.display_name,
    'is_me', tgt.id = a.id,
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', f.set_id,
                'card_id', f.card_id,
                'holo', coalesce((select c.holo_count > 0 from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = f.set_id
                                    and c.card_id = f.card_id), false))
              order by f.created_at)
            from cps.favorites f where f.account_id = tgt.id), '[]'),
    'collection', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', c.set_id, 'card_id', c.card_id, 'n', c.count, 'h', c.holo_count)
              order by c.set_id, c.card_id)
            from cps.collection c where c.account_id = tgt.id and c.count > 0), '[]'),
    'sets', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', s.id,
                'set_name', s.name,
                'unique', (select count(*) from cps.collection c
                            where c.account_id = tgt.id and c.set_id = s.id and c.count > 0),
                'total', (select count(*) from cps.cards k where k.set_id = s.id))
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
