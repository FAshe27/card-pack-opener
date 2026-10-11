-- =====================================================================
-- 064_trade_post_fix.sql — insert parent rows before escrow rows
-- (FK violations on trade_escrow when listing / offering).
-- =====================================================================

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
  insert into cps.trade_listings (id, lister, set_id, card_id, holo, variant_tier, variant_serial, note)
    values (new_id, a.id, cset, ccard, cholo, ctier, cserial, left(coalesce(p_note, ''), 140));

  insert into cps.trade_escrow (listing_id, offer_id, account_id, set_id, card_id, holo,
                               variant_tier, variant_serial, qty)
    values (new_id, null, a.id, cset, ccard, cholo, ctier, cserial, 1);

  -- a fully-escrowed card can't stay favorited (mirrors transfer_card)
  delete from cps.favorites f
    where f.account_id = a.id and f.set_id = cset and f.card_id = ccard
      and not exists (select 1 from cps.collection cc
                      where cc.account_id = a.id and cc.set_id = cset
                        and cc.card_id = ccard and cc.count > 0);

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- cancel a listing (lister only, open only, full refunds) ----------------

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
  select id into old_id from cps.listing_offers
    where listing_id = p_listing and offerer = a.id and status = 'open'
    for update;
  if found then
    update cps.listing_offers set status = 'replaced' where id = old_id;
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
  -- offer row first (escrow FKs reference it)
  insert into cps.listing_offers (id, listing_id, offerer, tokens, tickets, pack_set, packs,
                               cards, status)
    values (new_id, p_listing, a.id, otokens, otickets, opackset, opacks,
            coalesce(p_offer->'cards', '[]'::jsonb), 'open');
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


  perform cps.notify(l.lister, 'trade_new_offer',
    a.display_name || ' made an offer on your Trading Post listing.', 'trading');

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- withdraw your offer (offerer only, open only, full refund) --------------
notify pgrst, 'reload schema';
