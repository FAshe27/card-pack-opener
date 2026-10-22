-- =====================================================================
-- 171_vault_breaker.sql -- Vault Breaker: real economy (Sandbox,
-- admin-only phase) + its daily quest. (Run after 170.)
--
--   Franklin (2026-10-21): "Move it to real tokens and remove dev
--   info." Vault Breaker graduates from fake Sandbox tokens to the
--   real economy the way Scratchoffs (129) and Plinko (145) did:
--   real game tokens in, real packs out, with the SERVER dealing
--   every board. Still a Sandbox 'testing' item: every RPC raises
--   unless the caller is an admin. Dropping the admin gate, flipping
--   the Sandbox item to 'public' with noTab, and pointing the Arcade
--   tile at it is the separate graduation step, later, on Franklin's
--   word (a "Coming Soon" teaser tile sits in the lobby meanwhile).
--
--   Game shape (locked through Franklin's V1-V3 Sandbox playtests;
--   do not re-tune here):
--     5x5 grid, 25 tiles. Before each run the player picks a vault:
--     3 alarms "Day Job" / 5 "Heist" / 8 "Inside Job". Entry is
--     3 game tokens flat, every vault. Crack safe tiles one at a
--     time to grow the pot; cash out whenever for the highest tier
--     reached; trip an alarm and the run ends, pot lost (the entry
--     is the only loss). Cracking the last safe tile is a full
--     clear and auto-banks the top tier.
--
--   Prize tables (highest tier reached pays; tokens = game tokens
--   back, pr = random packs, pj = Jumbled packs) -- defined ONCE in
--   cps.vault_prize below; cps.vault_tiers derives the display table
--   from it, vault_state hands that table to the client, and the
--   client CONFIG is a display copy of the same numbers:
--     3 alarms: 4 -> 3 tokens back | 6 -> 3 Jumbled | 8 -> 3+3 |
--               10 -> 5+5 | 12 -> 10+10 | 15 -> 20+20 | 18 -> 50+25
--     5 alarms: 3 -> 3 tokens back | 5 -> 3+3 | 7 -> 5+5 |
--               9 -> 25 random + 20 Jumbled | 11 -> 30+20 |
--               14 -> 40+25 | 17 -> 100 random + 25 Jumbled
--     8 alarms: 2 -> 3 tokens back | 4 -> 10 random + 5 Jumbled |
--               6 -> 25+25 | 9 -> 50+25 | 12 -> 75 random + 50 Jumbled |
--               17 (full clear) -> 100 random + 100 Jumbled
--   "Random packs" are granted one at a time to a uniform-random
--   active set (cps.add_packs, reason 'vault_win'), exactly like
--   slot / scratch / plinko wins.
--
--   Announcements (Slots 061 pattern): banking the vault's OWN top
--   tier -- which includes every full clear -- notifies every other
--   player (kind 'vault_win', target 'arcade'). Nothing else
--   announces; V3 playtesting showed a prize-size threshold would
--   fire on ~7% of Inside Job runs, so the rule is tier identity.
--
--   Daily quest (062 pattern): Easy 'vault_cashout' "Cash out a
--   Vault Breaker run" -> 5 game tokens, target 1. vault_settle
--   bumps it on every banked cash-out, full clears included. The
--   quest helpers below are the LIVE bodies (read back from the
--   database 2026-10-21) with 'vault_cashout' inserted -- nothing
--   else about them changes; cps.quest_target needs no edit
--   (its else branch is already 1).
--
--   Every RPC takes p_token (client always sends one). Alarm
--   positions are dealt and stored server-side only: run payloads
--   carry 'alarms' as null until the run is over.
-- =====================================================================

