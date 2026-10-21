-- =====================================================================
-- 169_jumbled_exclusives.sql
-- Jumbled Mess exclusives: cards that can ONLY be pulled from Jumbled
-- Mess packs, forming a Jumbled collection of their own (Franklin,
-- 2026-10-21). Plus Jumbled's own fifth-slot odds table.
--
-- THE DESIGN (Franklin, locked 2026-10-21):
--   * Exclusives live in cps.cards under set_id 'jumbled' and join the
--     Jumbled pool at their own rarity -- "an epic's an epic, a
--     legendary's a legendary." No special pool, no bonus slot. Cards
--     are added one at a time as Franklin hands them over; this
--     migration seeds the first: #1 PackRipper (Chase).
--   * Slots 1-4 keep the boosted table (Uncommon 62 / Rare 26 /
--     Epic 10 / Legendary 2), now written as FRACTIONS (see below).
--   * The 5th card gets Jumbled's OWN table -- Rare 80 / Epic 14 /
--     Legendary 5 / Chase 1 -- instead of borrowing the source set's
--     guaranteed slot. On a Chase roll, a further 10% roll deals a
--     Jumbled Mess Chase instead of a normal Chase (net 0.1% of
--     Jumbled packs). The branch is dormant -- a normal Chase deals --
--     while no Jumbled Chase exists in cps.cards.
--   * Jumbled ONLY: every other set's packs are untouched, including
--     the shared guaranteed-slot table.
--   * NO set collection rewards for the Jumbled set: nothing to fence
--     here -- cps_award_turnin_rewards already no-ops for 'jumbled'
--     by name (126/144), its client check skips 'jumbled', completion
--     announcements require an ACTIVE set (jumbled stays inactive, so
--     no broadcast / no set_completions row / no Sets Completed
--     credit), and trophy set tiles skip 'jumbled' client-side. The
--     client half of this ship filters 'jumbled' out of the turn-in
--     milestone pop-ups (js/milestones.js) for the same reason.
--
-- WHY THE FRACTIONS (found while building this, verified live
-- 2026-10-21): the rarity roll below does NOT normalize weights --
-- x is in [0,1) and the first rarity whose cumulative weight passes x
-- wins -- so a table only deals as written if its weights sum to 1.
-- The old slots 1-4 literal was PERCENTS (62/26/10/2), which dealt
-- ~99.5% Uncommon in practice (5,512 packs, 30 days of ledger), and
-- the borrowed 5th-slot table dealt as written only for sets whose
-- server pack JSON stores fractions. Writing Jumbled's own tables as
-- fractions makes Jumbled deal exactly as designed no matter what
-- happens elsewhere. Hunk N fixes the ROOT: the roll now scales by
-- the slot's total weight, so every table -- fraction or percent,
-- in-function or in a set's pack JSON -- deals its advertised odds.
-- Fraction tables (States and friends, the Hero table, the Stuffed
-- extra slot) already summed to 1 and are numerically unchanged;
-- percent tables (35 sets) now deal the odds the client has always
-- advertised for them. No pack JSON data changes anywhere.
--
-- PROVENANCE / DEPENDENCIES:
--   * Run AFTER 168. The cps_open_pack rebuild is migration 164's
--     body verbatim (164 = live; built on 159; 165-168 do not touch
--     the function) plus the four (169) hunks:
--       A  declare jsets (source pool: active sets + 'jumbled')
--       B  build jsets next to active_sets
--       C  slots 1-4: fraction table + source pre-pick from jsets;
--          5th card: Jumbled's own fraction table, source deferred
--       D  post-roll source landing: the Jumbled Chase branch, and
--          the fall-back repick when the exclusives can't deal the
--          rolled rarity
--       N  the rarity roll now scales by the slot's TOTAL weight
--          (see "WHY THE FRACTIONS" below; Franklin, on being shown
--          the audit: "Fix whatever you deem necessary!")
--     Everything else -- Hero/Stuffed partition, slips, variant
--     lottery, quests, stats, ledger -- is byte-identical to 164.
--   * WARNING: parked 163 rebuilds cps_open_pack from 159 and would
--     silently remove Stuffed Packs AND this. Do not run 163 after
--     169; rebase it onto 169 if it is ever revived.
--   * The 'jumbled' card_sets row stays INACTIVE (active=false):
--     that one fact keeps the set out of the shop, Card of the Day,
--     random-pack pools and direct pack opening, while cps_open_pack's
--     Jumbled branch and cps_turn_in (no active check) work as-is.
--   * Client half of this ship: sets/jumbled-exclusives.js (the set
--     file), sets/manifest.js + sets/boot-index.js (registration),
--     js/app.js (collection/odds/turn-in hooks), js/milestones.js
--     (pop-up filter), assets/sets/jumbled/images/packripper.webp.
-- =====================================================================

