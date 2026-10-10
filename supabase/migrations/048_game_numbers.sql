-- =====================================================================
-- 048_game_numbers.sql — Higher/Lower uses numbers 1-10 instead of a deck.
-- (Run after 047.)
-- =====================================================================

create or replace function cps.draw_game_card() returns jsonb
language plpgsql set search_path = cps, pg_temp as $$
begin
  return jsonb_build_object('rank', 1 + floor(random() * 10)::int);
end $$;

notify pgrst, 'reload schema';
