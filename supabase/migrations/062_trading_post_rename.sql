-- =====================================================================
-- 062_trading_post_rename.sql — fix 061's accidental overwrite of the
-- direct-trading cps_list_trades (trade history). Restores the original
-- and moves the Trading Post list function to cps_trading_post.
-- =====================================================================

-- drop the trading-post version that 061 installed under the wrong name
drop function if exists public.cps_list_trades(text);

-- =====================================================================
-- 012_trade_history.sql — include decided_at in cps_list_trades so the
-- trade history screen can show when each offer was decided.
-- =====================================================================

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
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty)
                      order by set_id, card_id, holo)
                    from cps.trade_offer_items where offer_id = o.id and side = 'offer'), '[]'),
      'want_items', coalesce((select jsonb_agg(jsonb_build_object(
                        'set_id', set_id, 'card_id', card_id, 'holo', holo, 'qty', qty)
                      order by set_id, card_id, holo)
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



-- trading-post list function under its own collision-free name
create or replace function public.cps_trading_post(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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

  for l in
    select t.*, ac.display_name as lister_name,
           k.name as card_name, s.name as set_name, k.rarity as rarity,
           (select count(*) from cps.trade_offers ofr
             where ofr.listing_id = t.id and ofr.status = 'open') as offer_count,
           (select ofr.id from cps.trade_offers ofr
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
      from cps.trade_offers ofr
      join cps.accounts ac2 on ac2.id = ofr.offerer
      left join cps.card_sets ps on ps.id = ofr.pack_set
      where ofr.listing_id = l.id and ofr.status = 'open'
      order by ofr.created_at asc
    loop
      oj := oj || jsonb_build_object(
        'id', o.id, 'offerer', o.offerer_name, 'offerer_id', o.offerer,
        'mine', o.offerer = a.id,
        'tokens', o.tokens, 'tickets', o.tickets,
        'pack_set', o.pack_set, 'packs', o.packs, 'pack_name', o.pack_name,
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
end $$;

notify pgrst, 'reload schema';

notify pgrst, 'reload schema';