create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8; tot float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text; chase_e record;
        vletter text;
        ins_kind text;
        -- jumbled additions
        is_jumbled boolean; is_hero boolean; hero_forced boolean; active_sets text[]; jsets text[]; rset text; rs cps.card_sets%rowtype; slot_odds jsonb;
        -- stuffed packs (164)
        is_stuffed boolean; is_stuffed_hero boolean; stuffed_n int := 0; base_n int := 0; sroll float8;
        vset text; set_rec record; set_n int; set_h int; set_byr jsonb; set_best jsonb; set_bscore int;
        set_st cps.user_set_stats%rowtype; card_rec record; cscore int;
begin
  a := cps.auth(p_token);
  is_jumbled := (p_set = 'jumbled');
  hero_forced := not is_jumbled and coalesce(a.force_hero_packs, 0) > 0;
  -- Stuffed packs (164): one flat partition roll decides every non-Jumbled
  -- pack's kind, so the advertised rates are exact -- Stuffed Hero 0.2%,
  -- plain Hero 0.8%, regular Stuffed 2.0%, normal 97.0%. (Story: Hero is
  -- 1% total and 1 in 5 Hero packs is stuffed; Stuffed is 2% of the rest.)
  -- is_hero stays the hero-FAMILY flag: the card loop deals the Hero table
  -- whenever it is set, which a Stuffed Hero needs for ALL of its slots.
  -- A FORCED hero skips the partition (it is a Hero for sure) and instead
  -- gets the same 1-in-5 stuffing check on its own.
  is_stuffed := false; is_stuffed_hero := false;
  if hero_forced then
    is_hero := true;
    is_stuffed_hero := cps.rand01() < 0.20;
  elsif is_jumbled then
    is_hero := false;
  else
    sroll := cps.rand01();
    is_stuffed_hero := sroll < 0.002;
    is_hero := sroll < 0.010;
    is_stuffed := sroll >= 0.010 and sroll < 0.030;
  end if;

  if is_jumbled then
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = 'jumbled' for update;
    if coalesce(inv, 0) < 1 then raise exception 'No Jumbled Mess packs left.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = 'jumbled' returning packs into inv;
    select coalesce(array_agg(id order by id), '{}') into active_sets from cps.card_sets where active and id <> 'jumbled' and not coalesce(exclude_from_jumbled, false);
    jsets := array_append(active_sets, 'jumbled');
    if coalesce(array_length(active_sets, 1), 0) = 0 then raise exception 'No sets available for Jumbled Mess.'; end if;
  else
    select * into s from cps.card_sets where id = p_set and active;
    if not found then raise exception 'This set is not available online yet.'; end if;
    select packs into inv from cps.pack_inventory where account_id = a.id and set_id = p_set for update;
    if coalesce(inv, 0) < 1 then raise exception 'No packs left for this set.'; end if;
    update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = p_set returning packs into inv;

    select * into st from cps.user_set_stats where account_id = a.id and set_id = p_set for update;
    best_score := case when st.best is null then -1
                       else cps.rarity_rank((select rarity from cps.cards where set_id = p_set and card_id = st.best->>'id')) * 10
                            + case when (st.best->>'holo')::boolean then 5 else 0 end end;
    best_score := coalesce(best_score, -1);
  end if;

  -- Stuffed packs (164): size the extras from the set's OWN server slot
  -- list -- base_n is this pack's real card count, whatever the set deals.
  -- Below, the extras ride the SAME card loop as one appended slot, so they
  -- get the identical per-card pipeline (collection, is_new, holo, variant
  -- lottery, stats). A regular Stuffed pack's appended slot carries the
  -- Wild table (never Legendary/Chase); a Stuffed Hero's appended slot
  -- needs no odds of its own -- is_hero makes the loop deal the Hero table
  -- for every slot, extras included.
  if not is_jumbled then
    base_n := (select coalesce(sum((sl->>'count')::int), 0)
                 from jsonb_array_elements(s.pack->'slots') sl);
    if is_stuffed or is_stuffed_hero then
      stuffed_n := case base_n
        when 9 then 3 + floor(cps.rand01() * 4)::int   -- 12-15 total
        when 6 then 2 + floor(cps.rand01() * 2)::int   -- 8-9 total
        when 5 then 2 + floor(cps.rand01() * 2)::int   -- 7-8 total
        when 3 then 1 + floor(cps.rand01() * 3)::int   -- 4-6 total
        else least(6, greatest(1, round(base_n / 2.0)::int)) end;  -- no live set hits this
    end if;
  end if;

  -- Card loop. For jumbled we synthesize a 5-card slot list; each card then
  -- picks its own random set and uses that set's odds/holo rates.
  for slot in select value from jsonb_array_elements(
               case when is_jumbled
                    then '[{"count":5,"odds":{"common":1}}]'::jsonb
                    when stuffed_n > 0
                    then (s.pack->'slots') || jsonb_build_array(jsonb_build_object('count', stuffed_n, 'odds', '{"common": 0.55, "uncommon": 0.30, "rare": 0.12, "epic": 0.03}'::jsonb))
                    else s.pack->'slots' end) loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      if is_jumbled then
        -- Jumbled Mess: guaranteed uncommon or better (it's a special pack!).
        -- (169) Jumbled's own tables, written as FRACTIONS (the roll below
        -- does not normalize weights). Slots 1-4 pre-pick a source from
        -- jsets (every active set PLUS 'jumbled' itself, home of the
        -- Jumbled-only exclusives); the 5th card rolls its rarity first
        -- and picks its source after the roll (see the block below).
        if i <= 4 then
          slot_odds := '{"uncommon": 0.62, "rare": 0.26, "epic": 0.10, "legendary": 0.02}'::jsonb;
          rset := jsets[1 + floor(cps.rand01() * array_length(jsets, 1))::int];
        else
          slot_odds := '{"rare": 0.80, "epic": 0.14, "legendary": 0.05, "chase": 0.01}'::jsonb;
          rset := null;
        end if;
      else
        rset := p_set;
        rs := s;
        if is_hero then
          slot_odds := '{"uncommon": 0.20, "rare": 0.40, "epic": 0.25, "legendary": 0.12, "chase": 0.03}'::jsonb;
        else
          slot_odds := slot->'odds';
        end if;
      end if;

      -- (169, Hunk N) Normalize by the slot's TOTAL weight: odds are
      -- relative weights (the client registry treats them the same
      -- way), but the roll used to compare a [0,1) roll against raw
      -- cumulative weights -- so any slot whose weights summed past 1
      -- (every PERCENT-format table: Jumbled's old literals, and the
      -- server pack JSON of 35 sets seeded from client files) dealt
      -- its first rarity almost always. Scaling the roll by the total
      -- makes fractions and percents deal identically, as advertised.
      tot := (select coalesce(sum(value::float8), 0) from jsonb_each_text(slot_odds));
      x := cps.rand01() * tot; acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot_odds) order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      if is_jumbled then
        -- (169) Land the source set for this card.
        -- 5th card: on a Chase roll, a further 10% roll deals a Jumbled
        -- Mess Chase instead of a normal Chase -- dormant (a normal
        -- Chase) while no Jumbled Chase exists in cps.cards. Any other
        -- 5th-card rarity picks uniformly from the active sets that can
        -- actually deal it. Slots 1-4: if the pre-pick landed on the
        -- exclusives but they hold no card of the rolled rarity, fall
        -- back the same way -- an exclusive only ever deals at its own
        -- rarity ("an epic's an epic"); it never bends a slot's rarity.
        if i = 5 and r = 'chase' and cps.rand01() < 0.10
           and exists (select 1 from cps.cards where set_id = 'jumbled' and rarity = 'chase') then
          rset := 'jumbled';
        elsif rset is null
           or (rset = 'jumbled'
               and not exists (select 1 from cps.cards where set_id = 'jumbled' and rarity = r)) then
          select id into rset from cps.card_sets
            where active and id <> 'jumbled' and not coalesce(exclude_from_jumbled, false)
              and exists (select 1 from cps.cards c where c.set_id = cps.card_sets.id and c.rarity = r)
            order by random() limit 1;
          rset := coalesce(rset, active_sets[1]);
        end if;
        select * into rs from cps.card_sets where id = rset;
      end if;
      select card_id into cid from cps.cards where set_id = rset and rarity = r and not ((rset || ':' || card_id) = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = rset and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', rset, r; end if;
      holo := cps.rand01() * 100 < coalesce((rs.pack->'holo'->>r)::float8, 0);
      picked := picked || (rset || ':' || cid);

      select count into prev_count from cps.collection where account_id = a.id and set_id = rset and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0
        and not exists (select 1 from cps.turn_ins t
                         where t.account_id = a.id and t.set_id = rset and t.card_id = cid);
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, rset, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      if not is_jumbled then
        sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
        if sc > best_score then
          best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
          best_changed := st.best is not null or best_changed;
        end if;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'set_id', rset, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  -- numbered variant lottery: 1% of packs; one random rare+ card becomes a variant
  -- (admins never mint variants — they can grant themselves packs)
  vserial := null;
  if not coalesce(a.is_admin, false) and cps.rand01() < 0.0085 then
    select array_agg(t.idx) into vidx from (
      select (o.ord - 1)::int as idx
      from jsonb_array_elements(out) with ordinality as o(e, ord)
      where o.e->>'rarity' in ('rare','epic','legendary','chase')
    ) t;
    if vidx is not null and coalesce(array_length(vidx, 1), 0) > 0 then
      vi := vidx[1 + floor(cps.rand01() * array_length(vidx, 1))::int];
      vcid := out->vi->>'id';
      vset := out->vi->>'set_id';
      vx := cps.rand01();
      vtier := case when vx < 0.70 then 'rainbow' when vx < 0.90 then 'prism' when vx < 0.98 then 'obsidian' else 'oneofone' end;
      vtiers := case vtier
        when 'rainbow' then array['rainbow']
        when 'prism' then array['prism','rainbow']
        when 'obsidian' then array['obsidian','prism','rainbow']
        else array['oneofone','obsidian','prism','rainbow'] end;
      foreach vt in array vtiers loop
        vserial := cps.mint_variant(a.id, vset, vcid, vt);
        if vserial is not null then vtier := vt; exit; end if;
      end loop;
      if vserial is not null then
        perform cps.auto_turn_in(a.id, vset, vcid);
        out := (select jsonb_agg(case when t.rn = vi
            then t.e || jsonb_build_object('variant', vtier, 'serial', vserial)
            else t.e end order by t.rn)
          from (select e, (row_number() over ()) - 1 as rn from jsonb_array_elements(out) e) t);
        if vtier in ('prism','obsidian','oneofone','rainbow') then
          select kk.name into vcardname from cps.cards kk where kk.set_id = vset and kk.card_id = vcid;
          select ss.name into vtext from cps.card_sets ss where ss.id = vset;
          vtext := case vtier
            when 'oneofone' then '👑 ' || a.display_name || ' pulled a one-of-one ' || vcardname || ' (' || vtext || ')!'
            when 'obsidian' then '🌑 ' || a.display_name || ' pulled Obsidian #' || vserial || '/5 ' || vcardname || ' (' || vtext || ')!'
            when 'rainbow' then '🌈 ' || a.display_name || ' pulled Rainbow #' || vserial || '/50 ' || vcardname || ' (' || vtext || ')!'
            else '💠 ' || a.display_name || ' pulled Prism #' || vserial || '/10 ' || vcardname || ' (' || vtext || ')!'
          end;
          insert into cps.notifications (account_id, kind, text, target_view, meta)
            select xx.id, 'variant_pull', vtext, 'collection',
              jsonb_build_object('set_id', vset, 'card_id', vcid,
                'holo', coalesce((out->vi->>'holo')::boolean, false),
                'tier', vtier, 'serial', vserial)
            from cps.accounts xx where xx.id <> a.id and not xx.disabled;
        -- numbered variants qualify for Latest big pull
        insert into cps.big_pulls (account_id, set_id, card_id, rarity, variant_tier, variant_serial)
          values (a.id, vset, vcid,
                  (select kk.rarity from cps.cards kk where kk.set_id = vset and kk.card_id = vcid),
                  vtier, vserial);
        end if;
      end if;
    end if;
  end if;

  -- record big pulls: Chase cards only (Legendary no longer qualifies) + global chase announcements
  for chase_e in select e from jsonb_array_elements(out) e where e->>'rarity' = 'chase' loop
    insert into cps.big_pulls (account_id, set_id, card_id, rarity)
      values (a.id, chase_e.e->>'set_id', chase_e.e->>'id', 'chase');
    if chase_e.e->>'rarity' = 'chase' then
      -- Admin pulls are not announced (Franklin, 2026-10-16): the pull
      -- still records in big_pulls above; only the broadcast is skipped.
      if not coalesce(a.is_admin, false) then
      select kk.name into vcardname from cps.cards kk where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      select ss.name into vtext from cps.card_sets ss where ss.id = chase_e.e->>'set_id';
      vtext := '🎯 ' || a.display_name || ' pulled ' || vcardname || ' (Chase · ' || vtext || ')!';
      insert into cps.notifications (account_id, kind, text, target_view, meta)
        select xx.id, 'chase_pull', vtext, 'collection',
          jsonb_build_object('set_id', chase_e.e->>'set_id', 'card_id', chase_e.e->>'id',
            'holo', coalesce((chase_e.e->>'holo')::boolean, false))
        from cps.accounts xx where xx.id <> a.id and not xx.disabled;
      end if;
    end if;
  end loop;

  -- --- pack insert: 10% of packs roll the insert table. One card is
  -- replaced: a Common if the pack has one, else an Uncommon (Jumbled).
  -- Table (equal odds): spin ticket / $5 Store Credit / 5 Arcade Tokens.
  -- (admin force_ticket_next guarantees the ticket row, clears on success)
  ins_kind := null;
  if not is_jumbled and (coalesce(a.force_ticket_next, false) or cps.rand01() < 0.10) then
    ins_kind := case when coalesce(a.force_ticket_next, false) then 'ticket'
      else (array['ticket', 'credit', 'tokens'])[1 + floor(cps.rand01() * 3)::int] end;
    -- Stuffed packs (164): the slip still replaces a BASE-pack card only,
    -- so candidates are the first base_n entries of out (extras sit after
    -- them). With no extras this selects exactly the same rows as before.
    select idx into vi from (
      select (o.ord - 1)::int as idx
      from jsonb_array_elements(out) with ordinality as o(e, ord)
      where o.ord <= base_n
        and not coalesce((e->>'ticket')::boolean, false)
        and (e->>'credit') is null
        and (e->>'tokens') is null
        and (e->>'rarity') in ('common', 'uncommon')
      order by case when (e->>'rarity') = 'common' then 0 else 1 end, random()
      limit 1
    ) t;
    if vi is not null then
      vcid := out->vi->>'id';
      vset := out->vi->>'set_id';
      -- undo the collection increment for the replaced card
      update cps.collection
      set count = greatest(count - 1, 0),
          holo_count = greatest(holo_count - case when coalesce((out->vi->>'holo')::boolean, false) then 1 else 0 end, 0)
      where account_id = a.id and set_id = vset and card_id = vcid;
      -- adjust rarity counts
      by_r := jsonb_set(by_r, array[out->vi->>'rarity'], to_jsonb(greatest(coalesce((by_r->>(out->vi->>'rarity'))::int, 1) - 1, 0)));
      if coalesce((out->vi->>'holo')::boolean, false) then n_holo := n_holo - 1; end if;
      if ins_kind = 'ticket' then
        out := jsonb_set(out, array[vi::text], '{"ticket": true}'::jsonb);
        update cps.accounts set spins = spins + 1 where id = a.id;
        insert into cps.spin_grants (account_id, spins, reason) values (a.id, 1, 'pack_jackpot');
        perform cps.quest_bump(a.id, 'pull_spin_ticket', 1);
        -- clear the force flag (only on success)
        update cps.accounts set force_ticket_next = false where id = a.id;
      elsif ins_kind = 'credit' then
        out := jsonb_set(out, array[vi::text], '{"credit": 5}'::jsonb);
        update cps.accounts set store_credit = coalesce(store_credit, 0) + 5 where id = a.id;
      else
        out := jsonb_set(out, array[vi::text], '{"tokens": 5}'::jsonb);
        update cps.accounts set game_tokens = coalesce(game_tokens, 0) + 5 where id = a.id;
        perform cps.quest_bump(a.id, 'pull_token_slip', 1);
      end if;
    end if;
  end if;

  -- daily quest bumps
  perform cps.quest_bump(a.id, 'open_packs', 1);
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e where e->>'set_id' is not null loop
      perform cps.quest_bump(a.id, 'open_packs_set', 1, set_rec.sid);
    end loop;
  else
    perform cps.quest_bump(a.id, 'open_packs_set', 1, p_set);
  end if;
  if n_holo > 0 then
    perform cps.quest_bump(a.id, 'pull_holo', n_holo);
    perform cps.quest_bump(a.id, 'pull_holos_3', n_holo);
  end if;
  perform cps.quest_bump(a.id, 'pull_rare_plus',
    coalesce((by_r->>'rare')::int, 0) + coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_epic_plus',
    coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_legendary_plus',
    coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_chase', coalesce((by_r->>'chase')::int, 0));
  if vserial is not null then perform cps.quest_bump(a.id, 'pull_variant', 1); end if;

  -- --- 6 new daily quests -------------------------------------------------
  -- open_jumbled
  if is_jumbled then perform cps.quest_bump(a.id, 'open_jumbled', 1); end if;
  -- pull_dupe, pull_holo_common, pull_letter (per-card)
  select q.meta->>'letter' into vletter
  from cps.daily_quests q
  where q.account_id = a.id
    and q.day = (now() at time zone 'America/Chicago')::date
    and q.quest_key = 'pull_letter';
  for chase_e in select e from jsonb_array_elements(out) e loop
    if not coalesce((chase_e.e->>'new')::boolean, true) then
      perform cps.quest_bump(a.id, 'pull_dupe', 1);
    end if;
    if chase_e.e->>'rarity' = 'common' and coalesce((chase_e.e->>'holo')::boolean, false) then
      perform cps.quest_bump(a.id, 'pull_holo_common', 1);
    end if;
    if vletter is not null then
      select kk.name into vcardname from cps.cards kk
      where kk.set_id = chase_e.e->>'set_id' and kk.card_id = chase_e.e->>'id';
      if vcardname ilike '%' || vletter || '%' then
        perform cps.quest_bump(a.id, 'pull_letter', 1);
      end if;
    end if;
  end loop;
  -- pull_2_holos_pack
  if n_holo >= 2 then perform cps.quest_bump(a.id, 'pull_2_holos_pack', 1); end if;
  -- pull_3_sets: track distinct home sets in meta
  for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e where e->>'set_id' is not null loop
    update cps.daily_quests q
    set meta = jsonb_build_object('sets',
              (select coalesce(jsonb_agg(distinct sx), '[]'::jsonb)
               from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                     union select set_rec.sid as sx) sub)),
        progress = (select count(distinct sx)
                    from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                          union select set_rec.sid as sx) sub),
        done = (select count(distinct sx) >= 3
                from (select jsonb_array_elements_text(coalesce(q.meta->'sets', '[]'::jsonb)) as sx
                      union select set_rec.sid as sx) sub)
    where q.account_id = a.id
      and q.day = (now() at time zone 'America/Chicago')::date
      and q.quest_key = 'pull_3_sets'
      and q.claimed_at is null;
  end loop;

  -- per-set stats
  if is_jumbled then
    for set_rec in select distinct e->>'set_id' as sid from jsonb_array_elements(out) e where e->>'set_id' is not null loop
      select count(*), coalesce(sum(case when (e->>'holo')::boolean then 1 else 0 end), 0)
        into set_n, set_h
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid;
      select coalesce(jsonb_object_agg(rkey, rcount), '{}') into set_byr from (
        select e->>'rarity' as rkey, count(*) as rcount
        from jsonb_array_elements(out) e where e->>'set_id' = set_rec.sid group by 1) t;
      -- best card of this set in this pack
      select e into card_rec from jsonb_array_elements(out) e
        where e->>'set_id' = set_rec.sid
        order by cps.rarity_rank(e->>'rarity') * 10 + case when (e->>'holo')::boolean then 5 else 0 end desc
        limit 1;
      set_best := null;
      if card_rec.e is not null then
        select * into set_st from cps.user_set_stats where account_id = a.id and set_id = set_rec.sid for update;
        set_bscore := case when set_st.best is null then -1
          else cps.rarity_rank((select rarity from cps.cards where set_id = set_rec.sid and card_id = set_st.best->>'id')) * 10
               + case when (set_st.best->>'holo')::boolean then 5 else 0 end end;
        set_bscore := coalesce(set_bscore, -1);
        cscore := cps.rarity_rank(card_rec.e->>'rarity') * 10 + case when (card_rec.e->>'holo')::boolean then 5 else 0 end;
        if cscore > set_bscore then
          set_best := jsonb_build_object('id', card_rec.e->>'id', 'holo', (card_rec.e->>'holo')::boolean, 'at', now());
        end if;
      end if;
      insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
        values (a.id, set_rec.sid, 0, set_n, set_h, set_byr, set_best)
        on conflict (account_id, set_id) do update set
          opened = cps.user_set_stats.opened,
          pulled = cps.user_set_stats.pulled + excluded.pulled,
          holos  = cps.user_set_stats.holos + excluded.holos,
          by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                        select key, sum(value::int) as total from (
                          select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                          union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
          best = coalesce(excluded.best, cps.user_set_stats.best);
    end loop;
    -- The pack itself counts as opened once, under Jumbled Mess; the
    -- source sets above take only the card-level stats (pulled/holos).
    insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
      values (a.id, p_set, 1, 0, 0, '{}'::jsonb, null)
      on conflict (account_id, set_id) do update set
        opened = cps.user_set_stats.opened + 1;
  else
    insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
      values (a.id, p_set, 1, jsonb_array_length(out), n_holo, by_r, new_best)
      on conflict (account_id, set_id) do update set
        opened = cps.user_set_stats.opened + 1,
        pulled = cps.user_set_stats.pulled + excluded.pulled,
        holos  = cps.user_set_stats.holos + excluded.holos,
        by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                      select key, sum(value::int) as total from (
                        select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                        union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
        best = coalesce(excluded.best, cps.user_set_stats.best);
  end if;

  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'set_id', e->>'set_id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e where not coalesce((e->>'ticket')::boolean, false) and (e->>'credit') is null and (e->>'tokens') is null));

  if hero_forced then
    update cps.accounts set force_hero_packs = force_hero_packs - 1 where id = a.id;
  end if;

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out, 'hero', is_hero,
    'stuffed', is_stuffed, 'stuffed_hero', is_stuffed_hero,
    'best', case when is_jumbled then null
                else (select best from cps.user_set_stats where account_id = a.id and set_id = p_set) end,
    'new_best', (not is_jumbled) and best_changed and new_best is not null);
end $$;

-- ---------------------------------------------------------------------
-- Data: Jumbled's own holo table (the row's pack JSON had none, so a
-- Jumbled-sourced card could never be holo) + the first exclusive.
-- The row stays inactive and its slots stay as they were.
-- ---------------------------------------------------------------------
update cps.card_sets
   set pack = jsonb_set(pack, '{holo}',
              '{"common": 1, "uncommon": 1.5, "rare": 3, "epic": 5, "legendary": 7.5, "chase": 12.5}'::jsonb),
       card_count = 1,
       updated_at = now()
 where id = 'jumbled';

