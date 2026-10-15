-- =====================================================================
-- 155_verify.sql — post-run smoke test for 155. Run AFTER
-- 155_market_nav_counts.sql. Everything happens inside one transaction
-- that ROLLS BACK: the planted session, bounty and listing all vanish.
-- Expect one row at the end: 155 VERIFY PASS.
--
-- Checks, in order:
--   1. cps_market_nav answers post-auth and its counts move by exactly
--      +1/+1 when a claimable bounty and an offered listing are planted.
--   2. Calling cps_market_nav does NOT touch today's visit_market
--      daily (progress unchanged — the bug being fixed).
--   3. A real board load (cps_list_bounties) still DOES bump
--      visit_market to done — a genuine Market visit still counts.
-- =====================================================================
begin;

insert into cps.sessions (token_hash, account_id, expires_at)
select cps.hash_text('smoke155-token-00000001'), id, now() + interval '1 hour'
  from cps.accounts where display_name = 'Admin Account';

do $$
declare
  v_admin   uuid;
  v_other   uuid;
  v_set     text;
  v_card    text;
  v_day     date := (now() at time zone 'America/Chicago')::date;
  v_before  jsonb;
  v_after   jsonb;
  v_prog0   int;
  v_prog1   int;
  v_done    boolean;
  r         jsonb;
begin
  select id into v_admin from cps.accounts where display_name = 'Admin Account';
  if v_admin is null then raise exception 'VERIFY FAIL: no Admin Account fixture'; end if;
  select id into v_other
    from cps.accounts
   where not is_admin and not disabled and id <> v_admin
   order by id limit 1;
  if v_other is null then raise exception 'VERIFY FAIL: no second account fixture'; end if;

  -- a card the Admin holds on hand (plain copy, not all vaulted)
  select c.set_id, c.card_id into v_set, v_card
    from cps.collection c
   where c.account_id = v_admin and c.count - c.vaulted_count >= 1
   order by c.set_id, c.card_id limit 1;
  if v_set is null then raise exception 'VERIFY FAIL: Admin holds no on-hand card for the fixture'; end if;

  -- today's visit_market progress BEFORE anything (null row = -1)
  select coalesce((select progress from cps.daily_quests
                    where account_id = v_admin and day = v_day
                      and quest_key = 'visit_market'), -1) into v_prog0;

  v_before := public.cps_market_nav('smoke155-token-00000001');
  if v_before ->> 'claimable' is null or v_before ->> 'trade_offers' is null then
    raise exception 'VERIFY FAIL: market_nav shape = %', v_before;
  end if;

  -- plant: a bounty from someone else wanting a card Admin holds,
  -- and a listing BY Admin with an open offer on it
  insert into cps.bounties (poster, want_set, want_card, want_holo, offer_tokens)
  values (v_other, v_set, v_card, 'any', 1);
  insert into cps.trade_listings (lister, set_id, card_id)
  values (v_admin, v_set, v_card);
  insert into cps.listing_offers (listing_id, offerer, tokens)
  select t.id, v_other, 1
    from cps.trade_listings t
   where t.lister = v_admin and t.set_id = v_set and t.card_id = v_card
     and t.status = 'open'
   order by t.created_at desc limit 1;

  v_after := public.cps_market_nav('smoke155-token-00000001');
  if (v_after ->> 'claimable')::int <> (v_before ->> 'claimable')::int + 1 then
    raise exception 'VERIFY FAIL: claimable % -> % (expected +1)', v_before, v_after;
  end if;
  if (v_after ->> 'trade_offers')::int <> (v_before ->> 'trade_offers')::int + 1 then
    raise exception 'VERIFY FAIL: trade_offers % -> % (expected +1)', v_before, v_after;
  end if;

  -- the whole point: badge counts must NOT move the daily
  select coalesce((select progress from cps.daily_quests
                    where account_id = v_admin and day = v_day
                      and quest_key = 'visit_market'), -1) into v_prog1;
  if v_prog1 <> v_prog0 then
    raise exception 'VERIFY FAIL: visit_market progress moved by a badge call (% -> %)', v_prog0, v_prog1;
  end if;

  -- and a real Market visit still completes it
  r := public.cps_list_bounties('smoke155-token-00000001');
  select progress, done into v_prog1, v_done
    from cps.daily_quests
   where account_id = v_admin and day = v_day and quest_key = 'visit_market';
  if not coalesce(v_done, false) then
    raise exception 'VERIFY FAIL: real board load did not complete visit_market (progress %)', v_prog1;
  end if;
end $$;

select '155 VERIFY PASS' as result;
rollback;
