-- Migration 222: PIN sign-in becomes legacy-only (Franklin's design, 2026-11-02).
--
-- The Google phase-out lands softly: PIN login keeps working ONLY for the
-- accounts that were still unlinked when this ran (the phase-out cohort —
-- Ayrton, Bailey, Brendan, Chris, Dylan, Garrett, Mitch, Molly) plus any
-- account Franklin later gives a PIN to on purpose (cps.set_pin flags those
-- too: creating an account or resetting a PIN is a deliberate act). Linking
-- Google clears the flag along with the PIN itself. Everyone else who tries
-- a PIN gets a plain 'retired' message pointing at Google / a claim code,
-- and only AFTER their PIN verifies — a wrong guess reveals nothing.
--
-- Client half (same ship): the login gate goes Google-first with a
-- 'Log in by PIN (Legacy accounts only)' door at the bottom, and a legacy
-- PIN login lands on the Link Google prompt (once per session).

alter table cps.accounts add column if not exists pin_legacy boolean not null default false;

-- The cohort snapshot: everyone still unlinked at phase-out time.
update cps.accounts set pin_legacy = true where oauth_linked_at is null;

CREATE OR REPLACE FUNCTION public.cps_login(p_username text, p_pin text, p_user_agent text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
  -- [222] PIN sign-in is legacy-only now. A correct PIN still has to belong
  -- to the phase-out cohort (pin_legacy) — Franklin's deliberately PIN-set
  -- accounts included (cps.set_pin flags them). Everyone else uses Google,
  -- or an admin claim code. Checked only AFTER the PIN verifies, so a wrong
  -- guess reveals nothing about an account's eligibility.
  if not coalesce(a.pin_legacy, false) then
    insert into cps.login_attempts (ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'legacy_retired', true,
      'error', 'PIN sign-in has been retired for this account. Please sign in with Google — if you never linked it, ask Franklin for a claim code.');
  end if;
  insert into cps.login_attempts (ip, success) values (v_ip, true);
  update cps.accounts set last_login_at = now(), pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0 where id = a.id;
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  exp := now() + make_interval(days => (cps.cfg('session_days'))::int);
  insert into cps.sessions (token_hash, account_id, expires_at, user_agent) values (cps.hash_text(tok), a.id, exp, left(p_user_agent, 200));
  delete from cps.sessions where account_id = a.id and expires_at < now();
  return jsonb_build_object('ok', true, 'token', tok, 'expires_at', exp,
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $function$;


CREATE OR REPLACE FUNCTION public.cps_oauth_link(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
      pin_hash = null, pin_legacy = false, pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
    where id = a.id;
  delete from cps.sessions where account_id = a.id and token_hash <> cps.hash_text(p_token);
  return jsonb_build_object('ok', true, 'pin_removed', true,
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'username', a.username));
end $function$;


CREATE OR REPLACE FUNCTION cps.set_pin(p_account uuid, p_pin text)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'cps', 'pg_temp'
AS $function$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  update cps.accounts set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8)),
    pin_legacy = true, pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
  where id = p_account;
end $function$;
