-- =====================================================================
-- 056_bounty_board.sql — Bounty Board: public standing offers.
--
-- A player posts a bounty naming ONE wanted card (optional holo requirement
-- or numbered-variant serial) and an offer: game tokens, spin tickets,
-- packs (one set + count), and/or up to 5 cards. The offer is held in escrow
-- at post time. The first claimer who currently holds the wanted card wins
-- it atomically. Bounties expire after 7 days with a full refund; the poster
-- can cancel anytime for a full refund. Max 5 open bounties per player.
-- Admins may post and claim (same as trading; unlike Card of the Day).
--
-- Design notes:
-- * Cards are count-based (cps.collection has no per-instance rows), so
--   "escrow" = decrement the poster's collection counts into
--   cps.bounty_escrow at post time. While escrowed, the cards are invisible
--   to the collection UI, trade offers, gifts, and both dupe trade-ins —
--   every one of those reads cps.collection, so no patches are needed
--   elsewhere. The escrow table is the refund ledger.
-- * Offered cards must be non-numbered-variant copies (validated against
--   cps.variants). Variants always exist; serial tracking through escrow is
--   out of scope. Known corner case, documented in the spec: if ALL of a
--   poster's holo copies of a card are variant copies, a holo offer could
--   escrow a variant copy's base slot. The serial itself is never moved or
--   destroyed (its cps.variants row keeps pointing at the poster), so this
--   is cosmetic, not destructive. Tightening it would need per-copy holo
--   tracking, which the schema doesn't have.
-- * New functions only — nothing is dropped or redefined, so there is no
--   overload risk (cf. the 002_pin.sql lesson).
-- =====================================================================

-- --- bounty headers -------------------------------------------------------
create table if not exists cps.bounties (
  id            uuid primary key default gen_random_uuid(),
  poster        uuid not null references cps.accounts(id) on delete cascade,
  want_set      text not null,
  want_card     text not null,
  want_holo     text not null default 'any' check (want_holo in ('any', 'holo')),
  want_tier     text check (want_tier is null or want_tier in ('rainbow', 'prism', 'obsidian', 'oneofone')),
  want_serial   int  check (want_serial is null or want_serial >= 1),
  offer_tokens  int  not null default 0 check (offer_tokens >= 0),
  offer_tickets int  not null default 0 check (offer_tickets >= 0),
  offer_pack_set text,
  offer_packs   int  not null default 0 check (offer_packs >= 0),
  status        text not null default 'open'
                  check (status in ('open', 'claimed', 'cancelled', 'expired')),
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null default now() + interval '7 days',
  claimed_by    uuid references cps.accounts(id) on delete set null,
  claimed_at    timestamptz,
  check ((want_tier is null) = (want_serial is null)),
  check (want_tier is null or want_holo = 'any')  -- a serial IS a specific copy
);
create index if not exists idx_bounties_poster on cps.bounties(poster, status);
create index if not exists idx_bounties_expiry on cps.bounties(status, expires_at);

-- --- escrow ledger: offered cards held out of the poster's collection -----
create table if not exists cps.bounty_escrow (
  bounty_id uuid not null references cps.bounties(id) on delete cascade,
  set_id    text not null,
  card_id   text not null,
  holo      boolean not null default false,
  qty       int not null check (qty >= 1),
  primary key (bounty_id, set_id, card_id, holo)
);

-- lock new tables down like the rest of the cps schema
alter table cps.bounties enable row level security;
alter table cps.bounty_escrow enable row level security;
revoke all on table cps.bounties from public;
revoke all on table cps.bounty_escrow from public;

-- --- internal: refund a bounty's full offer back to its poster -------------
create or replace function cps.bounty_refund(p_bounty uuid)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  b cps.bounties%rowtype;
  e record;
