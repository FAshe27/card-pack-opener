-- 229: store credit joins tokens/tickets as a tradeable currency in
-- direct trades, bounties, and Trading Post offers. Credit escrows when
-- an offer/bounty/trade is made (sender side), settles on accept/claim,
-- and refunds on decline/cancel/expire/withdraw -- exactly the shape
-- tokens and tickets already follow (184 / Market lineage). Credit has
-- no grants ledger (balance-only everywhere else too), so credit moves
-- are plain balance updates. Existing rows default to 0 = unchanged.

alter table cps.trade_offers    add column if not exists offer_credit integer not null default 0;
alter table cps.trade_offers    add column if not exists want_credit  integer not null default 0;
alter table cps.bounties        add column if not exists offer_credit integer not null default 0;
alter table cps.listing_offers  add column if not exists credit       integer not null default 0;

-- signature changes: the old shapes are dropped and recreated with a
-- trailing p_credit (default 0 keeps any unconverted caller working).
drop function if exists cps.trade_check_side(uuid, jsonb, text, integer, integer, integer, text);
drop function if exists cps.x_contents(integer, integer, text, integer, text[]);

create function cps.trade_check_side(p_owner uuid, p_items jsonb, p_pack_set text, p_packs integer, p_tokens integer, p_tickets integer, p_label text, p_credit integer default 0)
  returns void language plpgsql set search_path = cps, pg_temp as $m229$
declare
  total int;
  r     record;
  c     cps.collection%rowtype;
  v     record;
