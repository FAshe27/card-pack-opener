-- =====================================================================
-- 154_oneofone_provenance_fix.sql -- One-of-One provenance REPAIR.
-- Run AFTER 153.
--
-- Franklin's report (2026-10-15): he traded for the Ron Dennis
-- Formula 1 One-of-One that Molly pulled, and (a) HIS Trophy Case
-- shows the "One-of-One Pull" trophy ("You pulled Ron Dennis"), and
-- (b) the card's One-of-One census line reads "Owned by Franklin"
-- instead of "Pulled by Molly, owned by Franklin".
--
-- Two root causes, both in provenance lookups written against a
-- data shape production does not have:
--
-- (1) 153's cps.variant_puller searched cps.pack_openings for
--     entries stamped {variant, serial}. But EVERY cps_open_pack
--     body in the repo's history -- 016 through the current 140 --
--     stores pack_openings.cards entries rebuilt with ONLY
--     {id, set_id, rarity, holo}: the variant stamp exists on the
--     returned `out` object but is filtered out of the stored
--     insert. So the helper could never match a real pull and the
--     census always fell back to "Owned by X". (153's verify
--     planted a stamped opening -- the shape it assumed, not the
--     shape production writes -- which is why it passed.)
--     FIX: variant_puller now reads cps.big_pulls FIRST. Every
--     variant pull since 034 lands there with the puller's
--     account_id, set, card, tier and serial (insert present in
--     the current 140 body). The pack_openings search is kept,
--     unchanged, as a legacy fallback after it.
--
-- (2) cps_get_trophies (133) falls back, when a player has no
--     big_pulls One-of-One, to "the earliest one-of-one variant
--     the player OWNS". That fallback fires for ANY current owner,
--     even when the copy they hold was pulled by someone else and
--     DOES have a big_pulls record -- so trading for a 1/1 handed
--     the recipient the pull trophy too.
--     FIX: the fallback now requires that the owned copy has NO
--     big_pulls One-of-One record at all (that is the pre-034
--     case the fallback exists for). The primary big_pulls lookup
--     is untouched: Molly keeps the trophy, latched to her pull,
--     even though she no longer owns the card.
--
-- This file: variant_puller body replaced (same signature);
-- cps_get_trophies is 133's body with ONLY the fallback guard
-- inserted (proven by back-diff). cps_variant_census and
-- cps_variant_owners need no changes -- they call the helper.
-- No client change: js/census.js and js/trophies.js already
-- render the correct sentences off these fields.
-- =====================================================================

-- --- puller lookup: big_pulls is the real provenance ledger -------
create or replace function cps.variant_puller(p_set text, p_card text, p_tier text, p_serial int)
returns text language sql stable set search_path = cps, pg_temp as $$
  select coalesce(
    (select ba.display_name
       from cps.big_pulls bp
       join cps.accounts ba on ba.id = bp.account_id
      where bp.set_id = p_set and bp.card_id = p_card
        and bp.variant_tier = p_tier and bp.variant_serial = p_serial
      order by bp.pulled_at
      limit 1),
    (select pa.display_name
       from cps.pack_openings o
       join cps.accounts pa on pa.id = o.account_id
      where exists (select 1 from jsonb_array_elements(o.cards) e
                     where e->>'id' = p_card
                       and e->>'variant' = p_tier
                       and e->>'serial' = p_serial::text
                       and coalesce(e->>'set_id', o.set_id) = p_set)
      order by o.opened_at
      limit 1))
$$;

-- --- trophy case: fallback can no longer steal a pulled 1/1 -------
create or replace function public.cps_get_trophies(p_token text, p_account uuid)
returns jsonb
language plpgsql
security definer
set search_path = cps, pg_temp
as $$
declare
  a cps.accounts%rowtype;
  v_target uuid;
  v_is_admin boolean := false;
  v_oneofone jsonb := null;
  v_turned_ts timestamptz[];
  v_packs_ts timestamptz[];