begin
  select * into b from cps.bounties where id = p_bounty;
  if not found then return; end if;

  -- escrowed cards back into the poster's collection
  for e in select * from cps.bounty_escrow where bounty_id = p_bounty loop
    insert into cps.collection (account_id, set_id, card_id, count, holo_count)
      values (b.poster, e.set_id, e.card_id, e.qty, case when e.holo then e.qty else 0 end)
      on conflict (account_id, set_id, card_id) do update
        set count = cps.collection.count + excluded.count,
            holo_count = cps.collection.holo_count + excluded.holo_count;
  end loop;
  delete from cps.bounty_escrow where bounty_id = p_bounty;

  -- currencies back
  if b.offer_tokens > 0 or b.offer_tickets > 0 then
    update cps.accounts
      set game_tokens = game_tokens + b.offer_tokens,
          spins = spins + b.offer_tickets
      where id = b.poster;
    if b.offer_tickets > 0 then
      insert into cps.spin_grants (account_id, spins, reason)
        values (b.poster, b.offer_tickets, 'bounty_refund');
    end if;
    if b.offer_tokens > 0 then
      insert into cps.token_grants (account_id, tokens, reason)
        values (b.poster, b.offer_tokens, 'bounty_refund');
    end if;
  end if;

  -- packs back
  if b.offer_packs > 0 and b.offer_pack_set is not null then
    perform cps.add_packs(b.poster, b.offer_pack_set, b.offer_packs, 'bounty_refund', b.id::text, null);
  end if;
end $$;

-- --- internal: expire + refund every due bounty (called lazily) ------------
create or replace function cps.bounty_expire_due()
returns int language plpgsql set search_path = cps, pg_temp as $$
declare
  b    record;
  n    int := 0;
  vcard text;
  vset  text;
begin
  for b in
    select id, poster, want_set, want_card from cps.bounties
    where status = 'open' and expires_at < now()
    for update skip locked
  loop
    update cps.bounties set status = 'expired' where id = b.id;
    perform cps.bounty_refund(b.id);
    select k.name, s.name into vcard, vset
      from cps.cards k join cps.card_sets s on s.id = k.set_id
      where k.set_id = b.want_set and k.card_id = b.want_card;
    perform cps.notify(b.poster, 'bounty_expired',
      'Your bounty for ' || coalesce(vcard, 'a card') ||
      ' (' || coalesce(vset, b.want_set) || ') expired — your offer was refunded.',
      'bounties');
    n := n + 1;
  end loop;
  return n;
end $$;

-- --- post a bounty ----------------------------------------------------------
-- p_want:  {set, card, holo: 'any'|'holo', tier?, serial?}
-- p_offer: {tokens, tickets, pack_set, packs, cards: [{set, card, holo}]}
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
    if wserial is null or wserial < 1 or wserial > cps.variant_run(wtier) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(wtier), cps.variant_name(wtier); end if;
    if not exists (select 1 from cps.variants
                   where set_id = wset and card_id = wcard and tier = wtier and serial = wserial) then
      raise exception 'That numbered copy hasn''t been pulled yet — nobody could claim this bounty.'; end if;
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

  -- escrow cards: aggregate, validate non-variant copies, decrement collection
  for r in
    select t.set_id, t.card_id,
           sum(case when t.holo then 1 else 0 end)::int as holo_qty,
           sum(case when t.holo then 0 else 1 end)::int as plain_qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo
          from jsonb_array_elements(coalesce(p_offer->'cards', '[]'::jsonb)) j) t
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
    -- offered copies must be non-numbered-variant copies
    if coalesce(c.count, 0) - vn < r.holo_qty + r.plain_qty then
      raise exception 'You don''t have enough non-numbered copies to offer.'; end if;
    if r.holo_qty > 0 and coalesce(c.holo_count, 0) < r.holo_qty then
      raise exception 'You don''t have enough holo copies to offer.'; end if;
    update cps.collection
      set count = count - (r.holo_qty + r.plain_qty),
          holo_count = holo_count - r.holo_qty
      where account_id = a.id and set_id = r.set_id and card_id = r.card_id;
    if r.holo_qty > 0 then
      insert into cps.bounty_escrow (bounty_id, set_id, card_id, holo, qty)
        values (new_id, r.set_id, r.card_id, true, r.holo_qty);
    end if;
    if r.plain_qty > 0 then
      insert into cps.bounty_escrow (bounty_id, set_id, card_id, holo, qty)
        values (new_id, r.set_id, r.card_id, false, r.plain_qty);
    end if;
    -- a fully-escrowed card can't stay favorited (mirrors transfer_card)
    delete from cps.favorites f
      where f.account_id = a.id and f.set_id = r.set_id and f.card_id = r.card_id
        and not exists (select 1 from cps.collection cc
                        where cc.account_id = a.id and cc.set_id = r.set_id
                          and cc.card_id = r.card_id and cc.count > 0);
  end loop;

  -- the offer must be *something*
  if otokens = 0 and otickets = 0 and opacks = 0
     and not exists (select 1 from cps.bounty_escrow where bounty_id = new_id) then
    raise exception 'Your bounty needs an offer — tokens, tickets, packs, or cards.'; end if;

  insert into cps.bounties (id, poster, want_set, want_card, want_holo, want_tier, want_serial,
                            offer_tokens, offer_tickets, offer_pack_set, offer_packs)
    values (new_id, a.id, wset, wcard, wholo, wtier, wserial,
            otokens, otickets, opackset, opacks);

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- --- claim a bounty (atomic: row lock decides the winner) -------------------
create or replace function public.cps_claim_bounty(p_token text, p_bounty_id uuid)
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
  if b.want_serial is not null then
    -- serial-specific: the exact numbered copy
    select * into vrow from cps.variants
      where account_id = a.id and set_id = b.want_set and card_id = b.want_card
        and tier = b.want_tier and serial = b.want_serial for update;
    if not found then raise exception 'You no longer hold that numbered copy.'; end if;
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
    delete from cps.favorites f
      where f.account_id = a.id and f.set_id = b.want_set and f.card_id = b.want_card
        and not exists (select 1 from cps.collection cc
                        where cc.account_id = a.id and cc.set_id = b.want_set
                          and cc.card_id = b.want_card and cc.count > 0);
  else
    select * into c from cps.collection
      where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
    if not found or c.count < 1 then raise exception 'You no longer hold that card.'; end if;
    if b.want_holo = 'holo' then
      if c.holo_count < 1 then raise exception 'This bounty needs a holo copy.'; end if;
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
    select e2.qty, e2.holo, kk.name as card_name
    from cps.bounty_escrow e2
    join cps.cards kk on kk.set_id = e2.set_id and kk.card_id = e2.card_id
    where e2.bounty_id = b.id
    order by kk.name
  loop
    bits := bits || (e.qty || '× ' || e.card_name || case when e.holo then ' ✦ holo' else '' end);
  end loop;
  offer_desc := array_to_string(bits, ', ');

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

