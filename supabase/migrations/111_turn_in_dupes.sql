-- =====================================================================
-- PackRipper — migration 111: "Turn in all cards with duplicates"
-- Run AFTER 108_turn_ins_vault.sql. Supersedes 109_vault_dupes.sql
-- (that one was a mistyped request — Franklin meant Turn In, not Vault).
-- If 109 was already run, this migration drops its function; if 109 was
-- never run, the drop is a no-op and 109 should simply be skipped.
--
-- cps_turn_in_dupes(p_set, p_include_holos): for every card in the set
-- that is NOT already turned in and where the player holds at least 2
-- fungible copies ON HAND (total - vaulted - numbered variants >= 2),
-- turn in ONE copy (plain first; a holo only when p_include_holos,
-- matching cps_turn_in_all). Turn-in is once per card by design — the
-- card is permanently flagged collected; remaining copies stay in the
-- collection. Numbered variants and vaulted copies are never touched.
-- Returns { turned: n, skipped_holo: n }.
-- =====================================================================

drop function if exists public.cps_vault_dupes(text, text);

create or replace function public.cps_turn_in_dupes(p_token text, p_set text, p_include_holos boolean)
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
    grant execute on function public.cps_turn_in_dupes(text, text, boolean) to anon;
  end if;
end $$;

-- Verify after running:
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and proname in ('cps_turn_in_dupes', 'cps_vault_dupes');
--   -> should return ONLY cps_turn_in_dupes.
