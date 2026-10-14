-- 143_variant_owners.sql
-- Clickable variant census: who owns each minted numbered copy?
-- Two NEW read-only RPCs — nothing existing is rebuilt:
--   cps_variant_owners(p_token, p_set, p_card, p_tier)
--     p_tier 'rainbow'/'prism'/'obsidian'/'oneofone' -> that tier's copies
--     p_tier 'misprint' -> every misprinted copy of the card (all tiers)
--     A "misprint" is derived exactly the way the site already derives it
--     (popfill's MISPRINT tag): a variant instance on a Common/Uncommon
--     card. Variants only mint on Rare+ cards, so those instances are the
--     pre-134 mistaken mints.
--   cps_variant_misprints(p_token, p_set) -> { card_id: misprint count }
--     Per-set counts so the card modal can show the explainer line.
-- Inclusion matches cps_variant_census (016) EXACTLY — every variant row
-- counts, no admin/disabled filtering — so an owners list always adds up
-- to the "N found" number that was clicked.

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
      'mine', t.account_id = a.id, 'vaulted', t.vaulted, 'misprint', t.misprint)
      order by t.tier_rank, t.serial)
    from (
      select v.serial, v.tier, v.account_id, acc.display_name as owner,
             v.vaulted,
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

create or replace function public.cps_variant_misprints(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_object_agg(t.card_id, t.n)
    from (
      select v.card_id, count(*)::int as n
        from cps.variants v
        join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
       where v.set_id = p_set and k.rarity in ('common', 'uncommon')
       group by v.card_id
    ) t
  ), '{}');
end $$;

grant execute on function public.cps_variant_owners(text, text, text, text) to anon;
grant execute on function public.cps_variant_misprints(text, text) to anon;

notify pgrst, 'reload schema';
