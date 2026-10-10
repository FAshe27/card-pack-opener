-- =====================================================================
-- 035_random_variant_serials.sql — numbered variants get a random unissued
-- serial instead of sequential (1, 2, 3...). (Run after 034.)
-- =====================================================================

create or replace function cps.mint_variant(p_account uuid, p_set text, p_card text, p_tier text)
returns int language plpgsql set search_path = cps, pg_temp as $$
declare
  run int := cps.variant_run(p_tier);
  n int;
  s int;
begin
  if run = 0 then return null; end if;
  -- lock the counter row: serializes minting for this card+tier
  insert into cps.variant_counters (set_id, card_id, tier, issued)
    values (p_set, p_card, p_tier, 0)
    on conflict (set_id, card_id, tier) do nothing;
  select issued into n from cps.variant_counters
    where set_id = p_set and card_id = p_card and tier = p_tier for update;
  if n >= run then return null; end if;

  -- pick a random serial that hasn't been issued yet
  select gs.serial into s
  from generate_series(1, run) gs(serial)
  where not exists (
    select 1 from cps.variants v
    where v.set_id = p_set and v.card_id = p_card
      and v.tier = p_tier and v.serial = gs.serial
  )
  order by random()
  limit 1;

  if s is null then return null; end if;

  update cps.variant_counters set issued = issued + 1
    where set_id = p_set and card_id = p_card and tier = p_tier;
  insert into cps.variants (account_id, set_id, card_id, tier, serial)
    values (p_account, p_set, p_card, p_tier, s);
  return s;
end $$;
