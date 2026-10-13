-- =====================================================================
-- 129_scratchoffs.sql — Scratchoffs arcade game, SANDBOX TEST PHASE.
-- (Run after 128.)
--
--   Franklin (2026-10-13): convert the Sandbox Scratchoffs prototype from
--   test tokens to the REAL economy — real game tokens in, real packs
--   out — while the game stays in the admin-only Sandbox for testing.
--
--   ADMIN-ONLY, enforced server-side: every RPC below raises
--   'Admin only.' for non-admin accounts, so no regular player can buy
--   or claim a ticket by calling the RPCs directly while the game is in
--   the Sandbox. Graduation step (later, Franklin's call): drop those
--   checks, add daily quests + legendary/chase announcements, and flip
--   the Sandbox item to 'public' / move it to the Arcade lobby.
--
--   How it plays (unchanged from the prototype):
--     Buy a ticket in one of 3 tiers; the server decides the outcome and
--     all 9 symbols at purchase time and stores them, so scratching is
--     reveal-only and a refresh can never re-roll a ticket. Match 3 of
--     the same rarity symbol anywhere on the ticket to win that prize.
--     A winning ticket hides exactly 3 of the winning symbol and no other
--     triple; a losing ticket contains no triple at all.
--
--   Tiers + prizes (packs only; pr = random-set packs, pj = Jumbled):
--     jumbled (2 tokens):  common 0+1 / uncommon 0+2 / rare 1+2 /
--                          epic 2+2 / legendary 3+3 / chase 5+5
--     lucky   (5 tokens):  common 1+1 / uncommon 2+2 / rare 4+4 /
--                          epic 6+6 / legendary 10+10 / chase 20+20
--     chase   (10 tokens): common 2+2 / uncommon 4+4 / rare 8+8 /
--                          epic 12+12 / legendary 25+25 / chase 50+25
--   Outcome odds (all tiers, per 1000): none 600 / common 220 /
--     uncommon 90 / rare 50 / epic 25 / legendary 11 / chase 4.
--     => every tier returns ~0.38 packs per token at these numbers.
--   Random packs: uniform-random active set per pack (excl. 'jumbled'),
--   granted exactly like slot wins (cps.add_packs, reason 'scratch_win').
--
--   Prize + cost tables live in cps.scratch_prize / cps.scratch_cost
--   below AND in js/scratch.js CONFIG (display) — change both together.
--   Server is authoritative: the ticket row snapshots the prize at buy
--   time, so later table tweaks never change a ticket already sold.
--   Every RPC takes p_token (client always sends one).
-- =====================================================================

-- --- ticket store -----------------------------------------------------
create table if not exists cps.scratch_tickets (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null references cps.accounts(id) on delete cascade,
  tier          text not null check (tier in ('jumbled', 'lucky', 'chase')),
  outcome       text, -- null = no match; else the matched rarity symbol
  cells         text[] not null,
  packs_random  int not null default 0,
  packs_jumbled int not null default 0,
  claimed       boolean not null default false,
  created_at    timestamptz not null default now(),
  claimed_at    timestamptz
);
create index if not exists cps_scratch_tickets_account_idx
  on cps.scratch_tickets (account_id, claimed, created_at desc);

-- --- placeholder economy tables (tweak freely, client CONFIG to match) --
create or replace function cps.scratch_cost(p_tier text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_tier when 'jumbled' then 2 when 'lucky' then 5 when 'chase' then 10 end
$$;

create or replace function cps.scratch_prize(p_tier text, p_outcome text) returns int[]
language plpgsql immutable set search_path = cps, pg_temp as $$
begin
  if p_outcome is null then return array[0, 0]; end if;
  case p_tier
    when 'jumbled' then
      case p_outcome
        when 'common' then return array[0, 1];
        when 'uncommon' then return array[0, 2];
        when 'rare' then return array[1, 2];
        when 'epic' then return array[2, 2];
        when 'legendary' then return array[3, 3];
        when 'chase' then return array[5, 5];
      end case;
    when 'lucky' then
      case p_outcome
        when 'common' then return array[1, 1];
        when 'uncommon' then return array[2, 2];
        when 'rare' then return array[4, 4];
        when 'epic' then return array[6, 6];
        when 'legendary' then return array[10, 10];
        when 'chase' then return array[20, 20];
      end case;
    when 'chase' then
      case p_outcome
        when 'common' then return array[2, 2];
        when 'uncommon' then return array[4, 4];
        when 'rare' then return array[8, 8];
        when 'epic' then return array[12, 12];
        when 'legendary' then return array[25, 25];
        when 'chase' then return array[50, 25];
      end case;
  end case;
  return array[0, 0];
end $$;

-- --- outcome roll: per-1000 weights ------------------------------------
create or replace function cps.scratch_roll_outcome() returns text
language plpgsql set search_path = cps, pg_temp as $$
declare x float8 := cps.rand01() * 1000;
begin
  if x < 600 then return null;
  elsif x < 820 then return 'common';
  elsif x < 910 then return 'uncommon';
  elsif x < 960 then return 'rare';
  elsif x < 985 then return 'epic';
  elsif x < 996 then return 'legendary';
  else return 'chase';
  end if;
end $$;

-- --- ticket builder ------------------------------------------------------
-- Winning outcome: exactly 3 copies of it + 6 fillers, every filler symbol
-- capped at 2 copies so no second triple can appear. No outcome: all 9
-- cells capped at 2 per symbol. Cells are shuffled before returning.
create or replace function cps.scratch_make_cells(p_outcome text) returns text[]
language plpgsql set search_path = cps, pg_temp as $$
declare
  syms   text[] := array['common', 'uncommon', 'rare', 'epic', 'legendary', 'chase'];
  counts int[] := array[0, 0, 0, 0, 0, 0];
  cells  text[] := '{}';
  opts   int[];
  pick   int;
  i      int;
begin
  if p_outcome is not null then
    i := array_position(syms, p_outcome);
    cells := array[p_outcome, p_outcome, p_outcome];
    counts[i] := 3;
  end if;
  while coalesce(array_length(cells, 1), 0) < 9 loop
    opts := '{}';
    for i in 1..6 loop
      if syms[i] is distinct from p_outcome and counts[i] < 2 then
        opts := opts || i;
      end if;
    end loop;
    pick := opts[1 + floor(cps.rand01() * array_length(opts, 1))::int];
    cells := cells || syms[pick];
    counts[pick] := counts[pick] + 1;
  end loop;
  select array_agg(c order by cps.rand01()) into cells from unnest(cells) as c;
  return cells;
end $$;

-- --- shared ticket payload ------------------------------------------------
create or replace function cps.scratch_ticket_json(t cps.scratch_tickets)
returns jsonb language sql set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'ticket_id', t.id,
    'tier',      t.tier,
    'cells',     to_jsonb(t.cells),
    'claimed',   t.claimed
  )
$$;

-- --- state: balance + any open (unclaimed) ticket -------------------------
create or replace function public.cps_scratch_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  bal int;
  t   cps.scratch_tickets%rowtype;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;
  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  select * into t from cps.scratch_tickets
    where account_id = a.id and not claimed
    order by created_at desc limit 1;
  return jsonb_build_object(
    'tokens_now', bal,
    'ticket', case when t.id is null then null
                   else cps.scratch_ticket_json(t) end
  );
end $$;

-- --- buy ------------------------------------------------------------------
-- One open ticket at a time: if the account already has an unclaimed
-- ticket, it is returned (resumed) and nothing is charged.
create or replace function public.cps_scratch_buy(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  bal     int;
  cost    int;
  t       cps.scratch_tickets%rowtype;
  outcome text;
  prize   int[];
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;

  select * into t from cps.scratch_tickets
    where account_id = a.id and not claimed
    order by created_at desc limit 1;
  if t.id is not null then
    select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
    return jsonb_build_object(
      'ticket', cps.scratch_ticket_json(t),
      'tokens_now', bal,
      'resumed', true
    );
  end if;

  cost := cps.scratch_cost(p_tier);
  if cost is null then raise exception 'Unknown scratch ticket tier.'; end if;

  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < cost then
    raise exception 'Not enough game tokens (need %).', cost;
  end if;
  update cps.accounts set game_tokens = game_tokens - cost where id = a.id;

  outcome := cps.scratch_roll_outcome();
  prize := cps.scratch_prize(p_tier, outcome);
  insert into cps.scratch_tickets
    (account_id, tier, outcome, cells, packs_random, packs_jumbled)
  values
    (a.id, p_tier, outcome, cps.scratch_make_cells(outcome), prize[1], prize[2])
  returning * into t;

  return jsonb_build_object(
    'ticket', cps.scratch_ticket_json(t),
    'tokens_now', bal - cost,
    'resumed', false
  );
end $$;

-- --- claim ------------------------------------------------------------------
-- Pays the ticket's snapshotted prize exactly once. Claiming an already-
-- claimed ticket returns its original result without paying again, so a
-- client retry after a network hiccup is safe.
create or replace function public.cps_scratch_claim(p_token text, p_ticket uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  t           cps.scratch_tickets%rowtype;
  bal         int;
  active_sets text[];
  grants      jsonb := '[]';
  i           int;
  rset        text;
begin
  a := cps.auth(p_token);
  if not a.is_admin then raise exception 'Admin only.'; end if;

  select * into t from cps.scratch_tickets
    where id = p_ticket and account_id = a.id for update;
  if t.id is null then raise exception 'Ticket not found.'; end if;

  if not t.claimed then
    if t.packs_jumbled > 0 then
      perform cps.add_packs(a.id, 'jumbled', t.packs_jumbled, 'scratch_win', t.outcome, null);
    end if;
    if t.packs_random > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for scratch prizes.';
      end if;
      for i in 1..t.packs_random loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'scratch_win', t.outcome, null);
        grants := grants || jsonb_build_object('set_id', rset, 'packs', 1);
      end loop;
    end if;
    update cps.scratch_tickets
      set claimed = true, claimed_at = now() where id = t.id;
  end if;

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'win',           t.outcome is not null,
    'outcome',       t.outcome,
    'packs_random',  t.packs_random,
    'packs_jumbled', t.packs_jumbled,
    'grants',        grants,
    'already_claimed', t.claimed,
    'tokens_now',    bal
  );
end $$;

-- --- verification (run after executing) --------------------------------------
-- select cps.scratch_roll_outcome();              -- spot-check the roll
-- select cps.scratch_make_cells('chase');         -- exactly 3 'chase', no other triple
-- select cps.scratch_make_cells(null);            -- no triple at all
-- select * from cps.scratch_tickets order by created_at desc limit 5;

notify pgrst, 'reload schema';
