-- 179_turnin_rewards_instant.sql
-- Turn-In Rewards (25/50/75/100% of a set) used to be paid only by a
-- client-driven pass after a full state load (js/turninrewards.js), so
-- crossing a threshold during a turn-in surfaced the pop-up and prizes
-- only after further loads -- sometimes much later. This migration moves
-- the award INTO the turn-in RPCs: the same transaction that records the
-- turn-in pays anything owed and returns it in the response, and the
-- client announces it on the spot. The award core moves verbatim into
-- cps.award_turnin_rewards_for(account, set); the public award RPC
-- becomes a thin wrapper over it, so the load-time check keeps working
-- as the safety net (backpay, other devices) with identical behavior.

CREATE OR REPLACE FUNCTION cps.award_turnin_rewards_for(p_account uuid, p_set text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  total   int;
  turned  int;
  need    int;
  th      int;
  res     jsonb;
  paid    jsonb := '[]'::jsonb;
begin
  if p_set is null or p_set = 'jumbled' then
    return paid;
  end if;
  if not exists (select 1 from cps.card_sets where id = p_set and active) then
    return paid;
  end if;
  select count(*) into total from cps.cards where set_id = p_set;
  if total = 0 then
    return paid;
  end if;
  select count(*) into turned
    from cps.turn_ins where account_id = p_account and set_id = p_set;
  foreach th in array array[25, 50, 75, 100] loop
    need := (total * th + 99) / 100;
    if turned >= need then
      res := cps.pay_turnin_reward(p_account, p_set, th, 'turnin_reward');
      if (res ->> 'paid')::boolean then paid := paid || res; end if;
    end if;
  end loop;
  return paid;
end $function$;

CREATE OR REPLACE FUNCTION public.cps_award_turnin_rewards(p_token text, p_set text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a       cps.accounts%rowtype;
  sname   text;
  total   int;
  turned  int;
  paid    jsonb;
begin
  a := cps.auth(p_token);
  if p_set is null or p_set = 'jumbled' then
    return jsonb_build_object('ok', true, 'paid', '[]'::jsonb);
  end if;
  select name into sname from cps.card_sets where id = p_set and active;
  if sname is null then
    return jsonb_build_object('ok', true, 'paid', '[]'::jsonb);
  end if;
  paid := cps.award_turnin_rewards_for(a.id, p_set);
  select count(*) into total from cps.cards where set_id = p_set;
  select count(*) into turned
    from cps.turn_ins where account_id = a.id and set_id = p_set;
  return jsonb_build_object('ok', true, 'set', p_set, 'set_name', sname,
    'turned', turned, 'total', total, 'paid', paid);
end $function$;

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
  return jsonb_build_object('ok', true, 'holo', took_holo, 'turnin_rewards', paid);
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
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked,
                            'turnin_rewards', paid);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_turn_in_all_sets(p_token text, p_include_holos boolean)
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
  sets_hit text[] := '{}';
  before_n int := 0;
  sid text;
  paid jsonb;
  by_set jsonb := '{}'::jsonb;
begin
  a := cps.auth(p_token);
  for rec in
    select c.set_id, c.card_id, c.count, c.holo_count, c.vaulted_count, c.vaulted_holo
      from cps.collection c
     where c.account_id = a.id and c.count > 0
       and not exists (select 1 from cps.turn_ins t
                        where t.account_id = a.id and t.set_id = c.set_id and t.card_id = c.card_id)
     order by c.set_id, c.card_id
  loop
    select * into c2 from cps.collection
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id for update;
    if not found then continue; end if;
    before_n := turned;
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
    if turned > before_n and not (rec.set_id = any(sets_hit)) then
      sets_hit := sets_hit || rec.set_id;
    end if;
  end loop;
  foreach sid in array sets_hit loop
    paid := cps.award_turnin_rewards_for(a.id, sid);
    if jsonb_array_length(paid) > 0 then
      by_set := by_set || jsonb_build_object(sid, paid);
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked,
                            'turnin_rewards_by_set', by_set);
end $function$;
