-- =====================================================================
-- 006_dupe_trade_rates.sql — new trade-in rates: 15 common / 10 uncommon /
-- 5 rare / 3 epic+ dupes -> 1 pack. Replaces cps_trade_dupes (works whether
-- or not 005 was already applied).
-- =====================================================================

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
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 15;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 10;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 5;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 3;
  else raise exception 'Unknown trade tier.';
  end if;
  if not exists (select 1 from cps.card_sets where id = p_set) then
    raise exception 'That set is not on the server yet.';
  end if;

  -- Total tradable dupes: every copy beyond the first of each card.
  select coalesce(sum(greatest(c.count - 1, 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    where c.account_id = a.id and c.set_id = p_set
      and k.rarity = any (rars) and c.count > 0;

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per pack.', rate;
  end if;

  -- Deduct dupes: non-holos first, always keep one copy (a holo if we have one).
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
    update cps.collection
       set count = rec.n - take_nh - take_h,
           holo_count = rec.h - take_h
     where account_id = a.id and set_id = p_set and card_id = rec.card_id;
  end loop;

  packs_now := cps.add_packs(a.id, p_set, trades, 'dupe_trade', p_tier, null);

  return jsonb_build_object('ok', true, 'set_id', p_set, 'tier', p_tier,
    'trades', trades, 'dupes_used', trades * rate, 'packs_now', packs_now);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';

-- anon key needs execute rights on the function
grant execute on function public.cps_trade_dupes(text, text, text) to anon;
