-- 167_matchmaker_verify.sql — post-auth smoke test for migration 167
-- (Wantlist + Trade Matchmaker). Run AFTER 167_matchmaker.sql.
--
-- Runs ENTIRELY in one transaction and ROLLS BACK: the Muse admin
-- test account ('Admin Account') and one real non-admin player are
-- fixtured in-transaction (planted sessions, planted collection
-- rows), the real RPCs are called with the planted tokens, and
-- nothing persists — no wants, cards or sessions survive.
-- Expected: one NOTICE line, every check true.
begin;

do $$
declare
  admin_id  uuid;
  player_id uuid;
  pname     text;
  atok      text := 'smoke167-admin-00000001';
  ptok      text := 'smoke167-player-0000001';
  f_set     text;
  f_card    text;
  r         jsonb;
  m         jsonb;
  ok_add      boolean := false;
  ok_match    boolean := false;
  ok_spare    boolean := false;
  ok_adminhide boolean := false;
  ok_reverse  boolean := false;
  ok_remove   boolean := false;
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

  -- Fixture card: a Common the admin does not currently own, so the
  -- want survives the owned purge. The player is given 3 plain copies
  -- in-transaction (spare = 2: three minus the one keeper).
  select k.set_id, k.card_id into f_set, f_card from cps.cards k
   where k.rarity = 'common'
     and not exists (select 1 from cps.collection c
                      where c.account_id = admin_id and c.set_id = k.set_id
                        and c.card_id = k.card_id and c.count > 0)
   order by k.set_id, k.card_id limit 1;
  if f_set is null then raise exception 'no fixture card available'; end if;
  insert into cps.collection (account_id, set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)
  values (player_id, f_set, f_card, 3, 0, 0, 0)
  on conflict (account_id, set_id, card_id) do update set count = 3, holo_count = 0, vaulted_count = 0, vaulted_holo = 0;

  -- 1) Admin adds the want
  r := public.cps_wantlist_add(atok, f_set, f_card, 'any');
  ok_add := (r ->> 'ok')::boolean and (r ->> 'added')::boolean;

  -- 2) The match names the player, with spare = 2
  m := public.cps_matchmaker_matches(atok);
  ok_match := exists (select 1 from jsonb_array_elements(m -> 'matches') e
                       where e ->> 'set_id' = f_set and e ->> 'card_id' = f_card
                         and e ->> 'owner_name' = pname);
  ok_spare := coalesce((select (e ->> 'spare')::int from jsonb_array_elements(m -> 'matches') e
                         where e ->> 'set_id' = f_set and e ->> 'card_id' = f_card
                           and e ->> 'owner_name' = pname), 0) = 2;

  -- 3) Reverse view: the player sees the admin's want against his spare
  --    ONLY if the player is... no: admin wanters are hidden from
  --    non-admin callers, so the player's reverse view must NOT name
  --    the admin account. That invisibility is the check.
  r := public.cps_matchmaker_wanted_mine(ptok);
  ok_adminhide := not exists (select 1 from jsonb_array_elements(r -> 'wanted') e
                               where e ->> 'set_id' = f_set and e ->> 'card_id' = f_card);

  -- 4) The admin's own reverse view answers cleanly. (The positive
  --    reverse path — a named wanter against a real spare — is covered
  --    by the staged local-Postgres fixture run, test167.sql in the
  --    build package, checks 11-12.)
  r := public.cps_matchmaker_wanted_mine(atok);
  ok_reverse := (r ->> 'ok')::boolean;

  -- 5) Remove works and the want is gone
  r := public.cps_wantlist_remove(atok, f_set, f_card);
  ok_remove := (r ->> 'ok')::boolean
    and not exists (select 1 from cps.wantlist
                     where account_id = admin_id and set_id = f_set and card_id = f_card);

  if not (ok_add and ok_match and ok_spare and ok_adminhide and ok_reverse and ok_remove) then
    raise exception 'SMOKE FAIL add=% match=% spare=% adminhide=% reverse=% remove=%',
      ok_add, ok_match, ok_spare, ok_adminhide, ok_reverse, ok_remove;
  end if;
  raise notice 'SMOKE 167 PASS: add=%, match=%, spare=%, adminhide=%, reverse=%, remove=%',
    ok_add, ok_match, ok_spare, ok_adminhide, ok_reverse, ok_remove;
end $$;

rollback;
