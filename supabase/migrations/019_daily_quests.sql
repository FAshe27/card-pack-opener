-- =====================================================================
-- 019_daily_quests.sql — Daily Achievements.
--
--   5 quests per player per day (2 easy / 2 medium / 1 hard), reset at
--   America/Chicago midnight. Claim tickets per quest: easy 1, medium 2,
--   hard 3. Progress is bumped by pack opens, wheel spins, dupe trade-ins,
--   gifts and completed trades.
-- =====================================================================

-- --- table ----------------------------------------------------------------------
create table if not exists cps.daily_quests (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  day date not null,
  quest_key text not null,
  tier text not null,
  target int not null,
  progress int not null default 0,
  done boolean not null default false,
  meta jsonb not null default '{}',
  claimed_at timestamptz,
  primary key (account_id, day, quest_key)
);
create index if not exists idx_daily_quests_day on cps.daily_quests(day);

-- --- quest metadata helpers -------------------------------------------------------
create or replace function cps.quest_tier(p_key text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case when p_key in ('open_packs','open_packs_set','spin_wheel','dupe_trade') then 'easy'
              when p_key in ('pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done') then 'medium'
              else 'hard' end $$;
create or replace function cps.quest_tickets(p_tier text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_tier when 'easy' then 1 when 'medium' then 2 when 'hard' then 3 else 0 end $$;
create or replace function cps.quest_target(p_key text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_key when 'open_packs' then 3 when 'open_packs_set' then 2 when 'pull_holos_3' then 3 else 1 end $$;
create or replace function cps.quest_title(p_key text, p_meta jsonb) returns text
language plpgsql set search_path = cps, pg_temp as $$
declare sname text;
begin
  if p_key = 'open_packs_set' then
    select s.name into sname from cps.card_sets s where s.id = p_meta->>'set_id';
    return 'Open 2 ' || coalesce(sname, 'set') || ' packs';
  end if;
  return case p_key
    when 'open_packs' then 'Open 3 packs'
    when 'spin_wheel' then 'Spin the wheel'
    when 'dupe_trade' then 'Trade in duplicates'
    when 'pull_holo' then 'Pull a holo card'
    when 'pull_rare_plus' then 'Pull a Rare or better'
    when 'pull_epic_plus' then 'Pull an Epic or better'
    when 'gift_card' then 'Gift a card to a friend'
    when 'trade_done' then 'Complete a trade'
    when 'pull_legendary_plus' then 'Pull a Legendary or better'
    when 'pull_chase' then 'Pull a Chase card'
    when 'pull_variant' then 'Pull a numbered variant'
    when 'wheel_big_win' then 'Win 3+ packs in one spin'
    when 'pull_holos_3' then 'Pull 3 holo cards'
    else p_key end;
end $$;

-- --- deterministic daily assignment (2 easy / 2 medium / 1 hard) -------------------
create or replace function cps.assign_daily_quests(p_account uuid, p_day date)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare
  picked text[];
  k text; sid text;
begin
  if exists (select 1 from cps.daily_quests where account_id = p_account and day = p_day) then return; end if;
  perform setseed(('x' || substr(md5(p_account::text || p_day::text), 1, 8))::bit(32)::bigint / 4294967296.0);
  select array_agg(x) into picked from (
    (select x, 0 as o from unnest(array['open_packs','open_packs_set','spin_wheel','dupe_trade']) x order by random() limit 2)
    union all
    (select x, 1 as o from unnest(array['pull_holo','pull_rare_plus','pull_epic_plus','gift_card','trade_done']) x order by random() limit 2)
    union all
    (select x, 2 as o from unnest(array['pull_legendary_plus','pull_chase','pull_variant','wheel_big_win','pull_holos_3']) x order by random() limit 1)
  ) t;
  if 'open_packs_set' = any(picked) then
    select id into sid from cps.card_sets where active order by random() limit 1;
  end if;
  foreach k in array picked loop
    insert into cps.daily_quests (account_id, day, quest_key, tier, target, meta)
    values (p_account, p_day, k, cps.quest_tier(k), cps.quest_target(k),
            case when k = 'open_packs_set' then jsonb_build_object('set_id', sid) else '{}' end)
    on conflict do nothing;
  end loop;
end $$;

-- --- bump progress (called from game event hooks) ----------------------------------
create or replace function cps.quest_bump(p_account uuid, p_key text, p_inc int default 1, p_set text default null)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare d date := (now() at time zone 'America/Chicago')::date;
begin
  if coalesce(p_inc, 0) <= 0 then return; end if;
  perform cps.assign_daily_quests(p_account, d);
  update cps.daily_quests q
    set progress = least(q.progress + p_inc, q.target),
        done = least(q.progress + p_inc, q.target) >= q.target
    where q.account_id = p_account and q.day = d and q.quest_key = p_key
      and q.claimed_at is null
      and (p_set is null or q.meta->>'set_id' is null or q.meta->>'set_id' = p_set);
end $$;

-- --- list today's quests ------------------------------------------------------------
create or replace function public.cps_list_quests(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
begin
  a := cps.auth(p_token);
  perform cps.assign_daily_quests(a.id, d);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'key', q.quest_key, 'tier', q.tier, 'title', cps.quest_title(q.quest_key, q.meta),
      'target', q.target, 'progress', q.progress, 'done', q.done,
      'claimed', q.claimed_at is not null, 'tickets', cps.quest_tickets(q.tier))
      order by case q.tier when 'easy' then 0 when 'medium' then 1 else 2 end, q.quest_key)
    from cps.daily_quests q where q.account_id = a.id and q.day = d
  ), '[]');
