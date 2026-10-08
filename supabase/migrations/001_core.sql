-- =====================================================================
-- Card Pack Simulator: online accounts (username-only login), server-side
-- pack opening, prize codes. Safe to re-run (idempotent where practical).
--
-- Design:
--  * All tables live in the private schema "cps", which is NOT exposed by the
--    Supabase API and has no grants for anon/authenticated. RLS is enabled on
--    every table with NO policies (deny-all) as a second lock.
--  * The only API surface is the SECURITY DEFINER functions in "public"
--    (callable with the publishable key). Every user-facing function takes a
--    session token, which is resolved server-side to an account.
--  * Usernames are secrets: only a SHA-256 hash is stored (plus a short hint).
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists cps;
revoke all on schema cps from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then execute 'revoke all on schema cps from anon'; end if;
  if exists (select 1 from pg_roles where rolname = 'authenticated') then execute 'revoke all on schema cps from authenticated'; end if;
end $$;

-- ---------------------------------------------------------------- config
create table if not exists cps.app_config (
  key   text primary key,
  value jsonb not null
);
insert into cps.app_config (key, value) values
  ('welcome_packs', '3'),                 -- default starting packs in the admin "create account" form
  ('default_set', '"fast-food"'),         -- set used for welcome packs
  ('session_days', '365'),                -- how long "remember me" tokens last
  ('login_max_failures', '8'),            -- failed logins allowed per IP per window
  ('login_window_minutes', '15'),
  ('allow_guest_import', 'false'),        -- legacy: one-time upload of a local collection (the site is accounts-only now)
  ('guest_import_max_packs', '10')        -- cap on unopened packs carried over per set
on conflict (key) do nothing;

create or replace function cps.cfg(p_key text) returns jsonb
language sql stable set search_path = cps, pg_temp as $$
  select value from cps.app_config where key = p_key
$$;

