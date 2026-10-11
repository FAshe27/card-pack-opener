-- =====================================================================
-- 061_slots.sql — Slot machine arcade game (Franklin's spec, 2026-10-11).
-- (Run after 060.)
--
--   Cost: 3 game tokens per spin, deducted server-side.
--   Reels: 3 independent reels, rarity-weighted symbols per reel:
--     common 35 / uncommon 25 / rare 18 / epic 12 / legendary 7 / chase 3
--   Win = all three symbols match (triple). Triple odds:
--     common 4.29% (1 in 23) / uncommon 1.56% (1 in 64) /
--     rare 0.58% (1 in 171) / epic 0.17% (1 in 579) /
--     legendary 0.034% (1 in 2,915) / chase 0.0027% (1 in 37,037)
--   Any triple: ~6.6% of spins (about 1 win per 15 spins).
--
--   Prizes (Franklin-approved 2026-10-11, packs only — no tickets/tokens):
--     common    ->  0 random packs +  3 Jumbled Mess
--     uncommon  ->  3 random packs +  3 Jumbled Mess
--     rare      ->  5 random packs +  5 Jumbled Mess
--     epic      -> 10 random packs + 10 Jumbled Mess
--     legendary -> 20 random packs + 20 Jumbled Mess  (+ global announcement)
--     chase     -> 50 random packs + 25 Jumbled Mess  (+ global announcement)
--   "Random packs": server picks a uniform-random active set per pack
--   (all active sets except 'jumbled'; periodic included while active).
--
--   Economy note (flagged to Franklin, accepted): EV ≈ 0.33 packs/spin at
--   3 tokens/spin ≈ 9 tokens per pack. Generous vs Higher/Lower — tune later
--   if pack inflation shows up (knobs: spin cost, prize counts, reel weights).
--
--   Server is authoritative: reels roll here, client only animates.
--   Every RPC takes p_token (client always sends one).
-- =====================================================================

-- --- reel roller -----------------------------------------------------------
create or replace function cps.slot_reel() returns text
language plpgsql set search_path = cps, pg_temp as $$
declare x float8 := cps.rand01() * 100;
begin
  if x < 35 then return 'common';
  elsif x < 60 then return 'uncommon';
  elsif x < 78 then return 'rare';
  elsif x < 90 then return 'epic';
  elsif x < 97 then return 'legendary';
  else return 'chase';
  end if;
end $$;

-- --- spin log (audit + future stats, e.g. biggest slot win) -----------------
create table if not exists cps.slot_spins (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references cps.accounts(id) on delete cascade,
  tier          text, -- null when no triple hit
  symbols       text[] not null,
  packs_random  int not null default 0,
  packs_jumbled int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists cps_slot_spins_account_idx
  on cps.slot_spins (account_id, created_at desc);

-- --- the spin ---------------------------------------------------------------
create or replace function public.cps_slot_spin(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  bal         int;
  s1 text; s2 text; s3 text;
  tier        text := null;
  n_random    int := 0;
  n_jumbled   int := 0;
  active_sets text[];
  grants      jsonb := '[]';
  i           int;
  rset        text;
  vtext       text;
begin
  a := cps.auth(p_token);

  -- lock the account row and charge 3 tokens
  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < 3 then
    raise exception 'Not enough game tokens (need 3).';
  end if;
  update cps.accounts set game_tokens = game_tokens - 3 where id = a.id;

  -- roll the reels (server-authoritative)
  s1 := cps.slot_reel();
  s2 := cps.slot_reel();
  s3 := cps.slot_reel();
  if s1 = s2 and s2 = s3 then tier := s1; end if;

  if tier is not null then
    case tier
      when 'common'    then n_random := 0;  n_jumbled := 3;
      when 'uncommon'  then n_random := 3;  n_jumbled := 3;
      when 'rare'      then n_random := 5;  n_jumbled := 5;
      when 'epic'      then n_random := 10; n_jumbled := 10;
      when 'legendary' then n_random := 20; n_jumbled := 20;
      when 'chase'     then n_random := 50; n_jumbled := 25;
    end case;

    -- jumbled packs first (single grant)
    if n_jumbled > 0 then
      perform cps.add_packs(a.id, 'jumbled', n_jumbled, 'slot_win', tier, null);
    end if;

    -- random-set packs: uniform-random active set per pack
    if n_random > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for slot prizes.';
      end if;
      for i in 1..n_random loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'slot_win', tier, null);
        grants := grants || jsonb_build_object('set_id', rset, 'packs', 1);
      end loop;
    end if;

    -- daily quest hook: 'win_slots' (registered by 062; harmless no-op until then)
    perform cps.quest_bump(a.id, 'win_slots', 1);

    -- global announcement for legendary + chase tiers (everyone but winner)
    if tier in ('legendary', 'chase') then
      vtext := '🎰 ' || a.display_name || ' hit ' || upper(tier) ||
               ' on the slots and won ' || (n_random + n_jumbled) || ' packs!';
      insert into cps.notifications (account_id, kind, text, target_view)
        select xx.id, 'slot_win', vtext, 'arcade'
        from cps.accounts xx where xx.id <> a.id and not coalesce(xx.disabled, false);
    end if;
  end if;

  insert into cps.slot_spins (account_id, tier, symbols, packs_random, packs_jumbled)
    values (a.id, tier, array[s1, s2, s3], n_random, n_jumbled);

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'symbols',       jsonb_build_array(s1, s2, s3),
    'tier',          tier,
    'win',           tier is not null,
    'packs_random',  n_random,
    'packs_jumbled', n_jumbled,
    'grants',        grants,
    'tokens_now',    bal
  );
end $$;

-- --- verification (run after executing) --------------------------------------
-- select cps.slot_reel();                       -- spot-check a reel roll
-- select * from cps.slot_spins order by created_at desc limit 5;
