-- =====================================================================
-- PackRipper — migration 114: FIX cps_get_profile (repairs 113)
-- Run AFTER 113. 113 inserted the 'turned' field AFTER the closing
-- paren of jsonb_build_object in the 'sets' aggregate, turning it into
-- extra jsonb_agg arguments — every real profile call died with
-- 42883 'function jsonb_agg(jsonb, unknown, bigint) does not exist',
-- which the app reports as "server isn't ready". This rebuild is 108's
-- body with 'turned' inserted INSIDE the object (verified: removing
-- the insertion reproduces 108 byte-for-byte). Also removes the
-- temporary diagnostic session planted by diagnose-113-profile.sql.
-- =====================================================================

delete from cps.sessions where token_hash = cps.hash_text('diag-113-check-token-0001');

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
                'total', (select count(*) from cps.cards k where k.set_id = s.id),
                'turned', (select count(*) from cps.turn_ins t where t.account_id = tgt.id and t.set_id = s.id))
              order by s.name)
            from cps.card_sets s where s.active), '[]')
  );
end $$;

notify pgrst, 'reload schema';

-- Verify after running (needs any live session is NOT required — just
-- confirm the function exists; then open any profile in the app):
--   select proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--    where n.nspname = 'public' and proname = 'cps_get_profile';
