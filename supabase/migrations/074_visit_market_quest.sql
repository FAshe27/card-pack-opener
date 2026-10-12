-- =====================================================================
-- 074_visit_market_quest.sql — replace the 'Complete a trade' daily with
-- 'Visit the Market' (easy tier). The quest bumps whenever the Buyers or
-- Sellers list loads.
-- NOTE: takes effect on the next daily reset; today's rows are unchanged.
-- =====================================================================

create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade',
                             'open_jumbled','pull_dupe','pull_holo_common','pull_letter',
                             'pull_token_slip','win_3_rounds','pull_spin_ticket',
                             'win_slots','visit_market') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card',
                             'pull_3_sets','bank_5_streak') then 'medium'
              when p_key = 'bank_10_streak' then 'ultra'
              else 'hard' end $$;

create or replace function cps.quest_title(p_key text, p_meta jsonb) returns text
language plpgsql set search_path = cps, pg_temp as $$
declare sname text;
begin
  if p_key = 'open_packs_set' then
    select s.name into sname from cps.card_sets s where s.id = p_meta->>'set_id';
    return 'Open 2 ' || coalesce(sname, 'set') || ' packs';
  end if;
  if p_key = 'pull_letter' then
    return 'Pull a card with "' || coalesce(p_meta->>'letter', '?') || '" in the name';
  end if;
  return case p_key
    when 'open_packs' then 'Open 3 packs'
    when 'spin_wheel' then 'Spin the wheel'
    when 'dupe_trade' then 'Trade in duplicates'
    when 'pull_holo' then 'Pull a holo card'
    when 'pull_rare_plus' then 'Pull a Rare or better'
    when 'pull_epic_plus' then 'Pull an Epic or better'
    when 'gift_card' then 'Gift a card to a friend'
    when 'visit_market' then 'Visit the Market'
    when 'pull_legendary_plus' then 'Pull a Legendary or better'
    when 'pull_chase' then 'Pull a Chase card'
    when 'pull_variant' then 'Pull a numbered variant'
    when 'wheel_big_win' then 'Win 3+ packs from one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    when 'open_jumbled' then 'Open a Jumbled Mess pack'
    when 'pull_dupe' then 'Pull a duplicate card'
    when 'pull_holo_common' then 'Pull a holo Common'
    when 'pull_3_sets' then 'Pull cards from 3 different sets'
    when 'pull_2_holos_pack' then 'Pull 2 holos in one pack'
    when 'pull_token_slip' then 'Pull a Token Slip'
    when 'win_3_rounds' then 'Win 3 Rounds of Higher/Lower'
    when 'pull_spin_ticket' then 'Pull a Spin Ticket'
    when 'bank_5_streak' then 'Bank and Claim a 5+ Streak in Higher/Lower'
    when 'bank_10_streak' then 'Bank and Claim a 10+ Streak in Higher/Lower'
    when 'win_slots' then 'Win on Slots'
    else p_key end;
end $$;

