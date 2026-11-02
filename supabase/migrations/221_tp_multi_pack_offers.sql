-- 221: Trading Post offers can include MULTIPLE pack types (Franklin's ask,
-- 2026-11-02: "there should be an add button for the packs selection — I want
-- to offer two different types of packs but can't").
--
-- listing_offers gains pack_lines jsonb: [{set, n}, ...]. The legacy
-- pack_set/packs columns stay and mirror line 1, so un-updated readers keep
-- working; every pack-moving path resolves lines through the new
-- cps.offer_pack_lines() normaliser, which synthesises a one-line array for
-- pre-221 offers. All refund paths funnel through cps.trade_refund_offer, so
-- decline / withdraw / cancel / expire / replace inherit multi-line refunds
-- from that one rebuild. Bounties are untouched (their payment side stays
-- single-set by design).
--
-- Rebuild discipline: every function below is its CURRENT live body with
-- only the pack hunks changed (verified by diff against the live defs).

alter table cps.listing_offers add column if not exists pack_lines jsonb;

-- The one normaliser: explicit lines win; a legacy single pair becomes a
-- one-line array; no packs becomes an empty array.
create or replace function cps.offer_pack_lines(p_lines jsonb, p_set text, p_n int)
returns jsonb language sql immutable set search_path to 'cps', 'pg_temp' as $function$
  select case
    when p_lines is not null and jsonb_typeof(p_lines) = 'array' and jsonb_array_length(p_lines) > 0
      then p_lines
    when coalesce(p_n, 0) > 0 and p_set is not null
      then jsonb_build_array(jsonb_build_object('set', p_set, 'n', p_n))
    else '[]'::jsonb end $function$;

-- x_contents with pack lines (exchange history for Trading Post trades).
create or replace function cps.x_contents_lines(p_tokens integer, p_tickets integer, p_lines jsonb, p_items text[])
returns text language plpgsql stable set search_path to 'cps', 'pg_temp' as $function$
declare parts text[] := coalesce(p_items, '{}'); ln record;
begin
  for ln in select value as v from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) loop
    parts := parts || ('🎁 ' || (ln.v->>'n') || ' ' ||
      coalesce((select name from cps.card_sets where id = ln.v->>'set'), ln.v->>'set') ||
      ' pack' || case when (ln.v->>'n')::int = 1 then '' else 's' end);
  end loop;
  if coalesce(p_tokens, 0) > 0 then
    parts := parts || ('🪙 ' || p_tokens || ' token' || case when p_tokens = 1 then '' else 's' end);
  end if;
  if coalesce(p_tickets, 0) > 0 then
    parts := parts || ('🎟️ ' || p_tickets || ' ticket' || case when p_tickets = 1 then '' else 's' end);
  end if;
  if parts = '{}' then return 'nothing'; end if;
  return array_to_string(parts, ' + ');
end $function$;


