-- =====================================================================
-- 002: log in with USERNAME + 4-digit PIN.
--  * Usernames are no longer secret: 2–32 characters, unique ignoring case,
--    stored in plain text for the admin list (plus the old sha256 lookup hash).
--  * PINs are stored only as bcrypt hashes (pgcrypto crypt + per-row salt).
--  * Wrong PINs: per-IP limit (from 001) + per-account lockout
--    (5 wrong PINs in 15 min locks the account; repeat locks double, up to 2 h).
-- Idempotent: safe to run more than once, and safe to run after 001.
-- =====================================================================

alter table cps.accounts add column if not exists username        text;
alter table cps.accounts add column if not exists pin_hash        text;
alter table cps.accounts add column if not exists pin_fails       int not null default 0;
alter table cps.accounts add column if not exists pin_fail_since  timestamptz;
alter table cps.accounts add column if not exists locked_until    timestamptz;
alter table cps.accounts add column if not exists lock_streak     int not null default 0;

insert into cps.app_config (key, value) values
  ('pin_max_failures', '5'),          -- wrong PINs per account before it locks
  ('pin_window_minutes', '15'),       -- ...counted over this window
  ('pin_lock_minutes', '15'),         -- first lock; each repeat lock doubles
  ('pin_lock_max_minutes', '120')     -- cap on the lock length
on conflict (key) do nothing;
-- the site is accounts-only now: no more uploads of local (guest) collections
update cps.app_config set value = 'false' where key = 'allow_guest_import';

-- old signatures (username-only login) are removed so they can't be called any more
drop function if exists public.cps_login(text, text);
drop function if exists public.cps_admin_create_account(text, text, text, int, text, boolean);
drop function if exists public.cps_admin_update_account(text, uuid, text, text, boolean, boolean);
drop function if exists cps.create_account(text, text, boolean, int, text, uuid);
drop function if exists cps.bootstrap_admin(text, text, int);

-- ---------------------------------------------------------------- helpers
create or replace function cps.clean_username(p text) returns text
language plpgsql immutable set search_path = cps, pg_temp as $$
declare u text := btrim(coalesce(p, ''));
begin
  if length(u) < 2 then raise exception 'Username must be at least 2 characters.'; end if;
  if length(u) > 32 then raise exception 'Username must be 32 characters or fewer.'; end if;
  if u ~ '[[:cntrl:]]' then raise exception 'Username has invalid characters.'; end if;
  return u;
end $$;

create or replace function cps.set_pin(p_account uuid, p_pin text) returns void
language plpgsql set search_path = cps, pg_temp as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  update cps.accounts set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8)),
    pin_fails = 0, pin_fail_since = null, locked_until = null, lock_streak = 0
  where id = p_account;
end $$;

create or replace function cps.create_account(p_username text, p_display text, p_pin text, p_admin boolean, p_packs int, p_set text, p_by uuid)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := cps.clean_username(p_username);
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
  insert into cps.accounts (username_hash, username_hint, username, display_name, is_admin, created_by)
    values (cps.hash_text(cps.norm_username(u)), cps.make_hint(u), u, left(coalesce(nullif(btrim(p_display), ''), u), 32), coalesce(p_admin, false), p_by)
    returning id into uid;
  perform cps.set_pin(uid, p_pin);
  if coalesce(p_packs, 0) > 0 and p_set is not null and exists (select 1 from cps.card_sets where id = p_set) then
    perform cps.add_packs(uid, p_set, p_packs, 'welcome', null, p_by);
  end if;
  return uid;
end $$;

-- SQL Editor only (not callable through the API): create or promote the owner's admin account.
--   select cps.bootstrap_admin('YourName', 'Display Name', '1234');
-- For an existing username it makes it admin, re-enables it, records the username and (if given) sets the PIN.
create or replace function cps.bootstrap_admin(p_username text, p_display text default 'Admin', p_pin text default null, p_packs int default null)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := cps.clean_username(p_username);
begin
  select id into uid from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u));
  if uid is not null then
    update cps.accounts set is_admin = true, disabled = false, username = u, username_hint = cps.make_hint(u) where id = uid;
    if p_pin is not null then perform cps.set_pin(uid, p_pin); end if;
    return uid;
  end if;
  if p_pin is null then raise exception 'A new admin account needs a 4-digit PIN: select cps.bootstrap_admin(''name'', ''Display'', ''1234'');'; end if;
  return cps.create_account(u, p_display, p_pin, true,
    coalesce(p_packs, (cps.cfg('welcome_packs'))::int), cps.cfg('default_set')->>0, null);
end $$;

create or replace function cps.state_json(p_account uuid) returns jsonb
language sql stable set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin,
                  'hint', a.username_hint, 'username', a.username)
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from cps.pack_openings o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]')
  )
$$;

revoke execute on all functions in schema cps from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on all functions in schema cps from anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------- public API
-- Log in with username + PIN. Returns {ok, token, account, expires_at} or {ok:false, error, remaining?, locked?, retry_after?}.
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

create or replace function public.cps_admin_create_account(p_token text, p_username text, p_display_name text, p_pin text,
  p_start_packs int default null, p_set text default null, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; uid uuid; sid text := coalesce(p_set, cps.cfg('default_set')->>0);
        np int := coalesce(p_start_packs, (cps.cfg('welcome_packs'))::int);
begin
  a := cps.auth(p_token, true);
  if np < 0 or np > 999 then raise exception 'Starting packs must be 0–999.'; end if;
  uid := cps.create_account(p_username, p_display_name, p_pin, coalesce(p_is_admin, false), np, sid, a.id);
  return (select jsonb_build_object('id', x.id, 'username', x.username, 'display_name', x.display_name, 'packs', np, 'set_id', sid)
          from cps.accounts x where x.id = uid);
end $$;

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
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0),
      'opened', coalesce((select sum(opened) from cps.user_set_stats where account_id = x.id), 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x), '[]');
end $$;

-- Change display name / username / PIN (also unlocks) / disabled / admin flag.
create or replace function public.cps_admin_update_account(p_token text, p_account uuid, p_display_name text default null,
  p_new_username text default null, p_disabled boolean default null, p_is_admin boolean default null, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; u text;
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.accounts where id = p_account) then raise exception 'No such account.'; end if;
  if p_account = a.id and (p_disabled is true or p_is_admin is false) then raise exception 'You can''t disable or demote yourself.'; end if;
  if p_display_name is not null and btrim(p_display_name) <> '' then
    update cps.accounts set display_name = left(btrim(p_display_name), 32) where id = p_account;
  end if;
  if p_new_username is not null and btrim(p_new_username) <> '' then
    u := cps.clean_username(p_new_username);
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
end $$;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'grant execute on function public.cps_login(text, text, text) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_create_account(text, text, text, text, int, text, boolean) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_list_accounts(text) to anon, authenticated';
    execute 'grant execute on function public.cps_admin_update_account(text, uuid, text, text, boolean, boolean, text) to anon, authenticated';
  end if;
end $$;
revoke execute on function public.cps_login(text, text, text) from public;
revoke execute on function public.cps_admin_create_account(text, text, text, text, int, text, boolean) from public;
revoke execute on function public.cps_admin_update_account(text, uuid, text, text, boolean, boolean, text) from public;

notify pgrst, 'reload schema';
