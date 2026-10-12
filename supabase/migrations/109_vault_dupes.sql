-- =====================================================================
-- PackRipper — migration 109: "Vault all cards with duplicates"
-- Run AFTER 108_turn_ins_vault.sql.
--
-- cps_vault_dupes(p_set): for every card in the set where the player
-- holds at least 2 fungible copies ON HAND (total - vaulted - numbered
-- variants >= 2), vault ONE copy (plain first, else holo — the same
-- rule as cps_vault_copy). Numbered variants are never touched by the
-- bulk action (vault those per serial in the card modal). Reversible:
-- copies can be released from the Vault at any time.
-- Returns { vaulted: n }.
-- =====================================================================

create or replace function public.cps_vault_dupes(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a    cps.accounts%rowtype;
  rec  record;
  vn   int;
  fungible int;
  plain_avail int;
  vaulted_n int := 0;
begin
  a := cps.auth(p_token);
  if not exists (select 1 from cps.card_sets where id = p_set) then
    raise exception 'That set is not on the server yet.';
  end if;

  for rec in
    select c.card_id, c.count, c.holo_count, c.vaulted_count, c.vaulted_holo
      from cps.collection c
     where c.account_id = a.id and c.set_id = p_set and c.count > 0
     order by c.card_id
  loop
    select count(*) into vn from cps.variants
      where account_id = a.id and set_id = p_set and card_id = rec.card_id;
    fungible := rec.count - rec.vaulted_count - vn;
    if fungible < 2 then continue; end if;
    plain_avail := (rec.count - rec.holo_count) - (rec.vaulted_count - rec.vaulted_holo);
    if plain_avail >= 1 then
      update cps.collection set vaulted_count = vaulted_count + 1
        where account_id = a.id and set_id = p_set and card_id = rec.card_id;
    else
      update cps.collection set vaulted_count = vaulted_count + 1, vaulted_holo = vaulted_holo + 1
        where account_id = a.id and set_id = p_set and card_id = rec.card_id;
    end if;
    vaulted_n := vaulted_n + 1;
  end loop;

  return jsonb_build_object('vaulted', vaulted_n);
end $$;

notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_vault_dupes(text, text) to anon;
  end if;
end $$;

-- Verify after running:
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and proname = 'cps_vault_dupes';
