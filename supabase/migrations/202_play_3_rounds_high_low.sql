-- 202_play_3_rounds_high_low.sql
-- Franklin, 2026-10-28: the daily quest keyed win_3_rounds was titled
-- "Win 3 Rounds of High/Low" but its target was 1 and it counted only
-- correct guesses. His call: it is a PLAY quest -- "Play 3 Rounds of
-- High/Low", target 3, and a round counts when a run FINISHES, either
-- busted (a loss) or claimed (a banked win). Guesses inside a run no
-- longer tick it. Changes: quest_title (one string), quest_target
-- (win_3_rounds joins the named-target list at 3), and the
-- game_run_quest_hook trigger's first branch (the bank_5/bank_10
-- branch is untouched). Boards already assigned for today keep any
-- progress earned; unfinished rows are retargeted to 3 below so
-- today's boards match the new wording immediately.
-- Function bodies are the live definitions with only the marked
-- changes (line endings preserved).

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

CREATE OR REPLACE FUNCTION cps.quest_target(p_key text)
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case p_key when 'open_packs' then 3 when 'open_packs_set' then 2 when 'pull_holos_3' then 3
    when 'pull_3_sets' then 3 when 'pull_2_holos_pack' then 2 when 'win_3_rounds' then 3 else 1 end $function$;

CREATE OR REPLACE FUNCTION cps.game_run_quest_hook()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
begin
  -- [202] "Play 3 Rounds of High/Low": a finished run counts, however
  -- it ends -- busted (a loss) or claimed (a banked win). Guesses
  -- inside a run no longer tick this quest.
  if OLD.status = 'active' and NEW.status in ('busted', 'claimed') then
    perform cps.quest_bump(NEW.account_id, 'win_3_rounds', 1);
  end if;
  -- banking + claiming a run -> the streak quests
  if OLD.status = 'active' and NEW.status = 'claimed' then
    if NEW.streak >= 5 then perform cps.quest_bump(NEW.account_id, 'bank_5_streak', 1); end if;
    if NEW.streak >= 10 then perform cps.quest_bump(NEW.account_id, 'bank_10_streak', 1); end if;
  end if;
  return NEW;
end $function$;

update cps.daily_quests
   set target = 3
 where quest_key = 'win_3_rounds'
   and day = (now() at time zone 'America/Chicago')::date
   and done = false
   and claimed_at is null;
