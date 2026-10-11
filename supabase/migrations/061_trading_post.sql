-- =====================================================================
-- 061_trading_post.sql — Trading Post: list a card, field escrowed offers.
--
-- A player lists ONE owned card (holo choice, numbered-variant serials
-- allowed) with an optional note. The card is escrowed at post time. Other
-- players submit offers of game tokens, spin tickets, packs (one set +
-- count), and/or up to 5 cards — numbered-variant serials allowed, each
-- picked explicitly. EVERYTHING is escrowed at submit time, so acceptance
-- can never fail on missing items. The lister picks the winning offer;
-- the swap is atomic, losing offers are auto-declined with full refunds.
-- One active offer per player per listing (rebidding replaces + refunds the
-- old one). Listings expire after 7 days with full refunds; the lister can
-- cancel anytime. Max 5 open listings per player. Admins may post/offer
-- (same as bounties/trading).
--
-- Design notes:
-- * Cards are count-based (cps.collection has no per-instance rows), so
--   "escrow" = decrement collection counts into cps.trade_escrow at post/
--   offer time. While escrowed, cards are invisible to the collection UI,
--   trades, gifts, and both dupe trade-ins — all of those read
--   cps.collection, so no patches are needed elsewhere.
-- * Numbered variants live in cps.variants (one row per issued serial).
--   Escrow rows carry (variant_tier, variant_serial); the variants rows
--   themselves are NOT touched during escrow — only on accept, when the
--   serial's account_id moves to its new owner. Refunds therefore never
--   need variant bookkeeping. Every "do you own this serial" check excludes
--   serials with a live escrow row.
-- * Known edge (same class as bounty's cosmetic variant issue): if a player
--   holds 2+ copies of a card with one serial escrowed and direct-trades a
--   copy away, transfer_card moves the lowest serial, which may be the
--   escrowed one. The escrow itself is unaffected (the base copy is what
--   moves on accept), but the variants row would point at the trade
--   recipient until accept re-points it. Cosmetic, not destructive.
-- * New functions/tables only — nothing is dropped or redefined.
-- =====================================================================

-- --- listings ------------------------------------------------------------
create table if not exists cps.trade_listings (
  id             uuid primary key default gen_random_uuid(),
  lister         uuid not null references cps.accounts(id) on delete cascade,
  set_id         text not null,
  card_id        text not null,
  holo           boolean not null default false,
  variant_tier   text check (variant_tier is null or variant_tier in ('rainbow', 'prism', 'obsidian', 'oneofone')),
  variant_serial int  check (variant_serial is null or variant_serial >= 1),
  note           varchar(140) not null default '',
  status         text not null default 'open'
                   check (status in ('open', 'accepted', 'cancelled', 'expired')),
  created_at     timestamptz not null default now(),
  expires_at     timestamptz not null default now() + interval '7 days',
  accepted_offer uuid,
  accepted_at    timestamptz,
  check ((variant_tier is null) = (variant_serial is null))
);
create index if not exists idx_trade_listings_lister on cps.trade_listings(lister, status);
create index if not exists idx_trade_listings_expiry on cps.trade_listings(status, expires_at);

-- --- offers ---------------------------------------------------------------
create table if not exists cps.trade_offers (
  id         uuid primary key default gen_random_uuid(),
  listing_id uuid not null references cps.trade_listings(id) on delete cascade,
  offerer    uuid not null references cps.accounts(id) on delete cascade,
  tokens     int not null default 0 check (tokens >= 0),
  tickets    int not null default 0 check (tickets >= 0),
  pack_set   text,
  packs      int not null default 0 check (packs >= 0),
  cards      jsonb not null default '[]'::jsonb,
  status     text not null default 'open'
               check (status in ('open', 'accepted', 'declined', 'withdrawn', 'replaced', 'expired')),
  created_at timestamptz not null default now()
);
create index if not exists idx_trade_offers_listing on cps.trade_offers(listing_id, status);
create index if not exists idx_trade_offers_offerer on cps.trade_offers(offerer, status);

-- --- escrow ledger: cards held out of circulation --------------------------
-- offer_id null  => the lister's card; otherwise one of an offer's cards.
-- Rows exist only while the listing/offer is live; deleted on refund/accept.
create table if not exists cps.trade_escrow (
  id             uuid primary key default gen_random_uuid(),
  listing_id     uuid not null references cps.trade_listings(id) on delete cascade,
  offer_id       uuid references cps.trade_offers(id) on delete cascade,
  account_id     uuid not null references cps.accounts(id) on delete cascade,
  set_id         text not null,
  card_id        text not null,
  holo           boolean not null default false,
  variant_tier   text,
  variant_serial int,
  qty            int not null check (qty >= 1)
);
create index if not exists idx_trade_escrow_listing on cps.trade_escrow(listing_id);
create index if not exists idx_trade_escrow_offer on cps.trade_escrow(offer_id);
create index if not exists idx_trade_escrow_variant on cps.trade_escrow(set_id, card_id, variant_tier, variant_serial);

alter table cps.trade_listings enable row level security;
alter table cps.trade_offers   enable row level security;
alter table cps.trade_escrow   enable row level security;
revoke all on table cps.trade_listings from public;
revoke all on table cps.trade_offers   from public;
revoke all on table cps.trade_escrow   from public;

-- --- internal: is this numbered serial currently escrowed? ----------------
create or replace function cps.trade_variant_escrowed(p_set text, p_card text, p_tier text, p_serial int)
returns boolean language sql set search_path = cps, pg_temp as $$
  select exists (
    select 1 from cps.trade_escrow e
    where e.set_id = p_set and e.card_id = p_card
      and e.variant_tier = p_tier and e.variant_serial = p_serial
  );
$$;

-- --- internal: refund one offer's escrow back to its offerer ----------------
create or replace function cps.trade_refund_offer(p_offer uuid)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  o cps.trade_offers%rowtype;
  e record;
begin
  select * into o from cps.trade_offers where id = p_offer;
  if not found then return; end if;

  for e in select * from cps.trade_escrow where offer_id = p_offer loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (o.offerer, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
  end loop;
  delete from cps.trade_escrow where offer_id = p_offer;

  if o.tokens > 0 or o.tickets > 0 then
    update cps.accounts
      set game_tokens = game_tokens + o.tokens,
          spins = spins + o.tickets
      where id = o.offerer;
    if o.tickets > 0 then
      insert into cps.spin_grants (account_id, spins, reason)
        values (o.offerer, o.tickets, 'trade_refund');
    end if;
    if o.tokens > 0 then
      insert into cps.token_grants (account_id, tokens, reason)
        values (o.offerer, o.tokens, 'trade_refund');
    end if;
  end if;

  if o.packs > 0 and o.pack_set is not null then
    perform cps.add_packs(o.offerer, o.pack_set, o.packs, 'trade_refund', o.id::text, null);
  end if;
end $$;

-- --- internal: expire + refund every due listing (called lazily) -----------
create or replace function cps.trade_expire_due()
returns int language plpgsql set search_path = cps, pg_temp as $$
declare
  l        record;
  o        record;
  n        int := 0;
  cardname text;
  setname  text;
begin
  for l in
    select id, lister, set_id, card_id from cps.trade_listings
    where status = 'open' and expires_at < now()
    for update skip locked
  loop
    update cps.trade_listings set status = 'expired' where id = l.id;

    -- lister's card back
    for o in select * from cps.trade_escrow where listing_id = l.id and offer_id is null loop
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (l.lister, o.set_id, o.card_id, o.qty, case when o.holo then o.qty else 0 end)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + excluded.count,
              holo_count = cps.collection.holo_count + excluded.holo_count;
    end loop;

    -- every open offer declined + refunded
    for o in select id, offerer from cps.trade_offers where listing_id = l.id and status = 'open' loop
      update cps.trade_offers set status = 'expired' where id = o.id;
      perform cps.trade_refund_offer(o.id);
      perform cps.notify(o.offerer, 'trade_offer_expired',
        'Your offer was returned — the listing expired before it was accepted.', 'trading');
    end loop;

    delete from cps.trade_escrow where listing_id = l.id;

    select k.name, s.name into cardname, setname
      from cps.cards k join cps.card_sets s on s.id = k.set_id
      where k.set_id = l.set_id and k.card_id = l.card_id;
    perform cps.notify(l.lister, 'trade_expired',
      'Your Trading Post listing for ' || coalesce(cardname, 'a card') ||
      ' (' || coalesce(setname, l.set_id) || ') expired — your card was returned.', 'trading');
    n := n + 1;
  end loop;
  return n;
end $$;

-- --- post a listing ---------------------------------------------------------
-- p_card: {set, card, holo, tier?, serial?}
create or replace function public.cps_trade_post(p_token text, p_card jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  cset    text;
  ccard   text;
  cholo   boolean;
  ctier   text;
  cserial int;
  new_id  uuid := gen_random_uuid();
  vrar    text;
  vopen   int;
  c       cps.collection%rowtype;
begin
  a := cps.auth(p_token);

  cset    := p_card->>'set';
  ccard   := p_card->>'card';
  cholo   := coalesce((p_card->>'holo')::boolean, false);
  ctier   := nullif(p_card->>'tier', '');
  cserial := nullif(p_card->>'serial', '')::int;
  if cset is null or ccard is null then raise exception 'Pick a card to list.'; end if;
  select k.rarity into vrar from cps.cards k where k.set_id = cset and k.card_id = ccard;
  if not found then raise exception 'That card is not on the server.'; end if;

  if ctier is not null then
    if ctier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
    if vrar not in ('rare', 'epic', 'legendary', 'chase') then
      raise exception 'Numbered variants only exist for rare cards and up.'; end if;
    if cserial is null or cserial < 1 or cserial > cps.variant_run(ctier) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(ctier), cps.variant_name(ctier); end if;
    if not exists (select 1 from cps.variants
                   where account_id = a.id and set_id = cset and card_id = ccard
                     and tier = ctier and serial = cserial) then
      raise exception 'You don''t hold that numbered copy.'; end if;
    if cps.trade_variant_escrowed(cset, ccard, ctier, cserial) then
      raise exception 'That numbered copy is already listed or offered.'; end if;
  elsif cserial is not null then
    raise exception 'A serial needs a variant tier.'; end if;

  select count(*) into vopen from cps.trade_listings where lister = a.id and status = 'open';
  if vopen >= 5 then raise exception 'You already have 5 open listings — accept or cancel one first.'; end if;

  -- escrow the card: one specific copy leaves the collection
  select * into c from cps.collection
    where account_id = a.id and set_id = cset and card_id = ccard for update;
  if not found or c.count < 1 then raise exception 'You don''t hold that card.'; end if;
  if cholo and coalesce(c.holo_count, 0) < 1 then raise exception 'You don''t have a holo copy to list.'; end if;
  -- non-variant listings can't take a variant copy's base slot
  if ctier is null then
    declare vn int;
    begin
      select count(*) into vn from cps.variants
        where account_id = a.id and set_id = cset and card_id = ccard;
      if coalesce(c.count, 0) - vn < 1 then
        raise exception 'Your only copies are numbered — list it as a numbered card instead.'; end if;
    end;
  end if;
  update cps.collection
    set count = count - 1,
        holo_count = case when cholo then holo_count - 1
                          else least(holo_count, count - 1) end
    where account_id = a.id and set_id = cset and card_id = ccard;
  insert into cps.trade_escrow (listing_id, offer_id, account_id, set_id, card_id, holo,
                               variant_tier, variant_serial, qty)
    values (new_id, null, a.id, cset, ccard, cholo, ctier, cserial, 1);

  -- a fully-escrowed card can't stay favorited (mirrors transfer_card)
  delete from cps.favorites f
    where f.account_id = a.id and f.set_id = cset and f.card_id = ccard
      and not exists (select 1 from cps.collection cc
                      where cc.account_id = a.id and cc.set_id = cset
                        and cc.card_id = ccard and cc.count > 0);

  insert into cps.trade_listings (id, lister, set_id, card_id, holo, variant_tier, variant_serial, note)
    values (new_id, a.id, cset, ccard, cholo, ctier, cserial, left(coalesce(p_note, ''), 140));

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- cancel a listing (lister only, open only, full refunds) ----------------
create or replace function public.cps_trade_cancel(p_token text, p_listing uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  l cps.trade_listings%rowtype;
  e record;
  o record;
begin
  a := cps.auth(p_token);
  select * into l from cps.trade_listings where id = p_listing for update;
  if not found then raise exception 'Listing not found.'; end if;
  if l.lister <> a.id then raise exception 'Only the lister can cancel this.'; end if;
  if l.status <> 'open' then raise exception 'This listing is no longer open.'; end if;

  update cps.trade_listings set status = 'cancelled' where id = l.id;

  -- lister's card back
  for e in select * from cps.trade_escrow where listing_id = l.id and offer_id is null loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (l.lister, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
  end loop;

  -- open offers declined + refunded
  for o in select id, offerer from cps.trade_offers where listing_id = l.id and status = 'open' loop
    update cps.trade_offers set status = 'declined' where id = o.id;
    perform cps.trade_refund_offer(o.id);
    perform cps.notify(o.offerer, 'trade_offer_declined',
      'The listing you offered on was cancelled — your offer was refunded.', 'trading');
  end loop;

  delete from cps.trade_escrow where listing_id = l.id;
  return jsonb_build_object('ok', true);
end $$;

-- --- submit an offer (escrowed; replaces your existing open offer) -----------
-- p_offer: {tokens, tickets, pack_set, packs, cards: [{set, card, holo, tier?, serial?}]}
create or replace function public.cps_trade_offer(p_token text, p_listing uuid, p_offer jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  l        cps.trade_listings%rowtype;
  otokens  int;
  otickets int;
  opackset text;
  opacks   int;
  new_id   uuid := gen_random_uuid();
  vtok     int;
  vtix     int;
  vinv     int;
  old_id   uuid;
  r        record;
  c        cps.collection%rowtype;
  vn       int;
  ncards   int;
begin
  a := cps.auth(p_token);
  select * into l from cps.trade_listings where id = p_listing for update;
  if not found then raise exception 'Listing not found.'; end if;
  if l.status = 'open' and l.expires_at < now() then
    perform cps.trade_expire_due();
    raise exception 'This listing has expired.';
  end if;
  if l.status <> 'open' then raise exception 'This listing is no longer open.'; end if;
  if l.lister = a.id then raise exception 'You cannot offer on your own listing.'; end if;

  otokens  := greatest(coalesce((p_offer->>'tokens')::int, 0), 0);
  otickets := greatest(coalesce((p_offer->>'tickets')::int, 0), 0);
  opackset := nullif(p_offer->>'pack_set', '');
  opacks   := greatest(coalesce((p_offer->>'packs')::int, 0), 0);
  if jsonb_typeof(coalesce(p_offer->'cards', '[]'::jsonb)) <> 'array' then
    raise exception 'Bad card offer.'; end if;
  select count(*) into ncards from jsonb_array_elements(coalesce(p_offer->'cards', '[]'::jsonb));
  if ncards > 5 then raise exception 'At most 5 cards per offer.'; end if;

  -- replacing your existing open offer refunds it first
  select id into old_id from cps.trade_offers
    where listing_id = p_listing and offerer = a.id and status = 'open'
    for update;
  if found then
    update cps.trade_offers set status = 'replaced' where id = old_id;
    perform cps.trade_refund_offer(old_id);
  end if;

  -- escrow currencies
  select game_tokens, spins into vtok, vtix from cps.accounts where id = a.id for update;
  if otokens > vtok then raise exception 'You don''t have that many game tokens.'; end if;
  if otickets > vtix then raise exception 'You don''t have that many spin tickets.'; end if;
  if otokens > 0 or otickets > 0 then
    update cps.accounts set game_tokens = game_tokens - otokens, spins = spins - otickets where id = a.id;
  end if;

  -- escrow packs
  if opacks > 0 then
    if opackset is null or not exists (select 1 from cps.card_sets where id = opackset) then
      raise exception 'Pick a set for the pack offer.'; end if;
    select packs into vinv from cps.pack_inventory where account_id = a.id and set_id = opackset for update;
    if coalesce(vinv, 0) < opacks then raise exception 'You don''t have that many packs.'; end if;
    perform cps.add_packs(a.id, opackset, -opacks, 'trade_escrow', new_id::text, null);
  end if;

  -- escrow cards (numbered serials allowed, picked explicitly)
  for r in
    select t.set_id, t.card_id, t.holo, t.tier, t.serial, count(*)::int as qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo,
                 nullif(j->>'tier', '') as tier,
                 nullif(j->>'serial', '')::int as serial
          from jsonb_array_elements(coalesce(p_offer->'cards', '[]'::jsonb)) j) t
    group by t.set_id, t.card_id, t.holo, t.tier, t.serial
  loop
    if r.set_id is null or r.card_id is null then raise exception 'Bad card in your offer.'; end if;
    if not exists (select 1 from cps.cards where set_id = r.set_id and card_id = r.card_id) then
      raise exception 'Unknown card in your offer.'; end if;
    if (r.tier is null) <> (r.serial is null) then raise exception 'A serial needs a variant tier.'; end if;
    if r.tier is not null then
      if r.tier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
      if r.serial < 1 or r.serial > cps.variant_run(r.tier) then raise exception 'Bad serial.'; end if;
      if not exists (select 1 from cps.variants
                     where account_id = a.id and set_id = r.set_id and card_id = r.card_id
                       and tier = r.tier and serial = r.serial) then
        raise exception 'You don''t hold that numbered copy.'; end if;
      if cps.trade_variant_escrowed(r.set_id, r.card_id, r.tier, r.serial) then
        raise exception 'That numbered copy is already listed or offered.'; end if;
    end if;
    select * into c from cps.collection
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id for update;
    if r.tier is null then
      -- non-variant copies only (variants are picked as explicit serials)
      select count(*) into vn from cps.variants
        where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
      if coalesce(c.count, 0) - vn < r.qty then
        raise exception 'You don''t have enough non-numbered copies to offer.'; end if;
      if r.holo and coalesce(c.holo_count, 0) < r.qty then
        raise exception 'You don''t have enough holo copies to offer.'; end if;
    else
      if coalesce(c.count, 0) < r.qty then
        raise exception 'You don''t hold that card.'; end if;
    end if;
    update cps.collection
      set count = count - r.qty,
          holo_count = case when r.holo then holo_count - r.qty
                            else least(holo_count, count - r.qty) end
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
    insert into cps.trade_escrow (listing_id, offer_id, account_id, set_id, card_id, holo,
                                 variant_tier, variant_serial, qty)
      values (p_listing, new_id, a.id, r.set_id, r.card_id, r.holo, r.tier, r.serial, r.qty);
    delete from cps.favorites f
      where f.account_id = a.id and f.set_id = r.set_id and f.card_id = r.card_id
        and not exists (select 1 from cps.collection cc
                        where cc.account_id = a.id and cc.set_id = r.set_id
                          and cc.card_id = r.card_id and cc.count > 0);
  end loop;

  -- the offer must be *something*
  if otokens = 0 and otickets = 0 and opacks = 0
     and not exists (select 1 from cps.trade_escrow where offer_id = new_id) then
    raise exception 'Your offer needs tokens, tickets, packs, or cards.'; end if;

  insert into cps.trade_offers (id, listing_id, offerer, tokens, tickets, pack_set, packs,
                               cards, status)
    values (new_id, p_listing, a.id, otokens, otickets, opackset, opacks,
            coalesce(p_offer->'cards', '[]'::jsonb), 'open');

  perform cps.notify(l.lister, 'trade_new_offer',
    a.display_name || ' made an offer on your Trading Post listing.', 'trading');

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- withdraw your offer (offerer only, open only, full refund) --------------
create or replace function public.cps_trade_withdraw(p_token text, p_offer uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  o cps.trade_offers%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.offerer <> a.id then raise exception 'Only the offerer can withdraw this.'; end if;
  if o.status <> 'open' then raise exception 'This offer is no longer open.'; end if;

  update cps.trade_offers set status = 'withdrawn' where id = o.id;
  perform cps.trade_refund_offer(o.id);
  return jsonb_build_object('ok', true);
end $$;

-- --- accept an offer (lister only, atomic swap) --------------------------------
create or replace function public.cps_trade_accept(p_token text, p_listing uuid, p_offer uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  l          cps.trade_listings%rowtype;
  o          cps.trade_offers%rowtype;
  e          record;
  r          record;
  cardname   text;
  setname    text;
  offer_desc text := '';
  bits       text[];
  psetname   text;
begin
  a := cps.auth(p_token);
  select * into l from cps.trade_listings where id = p_listing for update;
  if not found then raise exception 'Listing not found.'; end if;
  if l.status = 'open' and l.expires_at < now() then
    perform cps.trade_expire_due();
    raise exception 'This listing has expired — everything was refunded.';
  end if;
  if l.status <> 'open' then raise exception 'This listing is no longer open.'; end if;
  if l.lister <> a.id then raise exception 'Only the lister can accept an offer.'; end if;

  select * into o from cps.trade_offers where id = p_offer and listing_id = p_listing for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.status <> 'open' then raise exception 'That offer is no longer open.'; end if;

  -- --- the lister's card goes to the winner (escrow -> winner's collection)
  for e in select * from cps.trade_escrow where listing_id = l.id and offer_id is null loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (o.offerer, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
    if e.variant_tier is not null then
      update cps.variants set account_id = o.offerer
        where account_id = l.lister and set_id = e.set_id and card_id = e.card_id
          and tier = e.variant_tier and serial = e.variant_serial;
    end if;
    insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
      values (l.lister, o.offerer, e.set_id, e.card_id, e.holo, e.qty, 'trade:' || l.id::text);
  end loop;

  -- --- the winner's escrowed offer goes to the lister ---
  bits := '{}';
  if o.tokens > 0 then bits := bits || ('🪙 ' || o.tokens || ' game tokens'); end if;
  if o.tickets > 0 then bits := bits || ('🎟️ ' || o.tickets || ' spin tickets'); end if;
  if o.packs > 0 then
    select name into psetname from cps.card_sets where id = o.pack_set;
    bits := bits || ('🎁 ' || o.packs || ' ' || coalesce(psetname, o.pack_set) || ' packs');
  end if;
  for e in select * from cps.trade_escrow where offer_id = o.id loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (l.lister, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
    if e.variant_tier is not null then
      update cps.variants set account_id = l.lister
        where account_id = o.offerer and set_id = e.set_id and card_id = e.card_id
          and tier = e.variant_tier and serial = e.variant_serial;
    end if;
    insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
      values (o.offerer, l.lister, e.set_id, e.card_id, e.holo, e.qty, 'trade:' || l.id::text);
    select k.name into cardname from cps.cards k where k.set_id = e.set_id and k.card_id = e.card_id;
    bits := bits || (e.qty || '× ' || coalesce(cardname, e.card_id) ||
      case when e.holo then ' ✦ holo' else '' end ||
      case when e.variant_tier is not null
           then ' (' || cps.variant_name(e.variant_tier) || ' #' || e.variant_serial || ')' else '' end);
  end loop;
  if o.tokens > 0 or o.tickets > 0 then
    update cps.accounts
      set game_tokens = game_tokens + o.tokens,
          spins = spins + o.tickets
      where id = l.lister;
    if o.tickets > 0 then
      insert into cps.spin_grants (account_id, spins, reason)
        values (l.lister, o.tickets, 'trade_accept');
    end if;
    if o.tokens > 0 then
      insert into cps.token_grants (account_id, tokens, reason)
        values (l.lister, o.tokens, 'trade_accept');
    end if;
  end if;
  if o.packs > 0 and o.pack_set is not null then
    perform cps.add_packs(l.lister, o.pack_set, o.packs, 'trade_accept', l.id::text, null);
  end if;
  offer_desc := array_to_string(bits, ', ');

  update cps.trade_offers set status = 'accepted' where id = o.id;

  -- --- losing offers: declined + refunded + notified ---
  for r in select id, offerer from cps.trade_offers
           where listing_id = l.id and status = 'open' and id <> o.id loop
    update cps.trade_offers set status = 'declined' where id = r.id;
    perform cps.trade_refund_offer(r.id);
    perform cps.notify(r.offerer, 'trade_offer_declined',
      'Your offer wasn''t accepted — everything was refunded.', 'trading');
  end loop;

  delete from cps.trade_escrow where listing_id = l.id;
  update cps.trade_listings
    set status = 'accepted', accepted_offer = o.id, accepted_at = now()
    where id = l.id;

  -- --- notifications ---
  select k.name, s.name into cardname, setname
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = l.set_id and k.card_id = l.card_id;
  perform cps.notify(o.offerer, 'trade_won',
    'Your offer won ' || a.display_name || '''s ' ||
    coalesce(cardname, 'card') || ' (' || coalesce(setname, l.set_id) || ')!', 'trading');
  perform cps.notify(l.lister, 'trade_accepted',
    'You accepted an offer: ' || offer_desc || '.', 'trading');

  return jsonb_build_object('ok', true, 'listing_id', l.id,
    'spins', (select spins from cps.accounts where id = a.id),
    'game_tokens', (select game_tokens from cps.accounts where id = a.id));
end $$;

-- --- list open trades ----------------------------------------------------------
create or replace function public.cps_list_trades(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  out jsonb := '[]'::jsonb;
  lj  jsonb;
  oj  jsonb;
  l   record;
  o   record;
  my_open int;
begin
  a := cps.auth(p_token);
  perform cps.trade_expire_due();

  for l in
    select t.*, ac.display_name as lister_name,
           k.name as card_name, s.name as set_name, k.rarity as rarity,
           (select count(*) from cps.trade_offers ofr
             where ofr.listing_id = t.id and ofr.status = 'open') as offer_count,
           (select ofr.id from cps.trade_offers ofr
             where ofr.listing_id = t.id and ofr.offerer = a.id and ofr.status = 'open'
             limit 1) as my_offer_id
    from cps.trade_listings t
    join cps.accounts ac on ac.id = t.lister
    left join cps.cards k on k.set_id = t.set_id and k.card_id = t.card_id
    left join cps.card_sets s on s.id = t.set_id
    where t.status = 'open'
    order by t.created_at desc
  loop
    oj := '[]'::jsonb;
    for o in
      select ofr.*, ac2.display_name as offerer_name,
             ps.name as pack_name
      from cps.trade_offers ofr
      join cps.accounts ac2 on ac2.id = ofr.offerer
      left join cps.card_sets ps on ps.id = ofr.pack_set
      where ofr.listing_id = l.id and ofr.status = 'open'
      order by ofr.created_at asc
    loop
      oj := oj || jsonb_build_object(
        'id', o.id, 'offerer', o.offerer_name, 'offerer_id', o.offerer,
        'mine', o.offerer = a.id,
        'tokens', o.tokens, 'tickets', o.tickets,
        'pack_set', o.pack_set, 'packs', o.packs, 'pack_name', o.pack_name,
        'cards', coalesce(o.cards, '[]'::jsonb),
        'created_at', o.created_at);
    end loop;
    lj := jsonb_build_object(
      'id', l.id, 'lister', l.lister_name, 'lister_id', l.lister,
      'mine', l.lister = a.id,
      'set_id', l.set_id, 'set_name', l.set_name,
      'card_id', l.card_id, 'card_name', l.card_name, 'rarity', l.rarity,
      'holo', l.holo, 'variant_tier', l.variant_tier, 'variant_serial', l.variant_serial,
      'note', l.note, 'expires_at', l.expires_at,
      'offer_count', l.offer_count, 'my_offer', l.my_offer_id,
      'offers', oj);
    out := out || lj;
  end loop;

  select count(*) into my_open from cps.trade_listings where lister = a.id and status = 'open';
  return jsonb_build_object('listings', out, 'my_open', my_open);
end $$;

notify pgrst, 'reload schema';
