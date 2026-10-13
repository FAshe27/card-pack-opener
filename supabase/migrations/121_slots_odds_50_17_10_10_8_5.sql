-- =====================================================================
-- PackRipper \u2014 migration 121: slots pay out ~1 spin in 7.5
-- Run AFTER 061 (the only definition of cps.slot_reel). Rebuilds
-- cps.slot_reel with new per-reel weights (Franklin's flavor: a
-- richer top end than a pure top-heavy rescale):
--   common 35 \u2192 50   uncommon 25 \u2192 17   rare 18 \u2192 10
--   epic   12 \u2192 10   legendary 7 \u2192 8    chase 3 \u2192 5
-- Three-of-a-kind rates: common 12.50% / uncommon 0.49% /
-- rare 0.10% / epic 0.10% / legendary 0.051% / chase 0.0125%
-- (1 in 8,000 spins, up from 1 in ~37,000). Any win: 13.26%,
-- about 1 in 7.5 spins (was 6.64%, ~1 in 15). Prizes and the
-- 2-token cost are unchanged (prize table lives in cps_slot_spin).
-- Only the five threshold numbers differ from 061's body.
-- =====================================================================

create or replace function cps.slot_reel() returns text
language plpgsql set search_path = cps, pg_temp as $$
declare x float8 := cps.rand01() * 100;
begin
  if x < 50 then return 'common';
  elsif x < 67 then return 'uncommon';
  elsif x < 77 then return 'rare';
  elsif x < 87 then return 'epic';
  elsif x < 95 then return 'legendary';
  else return 'chase';
  end if;
end $$;
