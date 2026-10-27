-- =====================================================================
-- PackRipper — migration 208: profile turned-in cards
-- cps_get_profile gains 'turned_cards': every card the profile owner
-- has turned in (set_id, card_id, holo), straight from cps.turn_ins.
-- The profile Collection screen switches from on-hand cards to
-- turned-in cards; it needs the per-card list, not just per-set counts.
-- Body is migration 180's verbatim except the one inserted key
-- (verified: removing the insertion reproduces 180 byte-for-byte).
-- =====================================================================

CREATE OR REPLACE FUNCTION public.cps_get_profile(p_token text, p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
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
    'turned_cards', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', t.set_id, 'card_id', t.card_id, 'holo', t.holo)
              order by t.set_id, t.card_id)
            from cps.turn_ins t where t.account_id = tgt.id), '[]'),
    'pack_inventory', coalesce((select jsonb_agg(jsonb_build_object(
                'set_id', pi.set_id, 'packs', pi.packs) order by pi.set_id)
              from cps.pack_inventory pi
              where pi.account_id = tgt.id and pi.packs > 0 and pi.set_id <> 'jumbled'), '[]'),
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
end $function$
;

NOTIFY pgrst, 'reload schema';