begin
  if jsonb_typeof(p_items) <> 'array' then
    raise exception '% must be a list of cards.', p_label;
  end if;
  total := (select count(*) from jsonb_array_elements(p_items));
  if total > 10 then
    raise exception '% can have at most 10 cards.', p_label;
  end if;
  if total < 1 and coalesce(p_packs, 0) < 1
     and coalesce(p_tokens, 0) < 1 and coalesce(p_tickets, 0) < 1
     and coalesce(p_credit, 0) < 1 then
    raise exception '% must include at least one card, a pack bundle, or some tokens/tickets/credit.', p_label;
  end if;
  -- 180: a side may add ONE pack bundle (one set + qty), Market-style.
  -- Jumbled packs stay fenced, matching the Bounty Board rule.
  if coalesce(p_packs, 0) > 0 then
    if p_pack_set is null or p_pack_set = 'jumbled'
       or not exists (select 1 from cps.card_sets where id = p_pack_set) then
      raise exception 'Bad pack bundle in the % list.', p_label;
    end if;
    if coalesce((select packs from cps.pack_inventory
                  where account_id = p_owner and set_id = p_pack_set), 0) < p_packs then
      raise exception 'Not enough packs for the pack bundle in the % list.', p_label;
    end if;
  end if;
  -- 154: pinned numbered copies are validated one by one -- the owner
  -- must hold that exact copy, unvaulted, not already committed to a
  -- Trading Post listing/offer or an open bounty.
  for v in
    select j->>'set' as set_id, j->>'card' as card_id,
           coalesce(j->>'tier', '') as tier,
           coalesce((j->>'serial')::int, 0) as serial,
           coalesce((j->>'holo')::boolean, false) as holo
    from jsonb_array_elements(p_items) j
    where coalesce(j->>'tier', '') <> ''
  loop
    if v.tier not in ('rainbow', 'prism', 'obsidian', 'oneofone') or v.serial < 1 then
      raise exception 'Bad numbered copy in the % list.', p_label;
    end if;
    if v.holo then
      raise exception 'A numbered copy in the % list cannot be marked holo.', p_label;
    end if;
    if (select count(*) from jsonb_array_elements(p_items) j
         where j->>'set' = v.set_id and j->>'card' = v.card_id
           and coalesce(j->>'tier', '') = v.tier
           and coalesce((j->>'serial')::int, 0) = v.serial) > 1 then
      raise exception 'The same numbered copy is listed twice in the % list.', p_label;
    end if;
    if not exists (select 1 from cps.variants vr
                    where vr.account_id = p_owner and vr.set_id = v.set_id
                      and vr.card_id = v.card_id and vr.tier = v.tier
                      and vr.serial = v.serial and not vr.vaulted) then
      raise exception 'A numbered copy in the % list is not available.', p_label;
    end if;
    if cps.trade_variant_escrowed(v.set_id, v.card_id, v.tier, v.serial) then
      raise exception 'A numbered copy in the % list is already committed elsewhere.', p_label;
    end if;
  end loop;
  for r in
    select t.set_id, t.card_id,
           sum(case when t.holo then 1 else 0 end)::int as holo_qty,
           sum(case when t.holo then 0 else 1 end)::int as plain_qty,
           (select count(*)::int from jsonb_array_elements(p_items) j
             where j->>'set' = t.set_id and j->>'card' = t.card_id
               and coalesce(j->>'tier', '') <> '') as pinned_qty,
           (select count(*)::int from cps.variants vr
             where vr.account_id = p_owner and vr.set_id = t.set_id
               and vr.card_id = t.card_id and not vr.vaulted) as vn_qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo
          from jsonb_array_elements(p_items) j
          where coalesce(j->>'tier', '') = '') t
    group by t.set_id, t.card_id
  loop
    if r.set_id is null or r.card_id is null then
      raise exception 'Bad card in the % list.', p_label;
    end if;
    select * into c from cps.collection
      where account_id = p_owner and set_id = r.set_id and card_id = r.card_id;
    if not found or c.count - c.vaulted_count < r.holo_qty + r.plain_qty + r.pinned_qty
       or c.holo_count - c.vaulted_holo < r.holo_qty
       or (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < r.plain_qty + r.vn_qty then
      raise exception 'Not enough copies for a card in the % list.', p_label;
    end if;
  end loop;
  -- cards whose entries are ALL pinned never reach the loop above;
  -- check their base slots (total + plain pool) here.
  for r in
    select j->>'set' as set_id, j->>'card' as card_id, count(*)::int as pinned_qty
    from jsonb_array_elements(p_items) j
    where coalesce(j->>'tier', '') <> ''
    group by 1, 2
  loop
    select * into c from cps.collection
      where account_id = p_owner and set_id = r.set_id and card_id = r.card_id;
    if not found or c.count - c.vaulted_count < r.pinned_qty
       or (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < r.pinned_qty then
      raise exception 'Not enough copies for a card in the % list.', p_label;
    end if;
  end loop;
end $m229$;

create function cps.x_contents(p_tokens integer, p_tickets integer, p_pack_set text, p_packs integer, p_items text[], p_credit integer default 0)
  returns text language plpgsql stable set search_path = cps, pg_temp as $m229$
declare parts text[] := coalesce(p_items, '{}');
begin
  if coalesce(p_packs, 0) > 0 and p_pack_set is not null then
    parts := parts || ('🎁 ' || p_packs || ' ' ||
      coalesce((select name from cps.card_sets where id = p_pack_set), p_pack_set) ||
      ' pack' || case when p_packs = 1 then '' else 's' end);
  end if;
  if coalesce(p_tokens, 0) > 0 then
    parts := parts || ('🪙 ' || p_tokens || ' token' || case when p_tokens = 1 then '' else 's' end);
  end if;
  if coalesce(p_tickets, 0) > 0 then
    parts := parts || ('🎟️ ' || p_tickets || ' ticket' || case when p_tickets = 1 then '' else 's' end);
  end if;
  if coalesce(p_credit, 0) > 0 then
    parts := parts || ('💵 $' || p_credit || ' store credit');
  end if;
  if parts = '{}' then return 'nothing'; end if;
  return array_to_string(parts, ' + ');
end $m229$;

create or replace function cps.x_trade_side(p_offer uuid, p_side text)
  returns text language sql stable set search_path = cps, pg_temp as $m229$
  select cps.x_contents(
    case when p_side = 'offer' then o.offer_tokens else o.want_tokens end,
    case when p_side = 'offer' then o.offer_tickets else o.want_tickets end,
    case when p_side = 'offer' then o.offer_pack_set else o.want_pack_set end,
    case when p_side = 'offer' then o.offer_packs else o.want_packs end,
    cps.x_trade_items(o.id, p_side),
    case when p_side = 'offer' then o.offer_credit else o.want_credit end)
  from cps.trade_offers o where o.id = p_offer
$m229$;

create or replace function cps.trade_refund_offer_currency(p_offer uuid)
  returns void language plpgsql set search_path = cps, pg_temp as $m229$
declare o cps.trade_offers%rowtype;
begin
  select * into o from cps.trade_offers where id = p_offer;
  if not found or (o.offer_tokens <= 0 and o.offer_tickets <= 0 and o.offer_credit <= 0) or o.offer_currency_refunded then return; end if;
  update cps.trade_offers set offer_currency_refunded = true where id = o.id;
  if o.offer_tokens > 0 then
    update cps.accounts set game_tokens = game_tokens + o.offer_tokens where id = o.from_account;
  end if;
  if o.offer_tickets > 0 then
    update cps.accounts set spins = spins + o.offer_tickets where id = o.from_account;
  end if;
  if o.offer_credit > 0 then
    update cps.accounts set store_credit = store_credit + o.offer_credit where id = o.from_account;
  end if;
end $m229$;

create or replace function public.cps_propose_trade(p_token text, p_to uuid, p_offer jsonb, p_want jsonb)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
declare
  a      cps.accounts%rowtype;
  tgt    cps.accounts%rowtype;
  new_id uuid;
  ocards jsonb; wcards jsonb;
  ops    text;  opk int;
  wps    text;  wpk int;
  vheld  int;
  otok int; otic int; wtok int; wtic int; ocred int; wcred int;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot trade with yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  -- 180: a side is {cards: [...], pack_set, packs}; a bare array is
  -- still accepted as cards-only (older cached clients).
  ocards := case when jsonb_typeof(p_offer) = 'array' then p_offer
                 else coalesce(p_offer -> 'cards', '[]'::jsonb) end;
  wcards := case when jsonb_typeof(p_want) = 'array' then p_want
                 else coalesce(p_want -> 'cards', '[]'::jsonb) end;
  ops := case when jsonb_typeof(p_offer) = 'object' then nullif(p_offer ->> 'pack_set', '') end;
  opk := case when jsonb_typeof(p_offer) = 'object' then greatest(coalesce((p_offer ->> 'packs')::int, 0), 0) else 0 end;
  wps := case when jsonb_typeof(p_want) = 'object' then nullif(p_want ->> 'pack_set', '') end;
  wpk := case when jsonb_typeof(p_want) = 'object' then greatest(coalesce((p_want ->> 'packs')::int, 0), 0) else 0 end;
  -- 184: a side may also carry tokens/tickets.
  otok := case when jsonb_typeof(p_offer) = 'object' then greatest(coalesce((p_offer ->> 'tokens')::int, 0), 0) else 0 end;
  otic := case when jsonb_typeof(p_offer) = 'object' then greatest(coalesce((p_offer ->> 'tickets')::int, 0), 0) else 0 end;
  wtok := case when jsonb_typeof(p_want) = 'object' then greatest(coalesce((p_want ->> 'tokens')::int, 0), 0) else 0 end;
  wtic := case when jsonb_typeof(p_want) = 'object' then greatest(coalesce((p_want ->> 'tickets')::int, 0), 0) else 0 end;
  -- 229: a side may also carry store credit.
  ocred := case when jsonb_typeof(p_offer) = 'object' then greatest(coalesce((p_offer ->> 'credit')::int, 0), 0) else 0 end;
  wcred := case when jsonb_typeof(p_want) = 'object' then greatest(coalesce((p_want ->> 'credit')::int, 0), 0) else 0 end;

  perform cps.trade_check_side(a.id, ocards, ops, opk, otok, otic, 'Your offer', ocred);
  perform cps.trade_check_side(tgt.id, wcards, wps, wpk, wtok, wtic, 'Their side', wcred);

  if (select count(*) from cps.trade_offers
        where from_account = a.id and status = 'pending') >= 10 then
    raise exception 'You have too many pending offers (max 10).';
  end if;

  -- 184: currency balances. The sender's row is locked and checked
  -- now (their tokens/tickets escrow below); the recipient's are
  -- checked here and again, under lock, when they accept -- the same
  -- shape as the pack bundles in 180.
  select * into a from cps.accounts where id = a.id for update;
  if otok > a.game_tokens then raise exception 'You do not have that many tokens.'; end if;
  if otic > a.spins then raise exception 'You do not have that many tickets.'; end if;
  if ocred > a.store_credit then raise exception 'You do not have that much store credit.'; end if;
  if wtok > tgt.game_tokens then raise exception 'Not enough tokens in the Their side list.'; end if;
  if wtic > tgt.spins then raise exception 'Not enough tickets in the Their side list.'; end if;
  if wcred > tgt.store_credit then raise exception 'Not enough store credit in the Their side list.'; end if;

  insert into cps.trade_offers (from_account, to_account,
      offer_pack_set, offer_packs, want_pack_set, want_packs,
      offer_tokens, offer_tickets, want_tokens, want_tickets,
      offer_credit, want_credit)
    values (a.id, tgt.id, ops, opk, wps, wpk, otok, otic, wtok, wtic, ocred, wcred) returning id into new_id;
  perform cps.trade_insert_items(new_id, 'offer', ocards);
  perform cps.trade_insert_items(new_id, 'want', wcards);

  -- 180: the sender's packs are escrowed NOW (Franklin's call) -- they
  -- leave the sender's inventory until the trade is accepted (delivered
  -- to the recipient), declined, cancelled, or expired (refunded). The
  -- recipient's packs cannot be escrowed before they accept; they are
  -- balance-checked here and again, under lock, at accept time.
  if opk > 0 then
    select packs into vheld from cps.pack_inventory
      where account_id = a.id and set_id = ops for update;
    if coalesce(vheld, 0) < opk then
      raise exception 'You no longer have that many packs.';
    end if;
    perform cps.add_packs(a.id, ops, -opk, 'direct_trade_escrow', new_id::text, null);
  end if;

  -- 184: the sender's tokens/tickets escrow NOW, like their packs --
  -- delivered on accept; refunded by cps.trade_refund_offer_currency
  -- on decline, cancel, or expiry.
  if otok > 0 then
    update cps.accounts set game_tokens = game_tokens - otok where id = a.id;
  end if;
  if otic > 0 then
    update cps.accounts set spins = spins - otic where id = a.id;
  end if;
  -- 229: the sender's store credit escrows now too, with the rest.
  if ocred > 0 then
    update cps.accounts set store_credit = store_credit - ocred where id = a.id;
  end if;

  -- Notify the recipient
  perform cps.notify(tgt.id, 'trade_offer',
    a.display_name || ' sent you a trade offer.', 'trading');

  return jsonb_build_object('id', new_id);
