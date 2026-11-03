-- Migration 224: signup starter currency (Franklin, 2026-11-03).
--
-- Un-parks the October idea, at his updated figures: a new Google
-- self-signup now starts with the 30 random welcome packs (unchanged)
-- PLUS 15 game tokens and $20 store credit. Insertion-only rebuild of
-- cps_oauth_signup: one grant block between the welcome packs and the
-- session mint — same transaction as the account insert, so it can only
-- ever run once per account (the already_linked guard bars a second
-- signup for the same Google identity). Self-signups only: admin-created
-- accounts are untouched, as are all existing accounts.

CREATE OR REPLACE FUNCTION public.cps_oauth_signup(p_display_name text, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare ident jsonb := cps.oauth_identity(); v_uid uuid; v_email text;
        v_display text; v_base text; v_user text; v_try text; n int := 1; uid uuid; sess jsonb;
        v_pool text[]; v_pool_n int := 0; rp record; v_granted int := 0;
begin
  if ident is null then
    return jsonb_build_object('ok', false, 'code', 'no_oauth_session',
      'error', 'Google/Apple sign-in did not complete. Please try again.');
  end if;
  v_uid := (ident->>'uid')::uuid; v_email := ident->>'email';
  if exists (select 1 from cps.accounts where auth_user_id = v_uid) then
    return jsonb_build_object('ok', false, 'code', 'already_linked',
      'error', 'This Google/Apple account already has a PackRipper account — use Continue with Google/Apple to log in.');
  end if;
  v_display := left(btrim(coalesce(p_display_name, '')), 32);
  if v_display = '' then
    return jsonb_build_object('ok', false, 'code', 'name_required',
      'error', 'Pick a display name first.');
  end if;
  -- [189 FILTER] Profanity/reserved gate from migration 188 (which
  -- ships first): the player-chosen display name must pass the same
  -- check as every other name surface. Raises 188's friendly P0001
  -- message ('That display name contains language we don't allow...'
  -- or '...is reserved...'), which the client surfaces like any RPC error.
  perform cps.assert_name_clean(v_display, 'display name');
  -- [217 INSERT] Display-name uniqueness, case-insensitive. This
  -- function's house style is a structured return (not a raised
  -- exception), code 'name_taken': the name modal already shows
  -- r.error and re-enables the button, so the player simply picks
  -- another name and retries — the Google identity is untouched and
  -- no account is created. (Prefilled name, player-edited: prompt
  -- over auto-suffix, per the spec.)
  if exists (select 1 from cps.accounts where lower(display_name) = lower(v_display)) then
    return jsonb_build_object('ok', false, 'code', 'name_taken',
      'error', 'That display name is taken — please pick another.');
  end if;
  -- [/217 INSERT]
  -- generated username: sanitised base + suffix until unique (case-insensitive, via username_hash)
  v_base := lower(regexp_replace(split_part(coalesce(v_email, ''), '@', 1), '[^a-z0-9_.-]', '', 'g'));
  if length(v_base) < 2 then
    v_base := lower(regexp_replace(v_display, '[^a-z0-9_.-]', '', 'g'));
  end if;
  if length(v_base) < 2 then v_base := 'player'; end if;
  v_base := left(v_base, 24);
  -- [189 FILTER] The username base comes from the email local-part,
  -- which the player controls at their email provider: if the base
  -- itself is dirty, fall back to a neutral 'player' base (the
  -- de-dup suffix loop below still guarantees uniqueness).
  if not cps.text_is_clean(v_base) then v_base := 'player'; end if;
  v_user := v_base; v_try := v_user;
  while exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(v_try))) loop
    n := n + 1;
    if n <= 20 then v_try := v_base || n::text;
    else v_try := v_base || '-' || left(encode(extensions.gen_random_bytes(3), 'hex'), 6); end if;
  end loop;
  v_user := v_try;
  insert into cps.accounts (username_hash, username_hint, username, display_name, is_admin, created_by,
                            auth_user_id, oauth_email, oauth_provider, oauth_linked_at)
    values (cps.hash_text(cps.norm_username(v_user)), cps.make_hint(v_user), v_user, v_display, false, null,
            v_uid, v_email, ident->>'provider', now())
    returning id into uid;
  -- pin_hash deliberately left null: OAuth accounts never have a PIN.
  -- Welcome grant: 30 random packs, migration 152/144 pool + draw.
  select array_agg(cs.id order by cs.id), count(*)
    into v_pool, v_pool_n
    from cps.card_sets cs
   where cs.active and cs.id <> 'jumbled'
     and exists (select 1 from cps.cards c where c.set_id = cs.id);
  if v_pool_n > 0 then
    for rp in
      select d.pick as set_id, count(*)::int as cnt
        from (select v_pool[1 + floor(random() * v_pool_n)::int] as pick
                from generate_series(1, 30)) d
       group by d.pick
    loop
      perform cps.add_packs(uid, rp.set_id, rp.cnt, 'oauth_welcome', null, null);
      v_granted := v_granted + rp.cnt;
    end loop;
  end if;
  -- [224] Starter currency (Franklin, 2026-11-03): new players also start
  -- with 15 tokens and $20 store credit alongside the welcome packs.
  -- Tokens are ledgered like every other token grant (the reason matches
  -- the welcome packs); credit follows the house pattern — balance only,
  -- no credit ledger exists anywhere in the game.
  update cps.accounts
     set game_tokens = coalesce(game_tokens, 0) + 15,
         store_credit = coalesce(store_credit, 0) + 20
   where id = uid;
  insert into cps.token_grants (account_id, tokens, reason)
    values (uid, 15, 'oauth_welcome');
  sess := cps.mint_session(uid, p_user_agent);
  return jsonb_build_object('ok', true, 'is_new', true, 'username', v_user, 'welcome_packs', v_granted,
    'token', sess->>'token', 'expires_at', sess->>'expires_at',
    'account', jsonb_build_object('id', uid, 'display_name', v_display, 'is_admin', false, 'username', v_user));
end $function$;