-- --- run store ---------------------------------------------------------
create table if not exists cps.vault_runs (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references cps.accounts(id) on delete cascade,
  mode          int not null check (mode in (3, 5, 8)),
  alarms        int[] not null,               -- alarm tile indices (0-24), SERVER ONLY
  picks         int[] not null default '{}',  -- tiles cracked, in order (all safe while active)
  depth         int not null default 0,       -- = array_length(picks), kept in step by vault_pick
  status        text not null default 'active'
                check (status in ('active', 'cashed', 'busted')),
  cost          int not null default 3,
  tokens_back   int not null default 0,
  packs_random  int not null default 0,
  packs_jumbled int not null default 0,
  announced     boolean not null default false, -- a global announcement was sent for this run
  created_at    timestamptz not null default now(),
  ended_at      timestamptz
);
-- one active run per player, enforced by the database itself
create unique index if not exists cps_vault_runs_one_active_idx
  on cps.vault_runs (account_id) where status = 'active';
create index if not exists cps_vault_runs_account_idx
  on cps.vault_runs (account_id, created_at desc);

-- --- prize table: [tokens_back, packs_random, packs_jumbled] -----------
-- Highest tier at or below p_depth; {0,0,0} below the first tier.
create or replace function cps.vault_prize(p_mode int, p_depth int) returns int[]
language plpgsql immutable set search_path = cps, pg_temp as $$
begin
  case p_mode
    when 3 then
      if    p_depth >= 18 then return array[0, 50, 25];
      elsif p_depth >= 15 then return array[0, 20, 20];
      elsif p_depth >= 12 then return array[0, 10, 10];
      elsif p_depth >= 10 then return array[0, 5, 5];
      elsif p_depth >= 8  then return array[0, 3, 3];
      elsif p_depth >= 6  then return array[0, 0, 3];
      elsif p_depth >= 4  then return array[3, 0, 0];
      end if;
    when 5 then
      if    p_depth >= 17 then return array[0, 100, 25];
      elsif p_depth >= 14 then return array[0, 40, 25];
      elsif p_depth >= 11 then return array[0, 30, 20];
      elsif p_depth >= 9  then return array[0, 25, 20];
      elsif p_depth >= 7  then return array[0, 5, 5];
      elsif p_depth >= 5  then return array[0, 3, 3];
      elsif p_depth >= 3  then return array[3, 0, 0];
      end if;
    when 8 then
      if    p_depth >= 17 then return array[0, 100, 100];
      elsif p_depth >= 12 then return array[0, 75, 50];
      elsif p_depth >= 9  then return array[0, 50, 25];
      elsif p_depth >= 6  then return array[0, 25, 25];
      elsif p_depth >= 4  then return array[0, 10, 5];
      elsif p_depth >= 2  then return array[3, 0, 0];
      end if;
    else raise exception 'Bad vault mode %', p_mode;
  end case;
  return array[0, 0, 0];
end $$;

-- --- display tiers, derived from vault_prize (single source) -----------
create or replace function cps.vault_tiers(p_mode int) returns jsonb
language plpgsql immutable set search_path = cps, pg_temp as $$
declare
  depths int[];
  d      int;
  p      int[];
  out    jsonb := '[]';
begin
  case p_mode
    when 3 then depths := array[4, 6, 8, 10, 12, 15, 18];
    when 5 then depths := array[3, 5, 7, 9, 11, 14, 17];
    when 8 then depths := array[2, 4, 6, 9, 12, 17];
    else raise exception 'Bad vault mode %', p_mode;
  end case;
  foreach d in array depths loop
    p := cps.vault_prize(p_mode, d);
    out := out || jsonb_build_object(
      'tiles', d, 'tokens', p[1], 'pr', p[2], 'pj', p[3]);
  end loop;
  return out;
end $$;

create or replace function cps.vault_all_tables() returns jsonb
language sql set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    '3', cps.vault_tiers(3), '5', cps.vault_tiers(5), '8', cps.vault_tiers(8))
$$;

create or replace function cps.vault_next_tier(p_mode int, p_depth int) returns jsonb
language plpgsql immutable set search_path = cps, pg_temp as $$
declare t jsonb;
begin
  for t in select value from jsonb_array_elements(cps.vault_tiers(p_mode)) loop
    if (t ->> 'tiles')::int > p_depth then return t; end if;
  end loop;
  return null;
end $$;

create or replace function cps.vault_mode_name(p_mode int) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case p_mode when 3 then 'Day Job' when 5 then 'Heist'
                     when 8 then 'Inside Job' end
