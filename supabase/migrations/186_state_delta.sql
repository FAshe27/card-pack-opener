-- 186_state_delta.sql
-- EXECUTED 2026-10-25 via the Supabase connector on Franklin's go
-- ("If you're good with 4, go for it!"). Rollback-verified beforehand
-- (trigger marking, one-bump bulk writes, merge == full equivalence,
-- daily-grant parity); post-run live probe on the Muse test account
-- confirmed unchanged/blocks behavior with zero data drift.
--
-- What: block-level delta state. cps.state_meta holds a per-account
-- version counter; cps.state_blocks holds the latest version at which
-- each state_json block changed. Statement-level AFTER triggers with
-- transition tables on the underlying tables do the marking, so no
-- mutating RPC needs to know deltas exist (over-marking is harmless;
-- triggers cannot under-mark). state_json gains 'ver'/'gver' keys.
-- New public.cps_get_state_delta(p_token, p_ver, p_gver):
--   unchanged -> {ver, gver, unchanged:true}
--   stale/ahead -> full state_json + game_tokens + {full:true}
--   else        -> {ver, gver, game_tokens, blocks:{changed only}}
-- The daily-spin grant from cps_get_state is mirrored so a
-- delta-only client never loses it. Old clients ignore everything.

create table if not exists cps.state_meta (
  account_id uuid primary key,
  ver bigint not null default 0
);
create table if not exists cps.state_blocks (
  account_id uuid not null,
  block text not null,
  changed_ver bigint not null,
  primary key (account_id, block)
);

create or replace function cps.state_bump(p_account uuid, p_blocks text[])
returns void language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare v_ver bigint;
begin
  insert into cps.state_meta (account_id, ver) values (p_account, 1)
    on conflict (account_id) do update set ver = cps.state_meta.ver + 1
    returning ver into v_ver;
  insert into cps.state_blocks (account_id, block, changed_ver)
    select p_account, b, v_ver from unnest(p_blocks) as b
    on conflict (account_id, block) do update set changed_ver = excluded.changed_ver;
end $fn$;

-- Trigger markers. Static transition-table references (no dynamic
-- SQL): *_a read account_id; *_acct read id (the accounts table);
-- *_global bumps the sentinel row used for online_sets/wheel.
create or replace function cps.state_mark_new_a() returns trigger
language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare v_ids uuid[];
begin
  select array_agg(distinct account_id) into v_ids from new_table;
  if v_ids is not null then
    for i in 1 .. array_length(v_ids, 1) loop
      perform cps.state_bump(v_ids[i], string_to_array(tg_argv[0], ','));
    end loop;
  end if;
  return null;
end $fn$;

create or replace function cps.state_mark_old_a() returns trigger
language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare v_ids uuid[];
begin
  select array_agg(distinct account_id) into v_ids from old_table;
  if v_ids is not null then
    for i in 1 .. array_length(v_ids, 1) loop
      perform cps.state_bump(v_ids[i], string_to_array(tg_argv[0], ','));
    end loop;
  end if;
  return null;
end $fn$;

create or replace function cps.state_mark_both_a() returns trigger
language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare v_ids uuid[];
begin
  select array_agg(distinct account_id) into v_ids
    from (select account_id from new_table union select account_id from old_table) u;
  if v_ids is not null then
    for i in 1 .. array_length(v_ids, 1) loop
      perform cps.state_bump(v_ids[i], string_to_array(tg_argv[0], ','));
    end loop;
  end if;
  return null;
end $fn$;

create or replace function cps.state_mark_both_acct() returns trigger
language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare v_ids uuid[];
begin
  select array_agg(distinct id) into v_ids
    from (select id from new_table union select id from old_table) u;
  if v_ids is not null then
    for i in 1 .. array_length(v_ids, 1) loop
      perform cps.state_bump(v_ids[i], string_to_array(tg_argv[0], ','));
    end loop;
  end if;
  return null;
end $fn$;

