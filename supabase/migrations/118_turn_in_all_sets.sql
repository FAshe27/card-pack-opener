-- =====================================================================
-- PackRipper \u2014 migration 118: turn in cards from ALL sets
-- Run AFTER 108 + 111. Adds two global versions of the per-set bulk
-- turn-ins, for the Collection view's all-sets button row:
--
-- cps_turn_in_all_sets(p_include_holos): the full sweep \u2014 the body
-- of 108's cps_turn_in_all with the per-set filter removed. Flags
-- every not-yet-turned-in card the player owns in EVERY set, one copy
-- each (plain first; holo only with p_include_holos). Vaulted copies
-- and numbered variants are never touched.
--
-- cps_turn_in_dupes_all_sets(p_include_holos): the body of 111's
-- cps_turn_in_dupes with the per-set filter removed \u2014 every
-- not-yet-turned-in card with >= 2 fungible copies on hand, across
-- all sets, turns in ONE copy.
--
-- Both bodies are their per-set sources with exactly four edits each:
-- name, dropped p_set parameter, dropped set-exists check, loop
-- widened to all sets (ordered by set, card). Verified by diff.
-- =====================================================================

create or replace function public.cps_turn_in_all_sets(p_token text, p_include_holos boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
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
  return jsonb_build_object('ok', true, 'turned', turned,
                            'skipped_holo', skipped_holo, 'skipped_locked', skipped_locked);
end $$;

create or replace function public.cps_turn_in_dupes_all_sets(p_token text, p_include_holos boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a    cps.accounts%rowtype;
  rec  record;
  c2   cps.collection%rowtype;
  vn   int;
  avail int;
  plain_avail int;
  turned int := 0;
  skipped_holo int := 0;
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
    rec.count := c2.count; rec.holo_count := c2.holo_count;
    rec.vaulted_count := c2.vaulted_count; rec.vaulted_holo := c2.vaulted_holo;
    select count(*) into vn from cps.variants
      where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    avail := rec.count - rec.vaulted_count - vn;
    if avail < 2 then continue; end if;
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
  end loop;
  return jsonb_build_object('ok', true, 'turned', turned, 'skipped_holo', skipped_holo);
end $$;

notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_turn_in_all_sets(text, boolean) to anon;
    grant execute on function public.cps_turn_in_dupes_all_sets(text, boolean) to anon;
  end if;
end $$;