$$;

-- prize text, spelled out in full (mirrors the client's prizeText;
-- used by the announcement so the wording can never drift server-side)
create or replace function cps.vault_prize_text(p_tokens int, p_pr int, p_pj int)
returns text language plpgsql immutable set search_path = cps, pg_temp as $$
declare parts text[] := '{}';
begin
  if p_pr > 0 then
    parts := parts || (p_pr || ' random pack' || case when p_pr = 1 then '' else 's' end);
  end if;
  if p_pj > 0 then
    parts := parts || (p_pj || ' Jumbled pack' || case when p_pj = 1 then '' else 's' end);
  end if;
  if p_tokens > 0 then
    parts := parts || (p_tokens || ' token' || case when p_tokens = 1 then '' else 's' end || ' back');
  end if;
  if coalesce(array_length(parts, 1), 0) = 0 then return 'Nothing'; end if;
  return array_to_string(parts, ' + ');
end $$;

-- --- shared run payload --------------------------------------------------
-- Alarm positions leave the server ONLY once the run is over.
create or replace function cps.vault_run_json(r cps.vault_runs, p_tokens int)
returns jsonb language plpgsql set search_path = cps, pg_temp as $$
declare
  p    int[] := cps.vault_prize(r.mode, r.depth);
  safe int := 25 - r.mode;
  over boolean := r.status <> 'active';
begin
  return jsonb_build_object(
    'run_id',   r.id,
    'mode',     r.mode,
    'name',     cps.vault_mode_name(r.mode),
    'status',   r.status,
    'depth',    r.depth,
    'picks',    to_jsonb(r.picks),
    'safe_tiles', safe,
    'bankable', jsonb_build_object('tokens', p[1], 'pr', p[2], 'pj', p[3]),
    'bankable_text', cps.vault_prize_text(p[1], p[2], p[3]),
    'next_tier', case when over then null
                      else cps.vault_next_tier(r.mode, r.depth) end,
    'tokens_now', p_tokens,
    'alarms',   case when over then to_jsonb(r.alarms) else null end,
    'banked',   case when r.status = 'cashed' then jsonb_build_object(
                      'tokens', r.tokens_back, 'pr', r.packs_random,
                      'pj', r.packs_jumbled)
                     else null end,
    'full',     r.status = 'cashed' and r.depth >= safe,
    'announced', r.announced
  );
end $$;

-- --- settle: bank the run's prize (cash-out + full-clear share this) ----
create or replace function cps.vault_settle(p_a cps.accounts, p_run_id uuid)
returns jsonb language plpgsql set search_path = cps, pg_temp as $$
declare
  r           cps.vault_runs%rowtype;
  p           int[];
  top         int[];
  ref         text;
  active_sets text[];
  grants      jsonb := '[]';
  i           int;
  rset        text;
  announce    boolean := false;
  vtext       text;
