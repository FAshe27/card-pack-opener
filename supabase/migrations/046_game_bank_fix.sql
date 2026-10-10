-- =====================================================================
-- 045_game_playing_cards.sql — Higher/Lower uses a traditional deck
-- (ranks 2-A, Ace high) instead of PackRipper cards.
-- (Run after 045.)
-- =====================================================================

create or replace function public.cps_game_guess(p_token text, p_run uuid, p_higher boolean) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; run cps.game_runs%rowtype;
        cur_r int; newcard jsonb; new_r int; vbank jsonb; bn int;
        w_pack numeric; w_ticket numeric; w_token numeric; w_nothing numeric;
        tot numeric; roll numeric; prize jsonb;
begin
  a := cps.auth(p_token);
  select * into run from cps.game_runs where id = p_run and account_id = a.id for update;
  if run.id is null then raise exception 'Run not found.'; end if;
  if run.status <> 'active' then raise exception 'Run is over.'; end if;
  cur_r := (run.current->>'rank')::int;
  newcard := cps.draw_game_card();
  new_r := (newcard->>'rank')::int;
  if new_r = cur_r then
    update cps.game_runs set current = newcard, updated_at = now() where id = run.id;
    return jsonb_build_object('tie', true, 'card', newcard, 'streak', run.streak, 'bank', coalesce(run.bank, '[]'::jsonb));
  end if;
  if (p_higher and new_r > cur_r) or (not p_higher and new_r < cur_r) then
    vbank := coalesce(run.bank, '[]'::jsonb); bn := jsonb_array_length(vbank);
    w_pack := 33 + 3 * bn; w_ticket := 25 + 2 * bn; w_token := 10 + 1 * bn;
    w_nothing := greatest(32 - 6 * bn, 4);
    tot := w_pack + w_ticket + w_token + w_nothing;
    roll := cps.rand01() * tot;
    if roll < w_pack then prize := '{"kind":"pack"}';
    elsif roll < w_pack + w_ticket then prize := '{"kind":"ticket"}';
    elsif roll < w_pack + w_ticket + w_token then prize := '{"kind":"tokens","n":1}';
    else prize := '{"kind":"nothing"}'; end if;
    if prize->>'kind' <> 'nothing' then vbank := vbank || prize; end if;
    update cps.game_runs set current = newcard, streak = run.streak + 1, bank = vbank, updated_at = now() where id = run.id;
    return jsonb_build_object('win', true, 'card', newcard, 'prize', prize,
                              'streak', run.streak + 1, 'bank', vbank);
  else
    update cps.game_runs set status = 'busted', updated_at = now() where id = run.id;
    return jsonb_build_object('bust', true, 'card', newcard,
                              'bank_lost', coalesce(run.bank, '[]'::jsonb), 'streak', run.streak);
  end if;
end $$;

notify pgrst, 'reload schema';