end $m229$;

create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  r   record;
  c   cps.collection%rowtype;
  vheld int;
  vfail text;
  tacct cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.to_account <> a.id then raise exception 'This offer is not for you.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  if o.expires_at < now() then
    -- 180: refund the sender's escrowed packs; the refund must persist,
    -- so this returns instead of raising (a raise would roll it back).
    perform cps.trade_refund_offer_packs(o.id);
    perform cps.trade_refund_offer_currency(o.id);
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    return jsonb_build_object('status', 'unavailable', 'message', 'This offer has expired.');
  end if;

  if not p_accept then
    perform cps.trade_refund_offer_packs(o.id);
    perform cps.trade_refund_offer_currency(o.id);
    update cps.trade_offers set status = 'declined', decided_at = now() where id = o.id;
    perform cps.notify(o.from_account, 'trade_declined', a.display_name || ' declined your trade', 'players');
    return jsonb_build_object('status', 'declined');
  end if;

  -- verify every line first (deterministic lock order: no deadlocks), then move cards
  -- 180: verification runs in a sub-block so a failure can refund the
  -- sender's escrowed packs and close the offer instead of raising
  -- (raising would roll the refund back with everything else).
  vfail := null;
  begin
  -- 154: pinned numbered copies are verified one by one (exact copy,
  -- still held, unvaulted, uncommitted) before the pool checks.
  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           i.set_id, i.card_id, i.tier, i.serial
    from cps.trade_offer_items i where i.offer_id = o.id and i.tier <> ''
    order by 1, 2, 3, 4, 5
  loop
    if not exists (select 1 from cps.variants vr
                    where vr.account_id = r.giver and vr.set_id = r.set_id
                      and vr.card_id = r.card_id and vr.tier = r.tier
                      and vr.serial = r.serial and not vr.vaulted)
       or cps.trade_variant_escrowed(r.set_id, r.card_id, r.tier, r.serial) then
      update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
      raise exception 'A card in this trade is no longer available.';
    end if;
  end loop;

  for r in
    select g.giver, g.set_id, g.card_id, g.holo, sum(g.qty)::int as qty,
           (select count(*)::int from cps.trade_offer_items p
             where p.offer_id = o.id and p.tier <> ''
               and p.set_id = g.set_id and p.card_id = g.card_id
               and (case when p.side = 'offer' then o.from_account else o.to_account end) = g.giver) as pinned_qty,
           (select count(*)::int from cps.variants vr
             where vr.account_id = g.giver and vr.set_id = g.set_id
               and vr.card_id = g.card_id and not vr.vaulted) as vn_qty
    from (select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
                 i.set_id, i.card_id, i.holo, i.qty
          from cps.trade_offer_items i where i.offer_id = o.id and i.tier = '') g
    group by 1, 2, 3, 4 order by 1, 2, 3, 4
  loop
    select * into c from cps.collection
      where account_id = r.giver and set_id = r.set_id and card_id = r.card_id for update;
    if not found or c.count - c.vaulted_count < r.qty + r.pinned_qty
       or (r.holo and c.holo_count - c.vaulted_holo < r.qty)
       or (not r.holo and (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < r.qty + r.vn_qty) then
      update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
      raise exception 'A card in this trade is no longer available.';
    end if;
  end loop;

  -- 180: the recipient's pack bundle is verified under lock (the
  -- sender's bundle is already escrowed, so it needs no check).
  if o.want_packs > 0 then
    select packs into vheld from cps.pack_inventory
      where account_id = o.to_account and set_id = o.want_pack_set for update;
    if coalesce(vheld, 0) < o.want_packs then
      raise exception 'A pack bundle in this trade is no longer available.';
    end if;
  end if;

  -- 184: the recipient's tokens/tickets are verified under lock too.
  -- 229: store credit joins the same under-lock verification.
  if o.want_tokens > 0 or o.want_tickets > 0 or o.want_credit > 0 then
    select * into tacct from cps.accounts where id = o.to_account for update;
    if tacct.game_tokens < o.want_tokens or tacct.spins < o.want_tickets
       or tacct.store_credit < o.want_credit then
      raise exception 'A currency amount in this trade is no longer available.';
    end if;
  end if;
  exception when others then
    vfail := SQLERRM;
  end;
  if vfail is not null then
    perform cps.trade_refund_offer_packs(o.id);
    perform cps.trade_refund_offer_currency(o.id);
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    return jsonb_build_object('status', 'unavailable', 'message', vfail);
  end if;

  -- 154: fungible lines move WITHOUT dragging numbered copies along
  -- (move_variants := false); pinned lines move their exact copy.
  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           (case when i.side = 'offer' then o.to_account else o.from_account end) as receiver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id and i.tier = ''
    group by 1, 2, 3, 4, 5 order by 1, 3, 4, 5
  loop
    perform cps.transfer_card(r.giver, r.receiver, r.set_id, r.card_id, r.holo, r.qty, o.id::text, false);
  end loop;

  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           (case when i.side = 'offer' then o.to_account else o.from_account end) as receiver,
           i.set_id, i.card_id, i.tier, i.serial
    from cps.trade_offer_items i where i.offer_id = o.id and i.tier <> ''
    order by 1, 3, 4, 5, 6
  loop
    perform cps.transfer_pinned_variant(r.giver, r.receiver, r.set_id, r.card_id, r.tier, r.serial, o.id::text);
  end loop;

  -- 180: pack bundles settle. The recipient's packs move now; the
  -- sender's were escrowed at propose time and are simply delivered.
  if o.want_packs > 0 then
    perform cps.add_packs(o.to_account, o.want_pack_set, -o.want_packs, 'direct_trade', o.id::text, null);
    perform cps.add_packs(o.from_account, o.want_pack_set, o.want_packs, 'direct_trade', o.id::text, null);
  end if;
  if o.offer_packs > 0 then
    perform cps.add_packs(o.to_account, o.offer_pack_set, o.offer_packs, 'direct_trade', o.id::text, null);
  end if;

  -- 184: currency settles. The recipient pays their side's
  -- tokens/tickets to the sender; the sender's escrowed currency
  -- (deducted at propose time) is delivered to the recipient.
  if o.want_tokens > 0 then
    update cps.accounts set game_tokens = game_tokens - o.want_tokens where id = o.to_account;
    update cps.accounts set game_tokens = game_tokens + o.want_tokens where id = o.from_account;
  end if;
  if o.want_tickets > 0 then
    update cps.accounts set spins = spins - o.want_tickets where id = o.to_account;
    update cps.accounts set spins = spins + o.want_tickets where id = o.from_account;
  end if;
  if o.want_credit > 0 then
    update cps.accounts set store_credit = store_credit - o.want_credit where id = o.to_account;
    update cps.accounts set store_credit = store_credit + o.want_credit where id = o.from_account;
  end if;
  if o.offer_tokens > 0 then
    update cps.accounts set game_tokens = game_tokens + o.offer_tokens where id = o.to_account;
  end if;
  if o.offer_tickets > 0 then
    update cps.accounts set spins = spins + o.offer_tickets where id = o.to_account;
  end if;
  if o.offer_credit > 0 then
    update cps.accounts set store_credit = store_credit + o.offer_credit where id = o.to_account;
  end if;

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  perform cps.quest_bump(o.from_account, 'trade_done', 1);
  perform cps.quest_bump(o.to_account, 'trade_done', 1);
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $m229$;

create or replace function public.cps_list_trades(p_token text)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
declare a cps.accounts%rowtype; lo record;
begin
  a := cps.auth(p_token);
  -- lazy expiry (180: expiring an offer refunds the sender's
  -- escrowed packs, so expiry goes row by row under lock)
  for lo in
    select id from cps.trade_offers
      where status = 'pending' and expires_at < now() for update
  loop
    perform cps.trade_refund_offer_packs(lo.id);
    perform cps.trade_refund_offer_currency(lo.id);
    update cps.trade_offers set status = 'expired', decided_at = now() where id = lo.id;
  end loop;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', o.id,
      'direction', case when o.from_account = a.id then 'outgoing' else 'incoming' end,
      'other_id', case when o.from_account = a.id then o.to_account else o.from_account end,
      'other_name', case when o.from_account = a.id then t.display_name else f.display_name end,
      'offer_items', coalesce((select jsonb_agg(jsonb_build_object(
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty,
                        'tier', nullif(tier, ''), 'serial', nullif(serial, 0))
                      order by set_id, card_id, holo, tier, serial)
                    from cps.trade_offer_items where offer_id = o.id and side = 'offer'), '[]'),
      'want_items', coalesce((select jsonb_agg(jsonb_build_object(
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty,
                        'tier', nullif(tier, ''), 'serial', nullif(serial, 0))
                      order by set_id, card_id, holo, tier, serial)
                    from cps.trade_offer_items where offer_id = o.id and side = 'want'), '[]'),
      'offer_pack_set', o.offer_pack_set, 'offer_packs', o.offer_packs,
      'want_pack_set', o.want_pack_set, 'want_packs', o.want_packs,
      'offer_tokens', o.offer_tokens, 'offer_tickets', o.offer_tickets,
      'want_tokens', o.want_tokens, 'want_tickets', o.want_tickets,
      'offer_credit', o.offer_credit, 'want_credit', o.want_credit,
      'status', o.status,
      'created_at', o.created_at, 'decided_at', o.decided_at, 'expires_at', o.expires_at)
    order by (o.status = 'pending') desc, coalesce(o.decided_at, o.created_at) desc)
    from cps.trade_offers o
    join cps.accounts f on f.id = o.from_account
    join cps.accounts t on t.id = o.to_account
    where (o.from_account = a.id or o.to_account = a.id)
      and o.created_at > now() - interval '30 days'), '[]');
