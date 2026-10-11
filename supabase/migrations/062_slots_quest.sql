-- =====================================================================
-- 062_slots_quest.sql — "Win on Slots" daily quest (Franklin's pick, 2026-10-11).
-- (Run after 061.)
--
--   Easy: 'win_slots' "Win on Slots" -> 5 game tokens (target 1).
--   Hook lives in 061's cps_slot_spin (quest_bump on any triple win).
--
--   Base versions carried forward (create or replace, latest live first):
--     quest_tier / quest_title / quest_reward_currency /
--     quest_reward_amount / assign_daily_quests  <- 060
--   (quest_target needs no change: 'win_slots' falls into the else-1 branch.)
-- =====================================================================

-- --- quest tiers ------------------------------------------------------------
create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done',
                             'pull_3_sets','bank_5_streak') then 'medium'
              when p_key = 'bank_10_streak' then 'ultra'
              else 'hard' end $$;

-- --- quest titles -----------------------------------------------------------
-- (060's full title function, plus 'win_slots'. Kept in sync with 060's body.)
create or replace function cps.quest_title(p_key text, p_meta jsonb) returns text
language plpgsql set search_path = cps, pg_temp as $$
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
    when 'trade_done' then 'Complete a trade'
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
    else p_key end;
end $$;

-- --- quest rewards ----------------------------------------------------------
create or replace function cps.quest_reward_currency(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('pull_token_slip','win_3_rounds','bank_5_streak','bank_10_streak',
                             'win_slots')
    then 'token' else 'ticket' end $$;

create or replace function cps.quest_reward_amount(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case
    when p_key = 'pull_token_slip' then 3
    when p_key = 'win_3_rounds' then 3
    when p_key = 'win_slots' then 5
    when p_key = 'bank_5_streak' then 5
    when p_key = 'bank_10_streak' then 15
    when cps.quest_tier(p_key) = 'easy' then 1
    when cps.quest_tier(p_key) = 'medium' then 2
    else 3 end $$;

-- --- assign: 060's 25 quests + win_slots ------------------------------------
create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
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
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack',
    'pull_token_slip','win_3_rounds','pull_spin_ticket','bank_5_streak','bank_10_streak',
    'win_slots'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

-- --- backfill: give today's players the new quest immediately ---------------
-- (tomorrow's reset picks it up via assign_daily_quests automatically)
insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
select distinct q.account_id, q.day, 'win_slots', cps.quest_tier('win_slots'),
       cps.quest_target('win_slots'), '{}'::jsonb
from cps.daily_quests q
where q.day = (now() at time zone 'America/Chicago')::date
on conflict do nothing;

-- --- verification (run after the migration) ----------------------------------
-- select cps.quest_reward_currency('win_slots'), cps.quest_reward_amount('win_slots');
--   -> token | 5

notify pgrst, 'reload schema';
