-- =====================================================================
-- 067_spin_wheel_quest.sql — restore the daily quest bump for spinning the
-- wheel (dropped when 051 redefined cps_spin_wheel).
-- =====================================================================

create or replace function public.cps_spin_wheel(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  res        jsonb;
  prize      jsonb;
  packs_now  int;
  tokens_now int;
  spins_now  int;
begin
  a := cps.auth(p_token);
  if coalesce(a.spins, 0) < 1 then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  update cps.accounts set spins = spins - 1 where id = a.id
    returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || coalesce(prize ->> 'set_id', 'tokens'));

  if prize ->> 'kind' = 'tokens' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + (prize ->> 'tokens')::int
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, (prize ->> 'tokens')::int, 'wheel');
  else
    packs_now := cps.add_packs(a.id, prize ->> 'set_id', (prize ->> 'packs')::int, 'wheel', null, null);
  end if;

  perform cps.quest_bump(a.id, 'spin_wheel', 1);
  if coalesce((prize ->> 'packs')::int, 0) >= 3 then
    perform cps.quest_bump(a.id, 'wheel_big_win', 1);
  end if;

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'tokens_won', (prize ->> 'tokens')::int,
    'tokens_now', tokens_now,
    'spins_left', spins_now
  );
end $$;

notify pgrst, 'reload schema';
