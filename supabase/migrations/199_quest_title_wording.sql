-- 199: Quest title wording (Franklin's calls, 2026-10-27):
--  * spell out "3 or more" instead of "3+" (can be misread as "more than 3");
--  * the game is named High/Low everywhere else on the site (Arcade tile
--    "HIGH / LOW", game page header, FAQ) -- the quest titles were the only
--    player-facing "Higher/Lower" left, so they come in line;
--  * the streak titles take his restructured wording with "or higher".
-- Title-only change in cps.quest_title; the rebuilt body differs from live
-- on exactly the four lines below, nothing else (verified by substitution
-- reversal against the live definition).

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
    when 'play_wordguesser' then 'Play a game of WordGuesser'
    else p_key end;
end $function$;