begin
  a := cps.auth(p_token);
  select id, coalesce(is_admin, false) into v_target, v_is_admin
    from cps.accounts where id = p_account and not coalesce(disabled, false);
  if v_target is null then
    raise exception 'Player not found.';
  end if;

  -- 1-of-1: the FIRST one the player ever PULLED (big_pulls ledger).
  select jsonb_build_object(
           'card_id', bp.card_id,
           'set_id', bp.set_id,
           'card_name', c.name,
           'set_name', cs.name,
           'serial', bp.variant_serial,
           'at', bp.pulled_at)
    into v_oneofone
    from cps.big_pulls bp
    left join cps.cards c on c.set_id = bp.set_id and c.card_id = bp.card_id
    left join cps.card_sets cs on cs.id = bp.set_id
   where bp.account_id = v_target and bp.variant_tier = 'oneofone'
   order by bp.pulled_at asc
   limit 1;

  -- Fallback for variant pulls that predate big_pulls variant columns:
  -- the earliest one-of-one variant the player owns.
  if v_oneofone is null then
    select jsonb_build_object(
             'card_id', v.card_id,
             'set_id', v.set_id,
             'card_name', c.name,
             'set_name', cs.name,
             'serial', v.serial,
             'at', v.pulled_at)
      into v_oneofone
      from cps.variants v
      left join cps.cards c on c.set_id = v.set_id and c.card_id = v.card_id
      left join cps.card_sets cs on cs.id = v.set_id
     where v.account_id = v_target and v.tier = 'oneofone'
       and not exists (select 1 from cps.big_pulls bp
                        where bp.set_id = v.set_id and bp.card_id = v.card_id
                          and bp.variant_tier = 'oneofone'
                          and bp.variant_serial = v.serial)
     order by v.pulled_at asc nulls last
     limit 1;
  end if;

  -- Ordered event timestamps: index N is when the Nth event happened,
  -- i.e. the day the matching tier was crossed.
  select array_agg(created_at order by created_at) into v_turned_ts
    from cps.turn_ins where account_id = v_target;
  select array_agg(opened_at order by opened_at) into v_packs_ts
    from cps.pack_openings where account_id = v_target;

  return jsonb_build_object(
    'sets', coalesce((
      select jsonb_agg(x order by x->>'set_name')
        from (
          select jsonb_build_object(
                   'set_id', t.set_id,
                   'set_name', cs.name,
                   'turned', t.turned,
                   'total', (select count(*) from cps.cards c where c.set_id = t.set_id),
                   'at', t.last_at) as x
            from (select set_id, count(*) as turned, max(created_at) as last_at
                    from cps.turn_ins where account_id = v_target group by set_id) t
            join cps.card_sets cs on cs.id = t.set_id
           where t.turned >= (select count(*) from cps.cards c where c.set_id = t.set_id)
             and (select count(*) from cps.cards c where c.set_id = t.set_id) > 0
        ) s), '[]'::jsonb),
    'progress', coalesce((
      select jsonb_agg(x order by x->>'set_id')
        from (
          select jsonb_build_object(
                   'set_id', t.set_id,
                   'turned', t.turned,
                   'total', (select count(*) from cps.cards c where c.set_id = t.set_id)) as x
            from (select set_id, count(*) as turned
                    from cps.turn_ins where account_id = v_target group by set_id) t
        ) s), '[]'::jsonb),
    'turned_total', coalesce(array_length(v_turned_ts, 1), 0),
    'turned_dates', jsonb_build_object(
      '1000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 1000 then v_turned_ts[1000] end,
      '2500', case when coalesce(array_length(v_turned_ts, 1), 0) >= 2500 then v_turned_ts[2500] end,
      '5000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 5000 then v_turned_ts[5000] end,
      '10000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 10000 then v_turned_ts[10000] end),
    'packs_opened', coalesce(array_length(v_packs_ts, 1), 0),
    'packs_dates', jsonb_build_object(
      '10', case when coalesce(array_length(v_packs_ts, 1), 0) >= 10 then v_packs_ts[10] end,
      '100', case when coalesce(array_length(v_packs_ts, 1), 0) >= 100 then v_packs_ts[100] end,
      '1000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 1000 then v_packs_ts[1000] end,
      '2500', case when coalesce(array_length(v_packs_ts, 1), 0) >= 2500 then v_packs_ts[2500] end,
      '5000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 5000 then v_packs_ts[5000] end,
      '10000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 10000 then v_packs_ts[10000] end),
    'oneofone', v_oneofone,
    'cotd_days', (select count(*) from cps.cotd_claims where account_id = v_target),
    'cotd_first', (select min(cotd_date) from cps.cotd_claims where account_id = v_target)
  );
end;
$$;

grant execute on function public.cps_get_trophies(text, uuid) to anon;

notify pgrst, 'reload schema';
