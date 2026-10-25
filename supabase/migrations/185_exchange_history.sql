-- 185_exchange_history.sql
-- EXECUTED 2026-10-25 via the Supabase connector on Franklin's go (ship items 1 and 2). Read-only; rollback-verified beforehand (all four entry kinds, both viewing directions).
-- 2026-10-25): an "Exchange history" button on each player's profile
-- showing your history with THAT player, chronologically — direct
-- trades, gifts both ways, bounties claimed between you, and Trading
-- Post sales between you.
--
-- Read-only. Every source already exists: gift notifications carry
-- meta.from + gift_label/card_name + thanked; trades live in
-- trade_offers + trade_offer_items; claimed bounties link poster and
-- claimed_by; accepted listings link lister and the winning offerer.
-- Summaries are built viewer-relative server-side (the client just
-- renders title/detail), with card names joined from cps.cards.

create or replace function cps.x_contents(p_tokens int, p_tickets int,
    p_pack_set text, p_packs int, p_items text[])
 returns text
 language plpgsql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
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
  if parts = '{}' then return 'nothing'; end if;
  return array_to_string(parts, ' + ');
end $function$;

create or replace function cps.x_trade_items(p_offer uuid, p_side text)
 returns text[]
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select coalesce(array_agg(lbl order by i.set_id, i.card_id, i.holo, i.tier, i.serial), '{}')
  from (
    select i.set_id, i.card_id, i.holo, i.tier, i.serial,
      coalesce(c.name, i.card_id)
      || case when i.holo then ' ✦' else '' end
      || case when i.tier <> '' then ' (' || i.tier || ' #' || i.serial || ')' else '' end
      || case when i.qty > 1 then ' ×' || i.qty else '' end as lbl
    from cps.trade_offer_items i
    left join cps.cards c on c.set_id = i.set_id and c.card_id = i.card_id
    where i.offer_id = p_offer and i.side = p_side
  ) i
$function$;

create or replace function cps.x_trade_side(p_offer uuid, p_side text)
 returns text
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select cps.x_contents(
    case when p_side = 'offer' then o.offer_tokens else o.want_tokens end,
    case when p_side = 'offer' then o.offer_tickets else o.want_tickets end,
    case when p_side = 'offer' then o.offer_pack_set else o.want_pack_set end,
    case when p_side = 'offer' then o.offer_packs else o.want_packs end,
    cps.x_trade_items(o.id, p_side))
  from cps.trade_offers o where o.id = p_offer
$function$;

create or replace function cps.x_bounty_items(p_bounty uuid)
 returns text[]
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select coalesce(array_agg(lbl order by e.set_id, e.card_id, e.holo, e.tier, e.serial), '{}')
  from (
    select e.set_id, e.card_id, e.holo, e.tier, e.serial,
      coalesce(c.name, e.card_id)
      || case when e.holo then ' ✦' else '' end
      || case when coalesce(e.tier, '') <> '' then ' (' || e.tier || ' #' || e.serial || ')' else '' end
      || case when e.qty > 1 then ' ×' || e.qty else '' end as lbl
    from cps.bounty_escrow e
    left join cps.cards c on c.set_id = e.set_id and c.card_id = e.card_id
    where e.bounty_id = p_bounty
  ) e
$function$;

create or replace function cps.x_json_items(p_cards jsonb)
 returns text[]
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select coalesce(array_agg(lbl order by sid, cid), '{}')
  from (
    select j->>'set' as sid, j->>'card' as cid,
      coalesce(c.name, j->>'card')
      || case when coalesce((j->>'holo')::boolean, false) then ' ✦' else '' end
      || case when coalesce(j->>'tier', '') <> '' then ' (' || (j->>'tier') || ' #' || (j->>'serial') || ')' else '' end as lbl
    from jsonb_array_elements(coalesce(p_cards, '[]'::jsonb)) j
    left join cps.cards c on c.set_id = j->>'set' and c.card_id = j->>'card'
  ) x
$function$;

create or replace function cps.x_card_label(p_set text, p_card text,
    p_holo boolean, p_tier text, p_serial int)
 returns text
 language sql
 stable
 set search_path to 'cps', 'pg_temp'
as $function$
  select coalesce((select name from cps.cards where set_id = p_set and card_id = p_card), p_card)
    || case when coalesce(p_holo, false) then ' ✦' else '' end
    || case when coalesce(p_tier, '') <> '' then ' (' || p_tier || ' #' || p_serial || ')' else '' end
$function$;

create or replace function public.cps_exchange_history(p_token text, p_other uuid)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'cps', 'pg_temp'
as $function$
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

        -- bounties one of us posted and the other claimed
        select jsonb_build_object(
            'kind', 'bounty',
            'at', b.claimed_at,
            'direction', case when b.poster = a.id then 'sent' else 'received' end,
            'status', 'claimed',
            'title', case when b.poster = a.id then 'Your bounty — claimed by them' else 'Their bounty — claimed by you' end,
            'detail', case when b.poster = a.id
              then 'Give: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id))
                || ' · Get: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
              else 'Give: ' || cps.x_card_label(b.want_set, b.want_card, b.want_holo = 'holo', b.want_tier, b.want_serial)
                || ' · Get: ' || cps.x_contents(b.offer_tokens, b.offer_tickets, b.offer_pack_set, b.offer_packs, cps.x_bounty_items(b.id))
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
                   || ' · For: ' || cps.x_contents(lo.tokens, lo.tickets, lo.pack_set, lo.packs, cps.x_json_items(lo.cards))
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
end $function$;
