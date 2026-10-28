-- =====================================================================
-- 210: expose oauth_linked in cps.state_json's account object.
--
-- Franklin's ask (2026-10-27, OAuth ship night): hide the 'Link Google'
-- item in the account dropdown for accounts that already have Google
-- linked. The audit found the client cannot know linked state on the
-- boot/resume path: every state load flows through cps.state_json,
-- whose account object was {id, display_name, is_admin, hint} only.
--
-- What this does, and ONLY this: rebuilds cps.state_json from its
-- current live body with ONE insertion in the account object --
--   'oauth_linked', (a.auth_user_id is not null)
-- so S.account.oauth_linked is present on get_state / get_state_delta
-- and every refresh. No other function, table, or grant is touched.
-- (auth_user_id itself is NOT exposed -- only the boolean.)
--
-- Proofs before running (house discipline): insertion-only diff vs
-- the live pg_get_functiondef body (byte-for-byte after removing the
-- insert), paren-depth walk, pglast parse, local-Postgres smoke on
-- stub tables (linked -> true, unlinked -> false). Go: Franklin,
-- 2026-10-27 ('Actually, just go for it - I trust you').
-- =====================================================================

CREATE OR REPLACE FUNCTION cps.state_json(p_account uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint, 'oauth_linked', (a.auth_user_id is not null))
                from cps.accounts a where a.id = p_account),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = p_account), '{}'),
    'collection', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)) from cps.collection where account_id = p_account and count > 0), '[]'),
    'stats', coalesce((select jsonb_object_agg(set_id, jsonb_build_object('opened', opened, 'pulled', pulled, 'holos', holos, 'by_rarity', by_rarity, 'best', best))
                       from cps.user_set_stats where account_id = p_account), '{}'),
    'recent', coalesce((select jsonb_object_agg(set_id, items) from (
                select set_id, jsonb_agg(item order by ord) as items from (
                  select o.set_id, c.value || jsonb_build_object('at', (extract(epoch from o.opened_at) * 1000)::bigint) as item, row_number() over (partition by o.set_id order by o.opened_at desc, c.ordinality desc) as ord
                  from (select o0.account_id, o0.set_id, o0.opened_at, o0.cards
                          from (select o1.account_id, o1.set_id, o1.opened_at, o1.cards,
                                       coalesce(sum(jsonb_array_length(o1.cards)) over (partition by o1.set_id order by o1.opened_at desc, o1.id desc), 0)
                                         - jsonb_array_length(o1.cards) as prior_cards
                                  from cps.pack_openings o1
                                 where o1.account_id = p_account and o1.opened_at > now() - interval '120 days') o0
                         where o0.prior_cards < 36) o, jsonb_array_elements(o.cards) with ordinality c
                  where o.account_id = p_account and o.opened_at > now() - interval '120 days'
                ) x where ord <= 36 group by set_id) y), '{}'),
    'guest_imported', exists (select 1 from cps.guest_imports where account_id = p_account),
    'online_sets', coalesce((select jsonb_agg(id order by id) from cps.card_sets where active), '[]'),
    'spins', coalesce((select spins from cps.accounts where id = p_account), 0),
    'wheel', cps.wheel_config(),
    'favorites', coalesce((select jsonb_agg(jsonb_build_array(u.set_id, u.card_id) order by vo.position nulls last, u.set_id, u.card_id)
                           from (select set_id, card_id from cps.collection where account_id = p_account and vaulted_count > 0
                                 union
                                 select set_id, card_id from cps.variants where account_id = p_account and vaulted) u
                           left join cps.vault_order vo
                             on vo.account_id = p_account and vo.set_id = u.set_id and vo.card_id = u.card_id), '[]'),
    'turn_ins', coalesce((select jsonb_object_agg(g.set_id, g.ids)
                           from (select set_id, jsonb_agg(card_id order by card_id) as ids
                                   from cps.turn_ins where account_id = p_account
                                  group by set_id) g), '{}'),
    'ver', coalesce((select ver from cps.state_meta where account_id = p_account), 0),
    'gver', coalesce((select ver from cps.state_meta where account_id = '00000000-0000-0000-0000-000000000000'::uuid), 0)
  )
$function$
;
-- let the API pick up the new function right away
notify pgrst, 'reload schema';
