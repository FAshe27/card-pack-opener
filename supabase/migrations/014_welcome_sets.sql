-- =====================================================================
-- 014_welcome_sets.sql — create-account grants starting packs for a LIST of
-- sets (checkboxes in the admin panel) instead of a single set.
-- =====================================================================

-- internal account creator now takes an array of set ids
drop function if exists cps.create_account(text, text, boolean, int, text, uuid);
create or replace function cps.create_account(p_username text, p_display text, p_admin boolean, p_packs int, p_sets text[], p_by uuid)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := btrim(coalesce(p_username, '')); sid text;
begin
  if length(u) < 6 then raise exception 'Username must be at least 6 characters (it works like a password).'; end if;
  if length(u) > 64 then raise exception 'Username is too long.'; end if;
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
  insert into cps.accounts (username_hash, username_hint, display_name, is_admin, created_by)
    values (cps.hash_text(cps.norm_username(u)), cps.make_hint(u), left(coalesce(nullif(btrim(p_display), ''), 'Player'), 32), coalesce(p_admin, false), p_by)
    returning id into uid;
  if coalesce(p_packs, 0) > 0 and p_sets is not null then
    foreach sid in array p_sets loop
      if exists (select 1 from cps.card_sets where id = sid) then
        perform cps.add_packs(uid, sid, p_packs, 'welcome', null, p_by);
      end if;
    end loop;
  end if;
  return uid;
end $$;

-- admin entry point: p_sets replaces p_set
drop function if exists public.cps_admin_create_account(text, text, text, int, text, boolean);
create or replace function public.cps_admin_create_account(p_token text, p_username text, p_display_name text,
  p_start_packs int default null, p_sets text[] default null, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; uid uuid;
        sids text[] := coalesce(p_sets, array[cps.cfg('default_set')->>0]);
        np int := coalesce(p_start_packs, (cps.cfg('welcome_packs'))::int);
begin
  a := cps.auth(p_token, true);
  if np < 0 or np > 999 then raise exception 'Starting packs must be 0–999.'; end if;
  uid := cps.create_account(p_username, p_display_name, coalesce(p_is_admin, false), np, sids, a.id);
  return jsonb_build_object('id', uid, 'display_name', left(coalesce(nullif(btrim(p_display_name), ''), 'Player'), 32),
    'packs', np, 'set_ids', sids);
end $$;

-- bootstrap_admin keeps working (single default set, wrapped as an array)
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
    coalesce(p_packs, (cps.cfg('welcome_packs'))::int), array[cps.cfg('default_set')->>0], null);
end $$;

notify pgrst, 'reload schema';
