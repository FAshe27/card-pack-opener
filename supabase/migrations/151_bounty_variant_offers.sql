-- =====================================================================
-- 151_bounty_variant_offers.sql -- Numbered copies in bounty offers.
-- Run AFTER 150. Franklin's ask (2026-10-15): the Bounty Board's
-- "You Offer" side rejects numbered (variant) copies -- a designed
-- exclusion from 056 ('serial tracking through escrow is out of
-- scope'). This migration closes it, mirroring the Trading Post's
-- proven patterns (108's cps_trade_offer validations and the shared
-- cps.trade_variant_escrowed pin check).
--
-- Design (count-model native, like 056's escrow):
--   * cps.bounty_escrow gains tier/serial ('' / 0 = fungible row), and
--     its PK widens to include them. A variant offer entry pins ONE
--     specific copy: its base slot leaves the poster's collection at
--     post time (same decrement as a fungible copy); the cps.variants
--     row itself stays with the poster until a claim moves it.
--   * Because refund (cancel / lazy expiry) is generic over escrow
--     rows, it needs NO changes: the base slot returns and the variant
--     row never moved.
--   * cps_post_bounty (base: 141) -- ONLY the card-escrow section
--     changes: pass V validates + pins numbered copies (holdings,
--     Vault, serial range, not already committed anywhere --
--     cps.trade_variant_escrowed now also sees open bounty pins);
--     pass F is 141's fungible loop with its variant count reduced by
--     the copies pass V pinned (no double subtraction).
--   * cps_claim_bounty (base: 141) -- two hunks: pinned variants are
--     transferred to the claimer before the generic escrow release
--     (a pinned copy that has left the poster's hands aborts the
--     claim atomically), and the win-notification's offer description
--     names numbered copies ('💠 Card #serial/run').
--   * cps_list_bounties (base: 141) -- offer_cards items gain tier +
--     serial (null for fungible) so the board can badge them.
--   * cps_variant_owners (base: 143) -- each copy gains an 'escrowed'
--     flag (pinned by an open bounty OR the Trading Post) so the card
--     pane can tag it 'in escrow' beside the owner's name; ownership
--     itself still shows the poster until a claim.
-- =====================================================================

-- --- 0. escrow ledger learns to pin a specific numbered copy ---------
alter table cps.bounty_escrow add column if not exists tier text not null default '';
alter table cps.bounty_escrow add column if not exists serial int not null default 0;
do $$
begin
  if exists (select 1 from pg_constraint
              where conrelid = 'cps.bounty_escrow'::regclass and contype = 'p') then
    execute 'alter table cps.bounty_escrow drop constraint ' ||
      (select conname from pg_constraint
        where conrelid = 'cps.bounty_escrow'::regclass and contype = 'p');
  end if;
  alter table cps.bounty_escrow
    add primary key (bounty_id, set_id, card_id, holo, tier, serial);
end $$;

-- --- 1. the shared pin check also sees open bounty pins -------
create or replace function cps.trade_variant_escrowed(p_set text, p_card text, p_tier text, p_serial int)
returns boolean language sql set search_path = cps, pg_temp as $$
  select exists (
    select 1 from cps.trade_escrow e
    where e.set_id = p_set and e.card_id = p_card
      and e.variant_tier = p_tier and e.variant_serial = p_serial
  ) or exists (
    -- 151: a copy pinned by an open Bounty Board escrow is just as
    -- committed as one on the Trading Post.
    select 1 from cps.bounty_escrow be
    join cps.bounties bo on bo.id = be.bounty_id
    where bo.status = 'open'
      and be.set_id = p_set and be.card_id = p_card
      and be.tier = p_tier and be.serial = p_serial
  );
$$;

-- --- 2. cps_post_bounty (base: 141) -----------------------------
create or replace function public.cps_post_bounty(p_token text, p_want jsonb, p_offer jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  wset     text;
  wcard    text;
  wholo    text;
  wtier    text;
  wserial  int;
  otokens  int;
  otickets int;
  opackset text;
  opacks   int;
  new_id   uuid := gen_random_uuid();
  vrar     text;
  vtok     int;
  vtix     int;
  vinv     int;
  vopen    int;
  r        record;
  c        cps.collection%rowtype;
  vn       int;
begin
  a := cps.auth(p_token);

  -- --- wanted card ---
  wset := p_want->>'set';
  wcard := p_want->>'card';
  wholo := coalesce(p_want->>'holo', 'any');
  wtier := nullif(p_want->>'tier', '');
  wserial := nullif(p_want->>'serial', '')::int;
  if wset is null or wcard is null then raise exception 'Pick a card to request.'; end if;
  select k.rarity into vrar from cps.cards k where k.set_id = wset and k.card_id = wcard;
  if not found then raise exception 'That card is not on the server.'; end if;
  if wholo not in ('any', 'holo') then raise exception 'Bad holo requirement.'; end if;
  if wtier is not null then
    if wtier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
    if vrar not in ('rare', 'epic', 'legendary', 'chase') then
      raise exception 'Numbered variants only exist for rare cards and up.'; end if;
    if wserial is not null and (wserial < 1 or wserial > cps.variant_run(wtier)) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(wtier), cps.variant_name(wtier); end if;
    if wserial is not null and not exists (select 1 from cps.variants
                   where set_id = wset and card_id = wcard and tier = wtier and serial = wserial) then
      raise exception 'That numbered copy hasn''t been pulled yet — nobody could claim this bounty.'; end if;
    -- serial absent (141) = any number of this tier: tier + rarity validated
    -- above, and there is deliberately no existence requirement.
    wholo := 'any';  -- a serial IS a specific copy; holo requirement is redundant
  elsif wserial is not null then
    raise exception 'A serial needs a variant tier.'; end if;

  -- --- bounty cap ---
  select count(*) into vopen from cps.bounties where poster = a.id and status = 'open';
  if vopen >= 5 then raise exception 'You already have 5 open bounties — claim or cancel one first.'; end if;

  -- --- offer ---
  otokens  := greatest(coalesce((p_offer->>'tokens')::int, 0), 0);
  otickets := greatest(coalesce((p_offer->>'tickets')::int, 0), 0);
  opackset := nullif(p_offer->>'pack_set', '');
  opacks   := greatest(coalesce((p_offer->>'packs')::int, 0), 0);
  if jsonb_typeof(coalesce(p_offer->'cards', '[]'::jsonb)) <> 'array' then
    raise exception 'Bad card offer.'; end if;

  -- parent row FIRST: cps.bounty_escrow has a FK to cps.bounties, so the bounty
  -- must exist before any escrow rows are inserted (was inserted at the end;
  -- card offers blew up on bounty_escrow_bounty_id_fkey)
  insert into cps.bounties (id, poster, want_set, want_card, want_holo, want_tier, want_serial,
                            offer_tokens, offer_tickets, offer_pack_set, offer_packs)
    values (new_id, a.id, wset, wcard, wholo, wtier, wserial,
            otokens, otickets, opackset, opacks);

  -- escrow currencies (row lock first, then validate)
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
    perform cps.add_packs(a.id, opackset, -opacks, 'bounty_escrow', new_id::text, null);
  end if;

  -- escrow cards (151): two passes over the grouped offer entries.
  -- Pass V pins specific numbered copies (entries carrying tier+serial);
  -- pass F is 141's fungible validation, with its variant count reduced
  -- by the copies pass V just pinned (their base slots already left
  -- c.count via pass V, so subtracting them again would double-count).
  -- Pass V: numbered copies -------------------------------------------
  for r in
    select t.set_id, t.card_id, t.holo, t.tier, t.serial, count(*)::int as qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo,
                 nullif(j->>'tier', '') as tier,
                 nullif(j->>'serial', '')::int as serial
          from jsonb_array_elements(coalesce(p_offer->'cards', '[]'::jsonb)) j) t
    where t.tier is not null or t.serial is not null
    group by t.set_id, t.card_id, t.holo, t.tier, t.serial
    order by t.set_id, t.card_id, t.tier, t.serial
  loop
    if r.set_id is null or r.card_id is null then raise exception 'Bad card in your offer.'; end if;
    if r.tier is null or r.serial is null then raise exception 'A serial needs a variant tier.'; end if;
    if r.holo then raise exception 'A numbered copy can''t be offered as a holo copy.'; end if;
    if r.qty <> 1 then raise exception 'A numbered copy can only be offered once.'; end if;
    select k.rarity into vrar from cps.cards k where k.set_id = r.set_id and k.card_id = r.card_id;
    if not found then raise exception 'Unknown card in your offer.'; end if;
    if r.tier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
    if vrar not in ('rare', 'epic', 'legendary', 'chase') then
      raise exception 'Numbered variants only exist for rare cards and up.'; end if;
    if r.serial < 1 or r.serial > cps.variant_run(r.tier) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(r.tier), cps.variant_name(r.tier); end if;
    if not exists (select 1 from cps.variants
                   where account_id = a.id and set_id = r.set_id and card_id = r.card_id
                     and tier = r.tier and serial = r.serial) then
      raise exception 'You don''t hold that numbered copy.'; end if;
    if exists (select 1 from cps.variants
               where account_id = a.id and set_id = r.set_id and card_id = r.card_id
                 and tier = r.tier and serial = r.serial and vaulted) then
      raise exception 'That numbered copy is in your Vault — release it before offering it.'; end if;
    if cps.trade_variant_escrowed(r.set_id, r.card_id, r.tier, r.serial) then
      raise exception 'That numbered copy is already listed, offered, or in a bounty.'; end if;
    -- the copy's base slot leaves the collection into escrow; the
    -- variant row itself stays with the poster until a claim moves it
    select * into c from cps.collection
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id for update;
    if not found or coalesce(c.count, 0) < 1 then raise exception 'You don''t hold that card.'; end if;
    update cps.collection
      set count = count - 1,
          holo_count = least(holo_count, count - 1)
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
    insert into cps.bounty_escrow (bounty_id, set_id, card_id, holo, qty, tier, serial)
      values (new_id, r.set_id, r.card_id, false, 1, r.tier, r.serial);
  end loop;

  -- Pass F: fungible copies (141's loop; entries without tier/serial) --
  for r in
    select t.set_id, t.card_id,
           sum(case when t.holo then 1 else 0 end)::int as holo_qty,
           sum(case when t.holo then 0 else 1 end)::int as plain_qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo
          from jsonb_array_elements(coalesce(p_offer->'cards', '[]'::jsonb)) j
          where nullif(j->>'tier', '') is null and nullif(j->>'serial', '') is null) t
    group by t.set_id, t.card_id
    order by t.set_id, t.card_id
  loop
    if r.set_id is null or r.card_id is null then raise exception 'Bad card in your offer.'; end if;
    if not exists (select 1 from cps.cards where set_id = r.set_id and card_id = r.card_id) then
      raise exception 'Unknown card in your offer.'; end if;
    select * into c from cps.collection
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id for update;
    select count(*) into vn from cps.variants
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
    -- 151: copies of this card pinned in pass V are already out of
    -- c.count; don't subtract them from the fungible pool twice.
    select vn - count(*) into vn from cps.bounty_escrow
      where bounty_id = new_id and set_id = r.set_id and card_id = r.card_id and tier <> '';
    -- offered copies must be non-numbered-variant copies
    if coalesce(c.count, 0) - c.vaulted_count - vn < r.holo_qty + r.plain_qty then
      raise exception 'You don''t have enough non-numbered copies to offer.'; end if;
    if r.holo_qty > 0 and coalesce(c.holo_count, 0) - c.vaulted_holo < r.holo_qty then
      raise exception 'You don''t have enough holo copies to offer.'; end if;
    update cps.collection
      set count = count - (r.holo_qty + r.plain_qty),
          holo_count = least(holo_count - r.holo_qty, count - (r.holo_qty + r.plain_qty))
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
    if r.holo_qty > 0 then
      insert into cps.bounty_escrow (bounty_id, set_id, card_id, holo, qty)
        values (new_id, r.set_id, r.card_id, true, r.holo_qty);
    end if;
    if r.plain_qty > 0 then
      insert into cps.bounty_escrow (bounty_id, set_id, card_id, holo, qty)
        values (new_id, r.set_id, r.card_id, false, r.plain_qty);
    end if;
  end loop;

  -- the offer must be *something*
  if otokens = 0 and otickets = 0 and opacks = 0
     and not exists (select 1 from cps.bounty_escrow where bounty_id = new_id) then
    raise exception 'Your bounty needs an offer — tokens, tickets, packs, or cards.'; end if;

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- 3. cps_claim_bounty (base: 141) ----------------------------
create or replace function public.cps_claim_bounty(p_token text, p_bounty_id uuid, p_serial int default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  b          cps.bounties%rowtype;
  vrow       cps.variants%rowtype;
  c          cps.collection%rowtype;
  e          record;
  poster_name text;
  cardname   text;
  setname    text;
  psetname   text;
  offer_desc text := '';
  bits       text[];
  vcnt       int;
begin
  a := cps.auth(p_token);
  select * into b from cps.bounties where id = p_bounty_id for update;
  if not found then raise exception 'Bounty not found.'; end if;

  -- lazy expiry: a stale open bounty refunds instead of paying out
  if b.status = 'open' and b.expires_at < now() then
    update cps.bounties set status = 'expired' where id = b.id;
    perform cps.bounty_refund(b.id);
    select k.name into cardname from cps.cards k where k.set_id = b.want_set and k.card_id = b.want_card;
    perform cps.notify(b.poster, 'bounty_expired',
      'Your bounty for ' || coalesce(cardname, 'a card') || ' expired — your offer was refunded.', 'bounties');
    raise exception 'This bounty has expired — the offer was refunded.';
  end if;
  if b.status <> 'open' then raise exception 'This bounty is no longer open.'; end if;
  if b.poster = a.id then raise exception 'You cannot claim your own bounty.'; end if;

  -- --- the claimer must currently hold the wanted card ---
  if b.want_tier is not null then
    -- numbered want (141): one specific serial, or any number of the tier
    if b.want_serial is not null then
      -- serial-specific: the exact numbered copy
      select * into vrow from cps.variants
        where account_id = a.id and set_id = b.want_set and card_id = b.want_card
          and tier = b.want_tier and serial = b.want_serial for update;
    elsif p_serial is not null then
      -- any number: the claimer picked which of their copies to hand over
      select * into vrow from cps.variants
        where account_id = a.id and set_id = b.want_set and card_id = b.want_card
          and tier = b.want_tier and serial = p_serial for update;
    else
      -- any number, no pick: resolve only when exactly one unvaulted copy is held
      select count(*) into vcnt from cps.variants
        where account_id = a.id and set_id = b.want_set and card_id = b.want_card
          and tier = b.want_tier and not coalesce(vaulted, false);
      if vcnt > 1 then raise exception 'Pick which numbered copy to hand over.'; end if;
      if vcnt = 0 then
        if exists (select 1 from cps.variants
                     where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                       and tier = b.want_tier) then
          raise exception 'That numbered copy is in your Vault — release it first to claim this bounty.';
        end if;
        raise exception 'You no longer hold that numbered copy.';
      end if;
      select * into vrow from cps.variants
        where account_id = a.id and set_id = b.want_set and card_id = b.want_card
          and tier = b.want_tier and not coalesce(vaulted, false) for update;
    end if;
    if not found then raise exception 'You no longer hold that numbered copy.'; end if;
    if coalesce(vrow.vaulted, false) then
      raise exception 'That numbered copy is in your Vault — release it first to claim this bounty.';
    end if;
    select * into c from cps.collection
      where account_id = a.id and set_id = b.want_set and card_id = b.want_card for update;
    if not found or c.count < 1 then raise exception 'You no longer hold that card.'; end if;
    -- move the base copy; the variant's own holo flag isn't tracked, so clamp
    -- holo_count instead of guessing (mirrors the gift flow's manual variant move)
    update cps.collection
      set count = count - 1,
          holo_count = least(holo_count, count - 1)
      where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (b.poster, b.want_set, b.want_card, 1, 0)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + 1;
    insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
      values (a.id, b.poster, b.want_set, b.want_card, false, 1, 'bounty:' || b.id::text);
    update cps.variants set account_id = b.poster where id = vrow.id;
    perform cps.auto_turn_in(b.poster, b.want_set, b.want_card);
  else
    select * into c from cps.collection
      where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
    if not found or c.count - c.vaulted_count < 1 then raise exception 'You no longer hold that card (on hand).'; end if;
    if b.want_holo = 'holo' then
      if c.holo_count - c.vaulted_holo < 1 then raise exception 'This bounty needs a holo copy (on hand).'; end if;
      perform cps.transfer_card(a.id, b.poster, b.want_set, b.want_card, true, 1, 'bounty:' || b.id::text, true);
    else
      -- 'any' copy: prefer a non-holo, fall back to holo (transfer_card re-validates)
      perform cps.transfer_card(a.id, b.poster, b.want_set, b.want_card,
                                (c.count - c.holo_count) < 1, 1, 'bounty:' || b.id::text, true);
    end if;
  end if;

  -- --- describe the offer for the notifications (before releasing escrow) ---
  bits := '{}';
  if b.offer_tokens > 0 then bits := bits || ('🪙 ' || b.offer_tokens || ' game tokens'); end if;
  if b.offer_tickets > 0 then bits := bits || ('🎟️ ' || b.offer_tickets || ' spin tickets'); end if;
  if b.offer_packs > 0 then
    select name into psetname from cps.card_sets where id = b.offer_pack_set;
    bits := bits || ('🎁 ' || b.offer_packs || ' ' || coalesce(psetname, b.offer_pack_set) || ' packs');
  end if;
  for e in
    select e2.qty, e2.holo, e2.tier, e2.serial, kk.name as card_name
    from cps.bounty_escrow e2
    join cps.cards kk on kk.set_id = e2.set_id and kk.card_id = e2.card_id
    where e2.bounty_id = b.id
    order by kk.name
  loop
    bits := bits || (case
      when e.tier <> '' then
        (case e.tier when 'rainbow' then '🌈' when 'prism' then '💠' when 'obsidian' then '🌑' else '👑' end)
        || ' ' || e.card_name || ' #' || e.serial || '/' || cps.variant_run(e.tier)
      else e.qty || '× ' || e.card_name || case when e.holo then ' ✦ holo' else '' end
    end);
  end loop;
  offer_desc := array_to_string(bits, ', ');

  -- --- numbered copies pinned in escrow move to the claimer (151) ---
  -- Checked before the generic release: if a pinned copy has left the
  -- poster's hands since posting, raising here aborts the whole claim
  -- (transaction rollback) -- the claimer's wanted card never moves.
  for e in select * from cps.bounty_escrow where bounty_id = b.id and tier <> '' loop
    update cps.variants
      set account_id = a.id
      where account_id = b.poster and set_id = e.set_id and card_id = e.card_id
        and tier = e.tier and serial = e.serial;
    if not found then
      raise exception 'The offered numbered copy is no longer available — this bounty can''t be claimed as posted.';
    end if;
  end loop;

  -- --- release escrow to the claimer ---
  for e in select * from cps.bounty_escrow where bounty_id = b.id loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (a.id, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
  end loop;
  delete from cps.bounty_escrow where bounty_id = b.id;

  if b.offer_tokens > 0 or b.offer_tickets > 0 then
    update cps.accounts
      set game_tokens = game_tokens + b.offer_tokens,
          spins = spins + b.offer_tickets
      where id = a.id;
    if b.offer_tickets > 0 then
      insert into cps.spin_grants (account_id, spins, reason)
        values (a.id, b.offer_tickets, 'bounty_claim');
    end if;
    if b.offer_tokens > 0 then
      insert into cps.token_grants (account_id, tokens, reason)
        values (a.id, b.offer_tokens, 'bounty_claim');
    end if;
  end if;
  if b.offer_packs > 0 and b.offer_pack_set is not null then
    perform cps.add_packs(a.id, b.offer_pack_set, b.offer_packs, 'bounty_claim', b.id::text, null);
  end if;

  update cps.bounties set status = 'claimed', claimed_by = a.id, claimed_at = now() where id = b.id;

  -- daily quest: a Market sale just completed (claimer sold, poster bought)
  perform cps.quest_bump(a.id, 'market_trade', 1);
  perform cps.quest_bump(b.poster, 'market_trade', 1);

  -- --- notifications ---
  select ac.display_name into poster_name from cps.accounts ac where ac.id = b.poster;
  select k.name, s.name into cardname, setname
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = b.want_set and k.card_id = b.want_card;
  perform cps.notify(b.poster, 'bounty_claimed',
    a.display_name || ' claimed your bounty — ' ||
    coalesce(cardname, 'the card') || ' (' || coalesce(setname, b.want_set) || ') is now in your collection.',
    'bounties');
  perform cps.notify(a.id, 'bounty_won',
    'You claimed ' || coalesce(poster_name, 'a') || '''s bounty: ' ||
    coalesce(cardname, 'the card') || ' for ' || offer_desc || '.',
    'bounties');

  return jsonb_build_object('ok', true, 'bounty_id', b.id,
    'spins', (select spins from cps.accounts where id = a.id),
    'game_tokens', (select game_tokens from cps.accounts where id = a.id));
end $$;

-- --- 4. cps_list_bounties (base: 141) ---------------------------
create or replace function public.cps_list_bounties(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  b       record;
  c       cps.collection%rowtype;
  can     boolean;
  items   jsonb;
  arr     jsonb := '[]';
  my_open int;
begin
  a := cps.auth(p_token);
  perform cps.bounty_expire_due();
  perform cps.quest_bump(a.id, 'visit_market', 1);

  select count(*) into my_open from cps.bounties where poster = a.id and status = 'open';

  for b in
    select bo.*, ac.display_name as poster_name,
           k.name as card_name, k.rarity as card_rarity,
           s.name as set_name, s.code as set_code
    from cps.bounties bo
    join cps.accounts ac on ac.id = bo.poster
    left join cps.cards k on k.set_id = bo.want_set and k.card_id = bo.want_card
    left join cps.card_sets s on s.id = bo.want_set
    where bo.status = 'open'
    order by bo.created_at desc
  loop
    -- can the viewer fill it? (server-side; the client also disables the button)
    -- Mirrors cps_claim_bounty's own checks (108) exactly: totals minus
    -- VAULTED copies, and a serial want also needs the copy unvaulted
    -- plus a base copy on hand. (Was: raw totals — a vaulted-only copy
    -- showed claimable, then the claim itself rejected it.)
    can := false;
    if b.poster <> a.id then
      if b.want_serial is not null then
        can := exists (select 1 from cps.variants
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and tier = b.want_tier and serial = b.want_serial
                         and not coalesce(vaulted, false))
               and exists (select 1 from cps.collection
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and count >= 1);
      elsif b.want_tier is not null then
        -- any number of the tier (141): an unvaulted instance of the tier,
        -- plus the same base-copy-on-hand check the serial case uses
        can := exists (select 1 from cps.variants
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and tier = b.want_tier
                         and not coalesce(vaulted, false))
               and exists (select 1 from cps.collection
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and count >= 1);
      else
        select * into c from cps.collection
          where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
        if found then
          can := case when b.want_holo = 'holo' then c.holo_count - c.vaulted_holo >= 1
                      else c.count - c.vaulted_count >= 1 end;
        end if;
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'set_id', e.set_id, 'card_id', e.card_id, 'holo', e.holo, 'qty', e.qty,
             'tier', nullif(e.tier, ''), 'serial', nullif(e.serial, 0),
             'card_name', kk.name, 'rarity', kk.rarity, 'set_name', ss.name)
           order by ss.name, kk.name), '[]') into items
      from cps.bounty_escrow e
      left join cps.cards kk on kk.set_id = e.set_id and kk.card_id = e.card_id
      left join cps.card_sets ss on ss.id = e.set_id
      where e.bounty_id = b.id;

    arr := arr || jsonb_build_object(
      'id', b.id, 'poster', b.poster_name, 'poster_id', b.poster, 'mine', b.poster = a.id,
      'want_set', b.want_set, 'want_card', b.want_card, 'want_holo', b.want_holo,
      'want_tier', b.want_tier, 'want_serial', b.want_serial,
      'card_name', b.card_name, 'rarity', b.card_rarity,
      'set_name', b.set_name, 'set_code', b.set_code,
      'offer_tokens', b.offer_tokens, 'offer_tickets', b.offer_tickets,
      'offer_pack_set', b.offer_pack_set, 'offer_packs', b.offer_packs,
      'offer_cards', items,
      'can_claim', can,
      'created_at', b.created_at, 'expires_at', b.expires_at);
  end loop;

  return jsonb_build_object('bounties', arr, 'my_open', my_open);
end $$;

-- --- 5. cps_variant_owners (base: 143) --------------------------
create or replace function public.cps_variant_owners(p_token text, p_set text, p_card text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  if p_tier not in ('rainbow', 'prism', 'obsidian', 'oneofone', 'misprint') then
    raise exception 'Unknown variant tier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'serial', t.serial, 'tier', t.tier, 'owner', t.owner,
      'mine', t.account_id = a.id, 'vaulted', t.vaulted, 'misprint', t.misprint,
      'escrowed', t.escrowed)
      order by t.tier_rank, t.serial)
    from (
      select v.serial, v.tier, v.account_id, acc.display_name as owner,
             v.vaulted,
             (exists (select 1 from cps.bounty_escrow be
                        join cps.bounties bo on bo.id = be.bounty_id
                       where bo.status = 'open' and be.set_id = v.set_id and be.card_id = v.card_id
                         and be.tier = v.tier and be.serial = v.serial)
              or exists (select 1 from cps.trade_escrow te
                          where te.set_id = v.set_id and te.card_id = v.card_id
                            and te.variant_tier = v.tier and te.variant_serial = v.serial)) as escrowed,
             (k.rarity in ('common', 'uncommon')) as misprint,
             case v.tier when 'oneofone' then 0 when 'obsidian' then 1
                         when 'prism' then 2 else 3 end as tier_rank
        from cps.variants v
        join cps.accounts acc on acc.id = v.account_id
        join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
       where v.set_id = p_set and v.card_id = p_card
         and ((p_tier <> 'misprint' and v.tier = p_tier)
              or (p_tier = 'misprint' and k.rarity in ('common', 'uncommon')))
    ) t
  ), '[]');
end $$;

notify pgrst, 'reload schema';
