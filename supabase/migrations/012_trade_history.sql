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

notify pgrst, 'reload schema';
