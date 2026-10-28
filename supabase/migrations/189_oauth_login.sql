-- =====================================================================
-- 189: OAuth login (Google / Apple via Supabase Auth) — BRIDGE design.
--
-- RENUMBERED 2026-10-25: drafted as 187, then 188; 187 was taken by
-- maintenance mode and 188 by the profanity filter
-- (188_profanity_filter.sql). Content unchanged except the signup
-- filter calls marked [189 FILTER] below. DEPENDENCY: this migration
-- requires 188 to have run first (cps.assert_name_clean /
-- cps.text_is_clean are defined there).
--
-- *** DRAFT — STAGED ONLY 2026-10-25. NOT RUN. DO NOT RUN without
-- *** Franklin's separate push-day go for this specific migration.
--
-- What this does, and ONLY this:
--  * Supabase Auth is IDENTITY ONLY. Google/Apple prove who you are;
--    this migration then mints the SAME cps session token cps_login
--    has always minted (32 random bytes hex, sha256 in cps.sessions).
--    Every existing game RPC is untouched — they still take p_token
--    and resolve it with cps.auth(p_token) exactly as before.
--  * cps.accounts gains OAuth link columns. ONE cps account links to
--    ONE Supabase auth user (auth_user_id, unique); that one auth user
--    may carry BOTH a Google and an Apple identity (auth.identities),
--    so one account can sign in with either provider.
--  * LINKING REMOVES PIN ACCESS (Franklin's call): the link RPC binds
--    the identity AND sets pin_hash = null atomically, in the same
--    transaction, after BOTH proofs (a valid existing cps session for
--    the old account + a verified Supabase JWT for the new identity).
--    cps_login already only succeeds when pin_hash is not null, so a
--    null hash is a hard off-switch — no PIN path can revive it.
--  * SELF-SIGNUP: an OAuth identity with no link can create a new
--    account (after the client's duplicate-account guard). New rows
--    are born with pin_hash = null and a generated unique username.
--    Welcome grant (FRANKLIN'S LOCKED DECISION, 2026-10-25,
--    superseding an earlier staged welcome_packs-config default):
--    30 RANDOM packs, rolled with migration 152/144 semantics — each
--    pack independently to a random ACTIVE set that has cards,
--    Jumbled excluded, duplicates possible — ledgered in
--    cps.pack_grants with reason 'oauth_welcome'. Signup is
--    idempotent: a repeat OAuth login/signup never re-grants (see
--    cps_oauth_signup). Admin-created accounts are UNAFFECTED: they
--    keep the app_config welcome_packs/default_set defaults.
--  * RECOVERY: an admin can unlink an account, which clears the OAuth
--    link and issues a ONE-TIME claim code (only its sha256 is stored,
--    with an expiry). The player re-links a new Google/Apple identity
--    with that code. The old PIN is NEVER restored.
--  * cps_login is rebuilt in PART B at the bottom — SURGICALLY, from
--    its latest body (002_pin.sql; no migration after 002 redefines
--    it) with ONE inserted if-block and nothing else changed. That
--    block only improves the error for an OAuth-linked account whose
--    PIN was turned off. PART B is the riskiest piece of this file
--    and is SEPARABLE: everything above it works if Part B is dropped
--    (linked players would just see the old 'no PIN yet' message).
--
-- Identity is NEVER taken from the client. The new RPCs read
-- auth.uid() — the subject of the Supabase JWT that PostgREST has
-- already verified (the client sends it as Authorization: Bearer) —
-- and read email/provider from auth.users / auth.identities
-- server-side. A client-supplied user id or email is never accepted.
--
-- Idempotent where practical (add column if not exists, create or
-- replace), like its neighbours.
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART A — columns, helpers, and the new OAuth RPCs. No existing
-- function is rebuilt in this part.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------- columns
alter table cps.accounts add column if not exists auth_user_id    uuid;
alter table cps.accounts add column if not exists oauth_email     text;
alter table cps.accounts add column if not exists oauth_provider  text;
alter table cps.accounts add column if not exists oauth_linked_at timestamptz;
alter table cps.accounts add column if not exists claim_code_hash bytea;
alter table cps.accounts add column if not exists claim_expires_at timestamptz;
-- one auth user <-> one cps account, both directions (column unique
-- covers auth->cps; the link/signup/claim RPCs cover cps->auth by
-- refusing to link an account that already has a different auth user)
create unique index if not exists accounts_auth_user_id_key
  on cps.accounts (auth_user_id) where auth_user_id is not null;

-- How long an admin-issued claim code stays valid (days).
insert into cps.app_config (key, value) values
  ('oauth_claim_days', '7')
on conflict (key) do nothing;

-- ---------------------------------------------------------------- helpers (internal only)

-- Mint a cps session for an account, using the EXACT token pattern
-- from cps_login (002): 32 random bytes as hex; only the sha256 hash
-- is stored; expiry from app_config session_days; expired sessions
-- for the account are pruned. Also stamps last_login_at, as cps_login
-- does on success. Returns {token, expires_at} — the raw token is
-- returned once, to the caller, and never stored.
create or replace function cps.mint_session(p_account uuid, p_user_agent text default null)
returns jsonb language plpgsql set search_path = cps, pg_temp as $fn$
declare tok text; exp timestamptz;
begin
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  exp := now() + make_interval(days => (cps.cfg('session_days'))::int);
  insert into cps.sessions (token_hash, account_id, expires_at, user_agent)
    values (cps.hash_text(tok), p_account, exp, left(p_user_agent, 200));
  delete from cps.sessions where account_id = p_account and expires_at < now();
  update cps.accounts set last_login_at = now() where id = p_account;
  return jsonb_build_object('token', tok, 'expires_at', exp);
end $fn$;

-- The verified OAuth identity behind this request, read server-side.
-- auth.uid() is the JWT subject PostgREST/Supabase already verified;
-- email and provider(s) come from auth.users / auth.identities, never
-- from client input. Returns null when there is no Supabase session
-- (no/invalid JWT), {uid, email, provider} otherwise. 'provider' is a
-- comma-joined, sorted list (e.g. 'apple,google') because one auth
-- user can carry both identities — that is how one cps account ends
-- up reachable by Google AND Apple.
create or replace function cps.oauth_identity()
returns jsonb language plpgsql stable set search_path = cps, pg_temp as $fn$
declare v_uid uuid := auth.uid(); v_email text; v_prov text;
begin
  if v_uid is null then return null; end if;
  select u.email into v_email from auth.users u where u.id = v_uid;
  select string_agg(i.provider, ',' order by i.provider) into v_prov
    from auth.identities i where i.user_id = v_uid;
  if v_prov is null then
    select u.raw_app_meta_data->>'provider' into v_prov from auth.users u where u.id = v_uid;
  end if;
  return jsonb_build_object('uid', v_uid, 'email', v_email, 'provider', v_prov);
end $fn$;

-- Normalise a claim code for hashing: upper-case, drop spaces/dashes.
-- Codes are generated as 12 upper-case hex characters (see the admin
-- unlink RPC), displayed grouped as XXXX-XXXX-XXXX for dictation.
create or replace function cps.norm_claim_code(p text) returns text
language sql immutable set search_path = cps, pg_temp as $fn$
  select upper(regexp_replace(coalesce(p, ''), '[^0-9A-Za-z]', '', 'g'))
$fn$;

revoke execute on function cps.mint_session(uuid, text) from public;
revoke execute on function cps.oauth_identity() from public;
revoke execute on function cps.norm_claim_code(text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on function cps.mint_session(uuid, text) from anon, authenticated';
    execute 'revoke execute on function cps.oauth_identity() from anon, authenticated';
    execute 'revoke execute on function cps.norm_claim_code(text) from anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------- OAuth login
-- Sign in with an ALREADY-LINKED Google/Apple identity.
-- Returns the same shape as cps_login on success:
--   {ok:true, token, expires_at, account:{id, display_name, is_admin, username}}
-- Not linked yet (the normal first-run case, NOT an error to hide):
--   {ok:false, code:'not_linked', error:'...'} — the client then offers
--   'link an existing account' vs 'create my account'. This RPC never
--   creates an account: signup is a separate, explicit call so an
--   existing player can never silently mint an empty duplicate.
create or replace function public.cps_oauth_login(p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare ident jsonb := cps.oauth_identity(); a cps.accounts%rowtype; sess jsonb;
begin
  if ident is null then
    return jsonb_build_object('ok', false, 'code', 'no_oauth_session',
      'error', 'Google/Apple sign-in did not complete. Please try again.');
  end if;
  select * into a from cps.accounts
    where auth_user_id = (ident->>'uid')::uuid and not disabled;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'not_linked',
      'error', 'This Google/Apple account is not linked to a PackRipper account yet.');
  end if;
  sess := cps.mint_session(a.id, p_user_agent);
  return jsonb_build_object('ok', true, 'token', sess->>'token', 'expires_at', sess->>'expires_at',
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $fn$;

-- ---------------------------------------------------------------- link (PIN -> OAuth, one-way)
-- Requires BOTH proofs, in one transaction:
--   1. p_token — a valid existing cps session for the OLD account
--      (resolved by cps.auth, exactly like every other RPC), and
--   2. a verified Supabase JWT whose auth.uid() is the NEW identity.
-- On success the identity is bound AND pin_hash is set to null (with
-- the PIN lockout counters cleared) — linking REMOVES PIN access,
-- atomically. The current cps session survives (it was proof #1);
-- every OTHER session for the account is ended, because the account's
-- credential just changed. Re-linking the SAME identity is a no-op
-- success; linking a DIFFERENT identity to an already-linked account
-- is refused (an admin unlink + claim code is the only way to move).
create or replace function public.cps_oauth_link(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare a cps.accounts%rowtype; ident jsonb := cps.oauth_identity(); v_uid uuid; other uuid;
begin
  a := cps.auth(p_token);
  if ident is null then
    return jsonb_build_object('ok', false, 'code', 'no_oauth_session',
      'error', 'Google/Apple sign-in did not complete. Please try again.');
  end if;
  v_uid := (ident->>'uid')::uuid;
  if a.auth_user_id is not null and a.auth_user_id <> v_uid then
    return jsonb_build_object('ok', false, 'code', 'already_linked_other',
      'error', 'This PackRipper account is already linked to a different Google/Apple account. Ask the site owner for help moving it.');
  end if;
  select id into other from cps.accounts where auth_user_id = v_uid and id <> a.id;
  if found then
    return jsonb_build_object('ok', false, 'code', 'identity_in_use',
      'error', 'That Google/Apple account is already linked to a different PackRipper account.');
  end if;
  if a.auth_user_id = v_uid then
    return jsonb_build_object('ok', true, 'already_linked', true,
      'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
  end if;
  update cps.accounts set
      auth_user_id = v_uid,
      oauth_email = ident->>'email',
      oauth_provider = ident->>'provider',
      oauth_linked_at = now(),
      claim_code_hash = null, claim_expires_at = null,
      pin_hash = null, pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
    where id = a.id;
  delete from cps.sessions where account_id = a.id and token_hash <> cps.hash_text(p_token);
  return jsonb_build_object('ok', true, 'pin_removed', true,
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $fn$;

-- ---------------------------------------------------------------- self-signup (new players)
-- Creates a cps.accounts row for an OAuth identity that has NO link.
-- The account is born PIN-less (pin_hash stays null). The username is
-- GENERATED (from the email local-part / display name, sanitised,
-- de-duplicated with a numeric/random suffix) — the player picks only
-- their display name, prefilled by the client from the provider.
-- Welcome grant: 30 RANDOM packs (Franklin's locked decision,
-- 2026-10-25), using migration 152/144's pool and draw verbatim in
-- shape: pool = active sets with cards, Jumbled excluded; each pack
-- rolled independently; duplicates possible. Ledgered via
-- cps.add_packs with reason 'oauth_welcome', granted_by null (the
-- system, not an admin). IDEMPOTENT: this function refuses when the
-- identity is already linked (code 'already_linked'), and
-- cps_oauth_login never grants — so the 30 are granted exactly once,
-- at account creation. If the pool is somehow empty the account is
-- still created and welcome_packs reports 0 (signup must not fail
-- because no set is seeded).
create or replace function public.cps_oauth_signup(p_display_name text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
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
end $fn$;

-- ---------------------------------------------------------------- claim (recovery re-link)
-- A player whose Google/Apple access is gone gives Franklin's ONE-TIME
-- claim code (from cps_admin_oauth_unlink) while presenting a NEW
-- verified OAuth identity. On success the code is burned (hash +
-- expiry cleared), the new identity is bound, and a cps session is
-- minted. The old PIN is never restored — pin_hash stays null.
create or replace function public.cps_oauth_claim(p_code text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare ident jsonb := cps.oauth_identity(); v_uid uuid; a cps.accounts%rowtype; sess jsonb;
begin
  if ident is null then
    return jsonb_build_object('ok', false, 'code', 'no_oauth_session',
      'error', 'Google/Apple sign-in did not complete. Please try again.');
  end if;
  v_uid := (ident->>'uid')::uuid;
  if exists (select 1 from cps.accounts where auth_user_id = v_uid) then
    return jsonb_build_object('ok', false, 'code', 'identity_in_use',
      'error', 'That Google/Apple account is already linked to a PackRipper account.');
  end if;
  select * into a from cps.accounts
    where claim_code_hash = cps.hash_text(cps.norm_claim_code(p_code))
      and claim_expires_at is not null and claim_expires_at > now() and not disabled
    for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'bad_code',
      'error', 'That claim code is not valid, or it has expired. Ask the site owner for a new one.');
  end if;
  update cps.accounts set
      auth_user_id = v_uid,
      oauth_email = ident->>'email',
      oauth_provider = ident->>'provider',
      oauth_linked_at = now(),
      claim_code_hash = null, claim_expires_at = null,
      pin_hash = null, pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
    where id = a.id;
  delete from cps.sessions where account_id = a.id;
  sess := cps.mint_session(a.id, p_user_agent);
  return jsonb_build_object('ok', true, 'token', sess->>'token', 'expires_at', sess->>'expires_at',
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $fn$;

-- ---------------------------------------------------------------- admin recovery: unlink + claim code
-- Admin only (cps.auth with p_admin = true, like every admin RPC).
-- Clears the account's OAuth link and ALL of its cps sessions (the
-- player may have lost control of the identity — old sessions must
-- not survive), and issues a ONE-TIME claim code: the raw code is in
-- this response and NOWHERE else; the database stores only its
-- sha256, with an expiry from app_config oauth_claim_days. The old
-- PIN is NOT restored (pin_hash is forced to null, in case the
-- account somehow still had one).
create or replace function public.cps_admin_oauth_unlink(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare adm cps.accounts%rowtype; t cps.accounts%rowtype; v_code text; v_exp timestamptz;
begin
  adm := cps.auth(p_token, true);
  select * into t from cps.accounts where id = p_account for update;
  if not found then raise exception 'No such account.'; end if;
  v_code := upper(left(encode(extensions.gen_random_bytes(6), 'hex'), 12));
  v_exp := now() + make_interval(days => coalesce((cps.cfg('oauth_claim_days'))::int, 7));
  update cps.accounts set
      auth_user_id = null, oauth_email = null, oauth_provider = null, oauth_linked_at = null,
      claim_code_hash = cps.hash_text(cps.norm_claim_code(v_code)), claim_expires_at = v_exp,
      pin_hash = null, pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
    where id = p_account;
  delete from cps.sessions where account_id = p_account;
  return jsonb_build_object('ok', true,
    'claim_code', substring(v_code from 1 for 4) || '-' || substring(v_code from 5 for 4) || '-' || substring(v_code from 9 for 4),
    'claim_expires_at', v_exp,
    'account', jsonb_build_object('id', t.id, 'display_name', t.display_name, 'username', t.username));
end $fn$;

-- ---------------------------------------------------------------- grants (house style: anon + authenticated, never public)
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_oauth_login(text) to anon, authenticated';
    execute 'grant execute on function public.cps_oauth_link(text) to anon, authenticated';
    execute 'grant execute on function public.cps_oauth_signup(text, text) to anon, authenticated';
    execute 'grant execute on function public.cps_oauth_claim(text, text) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_oauth_unlink(text, uuid) to anon, authenticated';
  end if;
end $$;
revoke execute on function public.cps_oauth_login(text) from public;
revoke execute on function public.cps_oauth_link(text) from public;
revoke execute on function public.cps_oauth_signup(text, text) from public;
revoke execute on function public.cps_oauth_claim(text, text) from public;
revoke execute on function public.cps_admin_oauth_unlink(text, uuid) from public;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- PART B — cps_login surgical rebuild. *** RISKIEST PIECE — SEPARABLE. ***
--
-- Source: the function text below is the LATEST cps_login body in the
-- repo (002_pin.sql; 001's username-only version was replaced by 002
-- and no later migration redefines cps_login) with exactly ONE
-- inserted if-block, marked [189 INSERT] ... [/189 INSERT], placed
-- immediately before the existing pin_hash-is-null return inside the
-- failed-login path. Effect: an OAuth-linked account (pin_hash null
-- BECAUSE it was linked) gets 'This account now uses Google/Apple
-- login. Your PIN has been turned off.' instead of 'This account has
-- no PIN yet. Ask the site owner to set one.'
--
-- Proof (validation/check_sql.py, results in VALIDATION.md): removing
-- the marked block from the function below reproduces the 002 body
-- byte-for-byte (sha256 compared), and a paren-depth walk of the body
-- (skipping string literals and -- comments) never goes negative and
-- ends at 0. If Franklin prefers zero rebuilds, Part B can be deleted
-- from this file and Part A still works end-to-end.
-- ---------------------------------------------------------------------

create or replace function public.cps_login(p_username text, p_pin text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare v_ip text := cps.client_ip(); fails int; maxf int := (cps.cfg('login_max_failures'))::int;
        win int := (cps.cfg('login_window_minutes'))::int; a cps.accounts%rowtype; tok text; exp timestamptz;
        oldest timestamptz; pmax int := coalesce((cps.cfg('pin_max_failures'))::int, 5);
        pwin int := coalesce((cps.cfg('pin_window_minutes'))::int, 15); plock int := coalesce((cps.cfg('pin_lock_minutes'))::int, 15);
        pcap int := coalesce((cps.cfg('pin_lock_max_minutes'))::int, 120); nf int; mins int; good boolean := false;
        remaining int; v_found boolean;
begin
  delete from cps.login_attempts where at < now() - interval '1 day';
  select count(*), min(la.at) into fails, oldest from cps.login_attempts la
    where la.ip = v_ip and not la.success and la.at > now() - make_interval(mins => win);
  if fails >= maxf then
    return jsonb_build_object('ok', false, 'error', 'Too many failed attempts from this network. Try again in a few minutes.',
      'retry_after', greatest(1, ceil(extract(epoch from (oldest + make_interval(mins => win) - now())))::int));
  end if;
  select * into a from cps.accounts where username_hash = cps.hash_text(cps.norm_username(p_username)) and not disabled;
  v_found := found;   -- keep it: later INSERT/UPDATE statements overwrite FOUND
  if v_found and a.locked_until is not null and a.locked_until > now() then
    mins := greatest(1, ceil(extract(epoch from (a.locked_until - now())) / 60))::int;
    return jsonb_build_object('ok', false, 'locked', true, 'retry_after', mins * 60,
      'error', 'Too many wrong PINs. This account is locked for ' || mins || ' more minute' || case when mins = 1 then '' else 's' end || '.');
  end if;
  if v_found and a.pin_hash is not null and p_pin ~ '^[0-9]{4}$' then
    good := a.pin_hash = extensions.crypt(p_pin, a.pin_hash);
  end if;
  if not good then
    insert into cps.login_attempts (ip, success) values (v_ip, false);
    remaining := greatest(maxf - fails - 1, 0);
    if v_found and a.pin_hash is not null then
      if a.pin_fail_since is null or a.pin_fail_since < now() - make_interval(mins => pwin) then
        update cps.accounts set pin_fails = 1, pin_fail_since = now() where id = a.id returning pin_fails into nf;
      else
        update cps.accounts set pin_fails = pin_fails + 1 where id = a.id returning pin_fails into nf;
      end if;
      if nf >= pmax then
        mins := least(pcap, plock * (2 ^ least(a.lock_streak, 10))::int);
        update cps.accounts set locked_until = now() + make_interval(mins => mins), lock_streak = lock_streak + 1,
          pin_fails = 0, pin_fail_since = null where id = a.id;
        perform pg_sleep(0.4 + least(fails, 8) * 0.2);
        return jsonb_build_object('ok', false, 'locked', true, 'retry_after', mins * 60,
          'error', 'Too many wrong PINs. This account is locked for ' || mins || ' minutes.');
      end if;
      remaining := least(remaining, pmax - nf);
    end if;
    perform pg_sleep(0.4 + least(fails, 8) * 0.2);   -- backoff grows with each failure from this IP
    -- [189 INSERT] OAuth-linked accounts had their PIN turned off at link time:
    -- say so, instead of the generic 'no PIN yet' / 'wrong PIN' messages below.
    if v_found and a.pin_hash is null and a.auth_user_id is not null then
      return jsonb_build_object('ok', false, 'error', 'This account now uses Google/Apple login. Your PIN has been turned off.', 'oauth_linked', true, 'remaining', remaining);
    end if;
    -- [/189 INSERT]
    if v_found and a.pin_hash is null then
      return jsonb_build_object('ok', false, 'error', 'This account has no PIN yet. Ask the site owner to set one.', 'remaining', remaining);
    end if;
    return jsonb_build_object('ok', false, 'error', 'Wrong username or PIN.', 'remaining', remaining);
  end if;
  insert into cps.login_attempts (ip, success) values (v_ip, true);
  update cps.accounts set last_login_at = now(), pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0 where id = a.id;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  exp := now() + make_interval(days => (cps.cfg('session_days'))::int);
  insert into cps.sessions (token_hash, account_id, expires_at, user_agent) values (cps.hash_text(tok), a.id, exp, left(p_user_agent, 200));
  delete from cps.sessions where account_id = a.id and expires_at < now();
  return jsonb_build_object('ok', true, 'token', tok, 'expires_at', exp,
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $$;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_login(text, text, text) to anon, authenticated';
  end if;
end $$;
revoke execute on function public.cps_login(text, text, text) from public;

notify pgrst, 'reload schema';
