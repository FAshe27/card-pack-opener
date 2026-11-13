-- 228_daily_spins_at_reset.sql
-- Franklin, 2026-11-12: the daily spin tickets change from 3-on-first-load
-- (only if holding fewer than 10) to a flat 5 granted at the daily reset
-- to players who were active the previous day. Cap dropped at his ruling
-- ("Drop it -- flat 5 for actives").
--
-- The grant moves into cps.ensure_cotd_today, inside the same per-player
-- pass that already pays the CotD + activity-bonus packs, using that
-- function's existing 'active yesterday' test (migration 226: a pack
-- opening yesterday, or a session used yesterday, or a login yesterday;
-- non-admin, non-disabled accounts only -- the loop's own filter).
-- The tickets are stamped (last_daily_spin) and logged in cps.spin_grants
-- with reason 'daily', exactly as the old grant logged them.
--
-- The old lazy grant is removed from BOTH public.cps_get_state and
-- public.cps_get_state_delta (the delta function mirrors it verbatim --
-- leaving either copy in place would double-pay). Bodies otherwise
-- byte-identical to live; the ensure body is insertion-only.
--
-- First effect: the 2026-11-13 rollover pays 5 tickets to everyone
-- active on 2026-11-12. No backfill for earlier days.

create or replace function cps.ensure_cotd_today()
returns void
language plpgsql
as $func$
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
    -- the last reset. Three signals, any qualifies -- a pack opening
    -- yesterday is the strongest proof (226: the session stamp alone
    -- failed Ciera two nights running, 2026-11-07/08: her open tab
    -- kept refreshing last_used_at past midnight, erasing yesterday
    -- before this check ran). The other two signals: a session that was
    -- used yesterday (cps.auth bumps sessions.last_used_at on every
    -- call, so players who simply stay signed in count -- they rarely
    -- type their PIN), or a recorded login yesterday (last_login_at,
    -- which also covers a player who logged in and back out, deleting
    -- their session row).
    vactive := exists (
      select 1 from cps.pack_openings o
       where o.account_id = r.id
         and (o.opened_at at time zone 'America/Chicago')::date = today - 1)
      or exists (
      select 1 from cps.sessions s
       where s.account_id = r.id
         and (s.last_used_at at time zone 'America/Chicago')::date = today - 1)
      or (r.last_login_at at time zone 'America/Chicago')::date = today - 1;

    if vactive then
      -- 5 packs of the CotD set to help the search
      perform cps.add_packs(r.id, vset, 5, 'cotd_daily', today::text, null);
      -- 5 daily spin tickets (228: the daily grant moved here from the
      -- lazy cps_get_state / cps_get_state_delta block -- flat 5 for
      -- players active yesterday, no fewer-than-10 cap.)
      update cps.accounts set spins = spins + 5, last_daily_spin = today where id = r.id;
      insert into cps.spin_grants (account_id, spins, reason) values (r.id, 5, 'daily');
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
end $func$;

create or replace function public.cps_get_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = cps, pg_temp
as $func$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
begin
  a := cps.auth(p_token);
  -- Daily-spin grant removed (228): the flat 5 now land in the
  -- ensure_cotd_today rollover for players active yesterday.
  select * into a from cps.accounts where id = a.id;
  return cps.state_json(a.id) || jsonb_build_object('game_tokens', coalesce(a.game_tokens, 0));
end $func$;

create or replace function public.cps_get_state_delta(p_token text, p_ver bigint, p_gver bigint)
returns jsonb
language plpgsql
security definer
set search_path = cps, pg_temp
as $func$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
  v_cur bigint;
  g_cur bigint;
  v_full jsonb;
  v_blocks jsonb := '{}'::jsonb;
  v_key text;
begin
  a := cps.auth(p_token);
  -- Daily-spin grant removed (228): the flat 5 now land in the
  -- ensure_cotd_today rollover for players active yesterday.
  select * into a from cps.accounts where id = a.id;

  v_cur := coalesce((select ver from cps.state_meta where account_id = a.id), 0);
  g_cur := coalesce((select ver from cps.state_meta
                      where account_id = '00000000-0000-0000-0000-000000000000'::uuid), 0);

  if p_ver is not null and p_ver = v_cur and coalesce(p_gver, -1) = g_cur then
    return jsonb_build_object('ver', v_cur, 'gver', g_cur, 'unchanged', true);
  end if;

  v_full := cps.state_json(a.id);
  if p_ver is null or p_ver <= 0 or p_ver > v_cur or p_gver is null or p_gver > g_cur then
    return v_full || jsonb_build_object('game_tokens', coalesce(a.game_tokens, 0), 'full', true);
  end if;

  for v_key in
    select block from cps.state_blocks where account_id = a.id and changed_ver > p_ver
    union
    select block from cps.state_blocks
     where account_id = '00000000-0000-0000-0000-000000000000'::uuid and changed_ver > p_gver
  loop
    v_blocks := v_blocks || jsonb_build_object(v_key, v_full -> v_key);
  end loop;

  return jsonb_build_object('ver', v_cur, 'gver', g_cur,
                            'game_tokens', coalesce(a.game_tokens, 0),
                            'blocks', v_blocks);
end $func$;
