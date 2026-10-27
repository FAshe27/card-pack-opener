-- 207: Daily quest "Buy a pack from the shop" (Easy) — prize $5 Store Credit.
-- Franklin's spec, verbatim: title 'Buy a pack from the shop', tier
-- easy, prize 5 Store Credit. Store Credit is the Shop's currency
-- (accounts.store_credit), so this is the quest system's THIRD reward
-- currency alongside tickets and tokens:
--   * quest_tier / quest_title / assign_daily_quests learn the key
--     'buy_shop_pack' (target 1, the default).
--   * quest_reward_currency returns 'store_credit' for it and
--     quest_reward_amount returns 5; cps_list_quests already reads
--     both helpers, so the board shows the real prize with no change.
--   * cps_claim_quest gains a store_credit branch (credits the
--     balance, returns 'credit' / 'credit_now' alongside the existing
--     ticket/token fields).
--   * The bump fires on pack purchases only: cps_shop_buy after its
--     add_packs (slots 5/6 sell a ticket/token and return earlier),
--     and once in cps_shop_buy_all before its pack branches (slots
--     3/4; its 5/6 return earlier too).
--   * Same-day backfill so the quest appears on today's boards.
-- Client (same ship): app.js renders the prize as "💵 $5 Store
-- Credit" and toasts "+$5 Store Credit!" on claim; daily.js Claim
-- All totals Store Credit too. Board grows 30 -> 31 quests.


CREATE OR REPLACE FUNCTION cps.quest_tier(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market','vault_cashout','play_plinko','play_wordguesser','buy_shop_pack') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card',
                             'pull_3_sets','bank_5_streak','market_trade') then 'medium'
              when p_key = 'bank_10_streak' then 'ultra'
              else 'hard' end $function$;

CREATE OR REPLACE FUNCTION cps.quest_title(p_key text, p_meta jsonb)
 RETURNS text
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare sname text;
begin
  if p_key = 'open_packs_set' then
    select s.name into sname from cps.card_sets s where s.id = p_meta->>'set_id';
    return 'Open 2 ' || coalesce(sname, 'set') || ' packs';
  end if;
  if p_key = 'pull_letter' then
    return 'Pull a card with "' || coalesce(p_meta->>'letter', '?') || '" in the name';
  end if;
  return case p_key
    when 'open_packs' then 'Open 3 packs'
    when 'spin_wheel' then 'Spin the wheel'
    when 'dupe_trade' then 'Trade in duplicates'
    when 'pull_holo' then 'Pull a holo card'
    when 'pull_rare_plus' then 'Pull a Rare or better'
    when 'pull_epic_plus' then 'Pull an Epic or better'
    when 'gift_card' then 'Gift a card to a friend'
    when 'visit_market' then 'Visit the Market'
    when 'market_trade' then 'Buy or sell a card in the Market'
    when 'pull_legendary_plus' then 'Pull a Legendary or better'
    when 'pull_chase' then 'Pull a Chase card'
    when 'pull_variant' then 'Pull a numbered variant'
    when 'wheel_big_win' then 'Win 3 or more packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    when 'pull_token_slip' then 'Pull a Token Slip'
    when 'win_3_rounds' then 'Win 3 Rounds of High/Low'
    when 'pull_spin_ticket' then 'Pull a Spin Ticket'
    when 'bank_5_streak' then 'Bank and claim a High/Low streak of 5 or higher'
    when 'bank_10_streak' then 'Bank and claim a High/Low streak of 10 or higher'
    when 'win_slots' then 'Win on Slots'
    when 'vault_cashout' then 'Cash out a Vault Breaker run'
    when 'play_plinko' then 'Play a game of Plinko'
    when 'play_wordguesser' then 'Complete a round of WordGuesser'
    when 'buy_shop_pack' then 'Buy a pack from the shop'
    else p_key end;
end $function$;

