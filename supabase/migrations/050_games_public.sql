-- =====================================================================
-- 050_games_public.sql — open the Arcade to all players (drop the
-- admin-only gate on game start).
-- (Run after 049.)
-- =====================================================================

create or replace function public.cps_game_start(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; card jsonb; runid uuid; left_n int;
begin
  a := cps.auth(p_token);
  if coalesce(a.game_tokens, 0) < 1 then raise exception 'No game tokens.'; end if;
  update cps.accounts set game_tokens = game_tokens - 1 where id = a.id returning game_tokens into left_n;
  update cps.game_runs set status = 'expired', updated_at = now() where account_id = a.id and status = 'active';
  card := cps.draw_game_card();
  insert into cps.game_runs (account_id, current) values (a.id, card) returning id into runid;
  insert into cps.token_grants (account_id, tokens, reason) values (a.id, -1, 'game_entry');
  return jsonb_build_object('run', runid, 'card', card, 'tokens_left', left_n);
end $$;

notify pgrst, 'reload schema';
