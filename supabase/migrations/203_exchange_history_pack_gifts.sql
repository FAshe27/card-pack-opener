-- 203: Exchange history — pack gifts from the pack_grants ledger.
-- Follow-up to 202 (Franklin: "Pack gifts too would be great"). Player
-- pack gifts move packs through cps.pack_grants as a matched -N / +N
-- pair of 'gift' rows sharing one transaction timestamp and set; this
-- adds a gift branch over those pairs to public.cps_exchange_history.
-- Same rules as 202's card branch: skipped when a matching gift
-- notification still exists (it already covers the whole gift),
-- 'thanked' recovered best-effort from one. The 280 'gift_pack'
-- notifications are admin mass grants (meta carries no sender), so
-- they stay out of player-pair history by design. Everything else in
-- the function is byte-identical to the post-202 body.
CREATE OR REPLACE FUNCTION public.cps_exchange_history(p_token text, p_other uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
end $function$