CREATE OR REPLACE FUNCTION cps.assign_daily_quests(p_account uuid, p_day date)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  k text; sid text; vletter text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  -- deterministic featured set per account per day
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select id into sid from cps.card_sets where active order by random() limit 1;
  -- deterministic random letter per account per day (A-Z)
  perform setseed(('x' || substr(md5('letter' || p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select chr(65 + floor(random() * 26)::int) into vletter;
  foreach k in array array['open_packs','open_packs_set','spin_wheel','dupe_trade',
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','visit_market','market_trade',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack',
    'pull_token_slip','win_3_rounds','pull_spin_ticket','bank_5_streak','bank_10_streak',
    'win_slots','vault_cashout','play_plinko','play_wordguesser','buy_shop_pack'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION cps.quest_reward_currency(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case when p_key in ('pull_token_slip','win_3_rounds','bank_5_streak','bank_10_streak',
                             'win_slots','vault_cashout')
    then 'token' when p_key = 'buy_shop_pack' then 'store_credit' else 'ticket' end $function$;

CREATE OR REPLACE FUNCTION cps.quest_reward_amount(p_key text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case
    when p_key = 'pull_token_slip' then 3
    when p_key = 'win_3_rounds' then 3
    when p_key = 'win_slots' then 5
    when p_key = 'buy_shop_pack' then 5
    when p_key = 'vault_cashout' then 5
    when p_key = 'bank_5_streak' then 5
    when p_key = 'bank_10_streak' then 15
    when cps.quest_tier(p_key) = 'easy' then 1
    when cps.quest_tier(p_key) = 'medium' then 2
    else 3 end $function$;

CREATE OR REPLACE FUNCTION public.cps_claim_quest(p_token text, p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
        q cps.daily_quests%rowtype;
        currency text; amount int;
        spins_now int; tokens_now int; credit_now int;
        v_pday date; v_pcount int; v_board int; v_perfect jsonb;
begin
  a := cps.auth(p_token);
  select * into q from cps.daily_quests
    where account_id = a.id and day = d and quest_key = p_key for update;
  if not found then raise exception 'Quest not found.'; end if;
  if not q.done then raise exception 'Quest is not complete yet.'; end if;
  if q.claimed_at is not null then raise exception 'Already claimed.'; end if;

  currency := cps.quest_reward_currency(p_key);
  amount := cps.quest_reward_amount(p_key);

  update cps.daily_quests set claimed_at = now()
    where account_id = a.id and day = d and quest_key = p_key;

  if currency = 'token' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + amount
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, amount, 'quest:' || p_key);
  elsif currency = 'store_credit' then
    update cps.accounts set store_credit = coalesce(store_credit, 0) + amount
      where id = a.id returning store_credit into credit_now;
  else
    update cps.accounts set spins = spins + amount where id = a.id returning spins into spins_now;
    insert into cps.spin_grants (account_id, spins, reason, ref)
      values (a.id, amount, 'quest', p_key);
  end if;

  -- [201] Perfect day: if this claim leaves today's whole board claimed
  -- and no perfect-day bonus is on record yet, award 5 spin tickets.
  if not exists (select 1 from cps.daily_quests
                  where account_id = a.id and day = d and claimed_at is null) then
    insert into cps.daily_perfect_days (account_id, day) values (a.id, d)
      on conflict do nothing returning day into v_pday;
    if v_pday is not null then
      update cps.accounts set spins = spins + 5 where id = a.id returning spins into spins_now;
      insert into cps.spin_grants (account_id, spins, reason, ref)
        values (a.id, 5, 'perfect_day', d::text);
      select count(*) into v_pcount from cps.daily_perfect_days where account_id = a.id;
      select count(*) into v_board from cps.daily_quests where account_id = a.id and day = d;
      v_perfect := jsonb_build_object('tickets', 5, 'quests', v_board, 'total_days', v_pcount);
    end if;
  end if;

  return jsonb_build_object('ok', true,
    'currency', currency,
    'amount', amount,
    'tickets', case when currency = 'ticket' then amount else 0 end,
    'tokens', case when currency = 'token' then amount else 0 end,
    'credit', case when currency = 'store_credit' then amount else 0 end,
    'credit_now', credit_now,
    'spins_now', spins_now,
    'tokens_now', tokens_now,
    'perfect_day', v_perfect);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_shop_buy(p_token text, p_slot integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a      cps.accounts%rowtype;
  stock  cps.shop_stock;
  cs     timestamptz;
  v_set  text;
  price  int;
  bought int := 0;
  lim    int := null;
  packs_now int;
begin
  if p_slot not in (1, 2, 3, 4, 5, 6) then raise exception 'Bad slot.'; end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  v_set := case p_slot when 1 then stock.slot1_set when 2 then stock.slot2_set
            when 3 then stock.slot3_set when 4 then stock.slot4_set else null end;
  if p_slot = 4 then
    -- 149: the Mystery pack rolls its set at purchase time -- per buyer,
    -- per buy -- instead of the cycle-wide stock.slot4_set (which
    -- shop_ensure_stock still fills; it is simply no longer used).
    -- Pool unchanged: any active set, Jumbled included.
    select id into v_set from cps.card_sets where active order by random() limit 1;
  end if;
  price := case p_slot when 1 then 5 when 2 then 5 when 3 then 2 when 4 then 1 when 6 then 1 else 3 end;
  lim := case when p_slot = 3 then 5 when p_slot = 4 then 10 when p_slot = 5 then 15 when p_slot = 6 then 20 else null end;
  if lim is not null then
    select coalesce(sum(count), 0) into bought from cps.shop_purchases
      where account_id = a.id and cycle_start = cs and slot = p_slot;
    if coalesce(bought, 0) >= lim then
      raise exception 'Limit reached (% per restock).', lim;
    end if;
  end if;
  if a.store_credit < price then raise exception 'Not enough Store Credit.'; end if;
  update cps.accounts set store_credit = store_credit - price where id = a.id;
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, 1)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + 1;
  if p_slot = 5 then
    update cps.accounts set spins = spins + 1 where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'ticket', null, price);
    return jsonb_build_object('ok', true, 'kind', 'ticket',
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'spins_now', (select spins from cps.accounts where id = a.id));
  end if;
  if p_slot = 6 then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + 1 where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'token', null, price);
    return jsonb_build_object('ok', true, 'kind', 'token',
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'tokens_now', (select coalesce(game_tokens, 0) from cps.accounts where id = a.id));
  end if;
  perform cps.add_packs(a.id, v_set, 1, 'shop_buy', cs::text, null);
  perform cps.quest_bump(a.id, 'buy_shop_pack');
  insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    values (a.id, cs, p_slot, 'pack', v_set, price);
  select coalesce(sum(pi.packs), 0) into packs_now
    from cps.pack_inventory pi where pi.account_id = a.id and pi.set_id = v_set;
  return jsonb_build_object('ok', true, 'kind', 'pack',
                            'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed_set', case when p_slot = 4 then v_set else null end,
                            'set_id', v_set,
                            'packs_now', packs_now);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_shop_buy_all(p_token text, p_slot integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a         cps.accounts%rowtype;
  stock     cps.shop_stock;
  cs        timestamptz;
  v_set     text;
  price     int;
  lim       int;
  bought    int := 0;
  remaining int;
  total     int;
  v_rolled  text[] := '{}';
  v_set_roll text;
  v_revealed jsonb := null;
  v_packs   jsonb := '[]'::jsonb;
  packs_now int;
  i         int;
begin
  if p_slot not in (3, 4, 5, 6) then
    raise exception 'Buy all is only for limited items.';
  end if;
  a := cps.auth(p_token);
  stock := cps.shop_ensure_stock();
  cs := stock.cycle_start;
  v_set := case p_slot when 3 then stock.slot3_set else null end;
  price := case p_slot when 3 then 2 when 4 then 1 when 5 then 3 when 6 then 1 end;
  lim   := case p_slot when 3 then 5 when 4 then 10 when 5 then 15 when 6 then 20 end;

  select coalesce(sum(count), 0) into bought from cps.shop_purchases
    where account_id = a.id and cycle_start = cs and slot = p_slot;
  remaining := lim - coalesce(bought, 0);
  if remaining <= 0 then
    raise exception 'Limit reached (% per restock).', lim;
  end if;
  total := price * remaining;
  -- All-or-nothing: never a partial buy, never a partial charge.
  if a.store_credit < total then
    raise exception 'Not enough Store Credit.';
  end if;

  update cps.accounts set store_credit = store_credit - total where id = a.id;
  insert into cps.shop_purchases (account_id, cycle_start, slot, count)
    values (a.id, cs, p_slot, remaining)
    on conflict (account_id, cycle_start, slot)
    do update set count = cps.shop_purchases.count + remaining;

  if p_slot = 5 then
    update cps.accounts set spins = spins + remaining where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'ticket', null, price from generate_series(1, remaining);
    return jsonb_build_object('ok', true, 'kind', 'ticket', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'spins_now', (select spins from cps.accounts where id = a.id));
  end if;

  if p_slot = 6 then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + remaining where id = a.id;
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'token', null, price from generate_series(1, remaining);
    return jsonb_build_object('ok', true, 'kind', 'token', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'tokens_now', (select coalesce(game_tokens, 0) from cps.accounts where id = a.id));
  end if;

  perform cps.quest_bump(a.id, 'buy_shop_pack');
  if p_slot = 3 then
    perform cps.add_packs(a.id, v_set, remaining, 'shop_buy', cs::text, null);
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
    select a.id, cs, p_slot, 'pack', v_set, price from generate_series(1, remaining);
    select coalesce(sum(pi.packs), 0) into packs_now
      from cps.pack_inventory pi where pi.account_id = a.id and pi.set_id = v_set;
    v_packs := jsonb_build_array(jsonb_build_object('set_id', v_set, 'packs_now', packs_now));
    return jsonb_build_object('ok', true, 'kind', 'pack', 'slot', p_slot,
                              'count', remaining, 'total', total,
                              'store_credit', (select store_credit from cps.accounts where id = a.id),
                              'set_id', v_set,
                              'packs', v_packs,
                              'packs_now', packs_now);
  end if;

  -- Slot 4 (Mystery): the set rolls fresh per pack, exactly like a
  -- single cps_shop_buy call per pack (149) — pool is any active set.
  for i in 1..remaining loop
    select id into v_set_roll from cps.card_sets where active order by random() limit 1;
    v_rolled := array_append(v_rolled, v_set_roll);
    perform cps.add_packs(a.id, v_set_roll, 1, 'shop_buy', cs::text, null);
    insert into cps.shop_history (account_id, cycle_start, slot, item_type, set_id, price)
      values (a.id, cs, p_slot, 'pack', v_set_roll, price);
  end loop;
  select jsonb_agg(jsonb_build_object('set_id', g.set_id, 'count', g.n) order by g.n desc, g.set_id)
    into v_revealed
    from (select u as set_id, count(*)::int as n from unnest(v_rolled) as u group by u) g;
  select jsonb_agg(jsonb_build_object('set_id', g.set_id, 'packs_now',
      (select coalesce(sum(pi.packs), 0) from cps.pack_inventory pi
        where pi.account_id = a.id and pi.set_id = g.set_id)))
    into v_packs
    from (select distinct u as set_id from unnest(v_rolled) as u) g;
  return jsonb_build_object('ok', true, 'kind', 'pack', 'slot', p_slot,
                            'count', remaining, 'total', total,
                            'store_credit', (select store_credit from cps.accounts where id = a.id),
                            'revealed', coalesce(v_revealed, '[]'::jsonb),
                            'packs', coalesce(v_packs, '[]'::jsonb));
end $function$;

-- Same-day backfill (assign_daily_quests early-returns when a board
-- already exists, so today's boards need the new key inserted).
insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
select dq.account_id, dq.day, 'buy_shop_pack',
       cps.quest_tier('buy_shop_pack'), cps.quest_target('buy_shop_pack'), '{}'::jsonb
from (select distinct account_id, day from cps.daily_quests
      where day = (now() at time zone 'America/Chicago')::date) dq
on conflict do nothing;
