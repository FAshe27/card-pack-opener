-- =====================================================================
-- PackRipper — migration 156: Card of the Day wording + activity grants
-- (REVISED activity test: logged in, not opened-a-pack)
-- Run AFTER 154. Supersedes the UN-RUN migration 155 — do not run 155.
--
-- Rebuilds ONLY cps.ensure_cotd_today (125's body, with the
-- announcement block extended — everything above the announcement
-- is 125 verbatim). No other function touched; the companion client
-- change (cotd.js modal wording) ships separately.
--
-- Franklin's calls (2026-10-15):
--   1. The nightly CotD notification now reads "...Pull it from a pack
--      to win N spin tickets!" ("a pack", not "any pack").
--   2. A player who was logged in YESTERDAY (Chicago calendar day —
--      i.e. since the last reset) gets 5 packs of the CotD set at
--      rollover, and their CotD notification gains the sentence:
--      "You've been given 5 [Set Name] packs to help your search."
--   3. The same active players also get 10 random packs at rollover
--      (the 144/152 pool: every active set that has cards, Jumbled
--      excluded, each pack rolled independently, duplicates possible),
--      with a separate notification in Franklin's exact words:
--      "Activity bonus! For being an active user, you've been granted
--      10 random packs!"
--
-- "Logged in" test (either signal qualifies):
--   * a session of theirs was used yesterday — cps.auth bumps
--     sessions.last_used_at on every authenticated call, so players
--     who simply stay signed in count (they rarely type their PIN;
--     accounts.last_login_at alone would miss them for weeks), OR
--   * accounts.last_login_at falls yesterday — which also covers a
--     player who logged in and back out (logout deletes the session).
--
-- Audience matches the existing CotD announcement and grant-all RPCs:
-- non-admin, non-disabled players only (admins never get CotD mail or
-- grants). Rollover is still the lazy ensure_cotd_today trigger (the
-- first CotD/pack/shop call after Chicago midnight), exactly like the
-- current announcement — there is no midnight cron in this stack.
-- Grants fire only in the call that actually creates today's CotD row
-- (guarded by the insert row-count, same as the announcement), so a
-- repeat call can never double-grant. Grants are ledgered in
-- cps.pack_grants: reason 'cotd_daily' (the 5 CotD-set packs) and
-- 'activity_bonus' (the 10 random packs), ref = the CotD date.
--
-- Also included, mirroring 125: a one-time wording repair of today's
-- already-sent CotD notifications ("any pack" -> "a pack"). No grants
-- are backpaid for today; the grants start at the next rollover.
-- =====================================================================

create or replace function cps.ensure_cotd_today() returns void
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  today date := (now() at time zone 'America/Chicago')::date;
  vx float8; vtier text; vsets text[]; vset text; vcards text[]; vcard text;
  vprize int; vsetname text; vtext text; n int;
  -- 155 additions
  r record; rp record; vactive boolean;
  vpool text[]; vpooln int := 0;