create or replace function cps.quest_reward_currency(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('pull_token_slip','win_3_rounds','bank_5_streak','bank_10_streak',
                             'win_slots')
    then 'token' else 'ticket' end $$;

create or replace function cps.quest_reward_amount(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case
    when p_key = 'pull_token_slip' then 3
    when p_key = 'win_3_rounds' then 3
    when p_key = 'win_slots' then 5
    when p_key = 'bank_5_streak' then 5
    when p_key = 'bank_10_streak' then 15
    when cps.quest_tier(p_key) = 'easy' then 1
    when cps.quest_tier(p_key) = 'medium' then 2
    else 3 end $$;

create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  k text; sid text; vletter text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  -- deterministic featured set per account per day
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select id into sid from cps.card_sets where active order by random() limit 1;
  -- deterministic random letter per account per day (A-Z)
  perform setseed(('x' || substr(md5('letter' || p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select chr(65 + floor(random() * 26)::int) into vletter;
  foreach k in array array['open_packs','open_packs_set','spin_wheel','dupe_trade',
    'pull_holo','pull_rare_plus','pull_epic_plus','gift_card','visit_market',
    'pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3',
    'open_jumbled','pull_dupe','pull_holo_common','pull_letter','pull_3_sets','pull_2_holos_pack',
    'pull_token_slip','win_3_rounds','pull_spin_ticket','bank_5_streak','bank_10_streak',
    'win_slots'] loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid)
                 when k = 'pull_letter' then jsonb_build_object('letter', vletter)
                 else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

create or replace function public.cps_list_bounties(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  b       record;
  c       cps.collection%rowtype;
  can     boolean;
  items   jsonb;
  arr     jsonb := '[]';
  my_open int;
begin
  a := cps.auth(p_token);
  perform cps.bounty_expire_due();
  perform cps.quest_bump(a.id, 'visit_market', 1);

  select count(*) into my_open from cps.bounties where poster = a.id and status = 'open';

  for b in
    select bo.*, ac.display_name as poster_name,
           k.name as card_name, k.rarity as card_rarity,
           s.name as set_name, s.code as set_code
    from cps.bounties bo
    join cps.accounts ac on ac.id = bo.poster
    left join cps.cards k on k.set_id = bo.want_set and k.card_id = bo.want_card
    left join cps.card_sets s on s.id = bo.want_set
    where bo.status = 'open'
    order by bo.created_at desc
  loop
    -- can the viewer fill it? (server-side; the client also disables the button)
    can := false;
    if b.poster <> a.id then
      if b.want_serial is not null then
        can := exists (select 1 from cps.variants
                       where account_id = a.id and set_id = b.want_set and card_id = b.want_card
                         and tier = b.want_tier and serial = b.want_serial);
      else
        select * into c from cps.collection
          where account_id = a.id and set_id = b.want_set and card_id = b.want_card;
        if found then
          can := case when b.want_holo = 'holo' then c.holo_count >= 1 else c.count >= 1 end;
        end if;
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
             'set_id', e.set_id, 'card_id', e.card_id, 'holo', e.holo, 'qty', e.qty,
             'card_name', kk.name, 'rarity', kk.rarity, 'set_name', ss.name)
           order by ss.name, kk.name), '[]') into items
      from cps.bounty_escrow e
      left join cps.cards kk on kk.set_id = e.set_id and kk.card_id = e.card_id
      left join cps.card_sets ss on ss.id = e.set_id
      where e.bounty_id = b.id;

    arr := arr || jsonb_build_object(
      'id', b.id, 'poster', b.poster_name, 'poster_id', b.poster, 'mine', b.poster = a.id,
      'want_set', b.want_set, 'want_card', b.want_card, 'want_holo', b.want_holo,
      'want_tier', b.want_tier, 'want_serial', b.want_serial,
      'card_name', b.card_name, 'rarity', b.card_rarity,
      'set_name', b.set_name, 'set_code', b.set_code,
      'offer_tokens', b.offer_tokens, 'offer_tickets', b.offer_tickets,
      'offer_pack_set', b.offer_pack_set, 'offer_packs', b.offer_packs,
      'offer_cards', items,
      'can_claim', can,
      'created_at', b.created_at, 'expires_at', b.expires_at);
  end loop;

  return jsonb_build_object('bounties', arr, 'my_open', my_open);
end $$;

-- API grants (anon key, like the other user RPCs)
grant execute on function public.cps_post_bounty(text, jsonb, jsonb) to anon;
grant execute on function public.cps_claim_bounty(text, uuid) to anon;
grant execute on function public.cps_cancel_bounty(text, uuid) to anon;
grant execute on function public.cps_list_bounties(text) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';

create or replace function public.cps_trading_post(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  out jsonb := '[]'::jsonb;
  lj  jsonb;
  oj  jsonb;
  l   record;
  o   record;
  my_open int;
begin
  a := cps.auth(p_token);
  perform cps.trade_expire_due();
  perform cps.quest_bump(a.id, 'visit_market', 1);

  for l in
    select t.*, ac.display_name as lister_name,
           k.name as card_name, s.name as set_name, k.rarity as rarity,
           (select count(*) from cps.listing_offers ofr
             where ofr.listing_id = t.id and ofr.status = 'open') as offer_count,
           (select ofr.id from cps.listing_offers ofr
             where ofr.listing_id = t.id and ofr.offerer = a.id and ofr.status = 'open'
             limit 1) as my_offer_id
    from cps.trade_listings t
    join cps.accounts ac on ac.id = t.lister
    left join cps.cards k on k.set_id = t.set_id and k.card_id = t.card_id
    left join cps.card_sets s on s.id = t.set_id
    where t.status = 'open'
    order by t.created_at desc
  loop
    oj := '[]'::jsonb;
    for o in
      select ofr.*, ac2.display_name as offerer_name,
             ps.name as pack_name
      from cps.listing_offers ofr
      join cps.accounts ac2 on ac2.id = ofr.offerer
      left join cps.card_sets ps on ps.id = ofr.pack_set
      where ofr.listing_id = l.id and ofr.status = 'open'
      order by ofr.created_at asc
    loop
      oj := oj || jsonb_build_object(
        'id', o.id, 'offerer', o.offerer_name, 'offerer_id', o.offerer,
        'mine', o.offerer = a.id,
        'tokens', o.tokens, 'tickets', o.tickets,
        'pack_set', o.pack_set, 'packs', o.packs, 'pack_name', o.pack_name,
        'cards', coalesce(o.cards, '[]'::jsonb),
        'created_at', o.created_at);
    end loop;
    lj := jsonb_build_object(
      'id', l.id, 'lister', l.lister_name, 'lister_id', l.lister,
      'mine', l.lister = a.id,
      'set_id', l.set_id, 'set_name', l.set_name,
      'card_id', l.card_id, 'card_name', l.card_name, 'rarity', l.rarity,
      'holo', l.holo, 'variant_tier', l.variant_tier, 'variant_serial', l.variant_serial,
      'note', l.note, 'expires_at', l.expires_at,
      'offer_count', l.offer_count, 'my_offer', l.my_offer_id,
      'offers', oj);
    out := out || lj;
  end loop;

  select count(*) into my_open from cps.trade_listings where lister = a.id and status = 'open';
  return jsonb_build_object('listings', out, 'my_open', my_open);
end $$;

notify pgrst, 'reload schema';