create or replace function cps.state_mark_global() returns trigger
language plpgsql security definer set search_path = cps, pg_temp as $fn$
begin
  perform cps.state_bump('00000000-0000-0000-0000-000000000000'::uuid, string_to_array(tg_argv[0], ','));
  return null;
end $fn$;

drop trigger if exists state_mark_i on cps.collection;
create trigger state_mark_i after insert on cps.collection
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('collection,favorites');
drop trigger if exists state_mark_u on cps.collection;
create trigger state_mark_u after update on cps.collection
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('collection,favorites');
drop trigger if exists state_mark_d on cps.collection;
create trigger state_mark_d after delete on cps.collection
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('collection,favorites');

drop trigger if exists state_mark_i on cps.turn_ins;
create trigger state_mark_i after insert on cps.turn_ins
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('turn_ins');
drop trigger if exists state_mark_u on cps.turn_ins;
create trigger state_mark_u after update on cps.turn_ins
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('turn_ins');
drop trigger if exists state_mark_d on cps.turn_ins;
create trigger state_mark_d after delete on cps.turn_ins
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('turn_ins');

drop trigger if exists state_mark_i on cps.pack_inventory;
create trigger state_mark_i after insert on cps.pack_inventory
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('inventory');
drop trigger if exists state_mark_u on cps.pack_inventory;
create trigger state_mark_u after update on cps.pack_inventory
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('inventory');
drop trigger if exists state_mark_d on cps.pack_inventory;
create trigger state_mark_d after delete on cps.pack_inventory
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('inventory');

drop trigger if exists state_mark_i on cps.user_set_stats;
create trigger state_mark_i after insert on cps.user_set_stats
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('stats');
drop trigger if exists state_mark_u on cps.user_set_stats;
create trigger state_mark_u after update on cps.user_set_stats
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('stats');
drop trigger if exists state_mark_d on cps.user_set_stats;
create trigger state_mark_d after delete on cps.user_set_stats
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('stats');

drop trigger if exists state_mark_i on cps.pack_openings;
create trigger state_mark_i after insert on cps.pack_openings
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('recent');
drop trigger if exists state_mark_u on cps.pack_openings;
create trigger state_mark_u after update on cps.pack_openings
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('recent');
drop trigger if exists state_mark_d on cps.pack_openings;
create trigger state_mark_d after delete on cps.pack_openings
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('recent');

drop trigger if exists state_mark_i on cps.variants;
create trigger state_mark_i after insert on cps.variants
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('favorites');
drop trigger if exists state_mark_u on cps.variants;
create trigger state_mark_u after update on cps.variants
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('favorites');
drop trigger if exists state_mark_d on cps.variants;
create trigger state_mark_d after delete on cps.variants
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('favorites');

drop trigger if exists state_mark_i on cps.vault_order;
create trigger state_mark_i after insert on cps.vault_order
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('favorites');
drop trigger if exists state_mark_u on cps.vault_order;
create trigger state_mark_u after update on cps.vault_order
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_a('favorites');
drop trigger if exists state_mark_d on cps.vault_order;
create trigger state_mark_d after delete on cps.vault_order
  referencing old table as old_table
  for each statement execute function cps.state_mark_old_a('favorites');

drop trigger if exists state_mark_i on cps.guest_imports;
create trigger state_mark_i after insert on cps.guest_imports
  referencing new table as new_table
  for each statement execute function cps.state_mark_new_a('guest_imported');

drop trigger if exists state_mark_u on cps.accounts;
create trigger state_mark_u after update on cps.accounts
  referencing old table as old_table new table as new_table
  for each statement execute function cps.state_mark_both_acct('account,spins');

drop trigger if exists state_mark_i on cps.card_sets;
create trigger state_mark_i after insert on cps.card_sets
  for each statement execute function cps.state_mark_global('online_sets,wheel');
drop trigger if exists state_mark_u on cps.card_sets;
create trigger state_mark_u after update on cps.card_sets
  for each statement execute function cps.state_mark_global('online_sets,wheel');
drop trigger if exists state_mark_d on cps.card_sets;
create trigger state_mark_d after delete on cps.card_sets
  for each statement execute function cps.state_mark_global('online_sets,wheel');