end $m229$;

create or replace function public.cps_post_bounty(p_token text, p_want jsonb, p_offer jsonb)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
declare
  a        cps.accounts%rowtype;
  wset     text;
  wcard    text;
  wholo    text;
  wtier    text;
  wserial  int;
  otokens  int;
  otickets int;
  ocredit  int;
  opackset text;
  opacks   int;
  new_id   uuid := gen_random_uuid();
  vrar     text;
  vtok     int;
  vtix     int;
  vcred    int;
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
  ocredit  := greatest(coalesce((p_offer->>'credit')::int, 0), 0);
  opackset := nullif(p_offer->>'pack_set', '');
  opacks   := greatest(coalesce((p_offer->>'packs')::int, 0), 0);
  if jsonb_typeof(coalesce(p_offer->'cards', '[]'::jsonb)) <> 'array' then
    raise exception 'Bad card offer.'; end if;

  -- parent row FIRST: cps.bounty_escrow has a FK to cps.bounties, so the bounty
  -- must exist before any escrow rows are inserted (was inserted at the end;
  -- card offers blew up on bounty_escrow_bounty_id_fkey)
  insert into cps.bounties (id, poster, want_set, want_card, want_holo, want_tier, want_serial,
                            offer_tokens, offer_tickets, offer_pack_set, offer_packs, offer_credit)
    values (new_id, a.id, wset, wcard, wholo, wtier, wserial,
            otokens, otickets, opackset, opacks, ocredit);

  -- escrow currencies (row lock first, then validate)
  select game_tokens, spins, store_credit into vtok, vtix, vcred from cps.accounts where id = a.id for update;
  if otokens > vtok then raise exception 'You don''t have that many game tokens.'; end if;
  if otickets > vtix then raise exception 'You don''t have that many spin tickets.'; end if;
  if ocredit > vcred then raise exception 'You don''t have that much store credit.'; end if;
  if otokens > 0 or otickets > 0 or ocredit > 0 then
    update cps.accounts set game_tokens = game_tokens - otokens, spins = spins - otickets,
                            store_credit = store_credit - ocredit where id = a.id;
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
  if otokens = 0 and otickets = 0 and ocredit = 0 and opacks = 0
     and not exists (select 1 from cps.bounty_escrow where bounty_id = new_id) then
    raise exception 'Your bounty needs an offer — tokens, tickets, store credit, packs, or cards.'; end if;

  return jsonb_build_object('ok', true, 'id', new_id);
