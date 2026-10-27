-- 197: Daily quest "Play a game of WordGuesser" (Easy tier -> pays 1 spin ticket).
-- Reward plumbing needs no change: cps.quest_reward_amount pays 1 for easy tier and
-- cps.quest_reward_currency pays 'ticket' for any key outside its token list.
-- cps.quest_target defaults to 1, which is the target ("play a game").
-- All four function rebuilds are insertion-only against their live bodies
-- (verified: removing the inserted text reproduces each live definition byte-for-byte,
-- and a paren-depth walk over each body passes).

CREATE OR REPLACE FUNCTION cps.quest_tier(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market','vault_cashout','play_wordguesser') then 'easy'
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
    when 'wheel_big_win' then 'Win 3+ packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    when 'pull_token_slip' then 'Pull a Token Slip'
    when 'win_3_rounds' then 'Win 3 Rounds of Higher/Lower'
    when 'pull_spin_ticket' then 'Pull a Spin Ticket'
    when 'bank_5_streak' then 'Bank and Claim a 5+ Streak in Higher/Lower'
    when 'bank_10_streak' then 'Bank and Claim a 10+ Streak in Higher/Lower'
    when 'win_slots' then 'Win on Slots'
    when 'vault_cashout' then 'Cash out a Vault Breaker run'
    when 'play_wordguesser' then 'Play a game of WordGuesser'
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
    'win_slots','vault_cashout','play_wordguesser'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
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

  perform cps.quest_bump(a.id, 'play_wordguesser');

  select coalesce(game_tokens, 0), coalesce(spins, 0) into bal, spn
    from cps.accounts where id = a.id;
  return jsonb_build_object(
    'game', cps.wordle_game_json(g, bal, spn),
    'resumed', false,
    'tokens_now', bal,
    'spins_now', spn
  );
end $function$;

-- Backfill today's boards: assign_daily_quests() early-returns for accounts that
-- already have today's quests, so without this the new quest would first appear
-- tomorrow. Insert the row for every account that already has a board today.
insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
select distinct dq.account_id, dq.day, 'play_wordguesser', 'easy', 1, '{}'::jsonb
from cps.daily_quests dq
where dq.day = (now() at time zone 'America/Chicago')::date
on conflict do nothing;
