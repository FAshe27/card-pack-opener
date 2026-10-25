-- 180_trade_packs.sql
-- Direct player-to-player trades gain pack bundles, Market-style:
-- each side may add ONE pack bundle (one set + a quantity) alongside
-- its 0-10 cards, and a side may be packs-only. The sender's offered
-- packs are ESCROWED at propose time (Franklin's choice, 2026-10-24):
-- they leave the sender's inventory and are delivered to the recipient
-- on accept, or refunded on decline / cancel / expiry. The recipient's
-- packs cannot be taken before they accept, so they are balance-checked
-- at propose time and again under lock at accept time; if they are gone
-- by then, the accept fails cleanly, the sender is refunded, and the
-- offer closes as expired (returned to the client as 'unavailable'
-- rather than raised, so the refund is not rolled back).
-- Jumbled packs are excluded, matching the Bounty Board fence.
-- cps_get_profile also gains pack_inventory (per-set unopened counts,
-- Jumbled excluded) so the trade builder can show what a partner holds.
-- Rebuilt functions are based on their live bodies as of 2026-10-24
-- (propose = 102, trade_check_side/respond = 108-lineage + 154,
-- list_trades = 062-lineage, cancel/get_profile current); every change
-- is marked with a 180 comment.
-- Rollback: drop the five added columns and restore the prior bodies
-- of the six rebuilt functions from their defining migrations.

ALTER TABLE cps.trade_offers
  ADD COLUMN IF NOT EXISTS offer_pack_set text,
  ADD COLUMN IF NOT EXISTS offer_packs integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS want_pack_set text,
  ADD COLUMN IF NOT EXISTS want_packs integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS offer_packs_refunded boolean NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS cps.trade_check_side(uuid, jsonb, text);

CREATE OR REPLACE FUNCTION cps.trade_check_side(p_owner uuid, p_items jsonb, p_pack_set text, p_packs integer, p_label text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
  if total < 1 and coalesce(p_packs, 0) < 1 then
    raise exception '% must include at least one card or a pack bundle.', p_label;
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
end $function$
;

CREATE OR REPLACE FUNCTION cps.trade_refund_offer_packs(p_offer uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare o cps.trade_offers%rowtype;
begin
  select * into o from cps.trade_offers where id = p_offer;
  if not found or o.offer_packs <= 0 or o.offer_packs_refunded then return; end if;
  update cps.trade_offers set offer_packs_refunded = true where id = o.id;
  perform cps.add_packs(o.from_account, o.offer_pack_set, o.offer_packs,
                        'direct_trade_refund', o.id::text, null);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_propose_trade(p_token text, p_to uuid, p_offer jsonb, p_want jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a      cps.accounts%rowtype;
  tgt    cps.accounts%rowtype;
  new_id uuid;
  ocards jsonb; wcards jsonb;
  ops    text;  opk int;
  wps    text;  wpk int;
  vheld  int;
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

  perform cps.trade_check_side(a.id, ocards, ops, opk, 'Your offer');
  perform cps.trade_check_side(tgt.id, wcards, wps, wpk, 'Their side');

  if (select count(*) from cps.trade_offers
        where from_account = a.id and status = 'pending') >= 10 then
    raise exception 'You have too many pending offers (max 10).';
  end if;

  insert into cps.trade_offers (from_account, to_account,
      offer_pack_set, offer_packs, want_pack_set, want_packs)
    values (a.id, tgt.id, ops, opk, wps, wpk) returning id into new_id;
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

  -- Notify the recipient
  perform cps.notify(tgt.id, 'trade_offer',
    a.display_name || ' sent you a trade offer.', 'trading');

  return jsonb_build_object('id', new_id);
end $function$
;

CREATE OR REPLACE FUNCTION public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  r   record;
  c   cps.collection%rowtype;
  vheld int;
  vfail text;
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
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    return jsonb_build_object('status', 'unavailable', 'message', 'This offer has expired.');
  end if;

  if not p_accept then
    perform cps.trade_refund_offer_packs(o.id);
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
  exception when others then
    vfail := SQLERRM;
  end;
  if vfail is not null then
    perform cps.trade_refund_offer_packs(o.id);
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

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  perform cps.quest_bump(o.from_account, 'trade_done', 1);
  perform cps.quest_bump(o.to_account, 'trade_done', 1);
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $function$
;

CREATE OR REPLACE FUNCTION public.cps_cancel_trade(p_token text, p_offer uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a cps.accounts%rowtype;
  o cps.trade_offers%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.from_account <> a.id then raise exception 'Only the offerer can cancel.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  perform cps.trade_refund_offer_packs(o.id);
  update cps.trade_offers set status = 'cancelled', decided_at = now() where id = o.id;
  return jsonb_build_object('status', 'cancelled');
end $function$
;

CREATE OR REPLACE FUNCTION public.cps_list_trades(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
      'status', o.status,
      'created_at', o.created_at, 'decided_at', o.decided_at, 'expires_at', o.expires_at)
    order by (o.status = 'pending') desc, coalesce(o.decided_at, o.created_at) desc)
    from cps.trade_offers o
    join cps.accounts f on f.id = o.from_account
    join cps.accounts t on t.id = o.to_account
    where (o.from_account = a.id or o.to_account = a.id)
      and o.created_at > now() - interval '30 days'), '[]');
end $function$
;

CREATE OR REPLACE FUNCTION public.cps_get_profile(p_token text, p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a   cps.accounts%rowtype;
  tgt cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into tgt from cps.accounts where id = p_account and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  return jsonb_build_object(
    'id', tgt.id,
    'display_name', tgt.display_name,
    'is_me', tgt.id = a.id,
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', u.set_id,
                'card_id', u.card_id,
                'holo', coalesce((select c.holo_count > 0 from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), false),
                'v', coalesce((select c.vaulted_count from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), 0),
                'vh', coalesce((select c.vaulted_holo from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), 0))
              order by vo.position nulls last, u.set_id, u.card_id)
            from (select set_id, card_id from cps.collection where account_id = tgt.id and vaulted_count > 0
                  union
                  select set_id, card_id from cps.variants where account_id = tgt.id and vaulted) u
            left join cps.vault_order vo
              on vo.account_id = tgt.id and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'collection', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', c.set_id, 'card_id', c.card_id, 'n', c.count, 'h', c.holo_count, 'v', c.vaulted_count, 'vh', c.vaulted_holo,
                'variants', coalesce((select jsonb_agg(jsonb_build_object(
                                        'tier', v.tier, 'serial', v.serial, 'vaulted', v.vaulted)
                                      order by v.serial)
                                    from cps.variants v
                                    where v.account_id = tgt.id
                                      and v.set_id = c.set_id
                                      and v.card_id = c.card_id), '[]'))
              order by c.set_id, c.card_id)
            from cps.collection c where c.account_id = tgt.id and c.count > 0), '[]'),
    'pack_inventory', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', pi.set_id, 'packs', pi.packs) order by pi.set_id)
              from cps.pack_inventory pi
              where pi.account_id = tgt.id and pi.packs > 0 and pi.set_id <> 'jumbled'), '[]'),
    'sets', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', s.id,
                'set_name', s.name,
                'unique', (select count(*) from (
                            select card_id from cps.collection c
                             where c.account_id = tgt.id and c.set_id = s.id and c.count > 0
                            union
                            select card_id from cps.turn_ins t
                             where t.account_id = tgt.id and t.set_id = s.id) u),
                'total', (select count(*) from cps.cards k where k.set_id = s.id),
                'turned', (select count(*) from cps.turn_ins t where t.account_id = tgt.id and t.set_id = s.id))
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $function$
;

NOTIFY pgrst, 'reload schema';
