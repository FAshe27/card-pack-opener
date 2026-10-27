-- 198: Daily quest "Play a game of Plinko" (Easy tier -> pays 1 spin ticket).
-- Same pattern as 197 (WordGuesser): reward plumbing needs no change
-- (easy tier pays 1, currency 'ticket', target defaults to 1).
-- The bump fires once per successful cps_plinko_drop call, after all drops
-- resolve and token-back winnings are paid; a failed drop raises before it.
-- All four function rebuilds are insertion-only against their live bodies
-- (verified byte-for-byte + paren-depth walk). Plinko's live body uses CRLF
-- line endings; they are preserved verbatim.

CREATE OR REPLACE FUNCTION cps.quest_tier(p_key text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market','vault_cashout','play_plinko','play_wordguesser') then 'easy'
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
    when 'play_plinko' then 'Play a game of Plinko'
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
    'win_slots','vault_cashout','play_plinko','play_wordguesser'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $function$;

CREATE OR REPLACE FUNCTION public.cps_plinko_drop(p_token text, p_drops integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a           cps.accounts%rowtype;
  bal         int;
  cost_each   int := 3;
  total_cost  int;
  steps       int[];
  rights      int;
  prize       int[];
  d           int;
  i           int;
  rset        text;
  active_sets text[];
  tot_tokens  int := 0;
  tot_pr      int := 0;
  tot_pj      int := 0;
  results     jsonb := '[]';
begin
  a := cps.auth(p_token);
  if p_drops is null or p_drops not in (1, 10) then
    raise exception 'Drops must be 1 or 10.';
  end if;
  total_cost := cost_each * p_drops;

  -- lock the account row and charge the full cost up front
  select coalesce(game_tokens, 0) into bal from cps.accounts
    where id = a.id for update;
  if bal < total_cost then raise exception 'Not enough tokens.'; end if;
  update cps.accounts set game_tokens = bal - total_cost where id = a.id;
  bal := bal - total_cost;

  for d in 1..p_drops loop
    -- roll the path: 8 steps of -1 (left) / +1 (right); bin = rights
    steps := '{}';
    rights := 0;
    for i in 1..8 loop
      if cps.rand01() < 0.5 then
        steps := steps || (-1);
      else
        steps := steps || 1;
        rights := rights + 1;
      end if;
    end loop;
    prize := cps.plinko_prize(rights);

    insert into cps.plinko_drops
      (account_id, bin, steps, cost, tokens_back, packs_random, packs_jumbled)
    values
      (a.id, rights, steps, cost_each, prize[1], prize[2], prize[3]);

    -- pay packs for this drop (jumbled in one grant, random per pack)
    if prize[3] > 0 then
      perform cps.add_packs(a.id, 'jumbled', prize[3], 'plinko_win',
        'bin_' || (rights + 1), null);
    end if;
    if prize[2] > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for plinko prizes.';
      end if;
      for i in 1..prize[2] loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'plinko_win',
          'bin_' || (rights + 1), null);
      end loop;
    end if;

    tot_tokens := tot_tokens + prize[1];
    tot_pr := tot_pr + prize[2];
    tot_pj := tot_pj + prize[3];
    results := results || jsonb_build_object(
      'steps', to_jsonb(steps), 'bin', rights,
      'tokens', prize[1], 'pr', prize[2], 'pj', prize[3]);
  end loop;

  -- pay token-back winnings
  if tot_tokens > 0 then
    update cps.accounts set game_tokens = game_tokens + tot_tokens
      where id = a.id;
    bal := bal + tot_tokens;
  end if;

  perform cps.quest_bump(a.id, 'play_plinko');

  return jsonb_build_object(
    'tokens_now', bal,
    'results', results,
    'totals', jsonb_build_object(
      'tokens', tot_tokens, 'pr', tot_pr, 'pj', tot_pj));
end $function$;

-- Backfill today's boards (same as 197) so the quest is playable today.
insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
select distinct dq.account_id, dq.day, 'play_plinko', 'easy', 1, '{}'::jsonb
from cps.daily_quests dq
where dq.day = (now() at time zone 'America/Chicago')::date
on conflict do nothing;
