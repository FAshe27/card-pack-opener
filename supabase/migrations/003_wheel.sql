-- =====================================================================
-- 003_wheel.sql — Prize wheel: spin currency, daily spins, wheel config,
-- server-side spin rolling, and admin spin grants.
--
-- NOTE: the wheel structure (tiers / weights / gateways) is mirrored in
-- js/wheel.js (used for the guest-mode roll). KEEP THE TWO IN SYNC.
-- Segments are generated from the live cps.card_sets rows, so newly added
-- sets appear on all wheels automatically with no adjustments.
-- =====================================================================

-- ---------------------------------------------------------------- spin balance
alter table cps.accounts add column if not exists spins int not null default 0 check (spins >= 0);
alter table cps.accounts add column if not exists last_daily_spin date;

create table if not exists cps.spin_grants (
  id           bigserial primary key,
  account_id   uuid not null references cps.accounts(id) on delete cascade,
  spins        int not null,                       -- +granted / -consumed
  reason       text not null,                      -- 'admin' | 'daily' | 'wheel'
  ref          text,
  granted_by   uuid references cps.accounts(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists spin_grants_account on cps.spin_grants (account_id);

-- ---------------------------------------------------------------- wheel config
-- Resolves the static wheel structure against the live set list.
create or replace function cps.wheel_config() returns jsonb
language plpgsql stable set search_path = cps, pg_temp as $$
declare
  set_ids text[];
  w1 jsonb; w2 jsonb; w3 jsonb;
begin
  select coalesce(array_agg(id order by id), '{}') into set_ids
    from cps.card_sets where active;

  -- Wheel 1: 1 pack per set (weight 3 each) + gateway to wheel 2 (weight 1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w1 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 1, 'weight', 3) as seg from unnest(set_ids) s
    union all
    select 1, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Go to second wheel', 'weight', 1)
  ) x;

  -- Wheel 2: 2 packs per set (weight 2 each) + back to w1 (2) + gateway to w3 (1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w2 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 2, 'weight', 2) as seg from unnest(set_ids) s
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 2)
    union all
    select 2, jsonb_build_object('key', 'goto:w3', 'kind', 'goto', 'wheel', 'w3',
             'label', 'Go to third wheel', 'weight', 1)
  ) x;

  -- Wheel 3: 3 packs per set (weight 2 each) + back to w1 (1) + back to w2 (1)
  select coalesce(jsonb_agg(seg order by ord), '[]') into w3 from (
    select 0 as ord, jsonb_build_object('key', 'packs:' || s, 'kind', 'packs',
             'set_id', s, 'packs', 3, 'weight', 2) as seg from unnest(set_ids) s
    union all
    select 1, jsonb_build_object('key', 'goto:w1', 'kind', 'goto', 'wheel', 'w1',
             'label', 'Back to first wheel', 'weight', 1)
    union all
    select 2, jsonb_build_object('key', 'goto:w2', 'kind', 'goto', 'wheel', 'w2',
             'label', 'Back to second wheel', 'weight', 1)
  ) x;

  return jsonb_build_object('wheels', jsonb_build_array(
    jsonb_build_object('id', 'w1', 'name', 'Prize Wheel',  'segments', w1),
    jsonb_build_object('id', 'w2', 'name', 'Double Wheel', 'segments', w2),
    jsonb_build_object('id', 'w3', 'name', 'Triple Wheel', 'segments', w3)
  ));
end $$;

-- Rolls the full hop chain starting at w1. A spin only ends on a packs prize;
-- gateway hops are free. Returns {hops:[...], prize:{set_id, packs}}.
create or replace function cps.roll_wheel() returns jsonb
language plpgsql volatile set search_path = cps, pg_temp as $$
declare
  cfg   jsonb := cps.wheel_config();
  hops  jsonb := '[]'::jsonb;
  wid   text  := 'w1';
  w     jsonb;
  segs  jsonb;
  total int;
  r     int;
  acc   int;
  seg   jsonb;
  s     jsonb;
  guard int := 0;