-- --- cancel a bounty (poster only, open only, full refund) ------------------
create or replace function public.cps_cancel_bounty(p_token text, p_bounty_id uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  b        cps.bounties%rowtype;
  cardname text;
begin
  a := cps.auth(p_token);
  select * into b from cps.bounties where id = p_bounty_id for update;
  if not found then raise exception 'Bounty not found.'; end if;
  if b.poster <> a.id then raise exception 'Only the poster can cancel this bounty.'; end if;
  if b.status = 'open' and b.expires_at < now() then
    -- it lapsed while open: expire it instead of cancelling
    update cps.bounties set status = 'expired' where id = b.id;
    perform cps.bounty_refund(b.id);
    select k.name into cardname from cps.cards k where k.set_id = b.want_set and k.card_id = b.want_card;
    perform cps.notify(b.poster, 'bounty_expired',
      'Your bounty for ' || coalesce(cardname, 'a card') || ' expired — your offer was refunded.', 'bounties');
    raise exception 'This bounty had already expired — the offer was refunded.';
  end if;
  if b.status <> 'open' then raise exception 'This bounty is no longer open.'; end if;
  perform cps.bounty_refund(b.id);
  update cps.bounties set status = 'cancelled' where id = b.id;
  return jsonb_build_object('ok', true);
end $$;

-- --- list open bounties (lazy expiry; per-bounty claim eligibility) ----------
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
    can := false;
    if b.poster <> a.id then
      if b.want_serial is not null then
        can := exists (select 1 from cps.variants
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and tier = b.want_tier and serial = b.want_serial);
      else
        select * into c from cps.collection
          where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
        if found then
          can := case when b.want_holo = 'holo' then c.holo_count >= 1 else c.count >= 1 end;
        end if;
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'set_id', e.set_id, 'card_id', e.card_id, 'holo', e.holo, 'qty', e.qty,
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

-- API grants (anon key, like the other user RPCs)
grant execute on function public.cps_post_bounty(text, jsonb, jsonb) to anon;
grant execute on function public.cps_claim_bounty(text, uuid) to anon;
grant execute on function public.cps_cancel_bounty(text, uuid) to anon;
grant execute on function public.cps_list_bounties(text) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
