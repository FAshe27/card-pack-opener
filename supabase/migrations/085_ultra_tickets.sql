-- =====================================================================
-- 085_ultra_tickets.sql — Fix 'ultra' quest tier awarding 0 tickets.
-- =====================================================================

create or replace function cps.quest_tickets(p_tier text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_tier when 'easy' then 1 when 'medium' then 2 when 'hard' then 3 when 'ultra' then 5 else 0 end $$;

notify pgrst, 'reload schema';
