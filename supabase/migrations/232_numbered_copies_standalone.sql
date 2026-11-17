-- 232: Numbered copies are their own items
-- A pinned (numbered variant) copy no longer needs a base copy behind
-- it to trade, gift, or be offered: pulls never grant a base copy for
-- a variant (it lives only in cps.variants), and the auto turn-in
-- flag on receipt (cps.auto_turn_in, via='numbered') consumes none.
-- 1) cps.trade_check_side: pinned entries are validated solely as
--    exact copies (held, unvaulted, uncommitted); the base-slot loop
--    for all-pinned cards is removed, and plain-copy checks no longer
--    count pinned entries or held variants against the base pools.
-- 2) cps_respond_trade: the accept-time verification mirrors (1).
-- 3) cps.transfer_pinned_variant: settlement moves the variant row
--    alone; the base-copy drag via transfer_card is removed. The
--    receiver's auto_turn_in flag is unchanged.
-- Bodies rebuilt from the live definitions (md5-verified 2026-11-17).

create or replace function cps.trade_check_side(p_owner uuid, p_items jsonb, p_pack_set text, p_packs integer, p_tokens integer, p_tickets integer, p_label text, p_credit integer default 0)
  returns void language plpgsql set search_path = cps, pg_temp as $m232$
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
           sum(case when t.holo then 0 else 1 end)::int as plain_qty
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
    if not found or c.count - c.vaulted_count < r.holo_qty + r.plain_qty
       or c.holo_count - c.vaulted_holo < r.holo_qty
       or (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < r.plain_qty then
      raise exception 'Not enough copies for a card in the % list.', p_label;
    end if;
  end loop;
  -- 232: cards whose entries are all pinned need nothing here -- a
  -- numbered copy is its own item, validated solely by the exact-copy
  -- loop above (held, unvaulted, uncommitted). No base slot is asked.
end $m232$;

create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
  returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $m232$
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
    select g.giver, g.set_id, g.card_id, g.holo, sum(g.qty)::int as qty
    from (select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
                 i.set_id, i.card_id, i.holo, i.qty
          from cps.trade_offer_items i where i.offer_id = o.id and i.tier = '') g
    group by 1, 2, 3, 4 order by 1, 2, 3, 4
  loop
    select * into c from cps.collection
      where account_id = r.giver and set_id = r.set_id and card_id = r.card_id for update;
    if not found or c.count - c.vaulted_count < r.qty
       or (r.holo and c.holo_count - c.vaulted_holo < r.qty)
       or (not r.holo and (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < r.qty) then
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
end $m232$;

create or replace function cps.transfer_pinned_variant(p_from uuid, p_to uuid, p_set text, p_card text, p_tier text, p_serial integer, p_ref text default null)
  returns void language plpgsql set search_path = cps, pg_temp as $m232$
begin
  -- 232: a numbered copy is its own item -- it moves alone, with no
  -- base copy dragged along. The receiver's base-card completion
  -- flag is still settled by the auto_turn_in below.
  update cps.variants v set account_id = p_to
   where v.account_id = p_from and v.set_id = p_set and v.card_id = p_card
     and v.tier = p_tier and v.serial = p_serial and not v.vaulted;
  if not found then raise exception 'The numbered copy is no longer available.'; end if;
  perform cps.auto_turn_in(p_to, p_set, p_card);
end $m232$;
