-- =====================================================================
-- 047_game_claim_sync.sql — game_claim returns fresh balances so the
-- client can update pack/spin/token counts without a refresh.
-- (Run after 046.)
-- =====================================================================

create or replace function public.cps_game_claim(p_token text, p_run uuid) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; run cps.game_runs%rowtype;
        p jsonb; sid text; g int := 0; t int := 0; tk int := 0; n int;
begin
  a := cps.auth(p_token);
  select * into run from cps.game_runs where id = p_run and account_id = a.id for update;
  if run.id is null then raise exception 'Run not found.'; end if;
  if run.status <> 'active' then raise exception 'Run is over.'; end if;
  for p in select * from jsonb_array_elements(coalesce(run.bank, '[]'::jsonb)) loop
    case p->>'kind'
      when 'pack' then
        select id into sid from cps.card_sets where active and id <> 'jumbled' order by random() limit 1;
        perform cps.add_packs(a.id, sid, 1, 'game_prize', run.id::text, null);
        g := g + 1;
      when 'ticket' then
        update cps.accounts set spins = spins + 1 where id = a.id;
        insert into cps.spin_grants (account_id, spins, reason) values (a.id, 1, 'game_prize');
        t := t + 1;
      when 'tokens' then
        n := coalesce((p->>'n')::int, 1);
        update cps.accounts set game_tokens = game_tokens + n where id = a.id;
        insert into cps.token_grants (account_id, tokens, reason) values (a.id, n, 'game_prize');
        tk := tk + n;
    end case;
  end loop;
  update cps.game_runs set status = 'claimed', updated_at = now() where id = run.id;
  return jsonb_build_object(
    'packs', g, 'tickets', t, 'tokens', tk, 'streak', run.streak,
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = a.id), '{}'::jsonb),
    'spins', (select spins from cps.accounts where id = a.id),
    'game_tokens', (select coalesce(game_tokens, 0) from cps.accounts where id = a.id));
end $$;

notify pgrst, 'reload schema';
