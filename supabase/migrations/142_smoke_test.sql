-- 142_smoke_test.sql — post-auth smoke test for migration 142.
-- Runs ENTIRELY in one transaction and ROLLS BACK: the Muse test
-- account's collection is fixtured in-transaction, the real RPC is
-- called with a planted session token, and nothing persists.
-- Expected: one row, all five checks true.
begin;

do $$
declare
  acct      int;
  tok       text := 'smoke142-token-00000001';
  e_set text; e_card text;
  l_set text; l_card text;
  c_set text; c_card text;
  r         jsonb;
  msg       text;
  n         int;
  credit0   int;
  ok_epic_pool    boolean := false;
  ok_epic         boolean := false;
  ok_legendary    boolean := false;
  ok_chase        boolean := false;
  ok_chase_once   boolean := false;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  -- Fixture cards: one per rarity, none with variants for this account
  select set_id, card_id into e_set, e_card from cps.cards k
   where k.rarity = 'epic'
     and not exists (select 1 from cps.variants v where v.account_id = acct and v.set_id = k.set_id and v.card_id = k.card_id)
   order by set_id, card_id limit 1;
  select set_id, card_id into l_set, l_card from cps.cards k
   where k.rarity = 'legendary'
     and not exists (select 1 from cps.variants v where v.account_id = acct and v.set_id = k.set_id and v.card_id = k.card_id)
   order by set_id, card_id limit 1;
  select set_id, card_id into c_set, c_card from cps.cards k
   where k.rarity = 'chase'
     and not exists (select 1 from cps.variants v where v.account_id = acct and v.set_id = k.set_id and v.card_id = k.card_id)
   order by set_id, card_id limit 1;

  -- Neutralize the account's other epic/legendary/chase dupes (txn-only)
  update cps.collection col set count = 1, holo_count = 0, vaulted_count = 0, vaulted_holo = 0
   where col.account_id = acct
     and exists (select 1 from cps.cards k where k.set_id = col.set_id and k.card_id = col.card_id
                 and k.rarity in ('epic', 'legendary', 'chase'));

  delete from cps.collection where account_id = acct
    and ((set_id = e_set and card_id = e_card) or (set_id = l_set and card_id = l_card) or (set_id = c_set and card_id = c_card));
  insert into cps.collection (account_id, set_id, card_id, count, holo_count, vaulted_count, vaulted_holo) values
    (acct, e_set, e_card, 9, 0, 0, 0),
    (acct, l_set, l_card, 3, 0, 0, 0),
    (acct, c_set, c_card, 2, 0, 0, 0);

  select store_credit into credit0 from cps.accounts where id = acct;

  -- 1) EPIC sale: 8 dupes -> $2, removes exactly 8, pools stay separate
  r := public.cps_trade_dupes_credit(tok, 'epic');
  select count into n from cps.collection where account_id = acct and set_id = e_set and card_id = e_card;
  ok_epic := (r->>'dupes_used')::int = 8 and (r->>'credit')::int = 2 and n = 1;
  select count into n from cps.collection where account_id = acct and set_id = l_set and card_id = l_card;
  ok_epic_pool := n = 3;
  select count into n from cps.collection where account_id = acct and set_id = c_set and card_id = c_card;
  ok_epic_pool := ok_epic_pool and n = 2;

  -- 2) LEGENDARY sale: 2 dupes -> $1, keeps 1
  r := public.cps_trade_dupes_credit(tok, 'legendary');
  select count into n from cps.collection where account_id = acct and set_id = l_set and card_id = l_card;
  ok_legendary := (r->>'dupes_used')::int = 2 and (r->>'credit')::int = 1 and n = 1;

  -- 3) CHASE sale: 1 dupe -> $2, keeps 1
  r := public.cps_trade_dupes_credit(tok, 'chase');
  select count into n from cps.collection where account_id = acct and set_id = c_set and card_id = c_card;
  ok_chase := (r->>'dupes_used')::int = 1 and (r->>'credit')::int = 2 and n = 1;

  -- 4) CHASE again: no dupes left -> must raise the $2 not-enough error
  --    (under the old take math this call would pay $2 forever)
  begin
    r := public.cps_trade_dupes_credit(tok, 'chase');
    ok_chase_once := false;
  exception when others then
    msg := sqlerrm;
    ok_chase_once := msg like '%you need 1 per $2 credit%';
  end;

  -- 5) store credit moved by exactly 2 + 1 + 2 = $5
  select store_credit into n from cps.accounts where id = acct;

  create temp table smoke142_result on commit drop as
  select ok_epic_pool as epic_pool_separate, ok_epic as epic_exact_removal,
         ok_legendary as legendary_2_for_1, ok_chase as chase_1_for_2,
         (ok_chase_once and n = credit0 + 5) as chase_no_reprint_and_credit_exact;
end $$;

select * from smoke142_result;

rollback;
