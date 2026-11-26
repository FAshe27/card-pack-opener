-- Migration 234: High/Low streak records in cps_game_state
-- Adds a 'records' object to every cps_game_state response:
--   ever:  highest streak ever by a non-admin player {streak, name}
--          (earliest achiever wins ties)
--   today: highest streak by a non-admin player on runs last played
--          today, America/Chicago {streak, name} (null if none yet)
--   mine:  the caller's own best streak ever (0 if they have no runs)
-- CLAIMED RUNS ONLY (Franklin's ruling, 2026-11-26: "make it truly
-- risky!"): a run that busts keeps its peak streak stored in
-- cps.game_runs, but it does NOT count toward any record — you have
-- to bank the streak for it to go on the board.
-- No schema changes; the run lookup and existing return keys are
-- unchanged apart from the added 'records' key.

create or replace function public.cps_game_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = cps, pg_temp
as $func$
declare
  a   cps.accounts%rowtype;
  run cps.game_runs%rowtype;
  v_ever_streak  int;
  v_ever_name    text;
  v_today_streak int;
  v_today_name   text;
  v_my_best      int;
  rec jsonb;
begin
  a := cps.auth(p_token);
  select * into run from cps.game_runs
   where account_id = a.id and status = 'active'
   order by updated_at desc
   limit 1;

  select g.streak, acc.display_name into v_ever_streak, v_ever_name
    from cps.game_runs g
    join cps.accounts acc on acc.id = g.account_id
   where not acc.is_admin and g.streak > 0 and g.status = 'claimed'
   order by g.streak desc, g.updated_at asc
   limit 1;

  select g.streak, acc.display_name into v_today_streak, v_today_name
    from cps.game_runs g
    join cps.accounts acc on acc.id = g.account_id
   where not acc.is_admin and g.streak > 0 and g.status = 'claimed'
     and (g.updated_at at time zone 'America/Chicago')::date
       = (now() at time zone 'America/Chicago')::date
   order by g.streak desc, g.updated_at asc
   limit 1;

  select max(streak) into v_my_best from cps.game_runs where account_id = a.id and status = 'claimed';

  rec := jsonb_build_object(
    'ever',  case when v_ever_streak  is null then null
                  else jsonb_build_object('streak', v_ever_streak,  'name', v_ever_name)  end,
    'today', case when v_today_streak is null then null
                  else jsonb_build_object('streak', v_today_streak, 'name', v_today_name) end,
    'mine',  coalesce(v_my_best, 0));

  if run.id is null then
    return jsonb_build_object('run', null, 'records', rec);
  end if;
  return jsonb_build_object('run', run.id, 'card', run.current,
                            'streak', run.streak, 'bank', coalesce(run.bank, '[]'::jsonb),
                            'records', rec);
end
$func$;
