-- =====================================================================
-- PackRipper — migration 125: "an Epic", not "a Epic"
-- Run AFTER 055 (live cps.ensure_cotd_today).
--
-- The Card of the Day announcement hardcoded the article "a" before
-- the rarity, which reads wrong for vowel-initial tiers ("a Epic!").
-- The article is now chosen by the tier's first letter (an for
-- epic/uncommon, a otherwise). Only the vtext expression changes;
-- the rest of cps.ensure_cotd_today is 055 verbatim.
--
-- Also included: a one-time fix of the already-stored announcement
-- rows, so today's bell entry reads correctly too.
-- =====================================================================

create or replace function cps.ensure_cotd_today() returns void
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  today date := (now() at time zone 'America/Chicago')::date;
  vx float8; vtier text; vsets text[]; vset text; vcards text[]; vcard text;
  vprize int; vsetname text; vtext text; n int;
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

  -- the day's announcement to every player
  select name into vsetname from cps.card_sets where id = vset;
  vtext := '🎯 Today''s Card of the Day is hiding in the ' || vsetname || ' set — '
        || (case when left(vtier, 1) in ('a', 'e', 'i', 'o', 'u') then 'an ' else 'a ' end)
        || initcap(vtier) || '! Pull it from any pack to win ' || vprize || ' spin tickets!';
  insert into cps.notifications (account_id, kind, text, target_view)
    select id, 'cotd', vtext, 'packs'
    from cps.accounts where not is_admin and not disabled;
end $$;

-- one-time: repair already-stored announcements (exact-phrase replace)
update cps.notifications
   set text = replace(text, ' set ' || chr(8212) || ' a Epic!', ' set ' || chr(8212) || ' an Epic!')
 where kind = 'cotd' and text like '% a Epic!%';
