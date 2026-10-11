-- =====================================================================
-- 059_no_push_higher_lower.sql — Higher/Lower: ties are gone. The next
-- card is re-drawn until it differs from the current card, so every round
-- is win-or-bust. (Run after 054.)
-- =====================================================================

create or replace function public.cps_game_guess(p_token text, p_run uuid, p_higher boolean) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; run cps.game_runs%rowtype;
        cur_r int; newcard jsonb; new_r int; vbank jsonb; bn int; won jsonb;
begin
  a := cps.auth(p_token);
  select * into run from cps.game_runs where id = p_run and account_id = a.id for update;
  if run.id is null then raise exception 'Run not found.'; end if;
  if run.status <> 'active' then raise exception 'Run is over.'; end if;
  cur_r := (run.current->>'rank')::int;
  -- no pushes: re-draw until the next card differs from the current one
  loop
    newcard := cps.draw_game_card();
    new_r := (newcard->>'rank')::int;
    exit when new_r <> cur_r;
  end loop;
  if (p_higher and new_r > cur_r) or (not p_higher and new_r < cur_r) then
    vbank := coalesce(run.bank, '[]'::jsonb); bn := jsonb_array_length(vbank);
    won := '[]'::jsonb;
    if cps.rand01() * 100 < least(45 + 2 * bn, 85) then
      won := won || '{"kind":"pack"}'::jsonb;
    end if;
    if cps.rand01() * 100 < least(35 + 2 * bn, 75) then
      won := won || '{"kind":"ticket"}'::jsonb;
    end if;
    if cps.rand01() * 100 < least(20 + 1 * bn, 45) then
      won := won || '{"kind":"tokens","n":1}'::jsonb;
    end if;
    vbank := vbank || won;
    update cps.game_runs set current = newcard, streak = run.streak + 1, bank = vbank, updated_at = now() where id = run.id;
    return jsonb_build_object('win', true, 'card', newcard, 'prizes', won,
                              'streak', run.streak + 1, 'bank', vbank);
  else
    update cps.game_runs set status = 'busted', updated_at = now() where id = run.id;
    return jsonb_build_object('bust', true, 'card', newcard,
                              'bank_lost', coalesce(run.bank, '[]'::jsonb), 'streak', run.streak);
  end if;
end $$;

notify pgrst, 'reload schema';
