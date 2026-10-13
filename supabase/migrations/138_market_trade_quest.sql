-- =====================================================================
-- PackRipper -- migration 138: new daily quest "Buy or sell a card
-- in the Market" (medium, pays 2 tickets). Run AFTER 137.
-- Franklin's ask, 2026-10-13.
--
-- The quest key is 'market_trade'. What it takes:
--   * cps.quest_tier: 'market_trade' joins the medium list
--     (074's body, insertion-only).
--   * cps.quest_title: 'Buy or sell a card in the Market'
--     (074's body, insertion-only).
--   * cps.assign_daily_quests: the key joins the daily catalog
--     (074's body, insertion-only). Like 074's visit_market, this
--     takes effect at the next daily reset -- today's already-
--     assigned rows are unchanged.
--   * NO changes needed to cps.quest_target (072's default is 1),
--     cps.quest_reward_currency (anything unlisted pays 'ticket'),
--     or cps.quest_reward_amount (an unlisted medium pays 2) --
--     so the prize is exactly 2 spin tickets via the same helpers
--     cps_claim_quest (086) pays with. Verified in 138_verify.
--
-- The hooks (both parties, mirroring how 'trade_done' once bumped
-- both sides of a player trade): a Market sale completes in exactly
-- two places, and each gains two quest_bump lines at the point the
-- deal is final (insertion-only vs migration 108's bodies):
--   * public.cps_trade_accept -- a lister accepts an offer on the
--     Trading Post: lister SOLD, offerer BOUGHT.
--   * public.cps_claim_bounty -- a player claims a bounty with the
--     wanted card: claimer SOLD, poster BOUGHT.
-- Making an offer, posting a listing/bounty, cancelling, and
-- expiries do NOT count -- no card changed hands.
--
-- Proofs: every rebuilt function is insertion-only against its
-- source body (removing the additions reproduces the source
-- byte-for-byte); paren walks + pglast clean; the quest-helper
-- logic was executed against a stub database (tier/title/reward/
-- target, assignment, and the bump to done all exercised).
-- =====================================================================

create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card',
                             'pull_3_sets','bank_5_streak','market_trade') then 'medium'
              when p_key = 'bank_10_streak' then 'ultra'
              else 'hard' end $$;

create or replace function cps.quest_title(p_key text, p_meta jsonb) returns text
language plpgsql set search_path = cps, pg_temp as $$
declare sname text;
begin
  if p_key = 'open_packs_set' then
    select s.name into sname from cps.card_sets s where s.id = p_meta->>'set_id';
    return 'Open 2 ' || coalesce(sname, 'set') || ' packs';
  end if;
  if p_key = 'pull_letter' then
    return 'Pull a card with "' || coalesce(p_meta->>'letter', '?') || '" in the name';
  end if;
  return case p_key
    when 'open_packs' then 'Open 3 packs'
    when 'spin_wheel' then 'Spin the wheel'
    when 'dupe_trade' then 'Trade in duplicates'
    when 'pull_holo' then 'Pull a holo card'
    when 'pull_rare_plus' then 'Pull a Rare or better'
    when 'pull_epic_plus' then 'Pull an Epic or better'
    when 'gift_card' then 'Gift a card to a friend'
    when 'visit_market' then 'Visit the Market'
    when 'market_trade' then 'Buy or sell a card in the Market'
    when 'pull_legendary_plus' then 'Pull a Legendary or better'
    when 'pull_chase' then 'Pull a Chase card'
    when 'pull_variant' then 'Pull a numbered variant'
    when 'wheel_big_win' then 'Win 3+ packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    when 'pull_token_slip' then 'Pull a Token Slip'
    when 'win_3_rounds' then 'Win 3 Rounds of Higher/Lower'
    when 'pull_spin_ticket' then 'Pull a Spin Ticket'
    when 'bank_5_streak' then 'Bank and Claim a 5+ Streak in Higher/Lower'
    when 'bank_10_streak' then 'Bank and Claim a 10+ Streak in Higher/Lower'
    when 'win_slots' then 'Win on Slots'
    else p_key end;
end $$;

create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  k text; sid text; vletter text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  -- deterministic featured set per account per day
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select id into sid from cps.card_sets where active order by random() limit 1;
  -- deterministic random letter per account per day (A-Z)
  perform setseed(('x' || substr(md5('letter' || p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select chr(65 + floor(random() * 26)::int) into vletter;
  foreach k in array array['open_packs','open_packs_set','spin_wheel','dupe_trade',
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','visit_market','market_trade',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack',
    'pull_token_slip','win_3_rounds','pull_spin_ticket','bank_5_streak','bank_10_streak',
    'win_slots'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

create or replace function public.cps_trade_accept(p_token text, p_listing uuid, p_offer uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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
  if o.packs > 0 and o.pack_set is not null then
    perform cps.add_packs(l.lister, o.pack_set, o.packs, 'trade_accept', l.id::text, null);
  end if;
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
end $$;

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

notify pgrst, 'reload schema';
