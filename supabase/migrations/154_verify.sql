-- 154_verify.sql -- post-run smoke test for 154_trade_numbered_copies.
-- Run AFTER 154. Everything happens inside one transaction that ends
-- in ROLLBACK. Expect: NOTICE '154 VERIFY PASS'.
begin;
do $$
declare
  a cps.accounts%rowtype; b cps.accounts%rowtype;
  offer_card record; want_card record; vrow record;
  r jsonb; oid uuid;
begin
  select * into a from cps.accounts where display_name = 'Admin Account';
  if not found then raise exception 'VERIFY FAIL: Admin Account not found'; end if;
  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text('smoke154-token-00000001'), a.id, now() + interval '1 hour');

  select * into b from cps.accounts
   where id <> a.id and not disabled order by created_at limit 1;
  if not found then raise exception 'VERIFY FAIL: no second account'; end if;
  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text('smoke154-token-00000002'), b.id, now() + interval '1 hour');

  -- a card A can offer as a plain (non-numbered) copy
  select c.set_id, c.card_id into offer_card from cps.collection c
   where c.account_id = a.id
     and (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo)
         - (select count(*) from cps.variants v where v.account_id = a.id
              and v.set_id = c.set_id and v.card_id = c.card_id and not v.vaulted) > 0
   limit 1;
  if not found then raise exception 'VERIFY FAIL: Admin has no plain-offerable card'; end if;
  select c.set_id, c.card_id into want_card from cps.collection c
   where c.account_id = b.id
     and (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo)
         - (select count(*) from cps.variants v where v.account_id = b.id
              and v.set_id = c.set_id and v.card_id = c.card_id and not v.vaulted) > 0
   limit 1;
  if not found then raise exception 'VERIFY FAIL: second account has no plain-offerable card'; end if;

  -- plain 1-for-1 propose: items must store as fungible (tier '')
  r := public.cps_propose_trade('smoke154-token-00000001', b.id,
    jsonb_build_array(jsonb_build_object('set', offer_card.set_id, 'card', offer_card.card_id)),
    jsonb_build_array(jsonb_build_object('set', want_card.set_id, 'card', want_card.card_id)));
  oid := (r->>'id')::uuid;
  if oid is null then raise exception 'VERIFY FAIL: propose returned no id'; end if;
  if (select count(*) from cps.trade_offer_items where offer_id = oid and tier = '' and serial = 0) <> 2 then
    raise exception 'VERIFY FAIL: items not stored as fungible';
  end if;

  -- decline path still works end to end
  r := public.cps_respond_trade('smoke154-token-00000002', oid, false);
  if r->>'status' <> 'declined' then raise exception 'VERIFY FAIL: decline broken'; end if;

  -- list_player_variants answers with an array
  r := public.cps_list_player_variants('smoke154-token-00000001', b.id);
  if jsonb_typeof(r) <> 'array' then raise exception 'VERIFY FAIL: list_player_variants not an array'; end if;

  -- pinned validation: a real uncommitted variant passes for its owner
  select v.* into vrow from cps.variants v
   where not v.vaulted and not cps.trade_variant_escrowed(v.set_id, v.card_id, v.tier, v.serial)
   limit 1;
  if found then
    perform cps.trade_check_side(vrow.account_id,
      jsonb_build_array(jsonb_build_object('set', vrow.set_id, 'card', vrow.card_id,
                        'tier', vrow.tier, 'serial', vrow.serial)), 'verify');
    -- ...and fails for a non-owner (when Admin isn't the owner)
    if vrow.account_id <> a.id then
      begin
        perform cps.trade_check_side(a.id,
          jsonb_build_array(jsonb_build_object('set', vrow.set_id, 'card', vrow.card_id,
                            'tier', vrow.tier, 'serial', vrow.serial)), 'verify');
        raise exception 'VERIFY FAIL: pinned copy accepted for a non-owner';
      exception when others then
        if sqlerrm like 'VERIFY FAIL%' then raise; end if;
      end;
    end if;
  end if;

  raise notice '154 VERIFY PASS';
end $$;
rollback;