begin
  select * into r from cps.vault_runs where id = p_run_id for update;
  if r.id is null or r.status <> 'active' then
    raise exception 'That run is already over.';
  end if;
  p := cps.vault_prize(r.mode, r.depth);
  if p = array[0, 0, 0] then
    raise exception 'No prize to cash out yet.';
  end if;
  ref := case r.mode when 3 then 'day_job' when 5 then 'heist'
                     else 'inside_job' end;

  -- jumbled packs first (single grant), then random packs one at a time
  if p[3] > 0 then
    perform cps.add_packs(p_a.id, 'jumbled', p[3], 'vault_win', ref, null);
  end if;
  if p[2] > 0 then
    select coalesce(array_agg(id order by id), '{}') into active_sets
      from cps.card_sets where active and id <> 'jumbled';
    if coalesce(array_length(active_sets, 1), 0) = 0 then
      raise exception 'No active sets available for vault prizes.';
    end if;
    for i in 1..p[2] loop
      rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
      perform cps.add_packs(p_a.id, rset, 1, 'vault_win', ref, null);
      grants := grants || jsonb_build_object('set_id', rset, 'packs', 1);
    end loop;
  end if;
  if p[1] > 0 then
    update cps.accounts set game_tokens = game_tokens + p[1] where id = p_a.id;
  end if;

  -- announcement rule: banking the vault's own top tier (identity,
  -- not prize size). A full clear always banks the top tier.
  top := cps.vault_prize(r.mode, 25 - r.mode);
  announce := (p = top);

  update cps.vault_runs
     set status = 'cashed', tokens_back = p[1], packs_random = p[2],
         packs_jumbled = p[3], announced = announce, ended_at = now()
   where id = r.id;

  -- daily quest: 'vault_cashout' (registered below)
  perform cps.quest_bump(p_a.id, 'vault_cashout', 1);

  if announce then
    if r.depth >= 25 - r.mode then
      vtext := '🔓 ' || p_a.display_name || ' FULL-CLEARED the ' ||
               cps.vault_mode_name(r.mode) || ' vault in Vault Breaker and won ' ||
               cps.vault_prize_text(p[1], p[2], p[3]) || '!';
    else
      vtext := '🔓 ' || p_a.display_name || ' hit the top tier of the ' ||
               cps.vault_mode_name(r.mode) || ' vault in Vault Breaker and won ' ||
               cps.vault_prize_text(p[1], p[2], p[3]) || '!';
    end if;
    insert into cps.notifications (account_id, kind, text, target_view)
      select xx.id, 'vault_win', vtext, 'arcade'
        from cps.accounts xx
       where xx.id <> p_a.id and not coalesce(xx.disabled, false);
  end if;

  return jsonb_build_object('grants', grants);
end $$;

-- --- state: balance + prize tables + any active run (resume) ------------
create or replace function public.cps_vault_state(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
  r   cps.vault_runs%rowtype;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  return jsonb_build_object(
    'tokens_now', bal,
    'cost', 3,
    'tables', cps.vault_all_tables(),
    'run', case when r.id is null then null
                else cps.vault_run_json(r, bal) end
  );
end $$;

-- --- start: charge 3 tokens, deal the board server-side -----------------
-- An already-active run is resumed and returned, never double-charged
-- (the Scratchoffs buy pattern), so a client retry is always safe.
create or replace function public.cps_vault_start(p_token text, p_mode int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  bal    int;
  r      cps.vault_runs%rowtype;
  alarms int[];
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  if p_mode is null or p_mode not in (3, 5, 8) then
    raise exception 'Pick a vault: 3, 5 or 8 alarms.';
  end if;

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  if r.id is not null then
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'tokens_now', bal,
      'run', cps.vault_run_json(r, bal),
      'resumed', true
    );
  end if;

  -- lock the account row and charge the entry up front
  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < 3 then
    raise exception 'Not enough game tokens (need 3).';
  end if;
  update cps.accounts set game_tokens = game_tokens - 3 where id = a.id;
  bal := bal - 3;

  -- deal: p_mode distinct tiles out of 0..24, stored sorted
  select array_agg(x order by x) into alarms from (
    select t as x from generate_series(0, 24) as t
     order by cps.rand01() limit p_mode
  ) s;

  insert into cps.vault_runs (account_id, mode, alarms)
  values (a.id, p_mode, alarms)
  returning * into r;

  return jsonb_build_object(
    'tokens_now', bal,
    'run', cps.vault_run_json(r, bal),
    'resumed', false
  );
end $$;

-- --- pick: crack one tile -------------------------------------------------
create or replace function public.cps_vault_pick(p_token text, p_tile int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  r      cps.vault_runs%rowtype;
  bal    int;
  settle jsonb := null;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  if p_tile is null or p_tile < 0 or p_tile > 24 then
    raise exception 'Bad tile.';
  end if;

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1 for update;
  if r.id is null then raise exception 'No active Vault Breaker run.'; end if;
  if p_tile = any (r.picks) then
    raise exception 'That tile is already cracked.';
  end if;

  if p_tile = any (r.alarms) then
    update cps.vault_runs
       set status = 'busted', ended_at = now()
     where id = r.id
     returning * into r;
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'run', cps.vault_run_json(r, bal),
      'tokens_now', bal
    );
  end if;

  update cps.vault_runs
     set picks = picks || p_tile, depth = depth + 1
   where id = r.id
   returning * into r;

  if r.depth >= 25 - r.mode then
    -- last safe tile cracked: full clear auto-banks the top tier
    settle := cps.vault_settle(a, r.id);
    select * into r from cps.vault_runs where id = r.id;
  end if;

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'run', cps.vault_run_json(r, bal),
    'tokens_now', bal,
    'grants', coalesce(settle -> 'grants', '[]'::jsonb)
  );
