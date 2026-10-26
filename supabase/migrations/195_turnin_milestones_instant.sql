-- Migration 195: turn-in milestones ride the turn-in response.
-- The "Rarity Complete!" / "Collection Complete!" pop-ups were detected
-- by the ambient milestone_sync on the next state load, so they arrived
-- late (queued behind whatever modal was open by then). The 25/50/75/
-- 100% reward messages became instant in migration 179 by computing
-- them inside the turn-in transaction and returning them in the RPC
-- response, announced by the client in-flow. This does the same for
-- milestones: cps.milestone_fresh (156's sync logic, minus auth) runs
-- at the end of each turn-in RPC and the fresh milestones ride back in
-- a new 'milestones' response field. cps_milestone_sync is untouched
-- and stays as the safety net (its snapshot has already advanced, so
-- it finds nothing fresh). Client: milestones.announce() + one call
-- in each turn-in flow, right after the rewards announce.

-- Helper: compute + diff + advance the milestone snapshot for one
-- account (migration 156's sync logic, minus auth). Returns the sync
-- shape {baseline, fresh_rar, fresh_full}. Called by the turn-in RPCs
-- in-transaction so fresh milestones ride the turn-in response (the
-- migration-179 pattern that made the % reward messages instant);
-- cps_milestone_sync keeps its own copy of this logic as the ambient
-- safety net and simply finds nothing fresh afterwards.
create or replace function cps.milestone_fresh(p_account uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'cps', 'pg_temp'
as $fn$
declare
  v_rar        jsonb;
  v_full       jsonb;
  v_old_rar    jsonb;
  v_old_full   jsonb;
  v_fresh_rar  jsonb := '[]'::jsonb;
  v_fresh_full jsonb := '[]'::jsonb;
  k            text;
  v_cnt        bigint;
begin
  select count(*) into v_cnt from cps.turn_ins where account_id = p_account;

  select coalesce(jsonb_object_agg(key, true), '{}'::jsonb) into v_rar
    from (
      select t.set_id || ':' || t.rarity as key
        from (select set_id, rarity, count(*) as n
                from cps.cards group by set_id, rarity) t
        join (select ti.set_id, c.rarity, count(*) as n
                from cps.turn_ins ti
                join cps.cards c
                  on c.set_id = ti.set_id and c.card_id = ti.card_id
               where ti.account_id = p_account
               group by ti.set_id, c.rarity) u
          on u.set_id = t.set_id and u.rarity = t.rarity
       where u.n >= t.n
    ) s;

  select coalesce(jsonb_object_agg(set_id, true), '{}'::jsonb) into v_full
    from (
      select t.set_id
        from (select set_id, count(*) as n
                from cps.cards group by set_id) t
        join (select set_id, count(*) as n
                from cps.turn_ins
               where account_id = p_account
               group by set_id) u
          on u.set_id = t.set_id
       where u.n >= t.n
    ) s;

  -- First ever evaluation for this account: silent baseline (156).
  insert into cps.milestone_snapshots (account_id, rar, full_sets, ti_count)
  values (p_account, v_rar, v_full, v_cnt)
  on conflict (account_id) do nothing;
  if found then
    return jsonb_build_object('ok', true, 'baseline', true,
      'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
  end if;

  select rar, full_sets into v_old_rar, v_old_full
    from cps.milestone_snapshots
   where account_id = p_account
   for update;

  for k in select * from jsonb_object_keys(v_rar) loop
    if not (v_old_rar ? k) then
      v_fresh_rar := v_fresh_rar || jsonb_build_object(
        'set', split_part(k, ':', 1), 'rarity', split_part(k, ':', 2));
    end if;
  end loop;
  for k in select * from jsonb_object_keys(v_full) loop
    if not (v_old_full ? k) then
      v_fresh_full := v_fresh_full || to_jsonb(k);
    end if;
  end loop;

  update cps.milestone_snapshots
     set rar = v_rar, full_sets = v_full, ti_count = v_cnt, updated_at = now()
   where account_id = p_account;

  return jsonb_build_object('ok', true, 'baseline', false,
    'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
end $fn$;

CREATE OR REPLACE FUNCTION public.cps_turn_in(p_token text, p_set text, p_card text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a    cps.accounts%rowtype;
  c    cps.collection%rowtype;
  vn   int;
  avail int;
  plain_avail int;
  took_holo boolean := false;
  paid jsonb;
  ms   jsonb;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.cards where set_id = p_set and card_id = p_card) then
    raise exception 'Card not found.';
  end if;
  if exists (select 1 from cps.turn_ins where account_id = a.id and set_id = p_set and card_id = p_card) then
    raise exception 'This card is already turned in — that''s forever.';
  end if;
  select * into c from cps.collection
    where account_id = a.id and set_id = p_set and card_id = p_card for update;
  if not found then raise exception 'You don''t own this card.'; end if;
  select count(*) into vn from cps.variants
    where account_id = a.id and set_id = p_set and card_id = p_card;
  avail := c.count - c.vaulted_count - vn;
  if avail < 1 then
    raise exception 'No turn-in-able copy on hand — numbered and vaulted copies can''t be turned in.';
  end if;
  plain_avail := (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo);
  if plain_avail >= 1 then
    update cps.collection set count = count - 1
      where account_id = a.id and set_id = p_set and card_id = p_card;
  else
    update cps.collection set count = count - 1, holo_count = holo_count - 1
      where account_id = a.id and set_id = p_set and card_id = p_card;
    took_holo := true;
  end if;
  insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
    values (a.id, p_set, p_card, 'manual', took_holo);
  paid := cps.award_turnin_rewards_for(a.id, p_set);
  ms := cps.milestone_fresh(a.id);
  return jsonb_build_object('ok', true, 'holo', took_holo, 'turnin_rewards', paid, 'milestones', ms);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_turn_in_all(p_token text, p_set text, p_include_holos boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a    cps.accounts%rowtype;
  rec  record;
  c2   cps.collection%rowtype;
  vn   int;
  avail int;
  plain_avail int;
  turned int := 0;
  skipped_holo int := 0;
  skipped_locked int := 0;
  paid jsonb;
  ms   jsonb;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.card_sets where id = p_set) then
    raise exception 'That set is not on the server yet.';
  end if;
  for rec in
    select c.set_id, c.card_id, c.count, c.holo_count, c.vaulted_count, c.vaulted_holo
      from cps.collection c
     where c.account_id = a.id and c.set_id = p_set and c.count > 0
       and not exists (select 1 from cps.turn_ins t
                        where t.account_id = a.id and t.set_id = c.set_id and t.card_id = c.card_id)
     order by c.card_id
  loop
    select * into c2 from cps.collection
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id for update;
    if not found then continue; end if;
    rec.count := c2.count; rec.holo_count := c2.holo_count;
    rec.vaulted_count := c2.vaulted_count; rec.vaulted_holo := c2.vaulted_holo;
    select count(*) into vn from cps.variants
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    avail := rec.count - rec.vaulted_count - vn;
    if avail < 1 then
      skipped_locked := skipped_locked + 1;
    else
      plain_avail := (rec.count - rec.holo_count) - (rec.vaulted_count - rec.vaulted_holo);
      if plain_avail >= 1 then
        update cps.collection set count = count - 1
          where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
        insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
          values (a.id, rec.set_id, rec.card_id, 'bulk', false);
        turned := turned + 1;
      elsif coalesce(p_include_holos, false) then
        update cps.collection set count = count - 1, holo_count = holo_count - 1
          where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
        insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
          values (a.id, rec.set_id, rec.card_id, 'bulk', true);
        turned := turned + 1;
      else
        skipped_holo := skipped_holo + 1;
      end if;
    end if;
  end loop;
  paid := cps.award_turnin_rewards_for(a.id, p_set);
  ms := cps.milestone_fresh(a.id);
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked,
                            'turnin_rewards', paid, 'milestones', ms);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_turn_in_all_sets(p_token text, p_include_holos boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a    cps.accounts%rowtype;
  turned int := 0;
  skipped_holo int := 0;
  skipped_locked int := 0;
  sets_hit text[] := '{}';
  sid text;
  paid jsonb;
  ms   jsonb;
  by_set jsonb := '{}'::jsonb;
begin
  a := cps.auth(p_token);
  /* Set-based rewrite (183). The original loop re-read every candidate
     row FOR UPDATE and classified it with fresh values; this version
     classifies from one statement snapshot with the identical
     arithmetic and precedence, then applies one UPDATE + one INSERT.
     The UPDATE re-checks count >= 1 on the live row so a concurrent
     same-account action cannot drive a count negative; in that rare
     race the row is simply left for the next sweep (the original
     would have processed the other device's leftovers too). */
  with vn as (
    select set_id, card_id, count(*)::int as n
      from cps.variants where account_id = a.id group by set_id, card_id
  ),
  cls as (
    select c.set_id, c.card_id,
      case
        when c.count - c.vaulted_count - coalesce(vn.n, 0) < 1 then 'locked'
        when (c.count - c.holo_count) - (c.vaulted_count - c.vaulted_holo) >= 1 then 'plain'
        when coalesce(p_include_holos, false) then 'holo'
        else 'holo_skip'
      end as action
    from cps.collection c
    left join vn on vn.set_id = c.set_id and vn.card_id = c.card_id
    where c.account_id = a.id and c.count > 0
      and not exists (select 1 from cps.turn_ins t
                       where t.account_id = a.id and t.set_id = c.set_id and t.card_id = c.card_id)
  ),
  upd as (
    update cps.collection c
       set count = c.count - 1,
           holo_count = c.holo_count - (case when cls.action = 'holo' then 1 else 0 end)
      from cls
     where c.account_id = a.id and c.set_id = cls.set_id and c.card_id = cls.card_id
       and cls.action in ('plain', 'holo')
       and c.count >= 1
     returning c.set_id, c.card_id, cls.action
  ),
  ins as (
    insert into cps.turn_ins (account_id, set_id, card_id, via, holo)
    select a.id, u.set_id, u.card_id, 'bulk', (u.action = 'holo') from upd u
    returning set_id
  )
  select
    (select count(*) from ins)::int,
    (select count(*) from cls where action = 'holo_skip')::int,
    (select count(*) from cls where action = 'locked')::int,
    coalesce((select array_agg(distinct set_id) from ins), '{}')
  into turned, skipped_holo, skipped_locked, sets_hit;

  foreach sid in array sets_hit loop
    paid := cps.award_turnin_rewards_for(a.id, sid);
    if jsonb_array_length(paid) > 0 then
      by_set := by_set || jsonb_build_object(sid, paid);
    end if;
  end loop;
  ms := cps.milestone_fresh(a.id);
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked,
                            'turnin_rewards_by_set', by_set, 'milestones', ms);
end $function$;

