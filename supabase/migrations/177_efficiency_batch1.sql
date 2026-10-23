-- 177_efficiency_batch1.sql
-- Efficiency batch 1 (audit 2026-10-23). Read-path waste only; no behavior changes.
-- 1) GIN index on pack_openings.cards + containment pre-filter in cps_card_population:
--    was a full expansion of every opening in history per card view (10.8% of all DB time).
-- 2) cps.state_json 'recent' block: stop expanding every card element of the last 120 days
--    (63k elements for the largest account) to keep 36 per set; only openings that can
--    contribute to the top-36 are expanded now. Output proven identical for every account.
-- 3) cps_list_players / cps_admin_list_accounts: per-account correlated subqueries
--    (68+ executions per call) replaced by single-pass aggregates (list_players uses
--    |A union B| = |A| + |B| - |A and B| to skip the union dedup sorts entirely).
--    Outputs proven identical to the originals for every account.
-- 4) cps_market_nav: no longer runs the bounty/trade expiry WRITE sweeps on a badge read
--    (the market surfaces sweep themselves); counts exclude due items directly instead.
-- 5) NEW public.cps_get_balances: tiny balance read (spins/tokens/credit/packs) so the
--    arcade games stop downloading the full ~1.2 MB state just to resync one number.
--    (Client adoption in plinko/scratch/vaultbreaker is a separate follow-up push.)
-- NOT in this batch (audited, already fine): cps_list_quests (assign_daily_quests
-- self-gates on an EXISTS check) and cps_cotd_status (ensure_cotd_today self-gates).

create index if not exists pack_openings_cards_gin on cps.pack_openings using gin (cards jsonb_path_ops);

CREATE OR REPLACE FUNCTION public.cps_card_population(p_token text, p_set text, p_card text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'total', coalesce((select sum(c.count)::int from cps.collection c
                       join cps.accounts ac on ac.id = c.account_id
                       where c.set_id = p_set and c.card_id = p_card
                         and not ac.is_admin and not ac.disabled), 0),
    'holos', coalesce((select sum(c.holo_count)::int from cps.collection c
                       join cps.accounts ac on ac.id = c.account_id
                       where c.set_id = p_set and c.card_id = p_card
                         and not ac.is_admin and not ac.disabled), 0),
    'pulled', (select count(*) from cps.pack_openings o, jsonb_array_elements(o.cards) e
                       where o.cards @> jsonb_build_array(jsonb_build_object('set_id', p_set, 'id', p_card))
                         and e->>'set_id' = p_set and e->>'id' = p_card
                         and o.account_id in (select id from cps.accounts
                                                where not is_admin and not disabled))
  );
end $function$;

CREATE OR REPLACE FUNCTION cps.state_json(p_account uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'cps', 'pg_temp'
AS $function$
  select jsonb_build_object(
    'account', (select jsonb_build_object('id', a.id, 'display_name', a.display_name, 'is_admin', a.is_admin, 'hint', a.username_hint)
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
    'turn_ins', coalesce((select jsonb_agg(jsonb_build_array(set_id, card_id) order by set_id, card_id)
                           from cps.turn_ins where account_id = p_account), '[]')
  )
$function$;

CREATE OR REPLACE FUNCTION public.cps_list_players(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id,
      'display_name', x.display_name,
      'is_me', x.id = a.id,
      'favorites', coalesce(cv.n, 0) + coalesce(wv.n, 0) - coalesce(wvx.n, 0),
      'unique_cards', coalesce(c0.n, 0) + coalesce(ti.n, 0) - coalesce(tix.n, 0)
    ) order by x.display_name)
    from cps.accounts x
    left join (select account_id, count(*) as n from cps.collection where count > 0 group by account_id) c0 on c0.account_id = x.id
    left join (select account_id, count(*) as n from cps.turn_ins group by account_id) ti on ti.account_id = x.id
    left join (select t.account_id, count(*) as n from cps.turn_ins t
                 join cps.collection c on c.account_id = t.account_id and c.set_id = t.set_id and c.card_id = t.card_id and c.count > 0
                group by t.account_id) tix on tix.account_id = x.id
    left join (select account_id, count(*) as n from cps.collection where vaulted_count > 0 group by account_id) cv on cv.account_id = x.id
    left join (select account_id, count(*) as n from (select account_id, set_id, card_id from cps.variants where vaulted group by account_id, set_id, card_id) w group by account_id) wv on wv.account_id = x.id
    left join (select v.account_id, count(*) as n from (select account_id, set_id, card_id from cps.variants where vaulted group by account_id, set_id, card_id) v
                 join cps.collection c on c.account_id = v.account_id and c.set_id = v.set_id and c.card_id = v.card_id and c.vaulted_count > 0
                group by v.account_id) wvx on wvx.account_id = x.id
    where not x.disabled and not x.is_admin), '[]');
