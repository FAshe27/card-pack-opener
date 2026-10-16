-- =====================================================================
-- 160_admin_completion_notifications.sql
-- Same fix as 159, second door: cps_announce_set_completion (113)
-- broadcasts "🏆 <name> turned in EVERY card in <set>!" to every
-- other player when anyone completes a set turn-in — including
-- admin accounts. Per Franklin (2026-10-16): regular players
-- shouldn't see the admin account at all.
--
-- Change (ONE guard, function rebuilt from 113 verbatim): when the
-- completer is an admin, the broadcast is skipped and the function
-- returns announced=false. The cps.set_completions row is still
-- written first (dedupe + trophy logic rely on it), and non-admin
-- completions announce exactly as before. Plus the same one-time
-- cleanup for any set_complete notifications already delivered
-- about an admin account.
--
-- NOTE: Latest big pull needed NO fix — cps_global_pull_stats (115)
-- already excludes admin (and disabled) accounts from latest_big
-- and every All-Players aggregate.
-- =====================================================================

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
  -- Admin completions are not announced (Franklin, 2026-10-16): the
  -- completion row above still records (dedupe/trophies rely on it);
  -- only the broadcast is skipped.
  if coalesce(a.is_admin, false) then
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

-- ---------------------------------------------------------------------
-- One-time cleanup: remove existing admin set-completion broadcasts.
-- ---------------------------------------------------------------------
delete from cps.notifications n
 where n.kind = 'set_complete'
   and exists (select 1 from cps.accounts adm
                where adm.is_admin
                  and n.text like '🏆 ' || adm.display_name || ' turned in EVERY card in %');

notify pgrst, 'reload schema';

-- Verify (expect 0):
--   select count(*) from cps.notifications n
--    where n.kind = 'set_complete'
--      and exists (select 1 from cps.accounts adm
--                   where adm.is_admin
--                     and n.text like '🏆 ' || adm.display_name || ' turned in EVERY card in %');
