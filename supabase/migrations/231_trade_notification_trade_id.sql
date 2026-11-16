-- 231: Trade notifications carry their trade id
-- Clicking a direct-trade notification in the bell should open that exact
-- trade. Today trade_offer rows carry no meta and target_view 'trading',
-- which the client aliases to the Market (Trading Post) view.
-- 1) cps.notify gains a 5-arg overload that also writes meta (the 4-arg
--    original is untouched; every other caller keeps using it).
-- 2) cps_propose_trade stamps meta {trade_id} on the trade_offer
--    notification and targets 'players' (the fallback landing).
-- 3) cps_respond_trade stamps meta {trade_id} on trade_accepted /
--    trade_declined (their view is already 'players').
-- Trading Post notifications (trade_won, trade_new_offer, ...) are
-- unchanged: Market is the right landing for them, and their
-- 'trade_accepted' summary rows carry no trade_id, so the client can
-- tell the two systems' rows apart by meta alone.
-- Bodies rebuilt from the live definitions (md5-verified 2026-11-16).

create or replace function cps.notify(p_account uuid, p_kind text, p_text text, p_view text, p_meta jsonb)
  returns void language sql set search_path = cps, pg_temp as $m231$
  insert into cps.notifications (account_id, kind, text, target_view, meta)
  values (p_account, p_kind, p_text, p_view, p_meta);
$m231$;

create or replace function public.cps_propose_trade(p_token text, p_to uuid, p_offer jsonb, p_want jsonb)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m231$
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

  -- Notify the recipient (231: meta carries the offer id so the bell can
  -- open this exact trade in a pop-up; 'players' is the fallback landing)
  perform cps.notify(tgt.id, 'trade_offer',
    a.display_name || ' sent you a trade offer.', 'players',
    jsonb_build_object('trade_id', new_id));

  return jsonb_build_object('id', new_id);
end $m231$;

create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m231$
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
    perform cps.notify(o.from_account, 'trade_declined', a.display_name || ' declined your trade', 'players', jsonb_build_object('trade_id', o.id));
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
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players', jsonb_build_object('trade_id', o.id));
  return jsonb_build_object('status', 'accepted');
end $m231$;
