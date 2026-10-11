-- =====================================================================
-- 063_trading_post_fix.sql — 062 built cps_trading_post from a stale 061
-- copy (referenced cps.trade_offers). Replace with the correct body.
-- =====================================================================

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
