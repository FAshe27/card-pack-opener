-- =====================================================================
-- 015_create_account_cleanup.sql — 014 accidentally created overloads: 002 had
-- already redefined cps.create_account / cps_admin_create_account /
-- cps.bootstrap_admin with p_pin, so 014's drops (written against 001) were
-- no-ops. Drop every overload and recreate single correct versions that keep
-- 002's p_pin behavior plus 014's p_sets[] welcome packs.
-- =====================================================================

drop function if exists cps.create_account(text, text, text, boolean, int, text, uuid);
drop function if exists cps.create_account(text, text, boolean, int, text[], uuid);
drop function if exists public.cps_admin_create_account(text, text, text, text, int, text, boolean);
drop function if exists public.cps_admin_create_account(text, text, text, int, text[], boolean);
drop function if exists cps.bootstrap_admin(text, text, text, int);
drop function if exists cps.bootstrap_admin(text, text, int);

create or replace function cps.create_account(p_username text, p_display text, p_pin text, p_admin boolean, p_packs int, p_sets text[], p_by uuid)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := cps.clean_username(p_username); sid text;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
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
end $$;

create or replace function public.cps_admin_create_account(p_token text, p_username text, p_display_name text, p_pin text,
  p_start_packs int default null, p_sets text[] default null, p_is_admin boolean default false) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; uid uuid;
        sids text[] := coalesce(p_sets, array[cps.cfg('default_set')->>0]);
        np int := coalesce(p_start_packs, (cps.cfg('welcome_packs'))::int);
begin
  a := cps.auth(p_token, true);
  if np < 0 or np > 999 then raise exception 'Starting packs must be 0–999.'; end if;
  uid := cps.create_account(p_username, p_display_name, p_pin, coalesce(p_is_admin, false), np, sids, a.id);
  return (select jsonb_build_object('id', x.id, 'username', x.username, 'display_name', x.display_name, 'packs', np, 'set_ids', sids)
          from cps.accounts x where x.id = uid);
end $$;

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
    coalesce(p_packs, (cps.cfg('welcome_packs'))::int), array[cps.cfg('default_set')->>0], null);
end $$;

notify pgrst, 'reload schema';