end $function$;
CREATE OR REPLACE FUNCTION public.cps_admin_list_accounts(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id, 'display_name', x.display_name, 'username', x.username, 'hint', x.username_hint,
      'is_admin', x.is_admin, 'disabled', x.disabled, 'has_pin', x.pin_hash is not null,
      'locked', coalesce(x.locked_until > now(), false), 'locked_until', x.locked_until,
      'created_at', x.created_at, 'last_login_at', x.last_login_at,
      'packs', coalesce(pk.p, '{}'),
      'spins', x.spins,
      'spins_done', coalesce(sd.n, 0),
      'tokens', coalesce(x.game_tokens, 0),
      'unique_cards', coalesce(uc.n, 0),
      'opened', coalesce(op.s, 0),
      'is_me', x.id = a.id) order by x.created_at)
    from cps.accounts x
    left join (select account_id, jsonb_object_agg(set_id, packs) as p
                 from cps.pack_inventory group by account_id) pk on pk.account_id = x.id
    left join (select account_id, count(*) as n
                 from cps.spin_grants where reason = 'wheel' group by account_id) sd on sd.account_id = x.id
    left join (select account_id, count(*) as n
                 from cps.collection where count > 0 group by account_id) uc on uc.account_id = x.id
    left join (select account_id, sum(opened) as s
                 from cps.user_set_stats group by account_id) op on op.account_id = x.id), '[]');
end $function$;

CREATE OR REPLACE FUNCTION public.cps_market_nav(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a            cps.accounts%rowtype;
  claimable    int;
  trade_offers int;
begin
  a := cps.auth(p_token);
  -- Expiry sweeps intentionally NOT run here: cps_list_bounties sweeps bounties and
  -- cps_trading_post / cps_trade_offer / cps_trade_accept sweep trades before any
  -- state is read or changed. The counts below exclude due items directly instead.

  select count(*) into claimable
    from cps.bounties bo
   where bo.status = 'open'
     and bo.poster <> a.id
     and (bo.expires_at is null or bo.expires_at >= now())
     and (
       (bo.want_serial is not null
        and exists (select 1 from cps.variants v
                     where v.account_id = a.id
                       and v.set_id = bo.want_set and v.card_id = bo.want_card
                       and v.tier = bo.want_tier and v.serial = bo.want_serial
                       and not coalesce(v.vaulted, false))
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and c.count >= 1))
       or
       (bo.want_serial is null and bo.want_tier is not null
        and exists (select 1 from cps.variants v
                     where v.account_id = a.id
                       and v.set_id = bo.want_set and v.card_id = bo.want_card
                       and v.tier = bo.want_tier
                       and not coalesce(v.vaulted, false))
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and c.count >= 1))
       or
       (bo.want_serial is null and bo.want_tier is null
        and exists (select 1 from cps.collection c
                     where c.account_id = a.id
                       and c.set_id = bo.want_set and c.card_id = bo.want_card
                       and case when bo.want_holo = 'holo'
                                then c.holo_count - c.vaulted_holo >= 1
                                else c.count - c.vaulted_count >= 1 end))
     );

  select count(*) into trade_offers
    from cps.trade_listings t
   where t.lister = a.id
     and t.status = 'open'
     and (t.expires_at is null or t.expires_at >= now())
     and exists (select 1 from cps.listing_offers o
                  where o.listing_id = t.id and o.status = 'open');

  return jsonb_build_object('claimable', claimable, 'trade_offers', trade_offers);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_get_balances(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'spins', coalesce(a.spins, 0),
    'game_tokens', coalesce(a.game_tokens, 0),
    'store_credit', coalesce(a.store_credit, 0),
    'packs', coalesce((select sum(packs) from cps.pack_inventory where account_id = a.id), 0));
end $function$;

