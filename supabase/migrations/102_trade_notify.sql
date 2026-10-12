-- =====================================================================
-- 102_trade_notify.sql — Send notification when a direct trade is proposed.
-- =====================================================================

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

  -- Notify the recipient
  perform cps.notify(tgt.id, 'trade_offer',
    a.display_name || ' sent you a trade offer.', 'trading');

  return jsonb_build_object('id', new_id);
end $$;

notify pgrst, 'reload schema';