end $m229$;

create or replace function cps.bounty_refund(p_bounty uuid)
  returns void language plpgsql set search_path = cps, pg_temp as $m229$
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
  if b.offer_tokens > 0 or b.offer_tickets > 0 or b.offer_credit > 0 then
    update cps.accounts
      set game_tokens = game_tokens + b.offer_tokens,
          spins = spins + b.offer_tickets,
          store_credit = store_credit + b.offer_credit
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
end $m229$;

create or replace function public.cps_claim_bounty(p_token text, p_bounty_id uuid, p_serial integer default null)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
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
  if b.offer_credit > 0 then bits := bits || ('💵 $' || b.offer_credit || ' store credit'); end if;
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

  if b.offer_tokens > 0 or b.offer_tickets > 0 or b.offer_credit > 0 then
    update cps.accounts
      set game_tokens = game_tokens + b.offer_tokens,
          spins = spins + b.offer_tickets,
          store_credit = store_credit + b.offer_credit
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
    'game_tokens', (select game_tokens from cps.accounts where id = a.id),
    'store_credit', (select store_credit from cps.accounts where id = a.id));
end $m229$;

create or replace function public.cps_list_bounties(p_token text)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
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
      'offer_credit', b.offer_credit,
      'offer_pack_set', b.offer_pack_set, 'offer_packs', b.offer_packs,
      'offer_cards', items,
      'can_claim', can,
      'created_at', b.created_at, 'expires_at', b.expires_at);
  end loop;

  return jsonb_build_object('bounties', arr, 'my_open', my_open);
