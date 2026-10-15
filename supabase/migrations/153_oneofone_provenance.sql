-- =====================================================================
-- 153_oneofone_provenance.sql -- One-of-One provenance: pulled by /
-- owned by. Run AFTER 152.
--
-- Franklin's ask (2026-10-15, the day the first One-of-One was
-- pulled): a 1/1's line in the card modal's variant census should say
-- "Pulled and owned by X" when it is still with its puller, or
-- "Pulled by X, owned by Y" once it has changed hands. Until now the
-- census only knew the current owner (and called it "found by").
--
--   * cps.variant_puller (new helper) -- recovers the original
--     puller of a specific numbered copy from cps.pack_openings.
--   * cps_variant_census (base: 016, never rebuilt since) -- each
--     card gains 'oneofone_puller' beside the existing
--     'oneofone_by' (the current owner).
--   * cps_variant_owners (base: 151) -- each One-of-One row gains
--     'puller', so the owners list can phrase it the same way.
-- Both rebuilds are insertion-only against their bases (proven by
-- back-diff). No table changes; grants ride along (CREATE OR REPLACE).
-- =====================================================================

-- --- helper: who originally pulled a specific numbered copy --------
-- Every pack opening stamps the pulled card's entry with its variant
-- tier + serial (016), so the mint event for any copy can be found in
-- cps.pack_openings. The variants row itself only tracks the CURRENT
-- owner -- this recovers the puller. Null when no opening matches
-- (e.g. a copy minted outside pack opening).
create or replace function cps.variant_puller(p_set text, p_card text, p_tier text, p_serial int)
returns text language sql stable set search_path = cps, pg_temp as $$
  select pa.display_name
    from cps.pack_openings o
    join cps.accounts pa on pa.id = o.account_id
   where exists (select 1 from jsonb_array_elements(o.cards) e
                  where e->>'id' = p_card
                    and e->>'variant' = p_tier
                    and e->>'serial' = p_serial::text
                    and coalesce(e->>'set_id', o.set_id) = p_set)
   order by o.opened_at
   limit 1
$$;

-- --- variant census (base: 016) + oneofone_puller ------------------
create or replace function public.cps_variant_census(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_object_agg(t.card_id, jsonb_build_object(
      'rainbow', t.rainbow, 'prism', t.prism, 'obsidian', t.obsidian, 'oneofone', t.oneofone,
      'oneofone_by', t.oneofone_by,
      'oneofone_puller', t.oneofone_puller))
    from (
      select v.card_id,
        count(*) filter (where v.tier = 'rainbow')::int as rainbow,
        count(*) filter (where v.tier = 'prism')::int as prism,
        count(*) filter (where v.tier = 'obsidian')::int as obsidian,
        count(*) filter (where v.tier = 'oneofone')::int as oneofone,
        max(acc.display_name) filter (where v.tier = 'oneofone') as oneofone_by,
        case when count(*) filter (where v.tier = 'oneofone') > 0
             then cps.variant_puller(p_set, v.card_id, 'oneofone', 1)
        end as oneofone_puller
      from cps.variants v join cps.accounts acc on acc.id = v.account_id
      where v.set_id = p_set
      group by v.card_id
    ) t
  ), '{}');
end $$;

-- --- variant owners (base: 151) + puller on One-of-One rows --------
create or replace function public.cps_variant_owners(p_token text, p_set text, p_card text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  if p_tier not in ('rainbow', 'prism', 'obsidian', 'oneofone', 'misprint') then
    raise exception 'Unknown variant tier.';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'serial', t.serial, 'tier', t.tier, 'owner', t.owner,
      'mine', t.account_id = a.id, 'vaulted', t.vaulted, 'misprint', t.misprint,
      'escrowed', t.escrowed, 'puller', t.puller)
      order by t.tier_rank, t.serial)
    from (
      select v.serial, v.tier, v.account_id, acc.display_name as owner,
             case when v.tier = 'oneofone'
                  then cps.variant_puller(p_set, v.card_id, v.tier, v.serial)
             end as puller,
             v.vaulted,
             (exists (select 1 from cps.bounty_escrow be
                        join cps.bounties bo on bo.id = be.bounty_id
                       where bo.status = 'open' and be.set_id = v.set_id and be.card_id = v.card_id
                         and be.tier = v.tier and be.serial = v.serial)
              or exists (select 1 from cps.trade_escrow te
                          where te.set_id = v.set_id and te.card_id = v.card_id
                            and te.variant_tier = v.tier and te.variant_serial = v.serial)) as escrowed,
             (k.rarity in ('common', 'uncommon')) as misprint,
             case v.tier when 'oneofone' then 0 when 'obsidian' then 1
                         when 'prism' then 2 else 3 end as tier_rank
        from cps.variants v
        join cps.accounts acc on acc.id = v.account_id
        join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
       where v.set_id = p_set and v.card_id = p_card
         and ((p_tier <> 'misprint' and v.tier = p_tier)
              or (p_tier = 'misprint' and k.rarity in ('common', 'uncommon')))
    ) t
  ), '[]');
end $$;

notify pgrst, 'reload schema';
