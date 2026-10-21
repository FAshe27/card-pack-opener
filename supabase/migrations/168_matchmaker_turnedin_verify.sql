-- 168_matchmaker_turnedin_verify.sql — post-auth smoke test for
-- migration 168 (Matchmaker "Add Missing" by turned-in cards).
-- Run AFTER 168_matchmaker_turnedin.sql (which requires 167 live).
--
-- Runs ENTIRELY in one transaction and ROLLS BACK: the Muse admin
-- test account ('Admin Account') and one real non-admin player are
-- fixtured in-transaction (planted sessions, planted collection and
-- turn_ins rows), the real RPCs are called with the planted tokens,
-- and nothing persists.
--
-- Checks (Franklin's 168 semantics):
--   (a) owns a card, NOT turned in  -> wantlist_add succeeds
--   (b) HAS turned in a card        -> add returns reason 'turned_in'
--   (c) want placed, card turned in -> want auto-cleared on next list
--   (d) want placed, card only OWNED (pulled, not turned in)
--                                   -> want SURVIVES the list call
--   (e) matches still work when the wanter owns the wanted card
--       (the whole point of 168: the copy they'd turn in can come
--       from someone else's spare)
--   (f) wantlist_list output shape is unchanged from 167
--       (set_id / card_id / holo_pref keys on every want element)
-- Expected: one NOTICE line, every check true.
begin;

do $$
declare
  admin_id  uuid;
  player_id uuid;
  pname     text;
  atok      text := 'smoke168-admin-00000001';
  ptok      text := 'smoke168-player-0000001';
  fA        text; fA_set text;  -- owned by admin, not turned in
  fB        text; fB_set text;  -- owned by admin, not turned in; player has spares
  fC        text; fC_set text;  -- admin will "turn in" in-transaction
  r         jsonb;
  m         jsonb;
  ok_owned_add    boolean := false;
  ok_match        boolean := false;
  ok_reject       boolean := false;
  ok_survive      boolean := false;
  ok_purge        boolean := false;
  ok_shape        boolean := false;
begin
  select id into admin_id from cps.accounts where display_name = 'Admin Account';
  if admin_id is null then raise exception 'Muse test account (Admin Account) not found'; end if;
  select id, display_name into player_id, pname from cps.accounts
   where id <> admin_id and not is_admin and not disabled
   order by display_name limit 1;
  if player_id is null then raise exception 'no non-admin player available for the fixture'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text(atok), admin_id, now() + interval '1 hour'),
    (cps.hash_text(ptok), player_id, now() + interval '1 hour');

  -- Fixture cards: three distinct Commons the admin has NOT turned
  -- in (a turned-in card can never be wanted under 168, so the 167
  -- smoke's "not owned" pick is not enough any more).
  select k.set_id, k.card_id into fA_set, fA from cps.cards k
   where k.rarity = 'common'
     and not exists (select 1 from cps.turn_ins t
                      where t.account_id = admin_id and t.set_id = k.set_id
                        and t.card_id = k.card_id)
   order by k.set_id, k.card_id limit 1;
  select k.set_id, k.card_id into fB_set, fB from cps.cards k
   where k.rarity = 'common'
     and not (k.set_id = fA_set and k.card_id = fA)
     and not exists (select 1 from cps.turn_ins t
                      where t.account_id = admin_id and t.set_id = k.set_id
                        and t.card_id = k.card_id)
   order by k.set_id, k.card_id limit 1;
  select k.set_id, k.card_id into fC_set, fC from cps.cards k
   where k.rarity = 'common'
     and not (k.set_id = fA_set and k.card_id = fA)
     and not (k.set_id = fB_set and k.card_id = fB)
     and not exists (select 1 from cps.turn_ins t
                      where t.account_id = admin_id and t.set_id = k.set_id
                        and t.card_id = k.card_id)
   order by k.set_id, k.card_id limit 1;
  if fA is null or fB is null or fC is null then
    raise exception 'not enough fixture cards available'; end if;

  -- Clean slate for the fixture cards (in-transaction; rolls back).
  delete from cps.wantlist
   where account_id = admin_id
     and ((set_id = fA_set and card_id = fA)
       or (set_id = fB_set and card_id = fB)
       or (set_id = fC_set and card_id = fC));

  -- Admin OWNS A and B (one plain copy each, planted); the player
  -- holds 3 plain of B (spare = 2 after the keeper).
  insert into cps.collection (account_id, set_id, card_id, count, holo_count, vaulted_count, vaulted_holo) values
    (admin_id,  fA_set, fA, 1, 0, 0, 0),
    (admin_id,  fB_set, fB, 1, 0, 0, 0),
    (player_id, fB_set, fB, 3, 0, 0, 0)
  on conflict (account_id, set_id, card_id)
    do update set count = excluded.count, holo_count = 0, vaulted_count = 0, vaulted_holo = 0;

  -- (a) owned + not turned in -> add succeeds (both A and B)
  r := public.cps_wantlist_add(atok, fA_set, fA, 'any');
  ok_owned_add := (r ->> 'ok')::boolean and (r ->> 'added')::boolean;
  r := public.cps_wantlist_add(atok, fB_set, fB, 'any');
  ok_owned_add := ok_owned_add and (r ->> 'ok')::boolean and (r ->> 'added')::boolean;

  -- (e) matches: B matches the player's spare 2 even though the
  --     admin (wanter) already owns a copy of B
  m := public.cps_matchmaker_matches(atok);
  ok_match := coalesce((select (e ->> 'spare')::int from jsonb_array_elements(m -> 'matches') e
                         where e ->> 'set_id' = fB_set and e ->> 'card_id' = fB
                           and e ->> 'owner_name' = pname), 0) = 2;

  -- (b) turned-in card -> rejected with reason 'turned_in', no row
  insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
  values (admin_id, fC_set, fC, 'manual', false);
  r := public.cps_wantlist_add(atok, fC_set, fC, 'any');
  ok_reject := (r ->> 'added')::boolean is false
    and r ->> 'reason' = 'turned_in'
    and not exists (select 1 from cps.wantlist
                     where account_id = admin_id and set_id = fC_set and card_id = fC);

  -- (d) + (f) list: A and B wants SURVIVE (owning does not clear),
  --     and every want element keeps the 167 shape
  r := public.cps_wantlist_list(atok);
  ok_survive := exists (select 1 from jsonb_array_elements(r -> 'wants') e
                         where e ->> 'set_id' = fA_set and e ->> 'card_id' = fA)
    and exists (select 1 from jsonb_array_elements(r -> 'wants') e
                  where e ->> 'set_id' = fB_set and e ->> 'card_id' = fB);
  ok_shape := coalesce((select bool_and(e ? 'set_id' and e ? 'card_id' and e ? 'holo_pref')
                          from jsonb_array_elements(r -> 'wants') e), true);

  -- (c) turn in A -> next list call auto-clears A's want (row gone);
  --     B's want is untouched
  insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
  values (admin_id, fA_set, fA, 'manual', false);
  r := public.cps_wantlist_list(atok);
  ok_purge := not exists (select 1 from jsonb_array_elements(r -> 'wants') e
                           where e ->> 'set_id' = fA_set and e ->> 'card_id' = fA)
    and not exists (select 1 from cps.wantlist
                     where account_id = admin_id and set_id = fA_set and card_id = fA)
    and exists (select 1 from cps.wantlist
                 where account_id = admin_id and set_id = fB_set and card_id = fB);

  if not (ok_owned_add and ok_match and ok_reject and ok_survive and ok_purge and ok_shape) then
    raise exception 'SMOKE FAIL owned_add=% match=% reject=% survive=% purge=% shape=%',
      ok_owned_add, ok_match, ok_reject, ok_survive, ok_purge, ok_shape;
  end if;
  raise notice 'SMOKE 168 PASS: owned_add=%, match=%, reject=%, survive=%, purge=%, shape=%',
    ok_owned_add, ok_match, ok_reject, ok_survive, ok_purge, ok_shape;
end $$;

rollback;
