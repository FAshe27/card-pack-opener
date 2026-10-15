-- 151_verify.sql — post-auth smoke for migration 151 (variant bounty offers).
-- Runs in ONE transaction and ROLLS BACK: nothing persists. It plants a
-- session for the 'Admin Account', plants a numbered copy for it (a real
-- Rare+ card with a free Rainbow serial), posts a bounty offering that
-- exact copy, checks the escrow pin + the census owners 'escrowed' flag,
-- then cancels and checks the refund. Expect: one NOTICE 'SMOKE 151 OK'.
begin;
do $$
declare
  v_acct uuid;
  v_set  text; v_card text; v_want_set text; v_want_card text;
  v_bounty uuid; v_own jsonb;
begin
  select id into v_acct from cps.accounts where display_name = 'Admin Account';
  if v_acct is null then raise exception 'Admin Account not found.'; end if;

  -- a real Rare+ card with no Rainbow #50 yet, and any other real card to want
  select k.set_id, k.card_id into v_set, v_card
    from cps.cards k
   where k.rarity in ('rare', 'epic', 'legendary', 'chase')
     and not exists (select 1 from cps.variants v
                      where v.set_id = k.set_id and v.card_id = k.card_id
                        and v.tier = 'rainbow' and v.serial = 50)
   order by k.set_id, k.card_id limit 1;
  select k.set_id, k.card_id into v_want_set, v_want_card
    from cps.cards k where k.set_id <> v_set order by k.set_id, k.card_id limit 1;
  if v_set is null or v_want_set is null then raise exception 'Fixture cards not found.'; end if;

  -- plant the session + the numbered copy + its base slot
  insert into cps.sessions (token_hash, account_id, expires_at)
    values (cps.hash_text('smoke151-token-00000001'), v_acct, now() + interval '1 hour');
  insert into cps.collection (account_id, set_id, card_id, count, holo_count)
    values (v_acct, v_set, v_card, 1, 0)
    on conflict (account_id, set_id, card_id) do update set count = cps.collection.count + 1;
  insert into cps.variants (account_id, set_id, card_id, tier, serial)
    values (v_acct, v_set, v_card, 'rainbow', 50);

  -- post a bounty offering that exact copy
  v_bounty := (public.cps_post_bounty('smoke151-token-00000001',
    jsonb_build_object('set', v_want_set, 'card', v_want_card),
    jsonb_build_object('cards', jsonb_build_array(jsonb_build_object(
      'set', v_set, 'card', v_card, 'holo', false, 'tier', 'rainbow', 'serial', 50))))->>'id')::uuid;

  if not exists (select 1 from cps.bounty_escrow
                  where bounty_id = v_bounty and tier = 'rainbow' and serial = 50) then
    raise exception 'SMOKE FAIL: escrow pin missing.';
  end if;
  if not cps.trade_variant_escrowed(v_set, v_card, 'rainbow', 50) then
    raise exception 'SMOKE FAIL: pin check does not see the bounty pin.';
  end if;
  v_own := public.cps_variant_owners('smoke151-token-00000001', v_set, v_card, 'rainbow');
  if not exists (select 1 from jsonb_array_elements(v_own) e
                  where (e->>'serial')::int = 50 and (e->>'escrowed')::boolean) then
    raise exception 'SMOKE FAIL: owners list does not flag the copy as escrowed.';
  end if;

  -- list shows the pin with tier/serial; cancel refunds the base slot
  if not exists (select 1 from jsonb_array_elements(
        public.cps_list_bounties('smoke151-token-00000001')->'bounties') b
      cross join lateral jsonb_array_elements(b->'offer_cards') oc
      where (b->>'id')::uuid = v_bounty and oc->>'tier' = 'rainbow' and (oc->>'serial')::int = 50) then
    raise exception 'SMOKE FAIL: board payload lacks the numbered offer.';
  end if;
  perform public.cps_cancel_bounty('smoke151-token-00000001', v_bounty);
  if exists (select 1 from cps.bounty_escrow where bounty_id = v_bounty) then
    raise exception 'SMOKE FAIL: escrow not released on cancel.';
  end if;
  raise notice 'SMOKE 151 OK (set %, card %)', v_set, v_card;
end $$;
rollback;