CREATE OR REPLACE FUNCTION cps.trade_refund_offer(p_offer uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  o cps.listing_offers%rowtype;
  e record;
  ln record;
begin
  select * into o from cps.listing_offers where id = p_offer;
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

  for ln in select value as v from jsonb_array_elements(cps.offer_pack_lines(o.pack_lines, o.pack_set, o.packs)) loop
    perform cps.add_packs(o.offerer, ln.v->>'set', (ln.v->>'n')::int, 'trade_refund', o.id::text, null);
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.cps_trade_offer(p_token text, p_listing uuid, p_offer jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a        cps.accounts%rowtype;
  l        cps.trade_listings%rowtype;
  otokens  int;
  otickets int;
  opackset text;
  opacks   int;
  olines   jsonb;
  ototalpacks int := 0;
  ln       record;
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
  -- multi-set pack lines (221): pack_lines wins when present; the legacy
  -- pack_set/packs pair is honoured as a one-line offer otherwise.
  olines := cps.offer_pack_lines(p_offer->'pack_lines', opackset, opacks);
  if jsonb_array_length(olines) > 10 then
    raise exception 'At most 10 pack lines in an offer.'; end if;
  if exists (select 1 from jsonb_array_elements(olines) e
             where e->>'set' is null or coalesce(e->>'n', '') !~ '^[0-9]+$'
                or (e->>'n')::int < 1) then
    raise exception 'Bad pack line in your offer.'; end if;
  if (select count(distinct e->>'set') from jsonb_array_elements(olines) e)
       <> jsonb_array_length(olines) then
    raise exception 'Each set can only appear once — combine the amounts into one line.'; end if;
  select coalesce(sum((e->>'n')::int), 0) into ototalpacks from jsonb_array_elements(olines) e;
  if ototalpacks > 0 then
    opackset := olines->0->>'set';
    opacks   := (olines->0->>'n')::int;
  else
    opackset := null;
    opacks   := 0;
  end if;
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

  -- escrow packs (one or more set lines)
  for ln in select value as v from jsonb_array_elements(olines) loop
    if not exists (select 1 from cps.card_sets where id = ln.v->>'set') then
      raise exception 'Pick a set for the pack offer.'; end if;
    select packs into vinv from cps.pack_inventory where account_id = a.id and set_id = ln.v->>'set' for update;
    if coalesce(vinv, 0) < (ln.v->>'n')::int then raise exception 'You don''t have that many packs.'; end if;
    perform cps.add_packs(a.id, ln.v->>'set', -(ln.v->>'n')::int, 'trade_escrow', new_id::text, null);
  end loop;

  -- escrow cards (numbered serials allowed, picked explicitly)
  -- offer row first (escrow FKs reference it)
  insert into cps.listing_offers (id, listing_id, offerer, tokens, tickets, pack_set, packs, pack_lines,
                               cards, status)
    values (new_id, p_listing, a.id, otokens, otickets, opackset, opacks,
            case when ototalpacks > 0 then olines else null end,
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
      if exists (select 1 from cps.variants
                 where account_id = a.id and set_id = r.set_id and card_id = r.card_id
                   and tier = r.tier and serial = r.serial and vaulted) then
        raise exception 'That numbered copy is in your Vault — release it before offering it.';
      end if;
      if cps.trade_variant_escrowed(r.set_id, r.card_id, r.tier, r.serial) then
        raise exception 'That numbered copy is already listed or offered.'; end if;
    end if;
    select * into c from cps.collection
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id for update;
    if r.tier is null then
      -- non-variant copies only (variants are picked as explicit serials)
      select count(*) into vn from cps.variants
        where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
      if coalesce(c.count, 0) - c.vaulted_count - vn < r.qty then
        raise exception 'You don''t have enough non-numbered copies to offer.'; end if;
      if r.holo and coalesce(c.holo_count, 0) - c.vaulted_holo < r.qty then
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
  end loop;

  -- the offer must be *something*
  if otokens = 0 and otickets = 0 and ototalpacks = 0
     and not exists (select 1 from cps.trade_escrow where offer_id = new_id) then
    raise exception 'Your offer needs tokens, tickets, packs, or cards.'; end if;


  perform cps.notify(l.lister, 'trade_new_offer',
    a.display_name || ' made an offer on your Trading Post listing.', 'trading');

  return jsonb_build_object('ok', true, 'id', new_id);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_trade_accept(p_token text, p_listing uuid, p_offer uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a          cps.accounts%rowtype;
  l          cps.trade_listings%rowtype;
  o          cps.listing_offers%rowtype;
  e          record;
  r          record;
  cardname   text;
  setname    text;
  offer_desc text := '';
  bits       text[];
  psetname   text;
  ln         record;
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

  select * into o from cps.listing_offers where id = p_offer and listing_id = p_listing for update;
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
      perform cps.auto_turn_in(o.offerer, e.set_id, e.card_id);
    end if;
    insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
      values (l.lister, o.offerer, e.set_id, e.card_id, e.holo, e.qty, 'trade:' || l.id::text);
  end loop;

  -- --- the winner's escrowed offer goes to the lister ---
  bits := '{}';
  if o.tokens > 0 then bits := bits || ('🪙 ' || o.tokens || ' game tokens'); end if;
  if o.tickets > 0 then bits := bits || ('🎟️ ' || o.tickets || ' spin tickets'); end if;
  for ln in select value as v from jsonb_array_elements(cps.offer_pack_lines(o.pack_lines, o.pack_set, o.packs)) loop
    select name into psetname from cps.card_sets where id = ln.v->>'set';
    bits := bits || ('🎁 ' || (ln.v->>'n') || ' ' || coalesce(psetname, ln.v->>'set') || ' packs');
  end loop;
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
      perform cps.auto_turn_in(l.lister, e.set_id, e.card_id);
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
  for ln in select value as v from jsonb_array_elements(cps.offer_pack_lines(o.pack_lines, o.pack_set, o.packs)) loop
    perform cps.add_packs(l.lister, ln.v->>'set', (ln.v->>'n')::int, 'trade_accept', l.id::text, null);
  end loop;
  offer_desc := array_to_string(bits, ', ');

  update cps.listing_offers set status = 'accepted' where id = o.id;

  -- --- losing offers: declined + refunded + notified ---
  for r in select id, offerer from cps.listing_offers
           where listing_id = l.id and status = 'open' and id <> o.id loop
    update cps.listing_offers set status = 'declined' where id = r.id;
    perform cps.trade_refund_offer(r.id);
    perform cps.notify(r.offerer, 'trade_offer_declined',
      'Your offer wasn''t accepted — everything was refunded.', 'trading');
  end loop;

  delete from cps.trade_escrow where listing_id = l.id;
  update cps.trade_listings
    set status = 'accepted', accepted_offer = o.id, accepted_at = now()
    where id = l.id;

  -- daily quest: a Market sale just completed (lister sold, offerer bought)
  perform cps.quest_bump(l.lister, 'market_trade', 1);
  perform cps.quest_bump(o.offerer, 'market_trade', 1);

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
end $function$;

CREATE OR REPLACE FUNCTION public.cps_trading_post(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
  perform cps.quest_bump(a.id, 'visit_market', 1);

  for l in
    select t.*, ac.display_name as lister_name,
           k.name as card_name, s.name as set_name, k.rarity as rarity,
           (select count(*) from cps.listing_offers ofr
             where ofr.listing_id = t.id and ofr.status = 'open') as offer_count,
           (select ofr.id from cps.listing_offers ofr
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
      from cps.listing_offers ofr
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
        'pack_lines', (select coalesce(jsonb_agg(jsonb_build_object(
                          'set', e->>'set', 'n', (e->>'n')::int,
                          'name', (select name from cps.card_sets where id = e->>'set'))), '[]'::jsonb)
                       from jsonb_array_elements(cps.offer_pack_lines(o.pack_lines, o.pack_set, o.packs)) e),
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
end $function$;

CREATE OR REPLACE FUNCTION public.cps_exchange_history(p_token text, p_other uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a     cps.accounts%rowtype;
  other cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into other from cps.accounts where id = p_other and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  return coalesce((
    select jsonb_agg(e order by at desc)
    from (
      select * from (
        -- direct trades between us
        select jsonb_build_object(
            'kind', 'trade',
            'at', o.created_at,
            'direction', case when o.from_account = a.id then 'sent' else 'received' end,
            'status', o.status,
            'title', case when o.from_account = a.id then 'Trade you proposed' else 'Trade they proposed' end,
            'detail', 'Give: ' || cps.x_trade_side(o.id, case when o.from_account = a.id then 'offer' else 'want' end)
                   || ' · Get: ' || cps.x_trade_side(o.id, case when o.from_account = a.id then 'want' else 'offer' end)
          ) as e, o.created_at as at
        from cps.trade_offers o
        where (o.from_account = a.id and o.to_account = other.id)
           or (o.from_account = other.id and o.to_account = a.id)

        union all

        -- gifts between us (the recipient's notification carries the sender)
        select jsonb_build_object(
            'kind', 'gift',
            'at', n.created_at,
            'direction', case when n.account_id = other.id then 'sent' else 'received' end,
            'status', null,
            'title', case when n.account_id = other.id then 'Gift you sent' else 'Gift they sent you' end,
            'detail', coalesce(n.meta->>'gift_label', n.meta->>'card_name', 'a gift'),
            'thanked', coalesce((n.meta->>'thanked')::boolean, false)
          ), n.created_at
        from cps.notifications n
        where n.kind in ('gift', 'gift_card')
          and ((n.account_id = other.id and n.meta->>'from' = a.id::text)
            or (n.account_id = a.id and n.meta->>'from' = other.id::text))

        union all

        -- card gifts from the transfer ledger: covers gifts whose
        -- notification no longer exists (e.g. the recipient cleared
        -- their notifications). One entry per send (a send's rows
        -- share one transaction timestamp); skipped when a matching
        -- gift notification still exists, so nothing shows twice.
        select jsonb_build_object(
            'kind', 'gift',
            'at', g.at,
            'direction', case when g.from_account = a.id then 'sent' else 'received' end,
            'status', null,
            'title', case when g.from_account = a.id then 'Gift you sent' else 'Gift they sent you' end,
            'detail', g.detail,
            'thanked', g.thanked
          ), g.at
        from (
          select t.from_account, t.to_account, t.at,
                 string_agg(cps.x_card_label(t.set_id, t.card_id, t.holo, null, null)
                            || case when t.qty > 1 then ' ×' || t.qty else '' end, ' + ' order by t.id) as detail,
                 bool_or(exists (
                   select 1 from cps.notifications n2
                   where n2.account_id = t.to_account
                     and n2.kind in ('gift', 'gift_card')
                     and n2.meta->>'from' = t.from_account::text
                     and coalesce((n2.meta->>'thanked')::boolean, false)
                     and n2.created_at between t.at - interval '5 minutes' and t.at + interval '5 minutes'
                 )) as thanked
          from cps.card_transfers t
          where t.trade_ref = 'gift'
            and ((t.from_account = a.id and t.to_account = other.id)
              or (t.from_account = other.id and t.to_account = a.id))
            and not exists (
              select 1 from cps.notifications n3
              where n3.account_id = t.to_account
                and n3.kind in ('gift', 'gift_card')
                and n3.meta->>'from' = t.from_account::text
                and n3.created_at between t.at - interval '5 minutes' and t.at + interval '5 minutes'
            )
          group by t.from_account, t.to_account, t.at
        ) g

        union all

        -- pack gifts from the pack_grants ledger: a player gift's pack
        -- movement is a matched -N / +N pair of 'gift' rows sharing one
        -- transaction timestamp and set. Same notification rules as the
        -- card branch above: skipped when a matching gift notification
        -- still exists (it already covers the whole gift), 'thanked'
        -- recovered best-effort from one.
        select jsonb_build_object(
            'kind', 'gift',
            'at', p.at,
            'direction', case when p.sender = a.id then 'sent' else 'received' end,
            'status', null,
            'title', case when p.sender = a.id then 'Gift you sent' else 'Gift they sent you' end,
            'detail', cps.x_contents(0, 0, p.set_id, p.packs, '{}'),
            'thanked', p.thanked
          ), p.at
        from (
          select g1.account_id as sender, g2.account_id as recipient,
                 g1.set_id, g2.packs, g1.at,
                 exists (
                   select 1 from cps.notifications n2
                   where n2.account_id = g2.account_id
                     and n2.kind in ('gift', 'gift_card')
                     and n2.meta->>'from' = g1.account_id::text
                     and coalesce((n2.meta->>'thanked')::boolean, false)
                     and n2.created_at between g1.at - interval '5 minutes' and g1.at + interval '5 minutes'
                 ) as thanked
          from cps.pack_grants g1
          join cps.pack_grants g2
            on g2.reason = 'gift' and g2.at = g1.at and g2.set_id = g1.set_id
           and g2.packs = -g1.packs and g2.account_id <> g1.account_id
          where g1.reason = 'gift' and g1.packs < 0
            and ((g1.account_id = a.id and g2.account_id = other.id)
              or (g1.account_id = other.id and g2.account_id = a.id))
            and not exists (
              select 1 from cps.notifications n3
              where n3.account_id = g2.account_id
                and n3.kind in ('gift', 'gift_card')
                and n3.meta->>'from' = g1.account_id::text
                and n3.created_at between g1.at - interval '5 minutes' and g1.at + interval '5 minutes'
            )
        ) p

        union all

        -- token/ticket gifts from the grants ledgers (204 makes
        -- cps_gift log a matched -N / +N 'gift' pair per currency):
        -- tokens and tickets from one send share a transaction
        -- timestamp, so they merge into a single entry per send.
        -- Same notification rules as the other gift branches.
        select jsonb_build_object(
            'kind', 'gift',
            'at', p.at,
            'direction', case when p.sender = a.id then 'sent' else 'received' end,
            'status', null,
            'title', case when p.sender = a.id then 'Gift you sent' else 'Gift they sent you' end,
            'detail', cps.x_contents(p.tokens::int, p.tickets::int, null, 0, '{}'),
            'thanked', p.thanked
          ), p.at
        from (
          select u.sender, u.recipient, u.at,
                 sum(u.tokens) as tokens, sum(u.tickets) as tickets,
                 bool_or(u.thanked) as thanked
          from (
            select g1.account_id as sender, g2.account_id as recipient, g1.created_at as at,
                   g2.tokens as tokens, 0 as tickets,
                   exists (
                     select 1 from cps.notifications n2
                     where n2.account_id = g2.account_id
                       and n2.kind in ('gift', 'gift_card')
                       and n2.meta->>'from' = g1.account_id::text
                       and coalesce((n2.meta->>'thanked')::boolean, false)
                       and n2.created_at between g1.created_at - interval '5 minutes' and g1.created_at + interval '5 minutes'
                   ) as thanked
            from cps.token_grants g1
            join cps.token_grants g2
              on g2.reason = 'gift' and g2.created_at = g1.created_at
             and g2.tokens = -g1.tokens and g2.account_id <> g1.account_id
            where g1.reason = 'gift' and g1.tokens < 0
              and ((g1.account_id = a.id and g2.account_id = other.id)
                or (g1.account_id = other.id and g2.account_id = a.id))
              and not exists (
                select 1 from cps.notifications n3
                where n3.account_id = g2.account_id
                  and n3.kind in ('gift', 'gift_card')
                  and n3.meta->>'from' = g1.account_id::text
                  and n3.created_at between g1.created_at - interval '5 minutes' and g1.created_at + interval '5 minutes'
              )
            union all
            select g1.account_id, g2.account_id, g1.created_at,
                   0, g2.spins,
                   exists (
                     select 1 from cps.notifications n2
                     where n2.account_id = g2.account_id
                       and n2.kind in ('gift', 'gift_card')
                       and n2.meta->>'from' = g1.account_id::text
                       and coalesce((n2.meta->>'thanked')::boolean, false)
                       and n2.created_at between g1.created_at - interval '5 minutes' and g1.created_at + interval '5 minutes'
                   )
            from cps.spin_grants g1
            join cps.spin_grants g2
              on g2.reason = 'gift' and g2.created_at = g1.created_at
             and g2.spins = -g1.spins and g2.account_id <> g1.account_id
            where g1.reason = 'gift' and g1.spins < 0
              and ((g1.account_id = a.id and g2.account_id = other.id)
                or (g1.account_id = other.id and g2.account_id = a.id))
              and not exists (
                select 1 from cps.notifications n3
                where n3.account_id = g2.account_id
                  and n3.kind in ('gift', 'gift_card')
                  and n3.meta->>'from' = g1.account_id::text
                  and n3.created_at between g1.created_at - interval '5 minutes' and g1.created_at + interval '5 minutes'
              )
          ) u
          group by u.sender, u.recipient, u.at
        ) p

        union all

        -- bounties one of us posted and the other claimed
        select jsonb_build_object(
            'kind', 'bounty',
            'at', b.claimed_at,
            'direction', case when b.poster = a.id then 'sent' else 'received' end,
            'status', 'claimed',
            'title', case when b.poster = a.id then 'Your bounty — claimed by them' else 'Their bounty — claimed by you' end,
            'detail', case when b.poster = a.id
              then 'Give: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id))
                || ' · Get: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
              else 'Give: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
                || ' · Get: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id))
              end
          ), b.claimed_at
        from cps.bounties b
        where b.status = 'claimed'
          and ((b.poster = a.id and b.claimed_by = other.id)
            or (b.poster = other.id and b.claimed_by = a.id))

        union all

        -- trading post: an accepted listing between us
        select jsonb_build_object(
            'kind', 'market',
            'at', l.accepted_at,
            'direction', case when l.lister = a.id then 'received' else 'sent' end,
            'status', 'accepted',
            'title', case when l.lister = a.id then 'Trading Post — your listing sold' else 'Trading Post — you won their listing' end,
            'detail', 'Card: ' || cps.x_card_label(l.set_id, l.card_id, l.holo, l.variant_tier, l.variant_serial)
                   || ' · For: ' || cps.x_contents_lines(lo.tokens, lo.tickets, cps.offer_pack_lines(lo.pack_lines, lo.pack_set, lo.packs), cps.x_json_items(lo.cards))
          ), l.accepted_at
        from cps.trade_listings l
        join cps.listing_offers lo on lo.id = l.accepted_offer
        where l.status = 'accepted'
          and ((l.lister = a.id and lo.offerer = other.id)
            or (l.lister = other.id and lo.offerer = a.id))
      ) all_entries
      order by at desc
      limit 80
    ) lim
  ), '[]'::jsonb);
end $function$;
