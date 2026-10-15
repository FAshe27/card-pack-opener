-- =====================================================================
-- 152_admin_grant_random_packs.sql — Admin panel: "Random Packs".
-- Run AFTER 151.
--
-- The admin Accounts panel's Grant-packs row gains a "Random Packs"
-- entry in its set dropdown (client). These two RPCs are the random
-- siblings of the existing grant functions, same shapes/safeguards:
--   * cps_admin_grant_random_packs_all — the Everyone version;
--     audience + notification mirror 018's cps_admin_grant_packs_all
--     (non-admin, non-disabled players; the usual 'gift_pack' note).
--   * cps_admin_grant_random_packs — the single-player version;
--     mirrors 013's cps_admin_grant_packs (target defaults to the
--     admin; the recipient is notified unless it is the admin).
-- "Random" is migration 144's pool and draw: each pack is rolled
-- independently against every active set that has cards, Jumbled
-- excluded, duplicates possible. Grants are ledgered with reason
-- 'admin_grant_random' and granted_by = the acting admin.
-- =====================================================================

create or replace function public.cps_admin_grant_random_packs_all(p_token text, p_packs int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  n        int := 0;
  r        record;
  rp       record;
  v_pool   text[];
  v_pool_n int := 0;
begin
  a := cps.auth(p_token, true);
  if p_packs is null or p_packs < 1 or p_packs > 999 then raise exception 'Packs must be between 1 and 999.'; end if;

  select array_agg(cs.id order by cs.id), count(*)
    into v_pool, v_pool_n
    from cps.card_sets cs
   where cs.active and cs.id <> 'jumbled'
     and exists (select 1 from cps.cards c where c.set_id = cs.id);
  if v_pool_n = 0 then raise exception 'No sets in the random pool yet.'; end if;

  for r in select id from cps.accounts where not is_admin and not disabled loop
    for rp in
      select d.pick as set_id, count(*)::int as cnt
        from (select v_pool[1 + floor(random() * v_pool_n)::int] as pick
                from generate_series(1, p_packs)) d
       group by d.pick
    loop
      perform cps.add_packs(r.id, rp.set_id, rp.cnt, 'admin_grant_random', null, a.id);
    end loop;
    perform cps.notify(r.id, 'gift_pack',
      'You''ve been gifted ' || case when p_packs = 1 then 'a random pack' else p_packs || ' random packs' end || '!',
      'packs');
    n := n + 1;
  end loop;
  return jsonb_build_object('packs_each', p_packs, 'players', n);
end $$;

grant execute on function public.cps_admin_grant_random_packs_all(text, int) to anon;

create or replace function public.cps_admin_grant_random_packs(p_token text, p_packs int, p_account uuid default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a        cps.accounts%rowtype;
  target   uuid;
  rp       record;
  v_pool   text[];
  v_pool_n int := 0;
begin
  a := cps.auth(p_token, true);
  target := coalesce(p_account, a.id);
  if p_packs is null or p_packs < 1 or p_packs > 999 then raise exception 'Packs must be between 1 and 999.'; end if;
  if not exists (select 1 from cps.accounts where id = target) then raise exception 'No such account.'; end if;

  select array_agg(cs.id order by cs.id), count(*)
    into v_pool, v_pool_n
    from cps.card_sets cs
   where cs.active and cs.id <> 'jumbled'
     and exists (select 1 from cps.cards c where c.set_id = cs.id);
  if v_pool_n = 0 then raise exception 'No sets in the random pool yet.'; end if;

  for rp in
    select d.pick as set_id, count(*)::int as cnt
      from (select v_pool[1 + floor(random() * v_pool_n)::int] as pick
              from generate_series(1, p_packs)) d
     group by d.pick
  loop
    perform cps.add_packs(target, rp.set_id, rp.cnt, 'admin_grant_random', null, a.id);
  end loop;
  if target <> a.id then
    perform cps.notify(target, 'gift_pack',
      'You''ve been gifted ' || case when p_packs = 1 then 'a random pack' else p_packs || ' random packs' end || '!',
      'packs');
  end if;
  return jsonb_build_object('account', target, 'packs_each', p_packs);
end $$;

grant execute on function public.cps_admin_grant_random_packs(text, int, uuid) to anon;

notify pgrst, 'reload schema';
