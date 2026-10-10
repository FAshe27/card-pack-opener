-- =====================================================================
-- 049_admin_token_grants.sql — admin grant tokens to one account or all
-- non-admins; admin_list_accounts now includes game token balances.
-- (Run after 048.)
-- =====================================================================

create or replace function public.cps_admin_grant_tokens(p_token text, p_account uuid, p_tokens int) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  target uuid;
  n      int;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if p_tokens is null or p_tokens = 0 or p_tokens < -999 or p_tokens > 999 then
    raise exception 'Tokens must be between -999 and 999 (not 0).';
  end if;
  if not exists (select 1 from cps.accounts where id = target) then
    raise exception 'No such account.';
  end if;
  update cps.accounts set game_tokens = greatest(coalesce(game_tokens, 0) + p_tokens, 0)
    where id = target returning game_tokens into n;
  insert into cps.token_grants (account_id, tokens, reason)
    values (target, p_tokens, 'admin');
  return jsonb_build_object('account', target, 'tokens_now', n);
end $$;

create or replace function public.cps_admin_grant_tokens_all(p_token text, p_tokens int) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; n int := 0; r record;
begin
  a := cps.auth(p_token, true);
  if p_tokens is null or p_tokens < 1 or p_tokens > 999 then
    raise exception 'Tokens must be between 1 and 999.';
  end if;
  for r in select id from cps.accounts where not is_admin and not disabled loop
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + p_tokens where id = r.id;
    insert into cps.token_grants (account_id, tokens, reason)
      values (r.id, p_tokens, 'admin_all');
    perform cps.notify(r.id, 'gift_tokens',
      'You''ve been gifted ' || p_tokens || ' game token' || case when p_tokens = 1 then '' else 's' end || '!', 'arcade');
    n := n + 1;
  end loop;
  return jsonb_build_object('players', n);
end $$;

-- admin_list_accounts now includes game token balances
create or replace function public.cps_admin_list_accounts(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'display_name', x.display_name, 'username', x.username, 'hint', x.username_hint,
      'is_admin', x.is_admin, 'disabled', x.disabled, 'has_pin', x.pin_hash is not null,
      'locked', coalesce(x.locked_until > now(), false), 'locked_until', x.locked_until,
      'created_at', x.created_at, 'last_login_at', x.last_login_at,
      'packs', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = x.id), '{}'),
      'spins', x.spins,
      'spins_done', (select count(*) from cps.spin_grants where account_id = x.id and reason = 'wheel'),
      'tokens', coalesce(x.game_tokens, 0),
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0),
      'opened', coalesce((select sum(opened) from cps.user_set_stats where account_id = x.id), 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x), '[]');
end $$;

notify pgrst, 'reload schema';
