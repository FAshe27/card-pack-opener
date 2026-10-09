-- =====================================================================
-- 016_variants.sql — numbered card variants (parallels).
--
--   Tiers: rainbow /50, prism /10, obsidian /5, oneofone 1/1. Rare+ only.
--   1% of packs: one random rare+ card becomes a variant with a unique serial.
--   Prism/Obsidian/One-of-One pulls notify every other player.
--   Variants travel with their base card through trades and gifts.
-- =====================================================================

-- --- tables -------------------------------------------------------------------
create table if not exists cps.variant_counters (
  set_id text not null,
  card_id text not null,
  tier text not null,
  issued int not null default 0,
  primary key (set_id, card_id, tier),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);
create table if not exists cps.variants (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id text not null,
  card_id text not null,
  tier text not null,
  serial int not null,
  pulled_at timestamptz not null default now(),
  unique (set_id, card_id, tier, serial),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);
create index if not exists idx_variants_acct on cps.variants(account_id);
create index if not exists idx_variants_card on cps.variants(set_id, card_id);

-- --- tier helpers ----------------------------------------------------------------
create or replace function cps.variant_run(p_tier text) returns int
language sql immutable set search_path = cps, pg_temp as $$
  select case p_tier when 'rainbow' then 50 when 'prism' then 10
         when 'obsidian' then 5 when 'oneofone' then 1 else 0 end $$;
create or replace function cps.variant_name(p_tier text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select case p_tier when 'rainbow' then 'Rainbow' when 'prism' then 'Prism'
         when 'obsidian' then 'Obsidian' when 'oneofone' then 'One-of-One' else p_tier end $$;

-- --- mint one variant copy; returns the serial, or null when sold out ---------------
create or replace function cps.mint_variant(p_account uuid, p_set text, p_card text, p_tier text)
returns int language plpgsql set search_path = cps, pg_temp as $$
declare run int := cps.variant_run(p_tier); n int;
begin
  if run = 0 then return null; end if;
  insert into cps.variant_counters (set_id, card_id, tier, issued)
    values (p_set, p_card, p_tier, 0)
    on conflict (set_id, card_id, tier) do nothing;
  select issued into n from cps.variant_counters
    where set_id = p_set and card_id = p_card and tier = p_tier for update;
  if n >= run then return null; end if;
  update cps.variant_counters set issued = issued + 1
    where set_id = p_set and card_id = p_card and tier = p_tier;
  insert into cps.variants (account_id, set_id, card_id, tier, serial)
    values (p_account, p_set, p_card, p_tier, n + 1);
  return n + 1;
end $$;

-- --- transfer_card: variants travel with their base card (lowest serials first) -----
drop function if exists cps.transfer_card(uuid, uuid, text, text, boolean, int, text);
create or replace function cps.transfer_card(p_from uuid, p_to uuid, p_set text, p_card text, p_holo boolean, p_qty int, p_ref text default null, p_move_variants boolean default true)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare r cps.collection%rowtype;
begin
  if p_qty < 1 then raise exception 'qty must be positive'; end if;
  select * into r from cps.collection where account_id = p_from and set_id = p_set and card_id = p_card for update;
  if not found or r.count < p_qty or (p_holo and r.holo_count < p_qty) or (not p_holo and r.count - r.holo_count < p_qty) then
    raise exception 'Not enough copies to transfer';
  end if;
  update cps.collection set count = count - p_qty, holo_count = holo_count - case when p_holo then p_qty else 0 end
    where account_id = p_from and set_id = p_set and card_id = p_card;
  insert into cps.collection (account_id, set_id, card_id, count, holo_count)
    values (p_to, p_set, p_card, p_qty, case when p_holo then p_qty else 0 end)
    on conflict (account_id, set_id, card_id) do update
      set count = cps.collection.count + excluded.count, holo_count = cps.collection.holo_count + excluded.holo_count;
  insert into cps.card_transfers (from_account, to_account, set_id, card_id, holo, qty, trade_ref)
    values (p_from, p_to, p_set, p_card, p_holo, p_qty, p_ref);
  if p_move_variants then
    update cps.variants v set account_id = p_to
      where v.id in (
        select id from cps.variants
        where account_id = p_from and set_id = p_set and card_id = p_card
        order by serial limit (p_qty)
      );
  end if;
  -- a gifted/traded-away last copy can't stay favorited
  delete from cps.favorites f
    where f.account_id = p_from and f.set_id = p_set and f.card_id = p_card
      and not exists (select 1 from cps.collection c
                      where c.account_id = p_from and c.set_id = p_set and c.card_id = p_card and c.count > 0);
end $$;

-- --- open_pack: numbered variant lottery (1% of packs) --------------------------------
-- (001's body, unchanged, plus the lottery block before the stats insert)
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

-- --- trade_dupes: a destroyed variant copy takes its serial with it -----------------
-- (006's body, unchanged, plus variant trim inside the deduction loop)
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

  packs_now := cps.add_packs(a.id, p_set, trades, 'dupe_trade', p_tier, null);

  return jsonb_build_object('ok', true, 'set_id', p_set, 'tier', p_tier,
    'trades', trades, 'dupes_used', trades * rate, 'packs_now', packs_now);
end $$;

-- --- gift_card: optional specific variant serial --------------------------------------
drop function if exists public.cps_gift_card(text, uuid, text, text, boolean);
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
  return jsonb_build_object('ok', true);
end $$;

-- --- variant census for a set ----------------------------------------------------------
create or replace function public.cps_variant_census(p_token text, p_set text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_object_agg(t.card_id, jsonb_build_object(
      'rainbow', t.rainbow, 'prism', t.prism, 'obsidian', t.obsidian, 'oneofone', t.oneofone,
      'oneofone_by', t.oneofone_by))
    from (
      select v.card_id,
        count(*) filter (where v.tier = 'rainbow')::int as rainbow,
        count(*) filter (where v.tier = 'prism')::int as prism,
        count(*) filter (where v.tier = 'obsidian')::int as obsidian,
        count(*) filter (where v.tier = 'oneofone')::int as oneofone,
        max(acc.display_name) filter (where v.tier = 'oneofone') as oneofone_by
      from cps.variants v join cps.accounts acc on acc.id = v.account_id
      where v.set_id = p_set
      group by v.card_id
    ) t
  ), '{}');
end $$;

-- --- my variants --------------------------------------------------------------------------
create or replace function public.cps_list_variants(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', v.id, 'set_id', v.set_id, 'set_name', s.name,
      'card_id', v.card_id, 'card_name', k.name, 'rarity', k.rarity,
      'tier', v.tier, 'serial', v.serial, 'pulled_at', v.pulled_at)
      order by v.pulled_at desc)
    from cps.variants v
    join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
    join cps.card_sets s on s.id = v.set_id
    where v.account_id = a.id
  ), '[]');
end $$;

grant execute on function public.cps_variant_census(text, text) to anon;
grant execute on function public.cps_list_variants(text) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
