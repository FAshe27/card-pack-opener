-- =====================================================================
-- PackRipper — migration 141: bounties can want ANY number of a variant
-- Run AFTER 140.
--
-- Until now a numbered bounty want needed tier AND serial together —
-- the cps.bounties check ((want_tier is null) = (want_serial is null))
-- forced it, cps_post_bounty required a serial (and an already-pulled
-- instance) whenever a tier was given, and cps_claim_bounty keyed its
-- variant branch on the serial. Franklin wants both shapes: a specific
-- number, or any number of the tier.
--
-- 1. The both-or-neither check is relaxed to "a serial needs a tier"
--    (a tier may now stand alone). The old check was never named, so
--    it is found by its definition — it is the only check constraint
--    on the table mentioning both want_tier and want_serial — and
--    dropped in the DO block below; the replacement is added under
--    the name bounties_serial_needs_tier. (Idempotent: re-running
--    finds nothing to drop and the add is guarded.)
-- 2. cps_post_bounty — rebuilt from 139's body; ONLY the tier branch
--    changes: the serial-range and instance-exists checks now apply
--    only when a serial was actually given. A tier with no serial
--    needs just the tier validity + the Rare+ rarity gate. There is
--    deliberately NO existence requirement for a tier-only want —
--    wanting a variant nobody has pulled yet is legitimate; the
--    bounty simply waits. Back-diff proof: reversing the two guarded
--    lines and one added comment reproduces 139's body byte-for-byte.
-- 3. cps_claim_bounty — the old (text, uuid) signature is DROPPED and
--    the function is recreated from 138's body with an added
--    (p_serial int default null), so existing two-argument callers
--    keep working unchanged. The variant branch now keys on
--    want_tier instead of want_serial and resolves the copy to hand
--    over three ways: a serial-specific bounty takes that exact copy
--    (unchanged); a tier-only bounty honours p_serial when the
--    claimer picked one (held + unvaulted are validated with the same
--    friendly errors as today); with no pick it resolves only when
--    exactly one unvaulted copy of the tier is held — more than one
--    raises 'Pick which numbered copy to hand over.', none unvaulted
--    but a vaulted one held raises the Vault error, none held at all
--    raises 'You no longer hold that numbered copy.'. Everything
--    downstream of the branch — the base-copy move, escrow release,
--    notifications, the market_trade quest bumps, auto_turn_in — is
--    138's text verbatim. The drop destroys the function's ACL, so
--    the execute grant is re-issued for the new signature (same
--    pattern as 056/074).
-- 4. cps_list_bounties — rebuilt from 124's body; ONE insertion: an
--    elsif giving can_claim the tier-only case (viewer holds an
--    unvaulted instance of the tier, plus the same base-copy check
--    the serial case uses), mirroring claim's own eligibility.
-- =====================================================================

-- --- 1. bounties check: a serial needs a tier; a tier may stand alone ---
do $$
declare
  v_con text;
begin
  -- the 056 both-or-neither check was never named; find it by definition
  -- (the named replacement is excluded so a re-run leaves it in place)
  select conname into v_con
    from pg_constraint
   where conrelid = 'cps.bounties'::regclass
     and contype = 'c'
     and conname <> 'bounties_serial_needs_tier'
     and pg_get_constraintdef(oid) like '%want_tier%'
     and pg_get_constraintdef(oid) like '%want_serial%';
  if v_con is not null then
    execute format('alter table cps.bounties drop constraint %I', v_con);
  end if;
  if not exists (select 1 from pg_constraint
                  where conrelid = 'cps.bounties'::regclass
                    and conname = 'bounties_serial_needs_tier') then
    alter table cps.bounties
      add constraint bounties_serial_needs_tier
      check (want_serial is null or want_tier is not null);
  end if;
end $$;

-- --- 2. cps_post_bounty (base: 139) ---
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

-- --- 3. cps_claim_bounty (base: 138; signature gains p_serial) ---
drop function if exists public.cps_claim_bounty(text, uuid);

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

grant execute on function public.cps_claim_bounty(text, uuid, int) to anon;


-- --- 4. cps_list_bounties (base: 124) ---
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

notify pgrst, 'reload schema';