insert into cps.cards (set_id, card_id, num, name, rarity)
values ('jumbled', 'packripper', 1, 'PackRipper', 'chase')
on conflict (set_id, card_id)
  do update set num = excluded.num, name = excluded.name, rarity = excluded.rarity;

notify pgrst, 'reload schema';

-- =====================================================================
-- Verify after running:
--
-- 1) The installed function carries the 169 hunks (expect true):
--      select pg_get_functiondef('public.cps_open_pack(text, text)'::regprocedure)
--               like '%Jumbled Mess Chase%' as jumbled_169_installed;
--
-- 2) The exclusive is seeded and the set row is still inactive
--    (expect one row: packripper / chase / f / 1):
--      select c.card_id, c.rarity, s.active, s.card_count
--        from cps.cards c join cps.card_sets s on s.id = c.set_id
--       where c.set_id = 'jumbled';
--
-- 3) Post-auth smoke test (house rule): with a temp session planted,
--    call public.cps_open_pack(<token>, 'jumbled') on the Muse admin
--    account (grant it Jumbled packs first) and confirm packs open
--    cleanly, then delete the temp session. A bogus-token probe only
--    proves the function exists (28000).
--
-- 4) Distribution check after a day or two of Jumbled openings
--    (positions from the ledger; commons should be ~0 in 1-4):
--      select pos, rarity, count(*) from (
--        select ord as pos, e->>'rarity' as rarity
--          from cps.pack_openings o,
--               jsonb_array_elements(o.cards) with ordinality as t(e, ord)
--         where o.set_id = 'jumbled' and o.opened_at > now() - interval '2 days'
--      ) s group by 1, 2 order by 1, 2;
--    Slots 1-4 should land near Uncommon 62 / Rare 26 / Epic 10 /
--    Legendary 2; slot 5 near Rare 80 / Epic 14 / Legendary 5 /
--    Chase 1 (the Jumbled Chase itself is 0.1% of packs -- it will
--    take ~1,000 packs to expect one, so judge slot 5 on the
--    Rare/Epic/Legendary split, not on seeing PackRipper).
-- =====================================================================