begin
  if exists (select 1 from cps.cotd_days where cotd_date = today) then return; end if;

  -- weighted rarity tier: rare 62 / epic 33 / legendary 5 (no chase in the CotD pool)
  vx := cps.rand01();
  vtier := case when vx < 0.62 then 'rare' when vx < 0.95 then 'epic' else 'legendary' end;

  -- uniform random active set (house idiom, cf. the jumbled set pick)
  select coalesce(array_agg(id order by id), '{}') into vsets
    from cps.card_sets where active and id <> 'jumbled';
  if coalesce(array_length(vsets, 1), 0) = 0 then return; end if;
  vset := vsets[1 + floor(cps.rand01() * array_length(vsets, 1))::int];

  -- uniform random card of that tier in that set
  select coalesce(array_agg(card_id order by card_id), '{}') into vcards
    from cps.cards where set_id = vset and rarity = vtier;
  if coalesce(array_length(vcards, 1), 0) = 0 then
    -- defensive fallback: any rare+ card in the set (no live set needs this)
    select coalesce(array_agg(card_id order by card_id), '{}') into vcards
      from cps.cards where set_id = vset and rarity in ('rare', 'epic', 'legendary');
    if coalesce(array_length(vcards, 1), 0) = 0 then return; end if;
  end if;
  vcard := vcards[1 + floor(cps.rand01() * array_length(vcards, 1))::int];
  select rarity into vtier from cps.cards where set_id = vset and card_id = vcard;

  vprize := case vtier when 'rare' then 3 when 'epic' then 5 else 8 end;

  insert into cps.cotd_days (cotd_date, set_id, card_id, rarity, prize_tickets)
    select today, vset, vcard, vtier, vprize
    where not exists (select 1 from cps.cotd_days where cotd_date = today);
  get diagnostics n = row_count;
  if n = 0 then return; end if; -- lost the race; the other pick stands

  -- the day's announcement to every player, plus the activity grants.
  select name into vsetname from cps.card_sets where id = vset;
  vtext := '🎯 Today''s Card of the Day is hiding in the ' || vsetname || ' set — '
        || (case when left(vtier, 1) in ('a', 'e', 'i', 'o', 'u') then 'an ' else 'a ' end)
        || initcap(vtier) || '! Pull it from a pack to win ' || vprize || ' spin tickets!';

  -- random-pack pool for the activity bonus (144/152 definition)
  select array_agg(cs.id order by cs.id), count(*)
    into vpool, vpooln
    from cps.card_sets cs
   where cs.active and cs.id <> 'jumbled'
     and exists (select 1 from cps.cards c where c.set_id = cs.id);

  for r in select id, last_login_at from cps.accounts where not is_admin and not disabled loop
    -- active = logged in yesterday (Chicago calendar day), i.e. since
    -- the last reset. Two signals, either qualifies: a session that was
    -- used yesterday (cps.auth bumps sessions.last_used_at on every
    -- call, so players who simply stay signed in count -- they rarely
    -- type their PIN), or a recorded login yesterday (last_login_at,
    -- which also covers a player who logged in and back out, deleting
    -- their session row).
    vactive := exists (
      select 1 from cps.sessions s
       where s.account_id = r.id
         and (s.last_used_at at time zone 'America/Chicago')::date = today - 1)
      or (r.last_login_at at time zone 'America/Chicago')::date = today - 1;

    if vactive then
      -- 5 packs of the CotD set to help the search
      perform cps.add_packs(r.id, vset, 5, 'cotd_daily', today::text, null);
      -- 10 random packs, each rolled independently (152 draw shape)
      if vpooln > 0 then
        for rp in
          select d.pick as set_id, count(*)::int as cnt
            from (select vpool[1 + floor(random() * vpooln)::int] as pick
                    from generate_series(1, 10)) d
           group by d.pick
        loop
          perform cps.add_packs(r.id, rp.set_id, rp.cnt, 'activity_bonus', today::text, null);
        end loop;
      end if;
    end if;

    insert into cps.notifications (account_id, kind, text, target_view)
      values (r.id, 'cotd',
              vtext || case when vactive
                            then ' You''ve been given 5 ' || vsetname || ' packs to help your search.'
                            else '' end,
              'packs');

    if vactive then
      insert into cps.notifications (account_id, kind, text, target_view)
        values (r.id, 'activity_bonus',
                'Activity bonus! For being an active user, you''ve been granted 10 random packs!',
                'packs');
    end if;
  end loop;
end $$;

-- one-time: repair today's already-stored CotD announcements (125 pattern;
-- wording only — no grants are backpaid for today)
update cps.notifications
   set text = replace(text, 'Pull it from any pack to win', 'Pull it from a pack to win')
 where kind = 'cotd' and text like '%Pull it from any pack to win%';

notify pgrst, 'reload schema';
