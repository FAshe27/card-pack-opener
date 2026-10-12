-- =====================================================================
-- PackRipper — migration 112: completion milestones + profile turn-ins
-- Run AFTER 108_turn_ins_vault.sql and 111_turn_in_dupes.sql.
--
-- COMPLETION (for milestones) = every card in the set TURNED IN
-- (Franklin's definition — collected/owned does not count).
--
-- 1. cps_get_profile rebuilt from 108 verbatim + one field: each set in
--    the profile payload gains 'turned' (turn-in count for that set),
--    so profile stat lines can show turned-in counts/percentages.
-- 2. cps.set_completions: one row per (account, set) ever announced.
-- 3. cps_announce_set_completion(p_set): the client calls this when it
--    detects a full-set turn-in completion. The server VERIFIES the
--    completion (turn_ins count = card count for the set), records it
--    (exactly-once), and broadcasts a notification to every other
--    player — the same mechanism as chase-pull announcements.
-- =====================================================================

create or replace function public.cps_get_profile(p_token text, p_account uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  tgt cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  select * into tgt from cps.accounts where id = p_account and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  return jsonb_build_object(
    'id', tgt.id,
    'display_name', tgt.display_name,
    'is_me', tgt.id = a.id,
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', u.set_id,
                'card_id', u.card_id,
                'holo', coalesce((select c.holo_count > 0 from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), false),
                'v', coalesce((select c.vaulted_count from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), 0),
                'vh', coalesce((select c.vaulted_holo from cps.collection c
                                  where c.account_id = tgt.id and c.set_id = u.set_id
                                    and c.card_id = u.card_id), 0))
              order by vo.position nulls last, u.set_id, u.card_id)
            from (select set_id, card_id from cps.collection where account_id = tgt.id and vaulted_count > 0
                  union
                  select set_id, card_id from cps.variants where account_id = tgt.id and vaulted) u
            left join cps.vault_order vo
              on vo.account_id = tgt.id and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'collection', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', c.set_id, 'card_id', c.card_id, 'n', c.count, 'h', c.holo_count, 'v', c.vaulted_count, 'vh', c.vaulted_holo,
                'variants', coalesce((select jsonb_agg(jsonb_build_object(
                                        'tier', v.tier, 'serial', v.serial, 'vaulted', v.vaulted)
                                      order by v.serial)
                                    from cps.variants v
                                    where v.account_id = tgt.id
                                      and v.set_id = c.set_id
                                      and v.card_id = c.card_id), '[]'))
              order by c.set_id, c.card_id)
            from cps.collection c where c.account_id = tgt.id and c.count > 0), '[]'),
    'sets', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', s.id,
                'set_name', s.name,
                'unique', (select count(*) from (
                            select card_id from cps.collection c
                             where c.account_id = tgt.id and c.set_id = s.id and c.count > 0
                            union
                            select card_id from cps.turn_ins t
                             where t.account_id = tgt.id and t.set_id = s.id) u),
                'total', (select count(*) from cps.cards k where k.set_id = s.id)),
                'turned', (select count(*) from cps.turn_ins t where t.account_id = tgt.id and t.set_id = s.id)
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $$;

create table if not exists cps.set_completions (
  account_id   uuid not null references cps.accounts(id) on delete cascade,
  set_id       text not null references cps.card_sets(id) on delete cascade,
  announced_at timestamptz not null default now(),
  primary key (account_id, set_id)
);

create or replace function public.cps_announce_set_completion(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a     cps.accounts%rowtype;
  sname text;
  total int;
  turned int;
  ins   int := 0;
begin
  a := cps.auth(p_token);
  select name into sname from cps.card_sets where id = p_set and active;
  if sname is null then raise exception 'That set is not on the server yet.'; end if;
  select count(*) into total from cps.cards where set_id = p_set;
  select count(*) into turned from cps.turn_ins where account_id = a.id and set_id = p_set;
  if total = 0 or turned < total then
    return jsonb_build_object('ok', true, 'announced', false, 'turned', turned, 'total', total);
  end if;
  insert into cps.set_completions (account_id, set_id) values (a.id, p_set)
    on conflict do nothing;
  get diagnostics ins = row_count;
  if ins = 0 then
    return jsonb_build_object('ok', true, 'announced', false, 'turned', turned, 'total', total);
  end if;
  insert into cps.notifications (account_id, kind, text, target_view)
    select xx.id, 'set_complete',
           '🏆 ' || a.display_name || ' turned in EVERY card in ' || sname ||
           ' — the complete ' || total || '-card collection!',
           'collection'
      from cps.accounts xx where xx.id <> a.id and not xx.disabled;
  return jsonb_build_object('ok', true, 'announced', true, 'turned', turned, 'total', total);
end $$;

notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_announce_set_completion(text, text) to anon;
  end if;
end $$;

-- Verify after running:
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and proname in ('cps_get_profile', 'cps_announce_set_completion');
--   select count(*) from cps.set_completions;  -- 0 until someone completes a set