-- state_json: + ver/gver keys (insertion-only vs the live body)
CREATE OR REPLACE FUNCTION cps.state_json(p_account uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value || jsonb_build_object('at', (extract(epoch from o.opened_at) * 1000)::bigint) as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from (select o0.account_id, o0.set_id, o0.opened_at, o0.cards
                          from (select o1.account_id, o1.set_id, o1.opened_at, o1.cards,
                                       coalesce(sum(jsonb_array_length(o1.cards)) over (partition by o1.set_id order by o1.opened_at desc, o1.id desc), 0)
                                         - jsonb_array_length(o1.cards) as prior_cards
                                  from cps.pack_openings o1
                                 where o1.account_id = p_account and o1.opened_at > now() - interval '120 days') o0
                         where o0.prior_cards < 36) o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config(),
    'favorites', coalesce((select jsonb_agg(jsonb_build_array(u.set_id, u.card_id) order by vo.position nulls last, u.set_id, u.card_id)
                           from (select set_id, card_id from cps.collection where account_id = p_account and vaulted_count > 0
                                 union
                                 select set_id, card_id from cps.variants where account_id = p_account and vaulted) u
                           left join cps.vault_order vo
                             on vo.account_id = p_account and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'turn_ins', coalesce((select jsonb_object_agg(g.set_id, g.ids)
                           from (select set_id, jsonb_agg(card_id order by card_id) as ids
                                   from cps.turn_ins where account_id = p_account
                                  group by set_id) g), '{}'),
    'ver', coalesce((select ver from cps.state_meta where account_id = p_account), 0),
    'gver', coalesce((select ver from cps.state_meta where account_id = '00000000-0000-0000-0000-000000000000'::uuid), 0)
  )
$function$;

create or replace function public.cps_get_state_delta(p_token text, p_ver bigint, p_gver bigint)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $fn$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
  v_cur bigint;
  g_cur bigint;
  v_full jsonb;
  v_blocks jsonb := '{}'::jsonb;
  v_key text;
begin
  a := cps.auth(p_token);
  -- Daily-spin grant, mirrored verbatim from cps_get_state so a
  -- delta-only client never loses it. The accounts trigger marks the
  -- spins block, so the grant shows up in this very reply.
  update cps.accounts set spins = spins + 3, last_daily_spin = today
    where id = a.id and coalesce(last_daily_spin, date '1970-01-01') < today and spins < 10
      and not coalesce(a.is_admin, false);
  get diagnostics n = row_count;
  if n > 0 then
    insert into cps.spin_grants (account_id, spins, reason) values (a.id, 3, 'daily');
  end if;
  select * into a from cps.accounts where id = a.id;

  v_cur := coalesce((select ver from cps.state_meta where account_id = a.id), 0);
  g_cur := coalesce((select ver from cps.state_meta
                      where account_id = '00000000-0000-0000-0000-000000000000'::uuid), 0);

  if p_ver is not null and p_ver = v_cur and coalesce(p_gver, -1) = g_cur then
    return jsonb_build_object('ver', v_cur, 'gver', g_cur, 'unchanged', true);
  end if;

  v_full := cps.state_json(a.id);
  if p_ver is null or p_ver <= 0 or p_ver > v_cur or p_gver is null or p_gver > g_cur then
    return v_full || jsonb_build_object('game_tokens', coalesce(a.game_tokens, 0), 'full', true);
  end if;

  for v_key in
    select block from cps.state_blocks where account_id = a.id and changed_ver > p_ver
    union
    select block from cps.state_blocks
     where account_id = '00000000-0000-0000-0000-000000000000'::uuid and changed_ver > p_gver
  loop
    v_blocks := v_blocks || jsonb_build_object(v_key, v_full -> v_key);
  end loop;

  return jsonb_build_object('ver', v_cur, 'gver', g_cur,
                            'game_tokens', coalesce(a.game_tokens, 0),
                            'blocks', v_blocks);
end $fn$;
