-- 218_shop_seconds_dst_fix.sql
-- Bug (reported by Franklin 2026-11-01, fall-back morning): the Shop header
-- countdown rendered negative garbage ("New stock in 0-1:0-42:0-12").
-- Cause: cps.shop_seconds_to_restock added a flat interval '12 hours' to the
-- cycle start. The cycle start itself is correct (Chicago midnight/noon),
-- but the midnight->noon stretch on the fall-back day is 13 elapsed hours
-- (11 on spring-forward morning), so the countdown hit zero an hour early
-- and kept counting negative. Display-only: stock, limits and purchases key
-- off cps.shop_cycle_start(), which was never wrong.
-- Fix: compute the NEXT boundary in America/Chicago wall-clock time (today's
-- noon, or tomorrow's midnight), matching how the cycle start is computed.
create or replace function cps.shop_seconds_to_restock()
returns integer
language sql
stable
set search_path to 'cps', 'pg_temp'
as $$
  select extract(epoch from (
    case
      when (now() at time zone 'America/Chicago')::time < '12:00'::time
      then (date_trunc('day', now() at time zone 'America/Chicago') + interval '12 hours')
             at time zone 'America/Chicago'
      else (date_trunc('day', now() at time zone 'America/Chicago') + interval '1 day')
             at time zone 'America/Chicago'
    end - now()))::int
$$;
