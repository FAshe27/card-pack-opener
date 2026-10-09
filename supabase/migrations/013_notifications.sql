-- =====================================================================
-- 013_notifications.sql — player notifications + card gifting.
--
--   cps.notifications      : per-account notification feed
--   cps.notify             : internal helper
--   cps_list_notifications : unread count + recent items
--   cps_read_notifications : mark read (all or given ids)
--   cps_gift_card          : gift one owned card to another player
--   (also: transfer_card drops orphaned favorites; trade propose/respond
--    and admin pack/spin grants now notify the recipient)
-- =====================================================================

-- --- feed table -----------------------------------------------------------
create table if not exists cps.notifications (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references cps.accounts(id) on delete cascade,
  kind       text not null,
  text       text not null,
  target_view text,
  created_at timestamptz not null default now(),
  read_at    timestamptz
);
create index if not exists idx_notifications_acct on cps.notifications(account_id, created_at desc);

-- --- internal helper -------------------------------------------------------
create or replace function cps.notify(p_account uuid, p_kind text, p_text text, p_view text default null)
returns void language sql set search_path = cps, pg_temp as $$
  insert into cps.notifications (account_id, kind, text, target_view)
  values (p_account, p_kind, p_text, p_view);
$$;

-- --- list -------------------------------------------------------------------
create or replace function public.cps_list_notifications(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'unread', (select count(*) from cps.notifications where account_id = a.id and read_at is null),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                'id', id, 'kind', kind, 'text', text, 'view', target_view,
                'created_at', created_at, 'read', read_at is not null)
              order by created_at desc)
            from cps.notifications
            where account_id = a.id and created_at > now() - interval '30 days'), '[]'));
end $$;

-- --- mark read ----------------------------------------------------------------
create or replace function public.cps_read_notifications(p_token text, p_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  update cps.notifications set read_at = now()
    where account_id = a.id and read_at is null
      and (p_ids is null or id = any(p_ids));
  return jsonb_build_object('ok', true);
end $$;

-- --- clear read notifications -------------------------------------------------------
create or replace function public.cps_clear_notifications(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  delete from cps.notifications where account_id = a.id and read_at is not null;
  return jsonb_build_object('ok', true);
end $$;

-- --- transfer_card: drop favorites the giver no longer owns -------------------
create or replace function cps.transfer_card(p_from uuid, p_to uuid, p_set text, p_card text, p_holo boolean, p_qty int, p_ref text default null)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare r cps.collection%rowtype;
begin
  if p_qty < 1 then raise exception 'qty must be positive'; end if;
  select * into r from cps.collection where account_id = p_from and set_id = p_set and card_id = p_card for update;
  if not found or r.count < p_qty or (p_holo and r.holo_count < p_qty) or (not p_holo and r.count - r.holo_count < p_qty) then
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
  -- a gifted/traded-away last copy can't stay favorited
  delete from cps.favorites f
    where f.account_id = p_from and f.set_id = p_set and f.card_id = p_card
      and not exists (select 1 from cps.collection c
                      where c.account_id = p_from and c.set_id = p_set and c.card_id = p_card and c.count > 0);
end $$;

-- --- gift a card ---------------------------------------------------------------
create or replace function public.cps_gift_card(p_token text, p_to uuid, p_set text, p_card text, p_holo boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  tgt       cps.accounts%rowtype;
  card_name text;
  set_name  text;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot gift a card to yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  select k.name, s.name into card_name, set_name
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = p_set and k.card_id = p_card;
  if not found then raise exception 'Card not found.'; end if;
  perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift');
  perform cps.notify(tgt.id, 'gift_card',
    a.display_name || ' gifted you ' || card_name || ' (' || set_name || ')' ||
    case when coalesce(p_holo, false) then ' ✦ holo' else '' end,
    'collection');
  return jsonb_build_object('ok', true);
end $$;

-- --- trade propose: notify the recipient ----------------------------------------
create or replace function public.cps_propose_trade(
  p_token text, p_to uuid, p_offer jsonb, p_want jsonb)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  tgt    cps.accounts%rowtype;
  new_id uuid;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot trade with yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  perform cps.trade_check_side(a.id, p_offer, 'Your offer');
  perform cps.trade_check_side(tgt.id, p_want, 'Their side');

  if (select count(*) from cps.trade_offers
        where from_account = a.id and status = 'pending') >= 10 then
    raise exception 'You have too many pending offers (max 10).';
  end if;

  insert into cps.trade_offers (from_account, to_account)
    values (a.id, tgt.id) returning id into new_id;
  perform cps.trade_insert_items(new_id, 'offer', p_offer);
  perform cps.trade_insert_items(new_id, 'want', p_want);
  perform cps.notify(tgt.id, 'trade_offer',
    a.display_name || ' offered you a trade (' ||
    (select count(*) from jsonb_array_elements(p_offer)) || ' for ' ||
    (select count(*) from jsonb_array_elements(p_want)) || ')',
    'players');
  return jsonb_build_object('id', new_id);
end $$;

-- --- trade respond: notify the offerer -------------------------------------------
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
    if not found or c.count < r.qty
       or (r.holo and c.holo_count < r.qty)
       or (not r.holo and c.count - c.holo_count < r.qty) then
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
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $$;

-- --- admin grant packs: notify the recipient --------------------------------------
create or replace function public.cps_admin_grant_packs(p_token text, p_set text, p_packs int, p_account uuid default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; target uuid; n int; set_name text;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if not exists (select 1 from cps.card_sets where id = p_set) then raise exception 'That set is not on the server yet.'; end if;
  if p_packs is null or p_packs < -999 or p_packs > 999 or p_packs = 0 then raise exception 'Packs must be between -999 and 999 (not 0).'; end if;
  if not exists (select 1 from cps.accounts where id = target) then raise exception 'No such account.'; end if;
  n := cps.add_packs(target, p_set, p_packs, 'admin', null, a.id);
  if target <> a.id and p_packs > 0 then
    select s.name into set_name from cps.card_sets s where s.id = p_set;
    perform cps.notify(target, 'gift_pack',
      'You''ve been gifted ' || case when p_packs = 1 then 'a pack' else p_packs || ' packs' end ||
      ' (' || coalesce(set_name, p_set) || ')!', 'packs');
  end if;
  return jsonb_build_object('account', target, 'set_id', p_set, 'packs_now', n);
end $$;

-- --- admin grant spins: notify the recipient ---------------------------------------
create or replace function public.cps_admin_grant_spins(p_token text, p_account uuid, p_spins int) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  target uuid;
  n      int;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if p_spins is null or p_spins = 0 or p_spins < -999 or p_spins > 999 then
    raise exception 'Spins must be between -999 and 999 (not 0).';
  end if;
  if not exists (select 1 from cps.accounts where id = target) then
    raise exception 'No such account.'; end if;
  update cps.accounts set spins = greatest(spins + p_spins, 0)
    where id = target returning spins into n;
  insert into cps.spin_grants (account_id, spins, reason, granted_by)
    values (target, p_spins, 'admin', a.id);
  if target <> a.id and p_spins > 0 then
    perform cps.notify(target, 'gift_spin',
      'You''ve been gifted ' || case when p_spins = 1 then 'a spin ticket' else p_spins || ' spin tickets' end || '!',
      'wheel');
  end if;
  return jsonb_build_object('account', target, 'spins_now', n);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