end $$;

-- --- claim a completed quest ------------------------------------------------------------
create or replace function public.cps_claim_quest(p_token text, p_key text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
        q cps.daily_quests%rowtype; t int; n int;
begin
  a := cps.auth(p_token);
  select * into q from cps.daily_quests
    where account_id = a.id and day = d and quest_key = p_key for update;
  if not found then raise exception 'Quest not found.'; end if;
  if not q.done then raise exception 'Quest is not complete yet.'; end if;
  if q.claimed_at is not null then raise exception 'Already claimed.'; end if;
  t := cps.quest_tickets(q.tier);
  update cps.daily_quests set claimed_at = now()
    where account_id = a.id and day = d and quest_key = p_key;
  update cps.accounts set spins = spins + t where id = a.id returning spins into n;
  insert into cps.spin_grants (account_id, spins, reason, ref) values (a.id, t, 'quest', p_key);
  return jsonb_build_object('ok', true, 'tickets', t, 'spins_now', n);
end $$;

grant execute on function public.cps_list_quests(text) to anon;
grant execute on function public.cps_claim_quest(text, text) to anon;


-- --- hooked: open_pack --------------------------------------------------------
create or replace function public.cps_open_pack(p_token text, p_set text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; s cps.card_sets%rowtype; inv int; slot jsonb; i int; x float8; acc float8;
        r text; last_r text; k text; v text; cid text; holo boolean; picked text[] := '{}';
        out jsonb := '[]'; is_new boolean; prev_count int; st cps.user_set_stats%rowtype;
        best_score int; sc int; new_best jsonb; n_holo int := 0; by_r jsonb := '{}'; best_changed boolean := false;
        vidx int[]; vi int; vcid text; vt text; vtier text; vtiers text[]; vserial int; vx float8;
        vcardname text; vtext text;
begin
  a := cps.auth(p_token);
  select * into s from cps.card_sets where id = p_set and active;
  if not found then raise exception 'This set is not available online yet.'; end if;
  select packs into inv from cps.pack_inventory where account_id = a.id and set_id = p_set for update;
  if coalesce(inv, 0) < 1 then raise exception 'No packs left for this set.'; end if;
  update cps.pack_inventory set packs = packs - 1 where account_id = a.id and set_id = p_set returning packs into inv;

  select * into st from cps.user_set_stats where account_id = a.id and set_id = p_set for update;
  best_score := case when st.best is null then -1
                     else cps.rarity_rank((select rarity from cps.cards where set_id = p_set and card_id = st.best->>'id')) * 10
                          + case when (st.best->>'holo')::boolean then 5 else 0 end end;
  best_score := coalesce(best_score, -1);

  for slot in select value from jsonb_array_elements(s.pack->'slots') loop
    for i in 1..greatest(coalesce((slot->>'count')::int, 1), 1) loop
      x := cps.rand01(); acc := 0; r := null; last_r := null;
      for k, v in select key, value from jsonb_each_text(slot->'odds') order by cps.rarity_rank(key) loop
        acc := acc + v::float8; last_r := k;
        if x < acc then r := k; exit; end if;
      end loop;
      r := coalesce(r, last_r);
      select card_id into cid from cps.cards where set_id = p_set and rarity = r and not (card_id = any(picked)) order by random() limit 1;
      if cid is null then
        select card_id into cid from cps.cards where set_id = p_set and rarity = r order by random() limit 1;
      end if;
      if cid is null then raise exception 'Set % has no % cards on the server. Re-sync the set.', p_set, r; end if;
      holo := cps.rand01() * 100 < coalesce((s.pack->'holo'->>r)::float8, 0);
      picked := picked || cid;

      select count into prev_count from cps.collection where account_id = a.id and set_id = p_set and card_id = cid;
      is_new := coalesce(prev_count, 0) = 0;
      insert into cps.collection (account_id, set_id, card_id, count, holo_count)
        values (a.id, p_set, cid, 1, holo::int)
        on conflict (account_id, set_id, card_id) do update
          set count = cps.collection.count + 1, holo_count = cps.collection.holo_count + holo::int;

      sc := cps.rarity_rank(r) * 10 + case when holo then 5 else 0 end;
      if sc > best_score then
        best_score := sc; new_best := jsonb_build_object('id', cid, 'holo', holo, 'at', now());
        best_changed := st.best is not null or best_changed;
      end if;
      if holo then n_holo := n_holo + 1; end if;
      by_r := jsonb_set(by_r, array[r], to_jsonb(coalesce((by_r->>r)::int, 0) + 1));
      out := out || jsonb_build_object('id', cid, 'rarity', r, 'holo', holo, 'new', is_new);
    end loop;
  end loop;

  -- numbered variant lottery: 1% of packs; one random rare+ card becomes a variant
  vserial := null;
  if cps.rand01() < 0.01 then
    select array_agg(t.idx) into vidx from (
      select (row_number() over ()) - 1 as idx
      from jsonb_array_elements(out) e
      where e->>'rarity' in ('rare','epic','legendary','chase')
    ) t;
    if vidx is not null and coalesce(array_length(vidx, 1), 0) > 0 then
      vi := vidx[1 + floor(cps.rand01() * array_length(vidx, 1))::int];
      vcid := out->vi->>'id';
      vx := cps.rand01();
      vtier := case when vx < 0.70 then 'rainbow' when vx < 0.90 then 'prism' when vx < 0.98 then 'obsidian' else 'oneofone' end;
      vtiers := case vtier
        when 'rainbow' then array['rainbow']
        when 'prism' then array['prism','rainbow']
        when 'obsidian' then array['obsidian','prism','rainbow']
        else array['oneofone','obsidian','prism','rainbow'] end;
      foreach vt in array vtiers loop
        vserial := cps.mint_variant(a.id, p_set, vcid, vt);
        if vserial is not null then vtier := vt; exit; end if;
      end loop;
      if vserial is not null then
        out := (select jsonb_agg(case when t.rn = vi
            then t.e || jsonb_build_object('variant', vtier, 'serial', vserial)
            else t.e end order by t.rn)
          from (select e, (row_number() over ()) - 1 as rn from jsonb_array_elements(out) e) t);
        if vtier in ('prism','obsidian','oneofone') then
          select kk.name into vcardname from cps.cards kk where kk.set_id = p_set and kk.card_id = vcid;
          vtext := case vtier
            when 'oneofone' then '🌈 ' || a.display_name || ' pulled the One-of-One ' || vcardname || ' (' || s.name || ')!'
            when 'obsidian' then '🌈 ' || a.display_name || ' pulled Obsidian #' || vserial || '/5 ' || vcardname || ' (' || s.name || ')!'
            else '🌈 ' || a.display_name || ' pulled Prism #' || vserial || '/10 ' || vcardname || ' (' || s.name || ')!'
          end;
          insert into cps.notifications (account_id, kind, text, target_view)
            select xx.id, 'variant_pull', vtext, 'collection'
            from cps.accounts xx where xx.id <> a.id and not xx.disabled;
        end if;
      end if;
    end if;
  end if;

  -- daily quest bumps
  perform cps.quest_bump(a.id, 'open_packs', 1);
  perform cps.quest_bump(a.id, 'open_packs_set', 1, p_set);
  if n_holo > 0 then
    perform cps.quest_bump(a.id, 'pull_holo', n_holo);
    perform cps.quest_bump(a.id, 'pull_holos_3', n_holo);
  end if;
  perform cps.quest_bump(a.id, 'pull_rare_plus',
    coalesce((by_r->>'rare')::int, 0) + coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_epic_plus',
    coalesce((by_r->>'epic')::int, 0) + coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_legendary_plus',
    coalesce((by_r->>'legendary')::int, 0) + coalesce((by_r->>'chase')::int, 0));
  perform cps.quest_bump(a.id, 'pull_chase', coalesce((by_r->>'chase')::int, 0));
  if vserial is not null then perform cps.quest_bump(a.id, 'pull_variant', 1); end if;

  insert into cps.user_set_stats (account_id, set_id, opened, pulled, holos, by_rarity, best)
    values (a.id, p_set, 1, jsonb_array_length(out), n_holo, by_r, new_best)
    on conflict (account_id, set_id) do update set
      opened = cps.user_set_stats.opened + 1,
      pulled = cps.user_set_stats.pulled + excluded.pulled,
      holos  = cps.user_set_stats.holos + excluded.holos,
      by_rarity = (select coalesce(jsonb_object_agg(key, to_jsonb(total)), '{}') from (
                    select key, sum(value::int) as total from (
                      select * from jsonb_each_text(cps.user_set_stats.by_rarity)
                      union all select * from jsonb_each_text(excluded.by_rarity)) u group by key) t),
      best = coalesce(excluded.best, cps.user_set_stats.best);
  insert into cps.pack_openings (account_id, set_id, cards)
    values (a.id, p_set, (select jsonb_agg(jsonb_build_object('id', e->>'id', 'rarity', e->>'rarity', 'holo', (e->>'holo')::boolean)) from jsonb_array_elements(out) e));

  return jsonb_build_object('set_id', p_set, 'packs_left', inv, 'cards', out,
    'best', (select best from cps.user_set_stats where account_id = a.id and set_id = p_set), 'new_best', best_changed and new_best is not null);
end $$;

-- --- hooked: spin_wheel -------------------------------------------------------
create or replace function public.cps_spin_wheel(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  res       jsonb;
  prize     jsonb;
  packs_now int;
  spins_now int;
begin
  a := cps.auth(p_token);
  if coalesce(a.spins, 0) < 1 then
    raise exception 'No spins left. Ask an admin for more, or come back tomorrow for your daily spin.';
  end if;

  res := cps.roll_wheel();
  prize := res -> 'prize';

  update cps.accounts set spins = spins - 1 where id = a.id
    returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason, ref)
    values (a.id, -1, 'wheel', 'spin:' || (prize ->> 'set_id'));

  packs_now := cps.add_packs(a.id, prize ->> 'set_id', (prize ->> 'packs')::int, 'wheel', null, null);

  perform cps.quest_bump(a.id, 'spin_wheel', 1);
  if (prize->>'packs')::int >= 3 then perform cps.quest_bump(a.id, 'wheel_big_win', 1); end if;

  return jsonb_build_object(
    'ok', true,
    'hops', res -> 'hops',
    'prize', prize,
    'set_id', prize ->> 'set_id',
    'packs_won', (prize ->> 'packs')::int,
    'packs_now', packs_now,
    'spins_left', spins_now
  );
end $$;

-- --- hooked: trade_dupes ------------------------------------------------------
create or replace function public.cps_trade_dupes(p_token text, p_set text, p_tier text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  rars      text[];
  rate      int;
  total     int;
  trades    int;
  need      int;
  rec       record;
  take_nh   int;
  take_h    int;
  packs_now int;
  keep_n    int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 15;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 10;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 5;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 3;
  else raise exception 'Unknown trade tier.'; end if;
  if not exists (select 1 from cps.card_sets where id = p_set) then
    raise exception 'That set is not on the server yet.'; end if;

  select coalesce(sum(greatest(c.count - 1, 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    where c.account_id = a.id and c.set_id = p_set
      and k.rarity = any (rars) and c.count > 0;

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per pack.', rate; end if;

  need := trades * rate;
  for rec in
    select c.card_id, c.count as n, c.holo_count as h
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      where c.account_id = a.id and c.set_id = p_set
        and k.rarity = any (rars) and c.count > 1
      order by c.card_id
  loop
    exit when need <= 0;
    if rec.h > 0 then take_nh := least(rec.n - rec.h, need);
    else take_nh := least(greatest(rec.n - 1, 0), need);
    end if;
    need := need - take_nh;
    if rec.h > 0 then take_h := least(rec.h - 1, need);
    else take_h := 0;
    end if;
    need := need - take_h;
    keep_n := rec.n - take_nh - take_h;
    update cps.collection
       set count = keep_n,
           holo_count = rec.h - take_h
     where account_id = a.id and set_id = p_set and card_id = rec.card_id;
    -- destroyed copies take their serials with them (keep lowest serials)
    delete from cps.variants vv where vv.account_id = a.id and vv.set_id = p_set and vv.card_id = rec.card_id
      and vv.id not in (
        select id from cps.variants
        where account_id = a.id and set_id = p_set and card_id = rec.card_id
        order by serial limit (keep_n)
      );
  end loop;

  perform cps.quest_bump(a.id, 'dupe_trade', 1);

  packs_now := cps.add_packs(a.id, p_set, trades, 'dupe_trade', p_tier, null);

  return jsonb_build_object('ok', true, 'set_id', p_set, 'tier', p_tier,
    'trades', trades, 'dupes_used', trades * rate, 'packs_now', packs_now);
end $$;

-- --- hooked: gift_card --------------------------------------------------------
create or replace function public.cps_gift_card(p_token text, p_to uuid, p_set text, p_card text, p_holo boolean, p_variant_id uuid default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  tgt       cps.accounts%rowtype;
  card_name text;
  set_name  text;
  vtier     text;
  vserial   int;
  vlabel    text := '';
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot gift a card to yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  select k.name, s.name into card_name, set_name
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = p_set and k.card_id = p_card;
  if not found then raise exception 'Card not found.'; end if;
  if p_variant_id is not null then
    select vv.tier, vv.serial into vtier, vserial from cps.variants vv
      where vv.id = p_variant_id and vv.account_id = a.id and vv.set_id = p_set and vv.card_id = p_card;
    if not found then raise exception 'Variant not found.'; end if;
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
    update cps.variants set account_id = tgt.id where id = p_variant_id;
  else
    -- a regular copy: variants stay put (the gift modal picks serials explicitly)
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
  end if;
  if vtier is not null then
    vlabel := ' ' || cps.variant_name(vtier) || ' #' || vserial || '/' || cps.variant_run(vtier);
  end if;
  perform cps.notify(tgt.id, 'gift_card',
    a.display_name || ' gifted you ' || card_name || vlabel || ' (' || set_name || ')' ||
    case when vlabel = '' and coalesce(p_holo, false) then ' ✦ holo' else '' end,
    'collection');
  perform cps.quest_bump(a.id, 'gift_card', 1);
  return jsonb_build_object('ok', true);
end $$;

-- --- hooked: respond_trade ----------------------------------------------------
create or replace function public.cps_respond_trade(p_token text, p_offer uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  o   cps.trade_offers%rowtype;
  r   record;
  c   cps.collection%rowtype;
begin
  a := cps.auth(p_token);
  select * into o from cps.trade_offers where id = p_offer for update;
  if not found then raise exception 'Offer not found.'; end if;
  if o.to_account <> a.id then raise exception 'This offer is not for you.'; end if;
  if o.status <> 'pending' then raise exception 'This offer is no longer pending.'; end if;
  if o.expires_at < now() then
    update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
    raise exception 'This offer has expired.';
  end if;

  if not p_accept then
    update cps.trade_offers set status = 'declined', decided_at = now() where id = o.id;
    perform cps.notify(o.from_account, 'trade_declined', a.display_name || ' declined your trade', 'players');
    return jsonb_build_object('status', 'declined');
  end if;

  -- verify every line first (deterministic lock order: no deadlocks), then move cards
  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
    group by 1, 2, 3, 4 order by 1, 2, 3, 4
  loop
    select * into c from cps.collection
      where account_id = r.giver and set_id = r.set_id and card_id = r.card_id for update;
    if not found or c.count < r.qty
       or (r.holo and c.holo_count < r.qty)
       or (not r.holo and c.count - c.holo_count < r.qty) then
      update cps.trade_offers set status = 'expired', decided_at = now() where id = o.id;
      raise exception 'A card in this trade is no longer available.';
    end if;
  end loop;

  for r in
    select (case when i.side = 'offer' then o.from_account else o.to_account end) as giver,
           (case when i.side = 'offer' then o.to_account else o.from_account end) as receiver,
           i.set_id, i.card_id, i.holo, sum(i.qty)::int as qty
    from cps.trade_offer_items i where i.offer_id = o.id
    group by 1, 2, 3, 4, 5 order by 1, 3, 4, 5
  loop
    perform cps.transfer_card(r.giver, r.receiver, r.set_id, r.card_id, r.holo, r.qty, o.id::text);
  end loop;

  update cps.trade_offers set status = 'accepted', decided_at = now() where id = o.id;
  perform cps.quest_bump(o.from_account, 'trade_done', 1);
  perform cps.quest_bump(o.to_account, 'trade_done', 1);
  perform cps.notify(o.from_account, 'trade_accepted', a.display_name || ' accepted your trade', 'players');
  return jsonb_build_object('status', 'accepted');
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
