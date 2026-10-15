-- =====================================================================
-- 154_trade_numbered_copies.sql -- Direct trades: numbered copies are
-- chosen explicitly, never dragged along. Run AFTER 153.
--
-- Franklin's ask (2026-10-15): "Trading should have a selection just
-- for numbered cards, rather than selecting the base card and it just
-- happens to be the numbered card." Until now, offering a base card
-- silently attached the giver's LOWEST-serial unvaulted numbered copy
-- (transfer_card's variant travel), and there was no way to offer the
-- plain copy alone or to choose a specific serial -- on either side.
--
-- What changes:
--   * cps.trade_offer_items gains tier/serial ('' / 0 = fungible),
--     the same widening 151 gave bounty escrow.
--   * Items may now pin a specific copy: {set, card, tier, serial}.
--     cps.trade_check_side (base: 108) validates each pinned copy
--     (held by the side's owner, unvaulted, not committed to a
--     Trading Post listing/offer or an open bounty via
--     cps.trade_variant_escrowed, not listed twice, never holo) and
--     does the pool math with variant copies accounted: following
--     151's bounty model, EVERY on-hand numbered copy of a card
--     occupies a plain (non-holo) slot, so fungible plain picks must
--     be backed by non-numbered copies. With no pinned items and no
--     variants held, the checks reduce exactly to 108's.
--   * cps.trade_insert_items (base: 011) stores tier/serial, grouped
--     per distinct copy. cps_propose_trade itself is NOT rebuilt --
--     it already routes through check_side + insert_items.
--   * cps_respond_trade (base: 108) verifies pinned copies one by
--     one at accept time, then moves fungible lines with
--     move_variants := FALSE (plain means plain now) and pinned
--     lines via the new cps.transfer_pinned_variant (base slot with
--     no variant travel + the exact variants row + auto-turn-in for
--     the receiver, mirroring transfer_card's variant block). If a
--     pinned copy moved first, the accept fails cleanly and the
--     offer is marked expired -- never a substituted copy. Direct
--     trades still do not escrow while pending.
--   * cps_list_trades (base: 062) items gain tier/serial.
--   * NEW public.cps_list_player_variants -- another player's
--     numbered copies (the trade builder's step 2), same shape as
--     cps_list_variants plus an 'escrowed' flag. Ownership of
--     numbered copies is already public via the variant census.
--
-- Known limitation (shared with the bounty board since 151): a
-- numbered copy whose pack slot was holo sits in the holo pool in
-- collection accounting, while pinned copies are accounted against
-- the plain pool -- such a copy (a holo pull that also won the
-- variant lottery, ~1-in-thousands) cannot be pinned into a trade.
-- =====================================================================

alter table cps.trade_offer_items add column if not exists tier text not null default '';
alter table cps.trade_offer_items add column if not exists serial int not null default 0;

-- --- helper: move one specific numbered copy ---------------------
create or replace function cps.transfer_pinned_variant(p_from uuid, p_to uuid, p_set text, p_card text, p_tier text, p_serial int, p_ref text default null)
returns void language plpgsql set search_path = cps, pg_temp as $$
begin
  perform cps.transfer_card(p_from, p_to, p_set, p_card, false, 1, p_ref, false);
  update cps.variants v set account_id = p_to
   where v.account_id = p_from and v.set_id = p_set and v.card_id = p_card
     and v.tier = p_tier and v.serial = p_serial and not v.vaulted;
  if not found then raise exception 'The numbered copy is no longer available.'; end if;
  perform cps.auto_turn_in(p_to, p_set, p_card);
end $$;

-- --- trade_check_side (base: 108) --------------------------------
create or replace function cps.trade_check_side(p_owner uuid, p_items jsonb, p_label text)
returns void language plpgsql set search_path = cps, pg_temp as $$
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
  if total < 1 or total > 10 then
    raise exception '% must have between 1 and 10 cards.', p_label;
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
end $$;

-- --- trade_insert_items (base: 011) ------------------------------
create or replace function cps.trade_insert_items(p_offer uuid, p_side text, p_items jsonb)
returns void language sql set search_path = cps, pg_temp as $$
  insert into cps.trade_offer_items (offer_id, side, set_id, card_id, holo, qty, tier, serial)
  select p_offer, p_side, t.set_id, t.card_id, t.holo, count(*)::int, t.tier, t.serial
  from (select j->>'set' as set_id, j->>'card' as card_id,
               coalesce((j->>'holo')::boolean, false) as holo,
               coalesce(j->>'tier', '') as tier,
               case when coalesce(j->>'tier', '') = '' then 0
                    else coalesce((j->>'serial')::int, 0) end as serial
        from jsonb_array_elements(p_items) j) t
  group by t.set_id, t.card_id, t.holo, t.tier, t.serial;
$$;

-- --- respond_trade (base: 108) -----------------------------------
create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  r   record;
  c   cps.collection%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.to_account <> a.id then raise exception 'This offer is not for you.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  if o.expires_at < now() then
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    raise exception 'This offer has expired.';
  end if;

  if not p_accept then
    update cps.trade_offers set status = 'declined', decided_at = now() where id = o.id;
    perform cps.notify(o.from_account, 'trade_declined', a.display_name || ' declined your trade', 'players');
    return jsonb_build_object('status', 'declined');
  end if;

  -- verify every line first (deterministic lock order: no deadlocks), then move cards
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

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  perform cps.quest_bump(o.from_account, 'trade_done', 1);
  perform cps.quest_bump(o.to_account, 'trade_done', 1);
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $$;
-- --- list_trades (base: 062) --------------------------------------
create or replace function public.cps_list_trades(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  -- lazy expiry
  update cps.trade_offers set status = 'expired', decided_at = now()
    where status = 'pending' and expires_at < now();
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
      'status', o.status,
      'created_at', o.created_at, 'decided_at', o.decided_at, 'expires_at', o.expires_at)
    order by (o.status = 'pending') desc, coalesce(o.decided_at, o.created_at) desc)
    from cps.trade_offers o
    join cps.accounts f on f.id = o.from_account
    join cps.accounts t on t.id = o.to_account
    where (o.from_account = a.id or o.to_account = a.id)
      and o.created_at > now() - interval '30 days'), '[]');
end $$;
-- --- list_player_variants (new; shape mirrors 108's list_variants) --
create or replace function public.cps_list_player_variants(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', v.id, 'set_id', v.set_id, 'set_name', s.name,
      'card_id', v.card_id, 'card_name', k.name, 'rarity', k.rarity,
      'tier', v.tier, 'serial', v.serial, 'pulled_at', v.pulled_at, 'vaulted', v.vaulted,
      'escrowed', cps.trade_variant_escrowed(v.set_id, v.card_id, v.tier, v.serial))
      order by v.pulled_at desc)
    from cps.variants v
    join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
    join cps.card_sets s on s.id = v.set_id
    where v.account_id = p_account
  ), '[]');
end $$;

grant execute on function public.cps_list_player_variants(text, uuid) to anon;
notify pgrst, 'reload schema';
