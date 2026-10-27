-- 200_wordguesser_quest_complete_a_round.sql
-- Franklin, 2026-10-27: retitle the WordGuesser daily to
-- 'Complete a round of WordGuesser' and make the trigger match the
-- words: the quest now bumps when a round ENDS (win or lose) in
-- cps_wordle_guess, instead of when a game starts in cps_wordle_start.
-- All three bodies are the live definitions with only these deltas
-- (title: one string; start: the bump line removed; guess: one
-- if-block inserted after the win/loss updates).
-- Note: Franklin's own 2026-10-27 completion was credited manually
-- (quest_bump) before this migration, since he played before the
-- quest existed (migration 197).

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
    else p_key end;
end $function$;

CREATE OR REPLACE FUNCTION public.cps_wordle_start(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a       cps.accounts%rowtype;
  today   date := (now() at time zone 'America/Chicago')::date;
  g       cps.wordle_games%rowtype;
  is_free boolean;
  bal     int;
  spn     int;
  ans     text;
begin
  a := cps.auth(p_token);

  select * into g from cps.wordle_games
    where account_id = a.id and status = 'playing'
    order by created_at desc limit 1;
  if g.id is not null then
    select coalesce(game_tokens, 0), coalesce(spins, 0) into bal, spn
      from cps.accounts where id = a.id;
    return jsonb_build_object(
      'game', cps.wordle_game_json(g, bal, spn),
      'resumed', true,
      'tokens_now', bal,
      'spins_now', spn
    );
  end if;

  is_free := not exists (
    select 1 from cps.wordle_games
     where account_id = a.id and day = today and free);

  if not is_free then
    -- lock the account row and charge the entry up front
    select game_tokens into bal from cps.accounts where id = a.id for update;
    if coalesce(bal, 0) < 10 then
      raise exception 'Not enough game tokens (need 10).';
    end if;
    update cps.accounts set game_tokens = game_tokens - 10 where id = a.id;
  end if;

  select word into ans from cps.wordle_words
    where is_answer order by cps.rand01() limit 1;
  if ans is null then raise exception 'The word bank is empty.'; end if;

  insert into cps.wordle_games (account_id, day, answer, free)
  values (a.id, today, ans, is_free)
  returning * into g;


  select coalesce(game_tokens, 0), coalesce(spins, 0) into bal, spn
    from cps.accounts where id = a.id;
  return jsonb_build_object(
    'game', cps.wordle_game_json(g, bal, spn),
    'resumed', false,
    'tokens_now', bal,
    'spins_now', spn
  );
end $function$;

CREATE OR REPLACE FUNCTION public.cps_wordle_guess(p_token text, p_guess text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a      cps.accounts%rowtype;
  g      cps.wordle_games%rowtype;
  w      text := upper(coalesce(p_guess, ''));
  marks  text;
  p      int[];
  grants jsonb := '[]';
  tok    int;
  spn    int;
  n      int;
begin
  a := cps.auth(p_token);

  if char_length(w) < 5 then raise exception 'Not enough letters'; end if;
  if char_length(w) > 5 or w !~ '^[A-Z]{5}$' then
    raise exception 'Not in word list';
  end if;
  if not exists (select 1 from cps.wordle_words where word = w) then
    raise exception 'Not in word list';
  end if;

  select * into g from cps.wordle_games
    where account_id = a.id and status = 'playing'
    order by created_at desc limit 1 for update;
  if g.id is null then
    raise exception 'No game in progress — start a game first.';
  end if;

  marks := cps.wordle_score(g.answer, w);

  update cps.wordle_games set guesses = guesses || w
    where id = g.id returning * into g;
  n := array_length(g.guesses, 1);

  if marks = 'GGGGG' then
    p := cps.wordle_prize(n);
    if p[1] > 0 then grants := cps.wordle_grant_packs(a, p[1]); end if;
    if p[2] > 0 then
      update cps.accounts set spins = spins + p[2] where id = a.id;
    end if;
    update cps.wordle_games
       set status = 'won', prize_packs = p[1], prize_tickets = p[2],
           ended_at = now()
     where id = g.id returning * into g;

  elsif n >= 6 then
    update cps.wordle_games
       set status = 'lost', ended_at = now()
     where id = g.id returning * into g;
  end if;

  if g.status in ('won', 'lost') then
    perform cps.quest_bump(a.id, 'play_wordguesser');
  end if;

  select coalesce(game_tokens, 0), coalesce(spins, 0) into tok, spn
    from cps.accounts where id = a.id;
  return jsonb_build_object(
    'game', cps.wordle_game_json(g, tok, spn),
    'grants', grants,
    'tokens_now', tok,
    'spins_now', spn,
    'stats', cps.wordle_stats(a.id)
  );
end $function$;
