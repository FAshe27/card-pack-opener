-- =====================================================================
-- PackRipper — migration 166: 'Sets Completed' for All Players stats
-- Run AFTER 165 (independent of it — touches only cps_global_pull_stats).
-- Rebuilds cps_global_pull_stats from 115 verbatim plus a
-- 'sets_completed' total: rows in cps.set_completions (one per
-- player+set ever completed, recorded exactly-once by migration 113's
-- announcer) for non-admin, non-disabled accounts — the same
-- population as Cards pulled / Cards turned in / Holo pulls in the
-- All Players panel. Client adds the tile after Holo pulls.
-- =====================================================================

create or replace function public.cps_global_pull_stats(p_token text)
returns jsonb language sql security definer set search_path = cps, pg_temp as $$
  with agg as (
    select coalesce(sum(s.pulled), 0) as pulled,
           coalesce(sum(s.holos), 0) as holos
    from cps.user_set_stats s
    join cps.accounts a on a.id = s.account_id
    where not coalesce(a.is_admin, false) and not coalesce(a.disabled, false)
  ), rar as (
    select v.key as rarity, sum(v.value::int) as n
    from cps.user_set_stats s
    join cps.accounts a on a.id = s.account_id
    cross join jsonb_each_text(s.by_rarity) as v(key, value)
    where not coalesce(a.is_admin, false) and not coalesce(a.disabled, false)
    group by v.key
  ), num as (
    select count(*) as n
    from cps.variants v
    join cps.accounts a on a.id = v.account_id
    where not coalesce(a.is_admin, false) and not coalesce(a.disabled, false)
  ), tin as (
    select count(*) as n
    from cps.turn_ins t
    join cps.accounts a on a.id = t.account_id
    where not coalesce(a.is_admin, false) and not coalesce(a.disabled, false)
  ), comp as (
    select count(*) as n
    from cps.set_completions c
    join cps.accounts a on a.id = c.account_id
    where not coalesce(a.is_admin, false) and not coalesce(a.disabled, false)
  ), latest as (
    select b.set_id, b.card_id, b.rarity, b.pulled_at,
           b.variant_tier, b.variant_serial,
           acc.display_name as player, cs.name as set_name, k.name as card_name
    from cps.big_pulls b
    join cps.accounts acc on acc.id = b.account_id
    join cps.card_sets cs on cs.id = b.set_id
    join cps.cards k on k.set_id = b.set_id and k.card_id = b.card_id
    where not coalesce(acc.is_admin, false) and not coalesce(acc.disabled, false)
    order by b.pulled_at desc limit 1
  )
  select jsonb_build_object(
    'pulled', (select pulled from agg),
    'holos', (select holos from agg),
    'numbered', (select n from num),
    'turned_in', (select n from tin),
    'sets_completed', (select n from comp),
    'by_rarity', coalesce((select jsonb_object_agg(rarity, n) from rar), '{}'::jsonb),
    'latest_big', (select row_to_json(latest) from latest)
  );
$$;

notify pgrst, 'reload schema';

-- Verify: select public.cps_global_pull_stats('anything');  -- the result
-- gains "sets_completed" alongside the existing fields; every other field
-- is unchanged. Cross-check: select count(*) from cps.set_completions sc
-- join cps.accounts a on a.id = sc.account_id
-- where not coalesce(a.is_admin,false) and not coalesce(a.disabled,false);