end $$;

-- --- cash out: bank the highest tier reached ------------------------------
create or replace function public.cps_vault_cashout(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  r      cps.vault_runs%rowtype;
  bal    int;
  settle jsonb;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;

  select * into r from cps.vault_runs
    where account_id = a.id and status = 'active'
    order by created_at desc limit 1;
  if r.id is null then raise exception 'No active Vault Breaker run.'; end if;

  settle := cps.vault_settle(a, r.id); -- raises below the first tier
  select * into r from cps.vault_runs where id = r.id;
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'run', cps.vault_run_json(r, bal),
    'tokens_now', bal,
    'grants', settle -> 'grants'
  );
end $$;

-- =====================================================================
-- Daily quest: 'vault_cashout' -- "Cash out a Vault Breaker run"
-- Easy, pays 5 game tokens, target 1 (062's win_slots shape exactly).
-- The four helpers are the live bodies with the key inserted;
-- quest_target is untouched (its else branch already returns 1).
-- =====================================================================

create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market','vault_cashout') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card',
                             'pull_3_sets','bank_5_streak','market_trade') then 'medium'
              when p_key = 'bank_10_streak' then 'ultra'
              else 'hard' end $$;

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
    else p_key end;
end $$;

create or replace function cps.quest_reward_currency(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('pull_token_slip','win_3_rounds','bank_5_streak','bank_10_streak',
                             'win_slots','vault_cashout')
    then 'token' else 'ticket' end $$;

create or replace function cps.quest_reward_amount(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case
    when p_key = 'pull_token_slip' then 3
    when p_key = 'win_3_rounds' then 3
    when p_key = 'win_slots' then 5
    when p_key = 'vault_cashout' then 5
    when p_key = 'bank_5_streak' then 5
    when p_key = 'bank_10_streak' then 15
    when cps.quest_tier(p_key) = 'easy' then 1
    when cps.quest_tier(p_key) = 'medium' then 2
    else 3 end $$;

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
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','visit_market','market_trade',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack',
    'pull_token_slip','win_3_rounds','pull_spin_ticket','bank_5_streak','bank_10_streak',
    'win_slots','vault_cashout'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

-- --- backfill: give today's players the new quest immediately ---------
-- (tomorrow's reset picks it up via assign_daily_quests automatically)
insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
select distinct q.account_id, q.day, 'vault_cashout', cps.quest_tier('vault_cashout'),
       cps.quest_target('vault_cashout'), '{}'::jsonb
from cps.daily_quests q
where q.day = (now() at time zone 'America/Chicago')::date
on conflict do nothing;

-- --- verification (run after executing) ----------------------------------
-- select cps.vault_prize(3, 12), cps.vault_prize(5, 9), cps.vault_prize(8, 17);
--   -> {0,10,10} {0,25,20} {0,100,100}
-- select cps.vault_tiers(8);
--   -> 6 tiers, last is {"tiles":17,"tokens":0,"pr":100,"pj":100}
-- select cps.quest_tier('vault_cashout'), cps.quest_title('vault_cashout','{}'),
--        cps.quest_reward_currency('vault_cashout'), cps.quest_reward_amount('vault_cashout');
--   -> easy | Cash out a Vault Breaker run | token | 5
-- A bogus-token probe of cps_vault_state should answer
-- 28000 'Not logged in' (auth first); a NON-admin account should get
-- 'Admin only.' from every vault RPC during this Sandbox phase.
-- Full post-auth smoke: 171_vault_breaker_verify.sql (rolls back).

notify pgrst, 'reload schema';
