-- =====================================================================
-- 217: Unique display names — no two PackRipper accounts may share
-- a display name (case-insensitive).
--
-- Verified state before this migration: cps.accounts has NO unique
-- constraint on display_name (unique indexes only on id,
-- username_hash, auth_user_id) and the live roster (24 accounts)
-- has zero duplicates, exact or case-insensitive. Uniqueness today
-- is accidental; Google self-signup takes the name straight from
-- the Google profile, so the next duplicate is a matter of time.
--
-- What this does, and ONLY this:
--   * One unique index on lower(display_name) — the hard backstop.
--   * A pre-insert / pre-update collision check in each of the four
--     live name-setting functions, in that function's own error
--     style (raised exception for the admin/PIN paths, structured
--     {ok:false, code:'name_taken'} for Google signup, where the
--     existing name modal already shows the message and lets the
--     player retry with a different name). The checks run BEFORE
--     the write, so the index only ever fires on a race.
--   * The effective-name rule is preserved exactly: create_account's
--     fallback (blank display -> username) is unchanged, and the
--     checks exclude the account being renamed.
--
-- NOT in scope: cps_oauth_login / cps_oauth_link / cps_oauth_claim
-- never set display_name (link and claim only read it for the
-- response payload); bootstrap_admin routes through
-- cps.create_account and is covered. No client change is required:
-- the admin create form and the admin Rename button surface the
-- raised message through cloudError, and the Google name modal
-- already surfaces r.error and retries. Client surfaces are
-- documented in SPEC.md.
--
-- Standing rule applies: Franklin sees this SQL before it runs.
-- Post-auth smoke tests are still required at ship time (see SPEC).
--
-- =====================================================================


-- The backstop: one row per display name, case-insensitively.
-- display_name is NOT NULL (verified 2026-10-30), so no null handling
-- is needed. Current data is duplicate-free, so this creates cleanly.
create unique index if not exists accounts_display_name_lower_key
  on cps.accounts (lower(display_name));

CREATE OR REPLACE FUNCTION cps.create_account(p_username text, p_display text, p_pin text, p_admin boolean, p_packs integer, p_sets text[], p_by uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare uid uuid; u text := cps.clean_username(p_username); sid text;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  -- [188 INSERT] Profanity / reserved-name gate: the username and
  -- the effective display name (explicit display, else username).
  perform cps.assert_name_clean(u, 'username');
  perform cps.assert_name_clean(left(coalesce(nullif(btrim(p_display), ''), u), 32), 'display name');
  -- [/188 INSERT]
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
  -- [217 INSERT] Display-name uniqueness: no two accounts may share
  -- a display name, case-insensitively. The effective name here is
  -- the explicit display name, else the username — which is already
  -- unique, so the fallback can never collide; the check covers it
  -- anyway so the rule lives in one place.
  if exists (select 1 from cps.accounts
              where lower(display_name) = lower(left(coalesce(nullif(btrim(p_display), ''), u), 32))) then
    raise exception 'That display name is taken — please pick another.';
  end if;
  -- [/217 INSERT]
  insert into cps.accounts (username_hash, username_hint, username, display_name, is_admin, created_by)
    values (cps.hash_text(cps.norm_username(u)), cps.make_hint(u), u, left(coalesce(nullif(btrim(p_display), ''), u), 32), coalesce(p_admin, false), p_by)
    returning id into uid;
  perform cps.set_pin(uid, p_pin);
  if coalesce(p_packs, 0) > 0 and p_sets is not null then
    foreach sid in array p_sets loop
      if exists (select 1 from cps.card_sets where id = sid) then
        perform cps.add_packs(uid, sid, p_packs, 'welcome', null, p_by);
      end if;
    end loop;
  end if;
  return uid;
end $function$;
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
  sess := cps.mint_session(uid, p_user_agent);
  return jsonb_build_object('ok', true, 'is_new', true, 'username', v_user, 'welcome_packs', v_granted,
    'token', sess->>'token', 'expires_at', sess->>'expires_at',
    'account', jsonb_build_object('id', uid, 'display_name', v_display, 'is_admin', false, 'username', v_user));
end $function$;
CREATE OR REPLACE FUNCTION public.cps_set_display_name(p_token text, p_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype; n text := left(btrim(coalesce(p_name, '')), 32);
begin
  a := cps.auth(p_token);
  if n = '' then raise exception 'Name cannot be empty.'; end if;
  -- [188 INSERT] Profanity / reserved-name gate.
  perform cps.assert_name_clean(n, 'display name');
  -- [/188 INSERT]
  -- [217 INSERT] Display-name uniqueness, case-insensitive, self excluded.
  if exists (select 1 from cps.accounts where lower(display_name) = lower(n) and id <> a.id) then
    raise exception 'That display name is taken — please pick another.';
  end if;
  -- [/217 INSERT]
  update cps.accounts set display_name = n where id = a.id;
  return jsonb_build_object('ok', true, 'display_name', n);
end $function$;
CREATE OR REPLACE FUNCTION public.cps_admin_update_account(p_token text, p_account uuid, p_display_name text DEFAULT NULL::text, p_new_username text DEFAULT NULL::text, p_disabled boolean DEFAULT NULL::boolean, p_is_admin boolean DEFAULT NULL::boolean, p_pin text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype; u text;
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.accounts where id = p_account) then raise exception 'No such account.'; end if;
  if p_account = a.id and (p_disabled is true or p_is_admin is false) then raise exception 'You can''t disable or demote yourself.'; end if;
  if p_display_name is not null and btrim(p_display_name) <> '' then
    -- [188 INSERT] Profanity / reserved-name gate (display name).
    perform cps.assert_name_clean(left(btrim(p_display_name), 32), 'display name');
    -- [/188 INSERT]
    -- [217 INSERT] Display-name uniqueness, case-insensitive, target
    -- excluded (mirrors the username check in the branch below).
    if exists (select 1 from cps.accounts
                where lower(display_name) = lower(left(btrim(p_display_name), 32)) and id <> p_account) then
      raise exception 'That display name is taken — please pick another.';
    end if;
    -- [/217 INSERT]
    update cps.accounts set display_name = left(btrim(p_display_name), 32) where id = p_account;
  end if;
  if p_new_username is not null and btrim(p_new_username) <> '' then
    u := cps.clean_username(p_new_username);
    -- [188 INSERT] Profanity / reserved-name gate (username).
    perform cps.assert_name_clean(u, 'username');
    -- [/188 INSERT]
    if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u)) and id <> p_account) then
      raise exception 'That username is taken.';
    end if;
    update cps.accounts set username_hash = cps.hash_text(cps.norm_username(u)), username_hint = cps.make_hint(u), username = u where id = p_account;
  end if;
  if p_pin is not null then
    perform cps.set_pin(p_account, p_pin);   -- also clears any lockout
    delete from cps.sessions where account_id = p_account and token_hash <> cps.hash_text(p_token);  -- old PIN's sessions end
  end if;
  if p_disabled is not null then
    update cps.accounts set disabled = p_disabled where id = p_account;
    if p_disabled then delete from cps.sessions where account_id = p_account; end if;
  end if;
  if p_is_admin is not null then update cps.accounts set is_admin = p_is_admin where id = p_account; end if;
  return jsonb_build_object('ok', true);
end $function$;