begin
  loop
    guard := guard + 1;
    if guard > 25 then raise exception 'Wheel chain too long.'; end if;
    select v into w from jsonb_array_elements(cfg -> 'wheels') v where v ->> 'id' = wid;
    if w is null then raise exception 'Unknown wheel: %', wid; end if;
    segs := w -> 'segments';
    select coalesce(sum((x ->> 'weight')::int), 0) into total
      from jsonb_array_elements(segs) x;
    if total <= 0 then raise exception 'Wheel % has no segments.', wid; end if;
    r := floor(cps.rand01() * total)::int;
    acc := 0;
    seg := null;
    for s in select value from jsonb_array_elements(segs) loop
      acc := acc + (s ->> 'weight')::int;
      if r < acc then seg := s; exit; end if;
    end loop;
    if seg is null then raise exception 'Wheel roll failed.'; end if;
    hops := hops || jsonb_build_object(
      'wheel', wid, 'key', seg ->> 'key', 'kind', seg ->> 'kind',
      'set_id', seg -> 'set_id', 'packs', (seg ->> 'packs')::int,
      'label', seg ->> 'label', 'goto_wheel', seg ->> 'wheel');
    if seg ->> 'kind' = 'packs' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('set_id', seg ->> 'set_id',
                                    'packs', (seg ->> 'packs')::int));
    end if;
    wid := seg ->> 'wheel';
  end loop;
end $$;

-- ---------------------------------------------------------------- state (+spins)
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
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config()
  )
$$;

-- get_state now also grants the daily free spin (one per America/Chicago day).
create or replace function public.cps_get_state(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a     cps.accounts%rowtype;
  today date := (now() at time zone 'America/Chicago')::date;
  n     int;
begin
  a := cps.auth(p_token);
  update cps.accounts set spins = spins + 1, last_daily_spin = today
    where id = a.id and coalesce(last_daily_spin, date '1970-01-01') < today;
  get diagnostics n = row_count;
  if n > 0 then
    insert into cps.spin_grants (account_id, spins, reason) values (a.id, 1, 'daily');
  end if;
  return cps.state_json(a.id);
end $$;

-- ---------------------------------------------------------------- spin RPC
-- Spends one spin, rolls the wheel chain server-side, awards the packs.
create or replace function public.cps_spin_wheel(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  res       jsonb;
  prize     jsonb;
  packs_now int;
  spins_now int;
begin
  a := cps.auth(p_token);
  if coalesce(a.spins, 0) < 1 then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  update cps.accounts set spins = spins - 1 where id = a.id
    returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || (prize ->> 'set_id'));

  packs_now := cps.add_packs(a.id, prize ->> 'set_id', (prize ->> 'packs')::int, 'wheel', null, null);

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'spins_left', spins_now
  );
end $$;

-- Admin: grant (or remove) wheel spins for an account.
create or replace function public.cps_admin_grant_spins(p_token text, p_account uuid, p_spins int) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a      cps.accounts%rowtype;
  target uuid;
  n      int;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if p_spins is null or p_spins = 0 or p_spins < -999 or p_spins > 999 then
    raise exception 'Spins must be between -999 and 999 (not 0).';
  end if;
  if not exists (select 1 from cps.accounts where id = target) then
    raise exception 'No such account.';
  end if;
  update cps.accounts set spins = greatest(spins + p_spins, 0)
    where id = target returning spins into n;
  insert into cps.spin_grants (account_id, spins, reason, granted_by)
    values (target, p_spins, 'admin', a.id);
  return jsonb_build_object('account', target, 'spins_now', n);
end $$;

-- Admin account list now includes spin balances.
create or replace function public.cps_admin_list_accounts(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'display_name', x.display_name, 'hint', x.username_hint, 'is_admin', x.is_admin, 'disabled', x.disabled,
      'created_at', x.created_at, 'last_login_at', x.last_login_at,
      'packs', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = x.id), '{}'),
      'spins', x.spins,
      'unique_cards', (select count(*) from cps.collection where account_id = x.id and count > 0),
      'opened', coalesce((select sum(opened) from cps.user_set_stats where account_id = x.id), 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x), '[]');
end $$;

-- ---------------------------------------------------------------- permissions
revoke execute on all functions in schema cps from public;
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
