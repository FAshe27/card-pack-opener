-- =====================================================================
-- 155_market_nav_counts.sql — fix: 'Visit the Market' daily auto-completes
-- on login.
--
-- Root cause: the Market nav badge (added 2026-10-13) runs on EVERY state
-- load (applyPrefsUI -> CPS.bounties.navBadge), and it fetched the badge
-- counts by calling cps_list_bounties + cps_trading_post — the two RPCs
-- whose bodies bump the visit_market quest (074). So a player who simply
-- logged in had already "visited the Market" server-side before ever
-- opening the tab.
--
-- Fix: a dedicated lightweight counts RPC for the badge. It authenticates,
-- runs the same expiry passes the two board RPCs run (so the counts are
-- post-expiry, exactly like the boards), and returns ONLY the two badge
-- numbers. It deliberately does NOT call cps.quest_bump — loading a badge
-- count is not a Market visit. cps_list_bounties / cps_trading_post are
-- untouched, so a real Market visit still completes the quest exactly as
-- before.
--
-- claimable mirrors cps_list_bounties' can_claim logic (151) exactly:
-- someone else's open bounty where the viewer holds an on-hand copy —
-- exact-serial and any-of-tier wants need an UNVAULTED variant instance
-- plus a base copy (count >= 1); plain wants use on-hand totals
-- (count - vaulted_count, or holo_count - vaulted_holo for a holo want).
-- trade_offers mirrors the client filter in trading.js: my open listings
-- that have at least one open offer.
--
-- Deployment order is safe either way round: the new client treats a
-- missing RPC as a best-effort badge failure (badge just stays hidden),
-- and the old client is unaffected by this migration existing.
-- =====================================================================

create or replace function public.cps_market_nav(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a            cps.accounts%rowtype;
  claimable    int;
  trade_offers int;
begin
  a := cps.auth(p_token);
  perform cps.bounty_expire_due();
  perform cps.trade_expire_due();

  select count(*) into claimable
    from cps.bounties bo
   where bo.status = 'open'
     and bo.poster <> a.id
     and (
       (bo.want_serial is not null
        and exists (select 1 from cps.variants v
                     where v.account_id = a.id
                       and v.set_id = bo.want_set and v.card_id = bo.want_card
                       and v.tier = bo.want_tier and v.serial = bo.want_serial
                       and not coalesce(v.vaulted, false))
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and c.count >= 1))
       or
       (bo.want_serial is null and bo.want_tier is not null
        and exists (select 1 from cps.variants v
                     where v.account_id = a.id
                       and v.set_id = bo.want_set and v.card_id = bo.want_card
                       and v.tier = bo.want_tier
                       and not coalesce(v.vaulted, false))
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and c.count >= 1))
       or
       (bo.want_serial is null and bo.want_tier is null
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and case when bo.want_holo = 'holo'
                                then c.holo_count - c.vaulted_holo >= 1
                                else c.count - c.vaulted_count >= 1 end))
     );

  select count(*) into trade_offers
    from cps.trade_listings t
   where t.lister = a.id
     and t.status = 'open'
     and exists (select 1 from cps.listing_offers o
                  where o.listing_id = t.id and o.status = 'open');

  return jsonb_build_object('claimable', claimable, 'trade_offers', trade_offers);
end $$;

grant execute on function public.cps_market_nav(text) to anon;

notify pgrst, 'reload schema';