end $m229$;

create or replace function public.cps_trade_offer(p_token text, p_listing uuid, p_offer jsonb)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
declare
  a        cps.accounts%rowtype;
  l        cps.trade_listings%rowtype;
  otokens  int;
  otickets int;
  ocredit  int;
  opackset text;
  opacks   int;
  olines   jsonb;
  ototalpacks int := 0;
  ln       record;
  new_id   uuid := gen_random_uuid();
  vtok     int;
  vtix     int;
  vcred    int;
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
  ocredit  := greatest(coalesce((p_offer->>'credit')::int, 0), 0);
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
  select game_tokens, spins, store_credit into vtok, vtix, vcred from cps.accounts where id = a.id for update;
  if otokens > vtok then raise exception 'You don''t have that many game tokens.'; end if;
  if otickets > vtix then raise exception 'You don''t have that many spin tickets.'; end if;
  if ocredit > vcred then raise exception 'You don''t have that much store credit.'; end if;
  if otokens > 0 or otickets > 0 or ocredit > 0 then
    update cps.accounts set game_tokens = game_tokens - otokens, spins = spins - otickets,
                            store_credit = store_credit - ocredit where id = a.id;
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
  insert into cps.listing_offers (id, listing_id, offerer, tokens, tickets, credit, pack_set, packs, pack_lines,
                               cards, status)
    values (new_id, p_listing, a.id, otokens, otickets, ocredit, opackset, opacks,
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
  if otokens = 0 and otickets = 0 and ocredit = 0 and ototalpacks = 0
     and not exists (select 1 from cps.trade_escrow where offer_id = new_id) then
    raise exception 'Your offer needs tokens, tickets, store credit, packs, or cards.'; end if;


  perform cps.notify(l.lister, 'trade_new_offer',
    a.display_name || ' made an offer on your Trading Post listing.', 'trading');

  return jsonb_build_object('ok', true, 'id', new_id);
end $m229$;

create or replace function cps.trade_refund_offer(p_offer uuid)
  returns void language plpgsql set search_path = cps, pg_temp as $m229$
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

  if o.tokens > 0 or o.tickets > 0 or o.credit > 0 then
    update cps.accounts
      set game_tokens = game_tokens + o.tokens,
          spins = spins + o.tickets,
          store_credit = store_credit + o.credit
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
end $m229$;

create or replace function public.cps_trade_accept(p_token text, p_listing uuid, p_offer uuid)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
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
  if o.credit > 0 then bits := bits || ('💵 $' || o.credit || ' store credit'); end if;
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
  if o.tokens > 0 or o.tickets > 0 or o.credit > 0 then
    update cps.accounts
      set game_tokens = game_tokens + o.tokens,
          spins = spins + o.tickets,
          store_credit = store_credit + o.credit
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
    'game_tokens', (select game_tokens from cps.accounts where id = a.id),
    'store_credit', (select store_credit from cps.accounts where id = a.id));
end $m229$;

create or replace function public.cps_trading_post(p_token text)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
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
        'tokens', o.tokens, 'tickets', o.tickets, 'credit', o.credit,
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
end $m229$;

create or replace function public.cps_exchange_history(p_token text, p_other uuid)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m229$
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
              then 'Give: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id), b.offer_credit)
                || ' · Get: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
              else 'Give: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
                || ' · Get: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id), b.offer_credit)
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
end $m229$;

notify pgrst, 'reload schema';
