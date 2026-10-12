-- =====================================================================
-- 108_turn_ins_vault.sql — permanent turn-ins + the Vault (favorites v2)
-- Design locked with Franklin 2026-10-12 (~/workspace/turn-in-vault/SPEC.md).
-- Run after 106 (and after 107 if you ran it — unrelated). One file.
--
-- TURN-INS: turning in a copy destroys it and permanently flags the card
--   as collected for that player (cps.turn_ins). Completion everywhere
--   becomes owned UNION turned-in, so turning in can never lower it.
--   Numbered variants can NEVER be turned in; instead, ACQUIRING one
--   (pack pull, gift, any trade) auto-flags the base card (via='numbered').
-- THE VAULT: favorites are redefined as per-copy protection. Vaulted
--   copies stay in cps.collection.count but are invisible to every
--   consumer: trades, Trading Post, bounties, gifts, dupe sales and
--   turn-ins all operate on ON-HAND copies only:
--     on-hand total  = count - vaulted_count
--     on-hand holo   = holo_count - vaulted_holo
--     on-hand plain  = (count - holo_count) - (vaulted_count - vaulted_holo)
--   Numbered variants vault per serial (cps.variants.vaulted).
--   The old 20-favorite cap is GONE. Profile favorite ordering survives
--   via cps.vault_order. cps.favorites is converted, then dropped.
-- CLIENT NOTES: state collection tuples gain [4]=vaulted_count,
--   [5]=vaulted_holo; state 'favorites' now lists VAULTED cards (same
--   [set, card] shape); new state key 'turn_ins' = [set, card] pairs;
--   cps_list_variants items gain 'vaulted'.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Part A — schema
-- ---------------------------------------------------------------------
alter table cps.collection add column if not exists vaulted_count int not null default 0;
alter table cps.collection add column if not exists vaulted_holo  int not null default 0;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'collection_vault_chk') then
    alter table cps.collection add constraint collection_vault_chk
      check (vaulted_count >= 0 and vaulted_holo >= 0
             and vaulted_holo <= vaulted_count and vaulted_count <= count);
  end if;
end $$;

alter table cps.variants add column if not exists vaulted boolean not null default false;

create table if not exists cps.turn_ins (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id     text not null,
  card_id    text not null,
  via        text not null default 'manual' check (via in ('manual', 'bulk', 'numbered')),
  holo       boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (account_id, set_id, card_id),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);

-- profile showcase ordering for vaulted cards (successor to favorites.position)
create table if not exists cps.vault_order (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id     text not null,
  card_id    text not null,
  position   int,
  primary key (account_id, set_id, card_id)
);

-- ---------------------------------------------------------------------
-- Part B — helper: acquiring a numbered variant turns in the base card
-- ---------------------------------------------------------------------
create or replace function cps.auto_turn_in(p_account uuid, p_set text, p_card text)
returns void language sql set search_path = cps, pg_temp as $$
  insert into cps.turn_ins (account_id, set_id, card_id, via)
  values (p_account, p_set, p_card, 'numbered')
  on conflict do nothing;
$$;


-- ---------------------------------------------------------------------
-- Part C — new RPCs: turn-ins + vault management
-- ---------------------------------------------------------------------
create or replace function public.cps_turn_in(p_token text, p_set text, p_card text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a    cps.accounts%rowtype;
  c    cps.collection%rowtype;
  vn   int;
  avail int;
  plain_avail int;
  took_holo boolean := false;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.cards where set_id = p_set and card_id = p_card) then
    raise exception 'Card not found.';
  end if;
  if exists (select 1 from cps.turn_ins where account_id = a.id and set_id = p_set and card_id = p_card) then
    raise exception 'This card is already turned in — that''s forever.';
  end if;
  select * into c from cps.collection
    where account_id = a.id and set_id = p_set and card_id = p_card for update;
  if not found then raise exception 'You don''t own this card.'; end if;
  select count(*) into vn from cps.variants
    where account_id = a.id and set_id = p_set and card_id = p_card;
  avail := c.count - c.vaulted_count - vn;
  if avail < 1 then
    raise exception 'No turn-in-able copy on hand — numbered and vaulted copies can''t be turned in.';
  end if;
  plain_avail := (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo);
  if plain_avail >= 1 then
    update cps.collection set count = count - 1
      where account_id = a.id and set_id = p_set and card_id = p_card;
  else
    update cps.collection set count = count - 1, holo_count = holo_count - 1
      where account_id = a.id and set_id = p_set and card_id = p_card;
    took_holo := true;
  end if;
  insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
    values (a.id, p_set, p_card, 'manual', took_holo);
  return jsonb_build_object('ok', true, 'holo', took_holo);
end $$;

create or replace function public.cps_turn_in_all(p_token text, p_set text, p_include_holos boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a    cps.accounts%rowtype;
  rec  record;
  c2   cps.collection%rowtype;
  vn   int;
  avail int;
  plain_avail int;
  turned int := 0;
  skipped_holo int := 0;
  skipped_locked int := 0;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.card_sets where id = p_set) then
    raise exception 'That set is not on the server yet.';
  end if;
  for rec in
    select c.set_id, c.card_id, c.count, c.holo_count, c.vaulted_count, c.vaulted_holo
      from cps.collection c
     where c.account_id = a.id and c.set_id = p_set and c.count > 0
       and not exists (select 1 from cps.turn_ins t
                        where t.account_id = a.id and t.set_id = c.set_id and t.card_id = c.card_id)
     order by c.card_id
  loop
    select * into c2 from cps.collection
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id for update;
    if not found then continue; end if;
    rec.count := c2.count; rec.holo_count := c2.holo_count;
    rec.vaulted_count := c2.vaulted_count; rec.vaulted_holo := c2.vaulted_holo;
    select count(*) into vn from cps.variants
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    avail := rec.count - rec.vaulted_count - vn;
    if avail < 1 then
      skipped_locked := skipped_locked + 1;
    else
      plain_avail := (rec.count - rec.holo_count) - (rec.vaulted_count - rec.vaulted_holo);
      if plain_avail >= 1 then
        update cps.collection set count = count - 1
          where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
        insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
          values (a.id, rec.set_id, rec.card_id, 'bulk', false);
        turned := turned + 1;
      elsif coalesce(p_include_holos, false) then
        update cps.collection set count = count - 1, holo_count = holo_count - 1
          where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
        insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
          values (a.id, rec.set_id, rec.card_id, 'bulk', true);
        turned := turned + 1;
      else
        skipped_holo := skipped_holo + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked);