-- ---------------------------------------------------------------- sets / cards (server copy of sets/*.js)
create table if not exists cps.card_sets (
  id          text primary key,
  name        text not null,
  code        text not null default '',
  pack        jsonb not null,            -- {"name":..,"slots":[{"count":5,"label":"..","odds":{"common":1}}],"holo":{"common":2,...}}
  card_count  int not null default 0,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
create table if not exists cps.cards (
  set_id   text not null references cps.card_sets(id) on delete cascade,
  card_id  text not null,
  num      int,
  name     text not null,
  rarity   text not null check (rarity in ('common','uncommon','rare','epic','legendary','chase')),
  primary key (set_id, card_id)
);
create index if not exists cards_set_rarity on cps.cards (set_id, rarity);

-- ---------------------------------------------------------------- accounts & sessions
create table if not exists cps.accounts (
  id             uuid primary key default gen_random_uuid(),
  username_hash  bytea not null unique,     -- sha256(lower(trim(username)))
  username_hint  text not null default '',  -- e.g. "ja…(9)" so the admin can tell accounts apart
  display_name   text not null,
  is_admin       boolean not null default false,
  disabled       boolean not null default false,
  created_at     timestamptz not null default now(),
  created_by     uuid references cps.accounts(id) on delete set null,
  last_login_at  timestamptz
);
create table if not exists cps.sessions (
  token_hash    bytea primary key,           -- sha256(token); the raw token only lives in the user's browser
  account_id    uuid not null references cps.accounts(id) on delete cascade,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now(),
  expires_at    timestamptz not null,
  user_agent    text
);
create index if not exists sessions_account on cps.sessions (account_id);
create table if not exists cps.login_attempts (
  id       bigserial primary key,
  ip       text not null,
  at       timestamptz not null default now(),
  success  boolean not null
);
create index if not exists login_attempts_ip_at on cps.login_attempts (ip, at);

-- ---------------------------------------------------------------- player data
create table if not exists cps.pack_inventory (
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  set_id      text not null references cps.card_sets(id) on delete cascade,
  packs       int not null default 0 check (packs >= 0),
  primary key (account_id, set_id)
);
-- One row per (account, card). Counts make future trades a simple, atomic transfer.
create table if not exists cps.collection (
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  set_id      text not null,
  card_id     text not null,
  count       int not null default 0 check (count >= 0),
  holo_count  int not null default 0 check (holo_count >= 0 and holo_count <= count),
  first_at    timestamptz not null default now(),
  primary key (account_id, set_id, card_id),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);
create table if not exists cps.user_set_stats (
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  set_id      text not null references cps.card_sets(id) on delete cascade,
  opened      int not null default 0,
  pulled      int not null default 0,
  holos       int not null default 0,
  by_rarity   jsonb not null default '{}',
  best        jsonb,                         -- {"id":"247","holo":true,"at":"..."}
  primary key (account_id, set_id)
);
create table if not exists cps.pack_openings (
  id          bigserial primary key,
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  set_id      text not null references cps.card_sets(id) on delete cascade,
  opened_at   timestamptz not null default now(),
  cards       jsonb not null                 -- [{"id":"012","rarity":"common","holo":false}, ...]
);
create index if not exists pack_openings_account on cps.pack_openings (account_id, opened_at desc);
-- Ledger of every pack added to an inventory (welcome, admin grant, prize code, guest import).
create table if not exists cps.pack_grants (
  id          bigserial primary key,
  account_id  uuid not null references cps.accounts(id) on delete cascade,
  set_id      text not null references cps.card_sets(id) on delete cascade,
  packs       int not null,
  reason      text not null,
  ref         text,
  granted_by  uuid references cps.accounts(id) on delete set null,
  at          timestamptz not null default now()
);

-- ---------------------------------------------------------------- prize codes
create table if not exists cps.prize_codes (
  code        text primary key,
  set_id      text not null references cps.card_sets(id) on delete cascade,
  packs       int not null check (packs between 1 and 99),
  max_uses    int not null default 1 check (max_uses >= 1),
  uses        int not null default 0,
  note        text,
  created_by  uuid references cps.accounts(id) on delete set null,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz
);
create table if not exists cps.code_redemptions (
  code         text not null references cps.prize_codes(code) on delete cascade,
  account_id   uuid not null references cps.accounts(id) on delete cascade,
  redeemed_at  timestamptz not null default now(),
  primary key (code, account_id)
);
create table if not exists cps.guest_imports (
  account_id   uuid primary key references cps.accounts(id) on delete cascade,
  imported_at  timestamptz not null default now(),
  summary      jsonb
);

-- ---------------------------------------------------------------- trading groundwork (no UI yet)
create table if not exists cps.card_transfers (
  id            bigserial primary key,
  from_account  uuid references cps.accounts(id) on delete set null,
  to_account    uuid references cps.accounts(id) on delete set null,
  set_id        text not null,
  card_id       text not null,
  holo          boolean not null default false,
  qty           int not null check (qty > 0),
  trade_ref     text,
  at            timestamptz not null default now()
);
-- Atomically move cards between collections. Internal only (not callable by clients);
-- a future trade RPC (offer/accept) would call this once both sides agree.
create or replace function cps.transfer_card(p_from uuid, p_to uuid, p_set text, p_card text, p_holo boolean, p_qty int, p_ref text default null)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare r cps.collection%rowtype;
begin
  if p_qty < 1 then raise exception 'qty must be positive'; end if;
  select * into r from cps.collection where account_id = p_from and set_id = p_set and card_id = p_card for update;
  if not found or r.count < p_qty or (p_holo and r.holo_count < p_qty) or (not p_holo and r.count - r.holo_count < p_qty) then
    raise exception 'Not enough copies to transfer';
  end if;
  update cps.collection set count = count - p_qty, holo_count = holo_count - case when p_holo then p_qty else 0 end
    where account_id = p_from and set_id = p_set and card_id = p_card;
  insert into cps.collection (account_id, set_id, card_id, count, holo_count)
    values (p_to, p_set, p_card, p_qty, case when p_holo then p_qty else 0 end)
    on conflict (account_id, set_id, card_id) do update
      set count = cps.collection.count + excluded.count, holo_count = cps.collection.holo_count + excluded.holo_count;
  insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
    values (p_from, p_to, p_set, p_card, p_holo, p_qty, p_ref);
end $$;

-- ---------------------------------------------------------------- lock everything down
do $$ declare t text; begin
  for t in select tablename from pg_tables where schemaname = 'cps' loop
    execute format('alter table cps.%I enable row level security', t);
  end loop;
end $$;
revoke all on all tables in schema cps from public;
revoke all on all sequences in schema cps from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema cps from anon, authenticated';
    execute 'revoke all on all sequences in schema cps from anon, authenticated';
  end if;
end $$;

-- ---------------------------------------------------------------- internal helpers
create or replace function cps.hash_text(p text) returns bytea
language sql immutable set search_path = cps, pg_temp as $$
  select extensions.digest(convert_to(p, 'UTF8'), 'sha256')
$$;
create or replace function cps.norm_username(p text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select lower(btrim(coalesce(p, '')))
$$;
create or replace function cps.rand01() returns double precision
language sql volatile set search_path = cps, pg_temp as $$
  select ('x' || encode(extensions.gen_random_bytes(6), 'hex'))::bit(48)::bigint / 281474976710656.0
$$;
create or replace function cps.rarity_rank(p text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select array_position(array['common','uncommon','rare','epic','legendary','chase'], p) - 1
$$;
create or replace function cps.client_ip() returns text
language plpgsql stable set search_path = cps, pg_temp as $$
declare h json; v text;
begin
  begin h := current_setting('request.headers', true)::json; exception when others then h := null; end;
  if h is not null then
    v := coalesce(h->>'cf-connecting-ip', split_part(h->>'x-forwarded-for', ',', 1), h->>'x-real-ip');
  end if;
  return coalesce(nullif(btrim(v), ''), 'unknown');
end $$;

-- Resolve a session token to an account (raises if invalid). Used by every user RPC.
create or replace function cps.auth(p_token text, p_admin boolean default false) returns cps.accounts
language plpgsql volatile set search_path = cps, pg_temp as $$
declare s cps.sessions%rowtype; a cps.accounts%rowtype;
begin
  if p_token is null or length(p_token) < 20 then raise exception 'Not logged in' using errcode = '28000'; end if;
  select * into s from cps.sessions where token_hash = cps.hash_text(p_token);
  if not found or s.expires_at < now() then raise exception 'Session expired. Please log in again.' using errcode = '28000'; end if;
  select * into a from cps.accounts where id = s.account_id;
  if not found or a.disabled then raise exception 'This account is disabled.' using errcode = '28000'; end if;
  if p_admin and not a.is_admin then raise exception 'Admin only' using errcode = '42501'; end if;
  if s.last_used_at < now() - interval '1 hour' then
    update cps.sessions set last_used_at = now() where token_hash = s.token_hash;
  end if;
  return a;
end $$;

create or replace function cps.add_packs(p_account uuid, p_set text, p_packs int, p_reason text, p_ref text default null, p_by uuid default null)
returns int language plpgsql set search_path = cps, pg_temp as $$
declare n int;
begin
  if p_packs = 0 then
    select packs into n from cps.pack_inventory where account_id = p_account and set_id = p_set;
    return coalesce(n, 0);
  end if;
  insert into cps.pack_inventory (account_id, set_id, packs) values (p_account, p_set, greatest(p_packs, 0))
    on conflict (account_id, set_id) do update set packs = greatest(cps.pack_inventory.packs + p_packs, 0)
    returning packs into n;
  insert into cps.pack_grants (account_id, set_id, packs, reason, ref, granted_by) values (p_account, p_set, p_packs, p_reason, p_ref, p_by);
  return n;
end $$;

create or replace function cps.make_hint(p_username text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select left(btrim(p_username), 2) || '…(' || length(btrim(p_username)) || ')'
$$;

create or replace function cps.create_account(p_username text, p_display text, p_admin boolean, p_packs int, p_set text, p_by uuid)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := btrim(coalesce(p_username, ''));
begin
  if length(u) < 6 then raise exception 'Username must be at least 6 characters (it works like a password).'; end if;
  if length(u) > 64 then raise exception 'Username is too long.'; end if;
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
  insert into cps.accounts (username_hash, username_hint, display_name, is_admin, created_by)
    values (cps.hash_text(cps.norm_username(u)), cps.make_hint(u), left(coalesce(nullif(btrim(p_display), ''), 'Player'), 32), coalesce(p_admin, false), p_by)
    returning id into uid;
  if coalesce(p_packs, 0) > 0 and p_set is not null and exists (select 1 from cps.card_sets where id = p_set) then
    perform cps.add_packs(uid, p_set, p_packs, 'welcome', null, p_by);
  end if;
  return uid;
end $$;

-- Run once in the SQL editor to create the owner's admin account (not callable via the API).
create or replace function cps.bootstrap_admin(p_username text, p_display text default 'Admin', p_packs int default null)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid;
begin
  select id into uid from cps.accounts where username_hash = cps.hash_text(cps.norm_username(p_username));
  if uid is not null then
    update cps.accounts set is_admin = true, disabled = false where id = uid;
    return uid;
  end if;
  return cps.create_account(p_username, p_display, true,
    coalesce(p_packs, (cps.cfg('welcome_packs'))::int), cps.cfg('default_set')->>0, null);
end $$;

-- state snapshot for one account
create or replace function cps.state_json(p_account uuid) returns jsonb
language sql stable set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
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

-- =====================================================================
-- PUBLIC API (RPC). Callable with the publishable key.
-- =====================================================================

-- Log in with a username. Returns {ok, token, account, expires_at} or {ok:false, error, retry_after}.
create or replace function public.cps_login(p_username text, p_user_agent text default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare v_ip text := cps.client_ip(); fails int; maxf int := (cps.cfg('login_max_failures'))::int;
        win int := (cps.cfg('login_window_minutes'))::int; a cps.accounts%rowtype; tok text; exp timestamptz;
        oldest timestamptz;
begin
  delete from cps.login_attempts where at < now() - interval '1 day';
  select count(*), min(la.at) into fails, oldest from cps.login_attempts la
    where la.ip = v_ip and not la.success and la.at > now() - make_interval(mins => win);
  if fails >= maxf then
    return jsonb_build_object('ok', false, 'error', 'Too many failed attempts. Try again in a few minutes.',
      'retry_after', greatest(1, ceil(extract(epoch from (oldest + make_interval(mins => win) - now())))::int));
  end if;
  select * into a from cps.accounts where username_hash = cps.hash_text(cps.norm_username(p_username)) and not disabled;
  if not found then
    insert into cps.login_attempts (ip, success) values (v_ip, false);
    perform pg_sleep(0.4 + least(fails, 8) * 0.2);   -- backoff grows with each failure
    return jsonb_build_object('ok', false, 'error', 'Unknown username.', 'remaining', greatest(maxf - fails - 1, 0));
  end if;
  insert into cps.login_attempts (ip, success) values (v_ip, true);
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  exp := now() + make_interval(days => (cps.cfg('session_days'))::int);
  insert into cps.sessions (token_hash, account_id, expires_at, user_agent) values (cps.hash_text(tok), a.id, exp, left(p_user_agent, 200));
  update cps.accounts set last_login_at = now() where id = a.id;
  delete from cps.sessions where account_id = a.id and expires_at < now();
  return jsonb_build_object('ok', true, 'token', tok, 'expires_at', exp,
    'account', jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin));
end $$;

create or replace function public.cps_logout(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
begin
  delete from cps.sessions where token_hash = cps.hash_text(coalesce(p_token, ''));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cps_get_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return cps.state_json(a.id);
end $$;

create or replace function public.cps_set_display_name(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; n text := left(btrim(coalesce(p_name, '')), 32);
begin
  a := cps.auth(p_token);
  if n = '' then raise exception 'Name cannot be empty.'; end if;
  update cps.accounts set display_name = n where id = a.id;
  return jsonb_build_object('ok', true, 'display_name', n);
end $$;

-- Open one pack: checks + decrements inventory, rolls cards with the set's odds, records everything.
create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
begin
  a := cps.auth(p_token);
  select * into s from cps.card_sets where id = p_set and active;
  if not found then raise exception 'This set is not available online yet.'; end if;
  select packs into inv from cps.pack_inventory where account_id = a.id and set_id = p_set for update;
  if coalesce(inv, 0) < 1 then raise exception 'No packs left for this set.'; end if;
  update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = p_set returning packs into inv;

  select * into st from cps.user_set_stats where account_id = a.id and set_id = p_set for update;
  best_score := case when st.best is null then -1
                     else cps.rarity_rank((select rarity from cps.cards where set_id = p_set and card_id = st.best->>'id')) * 10
                          + case when (st.best->>'holo')::boolean then 5 else 0 end end;
  best_score := coalesce(best_score, -1);

  for slot in select value from jsonb_array_elements(s.pack->'slots') loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      x := cps.rand01(); acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot->'odds') order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      select card_id into cid from cps.cards where set_id = p_set and rarity = r and not (card_id = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = p_set and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', p_set, r; end if;
      holo := cps.rand01() * 100 < coalesce((s.pack->'holo'->>r)::float8, 0);
      picked := picked || cid;

      select count into prev_count from cps.collection where account_id = a.id and set_id = p_set and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0;
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, p_set, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
      if sc > best_score then
        best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
        best_changed := st.best is not null or best_changed;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
    values (a.id, p_set, 1, jsonb_array_length(out), n_holo, by_r, new_best)
    on conflict (account_id, set_id) do update set
      opened = cps.user_set_stats.opened + 1,
      pulled = cps.user_set_stats.pulled + excluded.pulled,
      holos  = cps.user_set_stats.holos + excluded.holos,
      by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                    select key, sum(value::int) as total from (
                      select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                      union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
      best = coalesce(excluded.best, cps.user_set_stats.best);
  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e));

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out,
    'best', (select best from cps.user_set_stats where account_id = a.id and set_id = p_set), 'new_best', best_changed and new_best is not null);
end $$;

-- Redeem a prize code (global use limit, one redemption per account).
create or replace function public.cps_redeem_code(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; c cps.prize_codes%rowtype; v_code text; n int; sname text;
begin
  a := cps.auth(p_token);
  v_code := upper(regexp_replace(coalesce(p_code, ''), '\s+', '', 'g'));
  select * into c from cps.prize_codes where prize_codes.code = v_code for update;
  if not found then
    perform pg_sleep(0.3);
    raise exception 'That code isn''t valid. Check for typos.';
  end if;
  if c.expires_at is not null and c.expires_at < now() then raise exception 'That code has expired.'; end if;
  if exists (select 1 from cps.code_redemptions where code_redemptions.code = c.code and account_id = a.id) then
    raise exception 'You already redeemed that code.';
  end if;
  if c.uses >= c.max_uses then raise exception 'That code was already used.'; end if;
  update cps.prize_codes set uses = uses + 1 where prize_codes.code = c.code;
  insert into cps.code_redemptions (code, account_id) values (c.code, a.id);
  n := cps.add_packs(a.id, c.set_id, c.packs, 'code', c.code, null);
  select name into sname from cps.card_sets where id = c.set_id;
  return jsonb_build_object('set_id', c.set_id, 'set_name', sname, 'packs', c.packs, 'packs_now', n);
end $$;

-- One-time upload of an offline/guest collection into the account (validated + capped).
create or replace function public.cps_import_guest(p_token text, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; sid text; sdata jsonb; cid text; cdata jsonb; n int; h int;
        cards_in int := 0; packs_in int := 0; maxp int := (cps.cfg('guest_import_max_packs'))::int; p int;
begin
  a := cps.auth(p_token);
  if not (cps.cfg('allow_guest_import'))::boolean then raise exception 'Guest uploads are turned off.'; end if;
  if exists (select 1 from cps.guest_imports where account_id = a.id) then raise exception 'You already uploaded a guest collection to this account.'; end if;
  if jsonb_typeof(p_data) <> 'object' then raise exception 'Bad upload.'; end if;
  for sid, sdata in select key, value from jsonb_each(p_data) loop
    continue when not exists (select 1 from cps.card_sets where id = sid);
    if jsonb_typeof(sdata->'cards') = 'object' then
      for cid, cdata in select key, value from jsonb_each(sdata->'cards') loop
        continue when not exists (select 1 from cps.cards where set_id = sid and card_id = cid);
        n := least(greatest(coalesce((cdata->>'n')::int, 0), 0), 50);
        h := least(greatest(coalesce((cdata->>'h')::int, 0), 0), n);
        continue when n = 0;
        insert into cps.collection (account_id, set_id, card_id, count, holo_count) values (a.id, sid, cid, n, h)
          on conflict (account_id, set_id, card_id) do update
            set count = cps.collection.count + excluded.count, holo_count = cps.collection.holo_count + excluded.holo_count;
        cards_in := cards_in + n;
      end loop;
    end if;
    p := least(greatest(coalesce((sdata->>'packs')::int, 0), 0), maxp);
    if p > 0 then perform cps.add_packs(a.id, sid, p, 'guest_import'); packs_in := packs_in + p; end if;
  end loop;
  insert into cps.guest_imports (account_id, summary) values (a.id, jsonb_build_object('cards', cards_in, 'packs', packs_in));
  return jsonb_build_object('cards', cards_in, 'packs', packs_in);
end $$;

-- ---------------------------------------------------------------- admin API
create or replace function public.cps_admin_create_account(p_token text, p_username text, p_display_name text,
  p_start_packs int default null, p_set text default null, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; uid uuid; sid text := coalesce(p_set, cps.cfg('default_set')->>0);
        np int := coalesce(p_start_packs, (cps.cfg('welcome_packs'))::int);
begin
  a := cps.auth(p_token, true);
  if np < 0 or np > 999 then raise exception 'Starting packs must be 0–999.'; end if;
  uid := cps.create_account(p_username, p_display_name, coalesce(p_is_admin, false), np, sid, a.id);
  return jsonb_build_object('id', uid, 'display_name', left(coalesce(nullif(btrim(p_display_name), ''), 'Player'), 32), 'packs', np, 'set_id', sid);
end $$;

create or replace function public.cps_admin_list_accounts(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'display_name', x.display_name, 'hint', x.username_hint, 'is_admin', x.is_admin, 'disabled', x.disabled,
      'created_at', x.created_at, 'last_login_at', x.last_login_at,
      'packs', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = x.id), '{}'),
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0),
      'opened', coalesce((select sum(opened) from cps.user_set_stats where account_id = x.id), 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x), '[]');
end $$;

create or replace function public.cps_admin_update_account(p_token text, p_account uuid, p_display_name text default null,
  p_new_username text default null, p_disabled boolean default null, p_is_admin boolean default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; u text := btrim(coalesce(p_new_username, ''));
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.accounts where id = p_account) then raise exception 'No such account.'; end if;
  if p_account = a.id and (p_disabled is true or p_is_admin is false) then raise exception 'You can''t disable or demote yourself.'; end if;
  if p_display_name is not null and btrim(p_display_name) <> '' then
    update cps.accounts set display_name = left(btrim(p_display_name), 32) where id = p_account;
  end if;
  if u <> '' then
    if length(u) < 6 then raise exception 'Username must be at least 6 characters.'; end if;
    if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u)) and id <> p_account) then
      raise exception 'That username is taken.';
    end if;
    update cps.accounts set username_hash = cps.hash_text(cps.norm_username(u)), username_hint = cps.make_hint(u) where id = p_account;
    delete from cps.sessions where account_id = p_account and token_hash <> cps.hash_text(p_token);  -- old username's sessions end
  end if;
  if p_disabled is not null then
    update cps.accounts set disabled = p_disabled where id = p_account;
    if p_disabled then delete from cps.sessions where account_id = p_account; end if;
  end if;
  if p_is_admin is not null then update cps.accounts set is_admin = p_is_admin where id = p_account; end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.cps_admin_delete_account(p_token text, p_account uuid) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  if p_account = a.id then raise exception 'You can''t delete your own account.'; end if;
  delete from cps.accounts where id = p_account;
  return jsonb_build_object('ok', found);
end $$;

create or replace function public.cps_admin_grant_packs(p_token text, p_set text, p_packs int, p_account uuid default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; target uuid; n int;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if not exists (select 1 from cps.card_sets where id = p_set) then raise exception 'That set is not on the server yet.'; end if;
  if p_packs is null or p_packs < -999 or p_packs > 999 or p_packs = 0 then raise exception 'Packs must be between -999 and 999 (not 0).'; end if;
  if not exists (select 1 from cps.accounts where id = target) then raise exception 'No such account.'; end if;
  n := cps.add_packs(target, p_set, p_packs, 'admin', null, a.id);
  return jsonb_build_object('account', target, 'set_id', p_set, 'packs_now', n);
end $$;

create or replace function public.cps_admin_generate_codes(p_token text, p_set text, p_packs int, p_count int default 1,
  p_max_uses int default 1, p_note text default null, p_expires_days int default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; codes text[] := '{}'; c text; i int; j int; alph text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ'; b bytea;
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.card_sets where id = p_set) then raise exception 'That set is not on the server yet.'; end if;
  if p_packs not between 1 and 99 then raise exception 'Packs per code must be 1–99.'; end if;
  if p_count not between 1 and 200 then raise exception 'Count must be 1–200.'; end if;
  if p_max_uses not between 1 and 1000 then raise exception 'Max uses must be 1–1000.'; end if;
  for i in 1..p_count loop
    loop
      b := extensions.gen_random_bytes(10); c := '';
      for j in 0..9 loop c := c || substr(alph, (get_byte(b, j) % 31) + 1, 1); end loop;
      c := 'PACK-' || p_packs || '-' || substr(c, 1, 5) || '-' || substr(c, 6, 5);
      exit when not exists (select 1 from cps.prize_codes where code = c);
    end loop;
    insert into cps.prize_codes (code, set_id, packs, max_uses, note, created_by, expires_at)
      values (c, p_set, p_packs, p_max_uses, nullif(btrim(p_note), ''), a.id,
              case when p_expires_days is not null then now() + make_interval(days => p_expires_days) end);
    codes := codes || c;
  end loop;
  return to_jsonb(codes);
end $$;

create or replace function public.cps_admin_list_codes(p_token text, p_limit int default 100) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(row_to_json(t)) from (
    select c.code, c.set_id, c.packs, c.uses, c.max_uses, c.note, c.created_at, c.expires_at,
      (select jsonb_agg(x.display_name) from cps.code_redemptions r join cps.accounts x on x.id = r.account_id where r.code = c.code) as redeemed_by
    from cps.prize_codes c order by c.created_at desc limit least(greatest(p_limit, 1), 500)) t), '[]');
end $$;

-- Upload / update a set (cards + resolved pack odds) from the app or tools/sync-set.js.
create or replace function public.cps_admin_upsert_set(p_token text, p_set jsonb) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; sid text := p_set->>'id'; n int; removed int;
begin
  a := cps.auth(p_token, true);
  if sid is null or sid !~ '^[a-z0-9_-]{1,64}$' then raise exception 'Set id must be lowercase letters, numbers, - or _.'; end if;
  if jsonb_typeof(p_set->'cards') <> 'array' or jsonb_array_length(p_set->'cards') = 0 then raise exception 'Set has no cards.'; end if;
  if jsonb_typeof(p_set->'pack'->'slots') <> 'array' then raise exception 'Set pack.slots missing.'; end if;
  insert into cps.card_sets (id, name, code, pack, card_count, active, updated_at)
    values (sid, coalesce(p_set->>'name', sid), coalesce(p_set->>'code', ''), p_set->'pack', jsonb_array_length(p_set->'cards'), true, now())
    on conflict (id) do update set name = excluded.name, code = excluded.code, pack = excluded.pack,
      card_count = excluded.card_count, active = true, updated_at = now();
  insert into cps.cards (set_id, card_id, num, name, rarity)
    select sid, c->>'id', nullif(c->>'num', '')::int, coalesce(c->>'name', c->>'id'), c->>'rarity'
    from jsonb_array_elements(p_set->'cards') c
    on conflict (set_id, card_id) do update set num = excluded.num, name = excluded.name, rarity = excluded.rarity;
  get diagnostics n = row_count;
  -- cards dropped from the set file are removed only if nobody owns them
  delete from cps.cards k where k.set_id = sid
    and not exists (select 1 from jsonb_array_elements(p_set->'cards') c where c->>'id' = k.card_id)
    and not exists (select 1 from cps.collection o where o.set_id = sid and o.card_id = k.card_id);
  get diagnostics removed = row_count;
  return jsonb_build_object('set_id', sid, 'cards', n, 'removed', removed);
end $$;

-- ---------------------------------------------------------------- grants for the API functions
do $$ declare f text; begin
  for f in select p.oid::regprocedure::text from pg_proc p join pg_namespace s on s.oid = p.pronamespace
           where s.nspname = 'public' and p.proname like 'cps\_%' loop
    execute format('revoke all on function %s from public', f);
    if exists (select 1 from pg_roles where rolname = 'anon') then
      execute format('grant execute on function %s to anon, authenticated', f);
    end if;
  end loop;
end $$;

-- let the API pick up the new functions right away
notify pgrst, 'reload schema';
