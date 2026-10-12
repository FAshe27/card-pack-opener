-- =====================================================================
-- 079_dupe_credit.sql — Trade dupes for Store Credit (replaces ticket trade).
-- Same rates as the ticket trade: 20/12/6/4 dupes -> $1 Store Credit.
-- Cross-set (all sets pooled). Numbered variants never tradable.
-- =====================================================================

create or replace function public.cps_trade_dupes_credit(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  rars      text[];
  rate      int;
  total     int;
  trades    int;
  need      int;
  rec       record;
  credit_now int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 20;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 12;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 6;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 4;
  else raise exception 'Unknown trade tier.'; end if;

  -- Total tradable dupes across ALL sets: every copy beyond the first.
  -- Numbered variants are never tradable (they have no dupe value).
  select coalesce(sum(greatest(c.count - 1, 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    where c.account_id = a.id
      and k.rarity = any (rars)
      and c.count > 1
      and (k.numbered is null or k.numbered = false);

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per $1 credit.', rate;
  end if;

  -- Deduct dupes: non-holos first, always keep one copy.
  need := trades * rate;
  for rec in
    select c.set_id, c.card_id, c.count as n, c.holo_count as h
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      where c.account_id = a.id
        and k.rarity = any (rars)
        and c.count > 1
        and (k.numbered is null or k.numbered = false)
      order by (c.count - coalesce(c.holo_count, 0)) desc, c.count desc
  loop
    exit when need <= 0;
    declare
      take_from_plain int;
      take_from_holo  int;
      keep_one        int := 1;
    begin
      -- keep 1 copy; take from plain first, then holo
      take_from_plain := least(rec.n - coalesce(rec.h, 0), need);
      take_from_plain := greatest(take_from_plain - (case when coalesce(rec.h, 0) = 0 then keep_one else 0 end), 0);
      need := need - take_from_plain;
      take_from_holo := 0;
      if need > 0 and coalesce(rec.h, 0) > 0 then
        take_from_holo := least(coalesce(rec.h, 0) - (case when rec.n - coalesce(rec.h, 0) - take_from_plain = 0 then keep_one else 0 end), need);
        take_from_holo := greatest(take_from_holo, 0);
        need := need - take_from_holo;
      end if;
      update cps.collection
        set count = count - take_from_plain - take_from_holo,
            holo_count = coalesce(holo_count, 0) - take_from_holo
        where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    end;
  end loop;

  -- Grant $1 Store Credit per trade
  update cps.accounts set store_credit = store_credit + trades where id = a.id;
  select store_credit into credit_now from cps.accounts where id = a.id;

  return jsonb_build_object(
    'ok', true,
    'dupes_used', trades * rate,
    'credit', trades,
    'credit_now', credit_now
  );
end $$;

notify pgrst, 'reload schema';