end $$;

create or replace function public.cps_vault_copy(p_token text, p_set text, p_card text, p_holo boolean, p_on boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  c cps.collection%rowtype;
begin
  a := cps.auth(p_token);
  select * into c from cps.collection
    where account_id = a.id and set_id = p_set and card_id = p_card for update;
  if not found then raise exception 'You don''t own this card.'; end if;
  if p_on then
    if coalesce(p_holo, false) then
      if c.holo_count - c.vaulted_holo < 1 then raise exception 'No holo copy on hand to vault.'; end if;
      update cps.collection set vaulted_count = vaulted_count + 1, vaulted_holo = vaulted_holo + 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    else
      if (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) < 1 then
        raise exception 'No plain copy on hand to vault.';
      end if;
      update cps.collection set vaulted_count = vaulted_count + 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    end if;
    insert into cps.vault_order (account_id, set_id, card_id, position)
      values (a.id, p_set, p_card,
              (select coalesce(max(position), -1) + 1 from cps.vault_order where account_id = a.id))
      on conflict do nothing;
  else
    if coalesce(p_holo, false) then
      if c.vaulted_holo < 1 then raise exception 'No holo copy is vaulted.'; end if;
      update cps.collection set vaulted_count = vaulted_count - 1, vaulted_holo = vaulted_holo - 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    else
      if c.vaulted_count - c.vaulted_holo < 1 then raise exception 'No plain copy is vaulted.'; end if;
      update cps.collection set vaulted_count = vaulted_count - 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    end if;
  end if;
  select * into c from cps.collection
    where account_id = a.id and set_id = p_set and card_id = p_card;
  return jsonb_build_object('ok', true,
    'vaulted', c.vaulted_count, 'vaulted_holo', c.vaulted_holo);
end $$;

create or replace function public.cps_vault_variant(p_token text, p_variant_id uuid, p_on boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  v cps.variants%rowtype;
begin
  a := cps.auth(p_token);
  select * into v from cps.variants where id = p_variant_id and account_id = a.id for update;
  if not found then raise exception 'Variant not found.'; end if;
  update cps.variants set vaulted = coalesce(p_on, false) where id = p_variant_id;
  if coalesce(p_on, false) then
    insert into cps.vault_order (account_id, set_id, card_id, position)
      values (a.id, v.set_id, v.card_id,
              (select coalesce(max(position), -1) + 1 from cps.vault_order where account_id = a.id))
      on conflict do nothing;
  end if;
  return jsonb_build_object('ok', true, 'vaulted', coalesce(p_on, false));
end $$;

-- The heart, redefined: quick-vault / quick-release one copy (plain first,
-- then holo, then a numbered variant). No more 20-card cap.
create or replace function public.cps_toggle_favorite(p_token text, p_set text, p_card text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  c   cps.collection%rowtype;
  did boolean;
  n   int;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.cards where set_id = p_set and card_id = p_card) then
    raise exception 'Card not found.';
  end if;
  select * into c from cps.collection
    where account_id = a.id and set_id = p_set and card_id = p_card for update;
  if not found or c.count < 1 then
    raise exception 'You can only vault cards you own.';
  end if;
  if c.vaulted_count > 0 or exists (select 1 from cps.variants
        where account_id = a.id and set_id = p_set and card_id = p_card and vaulted) then
    -- release one: plain copy, then holo copy, then a numbered variant
    if c.vaulted_count - c.vaulted_holo > 0 then
      update cps.collection set vaulted_count = vaulted_count - 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    elsif c.vaulted_holo > 0 then
      update cps.collection set vaulted_count = vaulted_count - 1, vaulted_holo = vaulted_holo - 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    else
      update cps.variants set vaulted = false
        where id = (select id from cps.variants
                     where account_id = a.id and set_id = p_set and card_id = p_card and vaulted
                     order by serial limit 1);
    end if;
    did := false;
  else
    -- vault one: plain on-hand, then holo on-hand, then a numbered variant
    if (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) >= 1 then
      update cps.collection set vaulted_count = vaulted_count + 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    elsif c.holo_count - c.vaulted_holo >= 1 and c.count - c.vaulted_count >= 1 then
      update cps.collection set vaulted_count = vaulted_count + 1, vaulted_holo = vaulted_holo + 1
        where account_id = a.id and set_id = p_set and card_id = p_card;
    elsif exists (select 1 from cps.variants
            where account_id = a.id and set_id = p_set and card_id = p_card and not vaulted) then
      update cps.variants set vaulted = true
        where id = (select id from cps.variants
                     where account_id = a.id and set_id = p_set and card_id = p_card and not vaulted
                     order by serial limit 1);
    else
      raise exception 'No copy on hand to vault.';
    end if;
    insert into cps.vault_order (account_id, set_id, card_id, position)
      values (a.id, p_set, p_card,
              (select coalesce(max(position), -1) + 1 from cps.vault_order where account_id = a.id))
      on conflict do nothing;
    did := true;
  end if;
  select count(*) into n from (
    select set_id, card_id from cps.collection where account_id = a.id and vaulted_count > 0
    union
    select set_id, card_id from cps.variants where account_id = a.id and vaulted
  ) u;
  return jsonb_build_object('favorited', did, 'count', n);
end $$;


-- ---------------------------------------------------------------------
-- Part D — existing functions rebuilt vault-aware (latest bodies)
-- ---------------------------------------------------------------------

create or replace function cps.transfer_card(p_from uuid, p_to uuid, p_set text, p_card text, p_holo boolean, p_qty int, p_ref text default null, p_move_variants boolean default true)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare r cps.collection%rowtype;
begin
  if p_qty < 1 then raise exception 'qty must be positive'; end if;
  select * into r from cps.collection where account_id = p_from and set_id = p_set and card_id = p_card for update;
  if not found or r.count - r.vaulted_count < p_qty or (p_holo and r.holo_count - r.vaulted_holo < p_qty) or (not p_holo and (r.count - r.holo_count) - (r.vaulted_count - r.vaulted_holo) < p_qty) then
    raise exception 'Not enough copies to transfer';
  end if;
  update cps.collection set count = count - p_qty, holo_count = holo_count - case when p_holo then p_qty else 0 end
    where account_id = p_from and set_id = p_set and card_id = p_card;
  insert into cps.collection (account_id, set_id, card_id, count, holo_count)
    values (p_to, p_set, p_card, p_qty, case when p_holo then p_qty else 0 end)
    on conflict (account_id, set_id, card_id) do update
      set count = cps.collection.count + excluded.count, holo_count = cps.collection.holo_count + excluded.holo_count;
  insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
    values (p_from, p_to, p_set, p_card, p_holo, p_qty, p_ref);
  if p_move_variants then
    update cps.variants v set account_id = p_to
      where v.id in (
        select id from cps.variants
        where account_id = p_from and set_id = p_set and card_id = p_card and not vaulted
        order by serial limit (p_qty)
      );
    -- 108: acquiring a numbered variant turns in the base card for the receiver
    if found then perform cps.auto_turn_in(p_to, p_set, p_card); end if;
  end if;
end $$;

create or replace function cps.trade_check_side(p_owner uuid, p_items jsonb, p_label text)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  total int;
  r     record;
  c     cps.collection%rowtype;
begin
  if jsonb_typeof(p_items) <> 'array' then
    raise exception '% must be a list of cards.', p_label;
  end if;
  total := (select count(*) from jsonb_array_elements(p_items));
  if total < 1 or total > 10 then
    raise exception '% must have between 1 and 10 cards.', p_label;
  end if;
  for r in
    select t.set_id, t.card_id,
           sum(case when t.holo then 1 else 0 end)::int as holo_qty,
           sum(case when t.holo then 0 else 1 end)::int as plain_qty
    from (select j->>'set' as set_id, j->>'card' as card_id,
                 coalesce((j->>'holo')::boolean, false) as holo
          from jsonb_array_elements(p_items) j) t
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
end $$;

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
  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
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

  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           (case when i.side = 'offer' then o.to_account else o.from_account end) as receiver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
    group by 1, 2, 3, 4, 5 order by 1, 3, 4, 5
  loop
    perform cps.transfer_card(r.giver, r.receiver, r.set_id, r.card_id, r.holo, r.qty, o.id::text);
  end loop;

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  perform cps.quest_bump(o.from_account, 'trade_done', 1);
  perform cps.quest_bump(o.to_account, 'trade_done', 1);
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $$;

create or replace function public.cps_gift_card(p_token text, p_to uuid, p_set text, p_card text, p_holo boolean, p_variant_id uuid default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  tgt       cps.accounts%rowtype;
  card_name text;
  set_name  text;
  vtier     text;
  vserial   int;
  vvaulted  boolean;
  vlabel    text := '';
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot gift a card to yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  select k.name, s.name into card_name, set_name
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = p_set and k.card_id = p_card;
  if not found then raise exception 'Card not found.'; end if;
  if p_variant_id is not null then
    select vv.tier, vv.serial, vv.vaulted into vtier, vserial, vvaulted from cps.variants vv
      where vv.id = p_variant_id and vv.account_id = a.id and vv.set_id = p_set and vv.card_id = p_card;
    if not found then raise exception 'Variant not found.'; end if;
    if coalesce(vvaulted, false) then
      raise exception 'That numbered copy is in your Vault — release it before gifting it.';
    end if;
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
    update cps.variants set account_id = tgt.id where id = p_variant_id;
    perform cps.auto_turn_in(tgt.id, p_set, p_card);
  else
    -- a regular copy: variants stay put (the gift modal picks serials explicitly)
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
  end if;
  if vtier is not null then
    vlabel := ' ' || cps.variant_name(vtier) || ' #' || vserial || '/' || cps.variant_run(vtier);
  end if;
  perform cps.notify(tgt.id, 'gift_card',
    a.display_name || ' gifted you ' || card_name || vlabel || ' (' || set_name || ')' ||
    case when vlabel = '' and coalesce(p_holo, false) then ' ✦ holo' else '' end,
    'collection');
  perform cps.quest_bump(a.id, 'gift_card', 1);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cps_trade_dupes_credit(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  rars      text[];
  rate      int;
  total     int;
  trades    int;
  need      int;
  rec       record;
  credit_now int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 20;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 12;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 6;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 4;
  else raise exception 'Unknown trade tier.'; end if;

  -- Total tradable dupes across ALL sets: every copy beyond the first.
  -- Numbered variants are never tradable (they have no dupe value).
  select coalesce(sum(greatest((c.count - c.vaulted_count) - greatest(1, coalesce(v.n, 0)), 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    left join (select set_id, card_id, count(*) as n from cps.variants
               where account_id = a.id and not vaulted group by 1, 2) v
      on v.set_id = c.set_id and v.card_id = c.card_id
    where c.account_id = a.id
      and k.rarity = any (rars)
      and c.count > 0;

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per $1 credit.', rate;
  end if;

  -- Deduct dupes: non-holos first, always keep one copy.
  need := trades * rate;
  for rec in
    select c.set_id, c.card_id, c.count as n, c.holo_count as h, coalesce(v.n, 0) as v,
             c.vaulted_count as vc, c.vaulted_holo as vh
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      left join (select set_id, card_id, count(*) as n from cps.variants
                 where account_id = a.id and not vaulted group by 1, 2) v
        on v.set_id = c.set_id and v.card_id = c.card_id
      where c.account_id = a.id
        and k.rarity = any (rars)
        and (c.count - c.vaulted_count) > greatest(1, coalesce(v.n, 0))
      order by (c.count - coalesce(c.holo_count, 0)) desc, c.count desc
  loop
    exit when need <= 0;
    declare
      take_from_plain int;
      take_from_holo  int;
      keep_n          int := greatest(1, coalesce(rec.v, 0));
      n2              int := rec.n - rec.vc;              -- on-hand copies
      h2              int := coalesce(rec.h, 0) - rec.vh; -- on-hand holos
    begin
      -- keep keep_n copies (1 + variants); take from plain first, then holo
      take_from_plain := least(n2 - h2, need);
      take_from_plain := greatest(take_from_plain - (case when h2 = 0 then keep_n else 0 end), 0);
      need := need - take_from_plain;
      take_from_holo := 0;
      if need > 0 and h2 > 0 then
        take_from_holo := least(h2 - (case when n2 - h2 - take_from_plain = 0 then keep_n else 0 end), need);
        take_from_holo := greatest(take_from_holo, 0);
        need := need - take_from_holo;
      end if;
      update cps.collection
        set count = greatest(count - take_from_plain - take_from_holo, 0),
            holo_count = greatest(coalesce(holo_count, 0) - take_from_holo, 0)
        where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    end;
  end loop;

  -- Grant $1 Store Credit per trade
  update cps.accounts set store_credit = coalesce(store_credit, 0) + trades where id = a.id;
  select store_credit into credit_now from cps.accounts where id = a.id;

  -- Daily quest: 'Trade in duplicates' (dupe_trade)
  perform cps.quest_bump(a.id, 'dupe_trade', trades);

  return jsonb_build_object(
    'ok', true,
    'dupes_used', trades * rate,
    'credit', trades,
    'credit_now', credit_now
  );
end $$;

create or replace function public.cps_trade_dupes_tickets(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  rars       text[];
  rate       int;
  total      int;
  tickets    int;
  need       int;
  rec        record;
  take_total int;
  take_nh    int;
  take_h     int;
  keep_n     int;
  spins_now  int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 20;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 12;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 6;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 4;
  else raise exception 'Unknown trade tier.'; end if;

  -- tradable dupes across all sets (keep one copy; never take numbered variants)
  select coalesce(sum(greatest((c.count - c.vaulted_count) - greatest(1, coalesce(v.n, 0)), 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    left join (select set_id, card_id, count(*) as n from cps.variants
               where account_id = a.id and not vaulted group by 1, 2) v
      on v.set_id = c.set_id and v.card_id = c.card_id
    where c.account_id = a.id and k.rarity = any (rars) and c.count > 0;

  tickets := total / rate;
  if tickets < 1 then
    raise exception 'Not enough duplicate cards — you need % per spin ticket.', rate; end if;

  need := tickets * rate;
  -- deduct from the sets with the most dupes first
  for rec in
    select c.set_id, c.card_id, c.count as n, c.holo_count as h, coalesce(v.n, 0) as v,
             c.vaulted_count as vc, c.vaulted_holo as vh
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      left join (select set_id, card_id, count(*) as n from cps.variants
                 where account_id = a.id and not vaulted group by 1, 2) v
        on v.set_id = c.set_id and v.card_id = c.card_id
      where c.account_id = a.id and k.rarity = any (rars) and (c.count - c.vaulted_count) > 1
      order by ((c.count - c.vaulted_count) - greatest(1, coalesce(v.n, 0))) desc, c.set_id, c.card_id
  loop
    exit when need <= 0;
    -- numbered variant copies are never traded in: keep every one of them
    keep_n := least(rec.n - rec.vc, greatest(1, rec.v));
    take_total := least(need, greatest((rec.n - rec.vc) - keep_n, 0));
    take_nh := least(greatest((rec.n - rec.vc) - (rec.h - rec.vh), 0), take_total);
    take_h := take_total - take_nh;
    need := need - take_total;
    update cps.collection
       set count = rec.n - take_total,
           holo_count = rec.h - take_h
     where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
  end loop;

  perform cps.quest_bump(a.id, 'dupe_trade', 1);

  update cps.accounts set spins = spins + tickets where id = a.id returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason) values (a.id, tickets, 'dupe_tickets');

  return jsonb_build_object('ok', true, 'tier', p_tier,
    'tickets', tickets, 'dupes_used', tickets * rate, 'spins_now', spins_now);
end $$;

create or replace function public.cps_trade_post(p_token text, p_card jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  cset    text;
  ccard   text;
  cholo   boolean;
  ctier   text;
  cserial int;
  new_id  uuid := gen_random_uuid();
  vrar    text;
  vopen   int;
  c       cps.collection%rowtype;
begin
  a := cps.auth(p_token);

  cset    := p_card->>'set';
  ccard   := p_card->>'card';
  cholo   := coalesce((p_card->>'holo')::boolean, false);
  ctier   := nullif(p_card->>'tier', '');
  cserial := nullif(p_card->>'serial', '')::int;
  if cset is null or ccard is null then raise exception 'Pick a card to list.'; end if;
  select k.rarity into vrar from cps.cards k where k.set_id = cset and k.card_id = ccard;
  if not found then raise exception 'That card is not on the server.'; end if;

  if ctier is not null then
    if ctier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
    if vrar not in ('rare', 'epic', 'legendary', 'chase') then
      raise exception 'Numbered variants only exist for rare cards and up.'; end if;
    if cserial is null or cserial < 1 or cserial > cps.variant_run(ctier) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(ctier), cps.variant_name(ctier); end if;
    if not exists (select 1 from cps.variants
                   where account_id = a.id and set_id = cset and card_id = ccard
                     and tier = ctier and serial = cserial) then
      raise exception 'You don''t hold that numbered copy.'; end if;
    if exists (select 1 from cps.variants
               where account_id = a.id and set_id = cset and card_id = ccard
                 and tier = ctier and serial = cserial and vaulted) then
      raise exception 'That numbered copy is in your Vault — release it before listing it.';
    end if;
    if cps.trade_variant_escrowed(cset, ccard, ctier, cserial) then
      raise exception 'That numbered copy is already listed or offered.'; end if;
  elsif cserial is not null then
    raise exception 'A serial needs a variant tier.'; end if;

  select count(*) into vopen from cps.trade_listings where lister = a.id and status = 'open';
  if vopen >= 5 then raise exception 'You already have 5 open listings — accept or cancel one first.'; end if;

  -- escrow the card: one specific copy leaves the collection
  select * into c from cps.collection
    where account_id = a.id and set_id = cset and card_id = ccard for update;
  if not found or c.count - c.vaulted_count < 1 then raise exception 'You don''t hold that card (on hand).'; end if;
  if cholo and coalesce(c.holo_count, 0) - c.vaulted_holo < 1 then raise exception 'You don''t have a holo copy to list (on hand).'; end if;
  -- non-variant listings can't take a variant copy's base slot
  if ctier is null then
    declare vn int;
    begin
      select count(*) into vn from cps.variants
        where account_id = a.id and set_id = cset and card_id = ccard;
      if coalesce(c.count, 0) - c.vaulted_count - vn < 1 then
        raise exception 'Your only copies are numbered — list it as a numbered card instead.'; end if;
    end;
  end if;
  update cps.collection
    set count = count - 1,
        holo_count = case when cholo then holo_count - 1
                          else least(holo_count, count - 1) end
    where account_id = a.id and set_id = cset and card_id = ccard;
  insert into cps.trade_listings (id, lister, set_id, card_id, holo, variant_tier, variant_serial, note)
    values (new_id, a.id, cset, ccard, cholo, ctier, cserial, left(coalesce(p_note, ''), 140));

  insert into cps.trade_escrow (listing_id, offer_id, account_id, set_id, card_id, holo,
                               variant_tier, variant_serial, qty)
    values (new_id, null, a.id, cset, ccard, cholo, ctier, cserial, 1);

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

create or replace function public.cps_trade_offer(p_token text, p_listing uuid, p_offer jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  l        cps.trade_listings%rowtype;
  otokens  int;
  otickets int;
  opackset text;
  opacks   int;
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

  -- escrow packs
  if opacks > 0 then
    if opackset is null or not exists (select 1 from cps.card_sets where id = opackset) then
      raise exception 'Pick a set for the pack offer.'; end if;
    select packs into vinv from cps.pack_inventory where account_id = a.id and set_id = opackset for update;
    if coalesce(vinv, 0) < opacks then raise exception 'You don''t have that many packs.'; end if;
    perform cps.add_packs(a.id, opackset, -opacks, 'trade_escrow', new_id::text, null);
  end if;

  -- escrow cards (numbered serials allowed, picked explicitly)
  -- offer row first (escrow FKs reference it)
  insert into cps.listing_offers (id, listing_id, offerer, tokens, tickets, pack_set, packs,
                               cards, status)
    values (new_id, p_listing, a.id, otokens, otickets, opackset, opacks,
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
  if otokens = 0 and otickets = 0 and opacks = 0
     and not exists (select 1 from cps.trade_escrow where offer_id = new_id) then
    raise exception 'Your offer needs tokens, tickets, packs, or cards.'; end if;


  perform cps.notify(l.lister, 'trade_new_offer',
    a.display_name || ' made an offer on your Trading Post listing.', 'trading');

  return jsonb_build_object('ok', true, 'id', new_id);
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
  end loop;

  -- the offer must be *something*
  if otokens = 0 and otickets = 0 and opacks = 0
     and not exists (select 1 from cps.bounty_escrow where bounty_id = new_id) then
    raise exception 'Your bounty needs an offer — tokens, tickets, packs, or cards.'; end if;

  return jsonb_build_object('ok', true, 'id', new_id);
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

create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text; chase_e record;
        vletter text;
        ins_kind text;
        -- jumbled additions
        is_jumbled boolean; is_hero boolean; hero_forced boolean; active_sets text[]; rset text; rs cps.card_sets%rowtype; slot_odds jsonb;
        vset text; set_rec record; set_n int; set_h int; set_byr jsonb; set_best jsonb; set_bscore int;
        set_st cps.user_set_stats%rowtype; card_rec record; cscore int;
begin
  a := cps.auth(p_token);
  is_jumbled := (p_set = 'jumbled');
  hero_forced := not is_jumbled and coalesce(a.force_hero_packs, 0) > 0;
  is_hero := hero_forced or (not is_jumbled and cps.rand01() < 0.01);

  if is_jumbled then
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = 'jumbled' for update;
    if coalesce(inv, 0) < 1 then raise exception 'No Jumbled Mess packs left.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = 'jumbled' returning packs into inv;
    select coalesce(array_agg(id order by id), '{}') into active_sets from cps.card_sets where active and id <> 'jumbled' and not coalesce(exclude_from_jumbled, false);
    if coalesce(array_length(active_sets, 1), 0) = 0 then raise exception 'No sets available for Jumbled Mess.'; end if;
  else
    select * into s from cps.card_sets where id = p_set and active;
    if not found then raise exception 'This set is not available online yet.'; end if;
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = p_set for update;
    if coalesce(inv, 0) < 1 then raise exception 'No packs left for this set.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = p_set returning packs into inv;

    select * into st from cps.user_set_stats where account_id = a.id and set_id = p_set for update;
    best_score := case when st.best is null then -1
                       else cps.rarity_rank((select rarity from cps.cards where set_id = p_set and card_id = st.best->>'id')) * 10
                            + case when (st.best->>'holo')::boolean then 5 else 0 end end;
    best_score := coalesce(best_score, -1);
  end if;

  -- Card loop. For jumbled we synthesize a 5-card slot list; each card then
  -- picks its own random set and uses that set's odds/holo rates.
  for slot in select value from jsonb_array_elements(
               case when is_jumbled
                    then '[{"count":5,"odds":{"common":1}}]'::jsonb
                    else s.pack->'slots' end) loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      if is_jumbled then
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        select * into rs from cps.card_sets where id = rset;
        -- Jumbled Mess: guaranteed uncommon or better (it's a special pack!).
        -- First 4 cards use boosted wild odds (no commons); 5th uses the set's
        -- "rare or better" slot.
        if i <= 4 then
          slot_odds := '{"uncommon": 62, "rare": 26, "epic": 10, "legendary": 2}'::jsonb;
        else
          slot_odds := coalesce(rs.pack->'slots'->3->'odds',
                                '{"rare": 81.8, "epic": 14, "legendary": 4, "chase": 0.2}'::jsonb);
        end if;
      else
        rset := p_set;
        rs := s;
        if is_hero then
          slot_odds := '{"uncommon": 0.20, "rare": 0.40, "epic": 0.25, "legendary": 0.12, "chase": 0.03}'::jsonb;
        else
          slot_odds := slot->'odds';
        end if;
      end if;

      x := cps.rand01(); acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot_odds) order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      select card_id into cid from cps.cards where set_id = rset and rarity = r and not ((rset || ':' || card_id) = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = rset and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', rset, r; end if;
      holo := cps.rand01() * 100 < coalesce((rs.pack->'holo'->>r)::float8, 0);
      picked := picked || (rset || ':' || cid);

      select count into prev_count from cps.collection where account_id = a.id and set_id = rset and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0;
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, rset, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      if not is_jumbled then
        sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
        if sc > best_score then
          best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
          best_changed := st.best is not null or best_changed;
        end if;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'set_id', rset, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  -- numbered variant lottery: 1% of packs; one random rare+ card becomes a variant
  -- (admins never mint variants — they can grant themselves packs)
  vserial := null;
  if not coalesce(a.is_admin, false) and cps.rand01() < 0.0085 then
    select array_agg(t.idx) into vidx from (
      select (row_number() over ()) - 1 as idx
      from jsonb_array_elements(out) e
      where e->>'rarity' in ('rare','epic','legendary','chase')
    ) t;
    if vidx is not null and coalesce(array_length(vidx, 1), 0) > 0 then
      vi := vidx[1 + floor(cps.rand01() * array_length(vidx, 1))::int];
      vcid := out->vi->>'id';
      vset := out->vi->>'set_id';
      vx := cps.rand01();
      vtier := case when vx < 0.70 then 'rainbow' when vx < 0.90 then 'prism' when vx < 0.98 then 'obsidian' else 'oneofone' end;
      vtiers := case vtier
        when 'rainbow' then array['rainbow']
        when 'prism' then array['prism','rainbow']
        when 'obsidian' then array['obsidian','prism','rainbow']
        else array['oneofone','obsidian','prism','rainbow'] end;
      foreach vt in array vtiers loop
        vserial := cps.mint_variant(a.id, vset, vcid, vt);
        if vserial is not null then vtier := vt; exit; end if;
      end loop;
      if vserial is not null then
        perform cps.auto_turn_in(a.id, vset, vcid);
        out := (select jsonb_agg(case when t.rn = vi
            then t.e || jsonb_build_object('variant', vtier, 'serial', vserial)
            else t.e end order by t.rn)
          from (select e, (row_number() over ()) - 1 as rn from jsonb_array_elements(out) e) t);
        if vtier in ('prism','obsidian','oneofone','rainbow') then
          select kk.name into vcardname from cps.cards kk where kk.set_id = vset and kk.card_id = vcid;
          select ss.name into vtext from cps.card_sets ss where ss.id = vset;
          vtext := case vtier
            when 'oneofone' then '🌈 ' || a.display_name || ' pulled the One-of-One ' || vcardname || ' (' || vtext || ')!'
            when 'obsidian' then '🌈 ' || a.display_name || ' pulled Obsidian #' || vserial || '/5 ' || vcardname || ' (' || vtext || ')!'
            when 'rainbow' then '🌈 ' || a.display_name || ' pulled Rainbow #' || vserial || '/50 ' || vcardname || ' (' || vtext || ')!'
            else '🌈 ' || a.display_name || ' pulled Prism #' || vserial || '/10 ' || vcardname || ' (' || vtext || ')!'
          end;
          insert into cps.notifications (account_id, kind, text, target_view)
            select xx.id, 'variant_pull', vtext, 'collection'
            from cps.accounts xx where xx.id <> a.id and not xx.disabled;
        -- numbered variants qualify for Latest big pull
        insert into cps.big_pulls (account_id, set_id, card_id, rarity, variant_tier, variant_serial)
          values (a.id, vset, vcid,
                  (select kk.rarity from cps.cards kk where kk.set_id = vset and kk.card_id = vcid),
                  vtier, vserial);
        end if;
      end if;
    end if;
  end if;

  -- record big pulls: Chase cards only (Legendary no longer qualifies) + global chase announcements
  for chase_e in select e from jsonb_array_elements(out) e where e->>'rarity' = 'chase' loop
    insert into cps.big_pulls (account_id, set_id, card_id, rarity)
      values (a.id, chase_e.e->>'set_id', chase_e.e->>'id', 'chase');
    if chase_e.e->>'rarity' = 'chase' then
      select kk.name into vcardname from cps.cards kk where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      select ss.name into vtext from cps.card_sets ss where ss.id = chase_e.e->>'set_id';
      vtext := '🎯 ' || a.display_name || ' pulled ' || vcardname || ' (Chase · ' || vtext || ')!';
      insert into cps.notifications (account_id, kind, text, target_view)
        select xx.id, 'chase_pull', vtext, 'collection'
        from cps.accounts xx where xx.id <> a.id and not xx.disabled;
    end if;
  end loop;

  -- --- pack insert: 10% of packs roll the insert table. One card is
  -- replaced: a Common if the pack has one, else an Uncommon (Jumbled).
  -- Table (equal odds): spin ticket / $5 Store Credit / 5 Arcade Tokens.
  -- (admin force_ticket_next guarantees the ticket row, clears on success)
  ins_kind := null;
  if coalesce(a.force_ticket_next, false) or cps.rand01() < 0.10 then
    ins_kind := case when coalesce(a.force_ticket_next, false) then 'ticket'
      else (array['ticket', 'credit', 'tokens'])[1 + floor(cps.rand01() * 3)::int] end;
    select idx into vi from (
      select (row_number() over ()) - 1 as idx
      from jsonb_array_elements(out) e
      where not coalesce((e->>'ticket')::boolean, false)
        and (e->>'credit') is null
        and (e->>'tokens') is null
        and (e->>'rarity') in ('common', 'uncommon')
      order by case when (e->>'rarity') = 'common' then 0 else 1 end, random()
      limit 1
    ) t;
    if vi is not null then
      vcid := out->vi->>'id';
      vset := out->vi->>'set_id';
      -- undo the collection increment for the replaced card
      update cps.collection
      set count = greatest(count - 1, 0),
          holo_count = greatest(holo_count - case when coalesce((out->vi->>'holo')::boolean, false) then 1 else 0 end, 0)
      where account_id = a.id and set_id = vset and card_id = vcid;
      -- adjust rarity counts
      by_r := jsonb_set(by_r, array[out->vi->>'rarity'], to_jsonb(greatest(coalesce((by_r->>(out->vi->>'rarity'))::int, 1) - 1, 0)));
      if coalesce((out->vi->>'holo')::boolean, false) then n_holo := n_holo - 1; end if;
      if ins_kind = 'ticket' then
        out := jsonb_set(out, array[vi::text], '{"ticket": true}'::jsonb);
        update cps.accounts set spins = spins + 1 where id = a.id;
        insert into cps.spin_grants (account_id, spins, reason) values (a.id, 1, 'pack_jackpot');
        perform cps.quest_bump(a.id, 'pull_spin_ticket', 1);
        -- clear the force flag (only on success)
        update cps.accounts set force_ticket_next = false where id = a.id;
      elsif ins_kind = 'credit' then
        out := jsonb_set(out, array[vi::text], '{"credit": 5}'::jsonb);
        update cps.accounts set store_credit = coalesce(store_credit, 0) + 5 where id = a.id;
      else
        out := jsonb_set(out, array[vi::text], '{"tokens": 5}'::jsonb);
        update cps.accounts set game_tokens = coalesce(game_tokens, 0) + 5 where id = a.id;
        perform cps.quest_bump(a.id, 'pull_token_slip', 1);
      end if;
    end if;
  end if;

  -- daily quest bumps
  perform cps.quest_bump(a.id, 'open_packs', 1);
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
      perform cps.quest_bump(a.id, 'open_packs_set', 1, set_rec.sid);
    end loop;
  else
    perform cps.quest_bump(a.id, 'open_packs_set', 1, p_set);
  end if;
  if n_holo > 0 then
    perform cps.quest_bump(a.id, 'pull_holo', n_holo);
    perform cps.quest_bump(a.id, 'pull_holos_3', n_holo);
  end if;
  perform cps.quest_bump(a.id, 'pull_rare_plus',
    coalesce((by_r->>'rare')::int, 0) + coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_epic_plus',
    coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_legendary_plus',
    coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_chase', coalesce((by_r->>'chase')::int, 0));
  if vserial is not null then perform cps.quest_bump(a.id, 'pull_variant', 1); end if;

  -- --- 6 new daily quests -------------------------------------------------
  -- open_jumbled
  if is_jumbled then perform cps.quest_bump(a.id, 'open_jumbled', 1); end if;
  -- pull_dupe, pull_holo_common, pull_letter (per-card)
  select q.meta->>'letter' into vletter
  from cps.daily_quests q
  where q.account_id = a.id
    and q.day = (now() at time zone 'America/Chicago')::date
    and q.quest_key = 'pull_letter';
  for chase_e in select e from jsonb_array_elements(out) e loop
    if not coalesce((chase_e.e->>'new')::boolean, true) then
      perform cps.quest_bump(a.id, 'pull_dupe', 1);
    end if;
    if chase_e.e->>'rarity' = 'common' and coalesce((chase_e.e->>'holo')::boolean, false) then
      perform cps.quest_bump(a.id, 'pull_holo_common', 1);
    end if;
    if vletter is not null then
      select kk.name into vcardname from cps.cards kk
      where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      if vcardname ilike '%' || vletter || '%' then
        perform cps.quest_bump(a.id, 'pull_letter', 1);
      end if;
    end if;
  end loop;
  -- pull_2_holos_pack
  if n_holo >= 2 then perform cps.quest_bump(a.id, 'pull_2_holos_pack', 1); end if;
  -- pull_3_sets: track distinct home sets in meta
  for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
    update cps.daily_quests q
    set meta = jsonb_build_object('sets',
              (select coalesce(jsonb_agg(distinct sx), '[]'::jsonb)
               from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                     union select set_rec.sid as sx) sub)),
        progress = (select count(distinct sx)
                    from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                          union select set_rec.sid as sx) sub),
        done = (select count(distinct sx) >= 3
                from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                      union select set_rec.sid as sx) sub)
    where q.account_id = a.id
      and q.day = (now() at time zone 'America/Chicago')::date
      and q.quest_key = 'pull_3_sets'
      and q.claimed_at is null;
  end loop;

  -- per-set stats
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e loop
      select count(*), coalesce(sum(case when (e->>'holo')::boolean then 1 else 0 end), 0)
        into set_n, set_h
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid;
      select coalesce(jsonb_object_agg(rkey, rcount), '{}') into set_byr from (
        select e->>'rarity' as rkey, count(*) as rcount
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid group by 1) t;
      -- best card of this set in this pack
      select e into card_rec from jsonb_array_elements(out) e
        where e->>'set_id' = set_rec.sid
        order by cps.rarity_rank(e->>'rarity') * 10 + case when (e->>'holo')::boolean then 5 else 0 end desc
        limit 1;
      set_best := null;
      if card_rec.e is not null then
        select * into set_st from cps.user_set_stats where account_id = a.id and set_id = set_rec.sid for update;
        set_bscore := case when set_st.best is null then -1
          else cps.rarity_rank((select rarity from cps.cards where set_id = set_rec.sid and card_id = set_st.best->>'id')) * 10
               + case when (set_st.best->>'holo')::boolean then 5 else 0 end end;
        set_bscore := coalesce(set_bscore, -1);
        cscore := cps.rarity_rank(card_rec.e->>'rarity') * 10 + case when (card_rec.e->>'holo')::boolean then 5 else 0 end;
        if cscore > set_bscore then
          set_best := jsonb_build_object('id', card_rec.e->>'id', 'holo', (card_rec.e->>'holo')::boolean, 'at', now());
        end if;
      end if;
      insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
        values (a.id, set_rec.sid, 1, set_n, set_h, set_byr, set_best)
        on conflict (account_id, set_id) do update set
          opened = cps.user_set_stats.opened + 1,
          pulled = cps.user_set_stats.pulled + excluded.pulled,
          holos  = cps.user_set_stats.holos + excluded.holos,
          by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                        select key, sum(value::int) as total from (
                          select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                          union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
          best = coalesce(excluded.best, cps.user_set_stats.best);
    end loop;
  else
    insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
      values (a.id, p_set, 1, jsonb_array_length(out), n_holo, by_r, new_best)
      on conflict (account_id, set_id) do update set
        opened = cps.user_set_stats.opened + 1,
        pulled = cps.user_set_stats.pulled + excluded.pulled,
        holos  = cps.user_set_stats.holos + excluded.holos,
        by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                      select key, sum(value::int) as total from (
                        select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                        union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
        best = coalesce(excluded.best, cps.user_set_stats.best);
  end if;

  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'set_id', e->>'set_id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e where not coalesce((e->>'ticket')::boolean, false)));

  if hero_forced then
    update cps.accounts set force_hero_packs = force_hero_packs - 1 where id = a.id;
  end if;

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out, 'hero', is_hero,
    'best', case when is_jumbled then null
                else (select best from cps.user_set_stats where account_id = a.id and set_id = p_set) end,
    'new_best', (not is_jumbled) and best_changed and new_best is not null);
end $$;

create or replace function cps.state_json(p_account uuid) returns jsonb
language sql stable set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from cps.pack_openings o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config(),
    'favorites', coalesce((select jsonb_agg(jsonb_build_array(u.set_id, u.card_id) order by vo.position nulls last, u.set_id, u.card_id)
                           from (select set_id, card_id from cps.collection where account_id = p_account and vaulted_count > 0
                                 union
                                 select set_id, card_id from cps.variants where account_id = p_account and vaulted) u
                           left join cps.vault_order vo
                             on vo.account_id = p_account and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'turn_ins', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id) order by set_id, card_id)
                           from cps.turn_ins where account_id = p_account), '[]')
  )
$$;

create or replace function public.cps_list_players(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id,
      'display_name', x.display_name,
      'is_me', x.id = a.id,
      'favorites', (select count(*) from (
                      select set_id, card_id from cps.collection where account_id = x.id and vaulted_count > 0
                      union
                      select set_id, card_id from cps.variants where account_id = x.id and vaulted) u),
      'unique_cards', (select count(*) from (
                      select set_id, card_id from cps.collection where account_id = x.id and count > 0
                      union
                      select set_id, card_id from cps.turn_ins where account_id = x.id) u2)
    ) order by x.display_name)
    from cps.accounts x where not x.disabled and not x.is_admin), '[]');
end $$;

create or replace function public.cps_get_profile(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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
    'sets', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', s.id,
                'set_name', s.name,
                'unique', (select count(*) from (
                            select card_id from cps.collection c
                             where c.account_id = tgt.id and c.set_id = s.id and c.count > 0
                            union
                            select card_id from cps.turn_ins t
                             where t.account_id = tgt.id and t.set_id = s.id) u),
                'total', (select count(*) from cps.cards k where k.set_id = s.id))
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $$;

create or replace function public.cps_reorder_favorites(p_token text, p_order jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  it  jsonb;
  i   int := 0;
begin
  a := cps.auth(p_token);
  if jsonb_typeof(p_order) != 'array' then raise exception 'Order must be an array.'; end if;
  for it in select * from jsonb_array_elements(p_order) loop
    if not exists (select 1 from (
                     select set_id, card_id from cps.collection
                      where account_id = a.id and vaulted_count > 0
                     union
                     select set_id, card_id from cps.variants
                      where account_id = a.id and vaulted) u
                    where u.set_id = it ->> 'set_id'
                      and u.card_id = it ->> 'card_id') then
      raise exception 'Not a vaulted card: %', it ->> 'card_id';
    end if;
  end loop;
  for it in select * from jsonb_array_elements(p_order) loop
    insert into cps.vault_order (account_id, set_id, card_id, position)
      values (a.id, it ->> 'set_id', it ->> 'card_id', i)
      on conflict (account_id, set_id, card_id) do update set position = excluded.position;
    i := i + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', i);
end $$;

create or replace function public.cps_list_variants(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', v.id, 'set_id', v.set_id, 'set_name', s.name,
      'card_id', v.card_id, 'card_name', k.name, 'rarity', k.rarity,
      'tier', v.tier, 'serial', v.serial, 'pulled_at', v.pulled_at, 'vaulted', v.vaulted)
      order by v.pulled_at desc)
    from cps.variants v
    join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
    join cps.card_sets s on s.id = v.set_id
    where v.account_id = a.id
  ), '[]');
end $$;


-- ---------------------------------------------------------------------
-- Part E — conversions (run once, at the end, after all functions are in)
-- ---------------------------------------------------------------------
-- 1) showcase order carries over
insert into cps.vault_order (account_id, set_id, card_id, position)
  select account_id, set_id, card_id, position from cps.favorites
  on conflict do nothing;

-- 2) every favorited card gets one copy vaulted (holo preferred)
update cps.collection c
   set vaulted_count = c.vaulted_count + 1,
       vaulted_holo  = c.vaulted_holo + (case when c.holo_count > 0 then 1 else 0 end)
  from cps.favorites f
 where f.account_id = c.account_id and f.set_id = c.set_id and f.card_id = c.card_id
   and c.count > c.vaulted_count;

-- 3) owning a numbered variant turns the base card in (backfill)
insert into cps.turn_ins (account_id, set_id, card_id, via)
  select distinct account_id, set_id, card_id, 'numbered' from cps.variants
  on conflict do nothing;

-- 4) the old favorites table is fully converted; retire it
drop table if exists cps.favorites;

-- ---------------------------------------------------------------------
-- Part F — grants + schema reload
-- ---------------------------------------------------------------------
notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_turn_in(text, text, text) to anon;
    grant execute on function public.cps_turn_in_all(text, text, boolean) to anon;
    grant execute on function public.cps_vault_copy(text, text, text, boolean, boolean) to anon;
    grant execute on function public.cps_vault_variant(text, uuid, boolean) to anon;
  end if;
end $$;

-- =====================================================================
-- Verify after running:
--   select count(*) from cps.turn_ins;                       -- backfilled numbered owners
--   select count(*) from cps.collection where vaulted_count > 0;  -- converted favorites
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and proname in
--    ('cps_turn_in','cps_turn_in_all','cps_vault_copy','cps_vault_variant');
-- =====================================================================
