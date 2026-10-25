-- 180_verify.sql — post-migration smoke test for pack bundles in direct
-- trades. Self-contained: creates two fixture accounts, plants sessions,
-- exercises the escrow lifecycle through the PUBLIC RPCs, and ROLLS BACK,
-- leaving no trace. Run after 180_trade_packs.sql. A clean run ends with
-- one row: '180 VERIFY PASS'. Any failure raises and aborts the script.
begin;
do $$
declare
  A uuid; B uuid; oid uuid; r jsonb; n int; st text;
  tokA text := 't180-token-aaaaaaaaaaaaaa';
  tokB text := 't180-token-bbbbbbbbbbbbbb';
  setA text; setB text; cardA text;
begin
  select id into setA from cps.card_sets where active and id <> 'jumbled' order by id limit 1;
  select id into setB from cps.card_sets where active and id <> 'jumbled' and id <> setA order by id limit 1;
  select card_id into cardA from cps.cards where set_id = setA order by num limit 1;

  A := cps.create_account('t180a', 'T180 A', '1234', false, 0, null, null);
  B := cps.create_account('t180b', 'T180 B', '1234', false, 0, null, null);
  insert into cps.sessions (token_hash, account_id, expires_at)
    values (cps.hash_text(tokA), A, now() + interval '1 hour'),
           (cps.hash_text(tokB), B, now() + interval '1 hour');
  perform cps.add_packs(A, setA, 10, 'test', null, null);
  perform cps.add_packs(B, setB, 6, 'test', null, null);
  insert into cps.collection (account_id, set_id, card_id, count, holo_count)
    values (A, setA, cardA, 2, 0);

  -- S1: packs-only both sides; the sender's packs escrow at propose time
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setA, 'packs', 5),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 3));
  oid := (r ->> 'id')::uuid;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 5 then raise exception 'S1 FAIL: sender not escrowed (has %, want 5)', n; end if;
  select packs into n from cps.pack_inventory where account_id = B and set_id = setB;
  if coalesce(n, 0) <> 6 then raise exception 'S1 FAIL: recipient packs touched at propose (has %, want 6)', n; end if;

  -- S2: decline refunds the escrow in full
  r := public.cps_respond_trade(tokB, oid, false);
  if r ->> 'status' <> 'declined' then raise exception 'S2 FAIL: status %', r; end if;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 10 then raise exception 'S2 FAIL: decline did not refund (has %, want 10)', n; end if;

  -- S3: accept settles both bundles (escrow delivered, want-side moved)
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setA, 'packs', 5),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 3));
  oid := (r ->> 'id')::uuid;
  r := public.cps_respond_trade(tokB, oid, true);
  if r ->> 'status' <> 'accepted' then raise exception 'S3 FAIL: status %', r; end if;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 5 then raise exception 'S3 FAIL: A setA % (want 5)', n; end if;
  select packs into n from cps.pack_inventory where account_id = B and set_id = setA;
  if coalesce(n, 0) <> 5 then raise exception 'S3 FAIL: B setA % (want 5 delivered)', n; end if;
  select packs into n from cps.pack_inventory where account_id = B and set_id = setB;
  if coalesce(n, 0) <> 3 then raise exception 'S3 FAIL: B setB % (want 3)', n; end if;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setB;
  if coalesce(n, 0) <> 3 then raise exception 'S3 FAIL: A setB % (want 3)', n; end if;

  -- S4: cancel refunds the escrow
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setA, 'packs', 2),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 1));
  oid := (r ->> 'id')::uuid;
  r := public.cps_cancel_trade(tokA, oid);
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 5 then raise exception 'S4 FAIL: cancel did not refund (has %, want 5)', n; end if;

  -- S5: recipient spent the wanted packs before accepting -> the accept
  -- fails cleanly as 'unavailable', the offer closes, sender refunded
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setA, 'packs', 2),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 3));
  oid := (r ->> 'id')::uuid;
  perform cps.add_packs(B, setB, -2, 'test', null, null);
  r := public.cps_respond_trade(tokB, oid, true);
  if r ->> 'status' <> 'unavailable' then raise exception 'S5 FAIL: status % (want unavailable)', r; end if;
  select status into st from cps.trade_offers where id = oid;
  if st <> 'expired' then raise exception 'S5 FAIL: offer not closed (status %)', st; end if;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 5 then raise exception 'S5 FAIL: sender not refunded (has %, want 5)', n; end if;
  perform cps.add_packs(B, setB, 2, 'test', null, null);

  -- S6: Jumbled packs are fenced
  begin
    perform public.cps_propose_trade(tokA, B,
      jsonb_build_object('cards', '[]'::jsonb, 'pack_set', 'jumbled', 'packs', 1),
      jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 1));
    raise exception 'S6 FAIL: jumbled bundle accepted';
  exception when others then
    if SQLERRM like 'S6 FAIL%' then raise; end if;
  end;

  -- S7: a completely empty side is rejected
  begin
    perform public.cps_propose_trade(tokA, B,
      jsonb_build_object('cards', '[]'::jsonb, 'pack_set', null, 'packs', 0),
      jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 1));
    raise exception 'S7 FAIL: empty side accepted';
  exception when others then
    if SQLERRM like 'S7 FAIL%' then raise; end if;
  end;

  -- S8: mixed card + pack side settles both
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', jsonb_build_array(jsonb_build_object('set', setA, 'card', cardA, 'holo', false)), 'pack_set', setA, 'packs', 2),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 1));
  oid := (r ->> 'id')::uuid;
  r := public.cps_respond_trade(tokB, oid, true);
  if r ->> 'status' <> 'accepted' then raise exception 'S8 FAIL: status %', r; end if;
  select count into n from cps.collection where account_id = B and set_id = setA and card_id = cardA;
  if coalesce(n, 0) <> 1 then raise exception 'S8 FAIL: card did not move (B has %)', n; end if;
  select packs into n from cps.pack_inventory where account_id = B and set_id = setA;
  if coalesce(n, 0) <> 7 then raise exception 'S8 FAIL: B setA packs % (want 5+2=7)', n; end if;

  -- S9: get_profile exposes pack_inventory (Jumbled excluded)
  r := public.cps_get_profile(tokA, B);
  if r -> 'pack_inventory' is null then raise exception 'S9 FAIL: no pack_inventory'; end if;
  if exists (select 1 from jsonb_array_elements(r -> 'pack_inventory') e where e ->> 'set_id' = 'jumbled') then
    raise exception 'S9 FAIL: jumbled leaked into pack_inventory';
  end if;
  if not exists (select 1 from jsonb_array_elements(r -> 'pack_inventory') e where e ->> 'set_id' = setB) then
    raise exception 'S9 FAIL: partner pack set missing from pack_inventory';
  end if;

  -- S10: lazy expiry in list_trades refunds the escrow
  r := public.cps_propose_trade(tokA, B,
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setA, 'packs', 1),
    jsonb_build_object('cards', '[]'::jsonb, 'pack_set', setB, 'packs', 1));
  oid := (r ->> 'id')::uuid;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 2 then raise exception 'S10 FAIL: escrow not taken (has %, want 2)', n; end if;
  update cps.trade_offers set expires_at = now() - interval '1 minute' where id = oid;
  perform public.cps_list_trades(tokA);
  if (select status from cps.trade_offers where id = oid) <> 'expired' then
    raise exception 'S10 FAIL: offer not expired by list_trades';
  end if;
  select packs into n from cps.pack_inventory where account_id = A and set_id = setA;
  if coalesce(n, 0) <> 3 then raise exception 'S10 FAIL: expiry did not refund (has %, want 3)', n; end if;
end $$;
select '180 VERIFY PASS' as result;
rollback;
