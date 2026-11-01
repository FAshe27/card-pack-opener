-- 219_wheel_big_win_2plus.sql
-- Franklin's ask (2026-11-01): the daily quest 'Win 3 or more packs from one
-- spin' becomes 'Win 2 or more packs from one spin', moves Hard -> Medium,
-- and pays 2 tickets. Three one-line changes:
--   1. cps.quest_tier: 'wheel_big_win' joins the medium list (the reward
--      helpers already pay medium = 2 tickets, no reward-function change).
--   2. cps.quest_title: the one title line, 3 -> 2.
--   3. public-facing cps.cps_spin_wheel: the big-win bump threshold >= 3 -> >= 2.
-- Each rebuilt body differs from its live body by exactly that one change
-- (verified: reverting the change reproduces the live body byte-for-byte).
-- Then: today's already-assigned boards get their stored tier relabelled,
-- and a backfill bumps everyone who provably earned it today -- a single
-- cps.pack_grants row of 2+ packs (reason 'wheel') can only come from one
-- spin's prize distribution, so it proves a 2+ single-spin win. (A 2-pack
-- win split 1+1 across two sets inside one SPIN x10 batch is not separable
-- from two 1-pack spins in the grant records and is not backfilled.)
-- quest_bump skips claimed rows, so today's one claimer (won 3+, claimed
-- 3 tickets under the old rule) is untouched.

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
                             'pull_3_sets','bank_5_streak','market_trade','wheel_big_win') then 'medium'
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
    when 'wheel_big_win' then 'Win 2 or more packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    when 'pull_token_slip' then 'Pull a Token Slip'
    when 'win_3_rounds' then 'Play 3 Rounds of High/Low'
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

CREATE OR REPLACE FUNCTION public.cps_spin_wheel(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a          cps.accounts%rowtype;
  res        jsonb;
  prize      jsonb;
  packs_now  int;
  tokens_now int;
  credit_now int;
  spins_now  int;
  k          text;
begin
  a := cps.auth(p_token);

  -- Atomic: only decrement if spins > 0. Concurrent calls can't both succeed.
  update cps.accounts set spins = spins - 1 where id = a.id and coalesce(spins, 0) > 0
    returning spins into spins_now;
  if not found then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', prize ->> 'kind'));

  if prize ->> 'kind' = 'tokens' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, (prize ->> 'tokens')::int, 'wheel');
  elsif prize ->> 'kind' = 'credit' then
    update cps.accounts set store_credit = coalesce(store_credit, 0) + (prize ->> 'credit')::int
      where id = a.id returning store_credit into credit_now;
  elsif prize ->> 'kind' = 'packs' then
    perform cps.add_packs(a.id, (prize ->> 'set_id'), (prize ->> 'packs')::int, 'wheel', null, null);
    select packs into packs_now from cps.pack_inventory where account_id = a.id and set_id = (prize ->> 'set_id');
  elsif prize ->> 'kind' = 'tickets' then
    update cps.accounts set spins = coalesce(spins, 0) + (prize ->> 'tickets')::int
      where id = a.id returning spins into spins_now;
    insert into cps.spin_grants (account_id, spins, reason, ref)
      values (a.id, (prize ->> 'tickets')::int, 'wheel_bonus', 'bonus:tickets');
  elsif prize ->> 'kind' = 'random_packs' then
    for k in select jsonb_object_keys(prize -> 'packs_by_set') loop
      perform cps.add_packs(a.id, k, (prize -> 'packs_by_set' ->> k)::int, 'wheel', null, null);
    end loop;
  end if;

  perform cps.quest_bump(a.id, 'spin_wheel', 1);
  if coalesce((prize ->> 'packs')::int, 0) >= 2 then
    perform cps.quest_bump(a.id, 'wheel_big_win', 1);
  end if;

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'packs_by_set', prize -> 'packs_by_set',
    'tokens_won', (prize ->> 'tokens')::int,
    'tokens_now', tokens_now,
    'credit_won', (prize ->> 'credit')::int,
    'credit_now', credit_now,
    'tickets_won', (prize ->> 'tickets')::int,
    'spins_left', spins_now
  );
end $function$;

-- Today's boards: relabel the stored tier snapshot for this quest.
update cps.daily_quests
   set tier = 'medium'
 where quest_key = 'wheel_big_win'
   and day = (now() at time zone 'America/Chicago')::date;

-- Backfill: trigger the quest for everyone who already earned it today.
select cps.quest_bump(g.account_id, 'wheel_big_win', 1)
  from (select distinct account_id
          from cps.pack_grants
         where reason = 'wheel'
           and packs >= 2
           and at >= ((now() at time zone 'America/Chicago')::date::timestamp
                      at time zone 'America/Chicago')) g;
