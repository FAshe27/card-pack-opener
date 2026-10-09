-- =====================================================================
-- 025_variant_safe_tradein.sql
--   1. Numbered variant copies can no longer be destroyed by dupe
--      trade-ins (per-set or cross-set): trade-ins keep every variant copy.
--   2. New cps_trade_dupes_tickets: trade dupes pooled across ALL sets for
--      wheel spin tickets (20 common / 12 uncommon / 6 rare / 4 epic+ per ticket).
-- (Run after 024.)
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
  take_total int;
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

  -- tradable dupes: keep one copy of each card, and never take numbered variant copies
  select coalesce(sum(greatest(c.count - greatest(1, coalesce(v.n, 0)), 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    left join (select set_id, card_id, count(*) as n from cps.variants
               where account_id = a.id group by 1, 2) v
      on v.set_id = c.set_id and v.card_id = c.card_id
    where c.account_id = a.id and c.set_id = p_set
      and k.rarity = any (rars) and c.count > 0;

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per pack.', rate; end if;

  need := trades * rate;
  for rec in
    select c.card_id, c.count as n, c.holo_count as h, coalesce(v.n, 0) as v
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      left join (select set_id, card_id, count(*) as n from cps.variants
                 where account_id = a.id group by 1, 2) v
        on v.set_id = c.set_id and v.card_id = c.card_id
      where c.account_id = a.id and c.set_id = p_set
        and k.rarity = any (rars) and c.count > 1
      order by c.card_id
  loop
    exit when need <= 0;
    -- numbered variant copies are never traded in: keep every one of them
    keep_n := least(rec.n, greatest(1, rec.v));
    take_total := least(need, greatest(rec.n - keep_n, 0));
    take_nh := least(greatest(rec.n - rec.h, 0), take_total);
    take_h := take_total - take_nh;
    need := need - take_total;
    update cps.collection
       set count = rec.n - take_total,
           holo_count = rec.h - take_h
     where account_id = a.id and set_id = p_set and card_id = rec.card_id;
  end loop;

  perform cps.quest_bump(a.id, 'dupe_trade', 1);

  packs_now := cps.add_packs(a.id, p_set, trades, 'dupe_trade', p_tier, null);

  return jsonb_build_object('ok', true, 'set_id', p_set, 'tier', p_tier,
    'trades', trades, 'dupes_used', trades * rate, 'packs_now', packs_now);
end $$;

-- --- cross-set dupe trade-in for spin tickets ---------------------------------------
create or replace function public.cps_trade_dupes_tickets(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a          cps.accounts%rowtype;
  rars       text[];
  rate       int;
  total      int;
  tickets    int;
  need       int;
  rec        record;
  take_total int;
  take_nh    int;
  take_h     int;
  keep_n     int;
  spins_now  int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 20;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 12;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 6;
  elsif p_tier = 'epic' then rars := array['epic','legendary','chase']; rate := 4;
  else raise exception 'Unknown trade tier.'; end if;

  -- tradable dupes across all sets (keep one copy; never take numbered variants)
  select coalesce(sum(greatest(c.count - greatest(1, coalesce(v.n, 0)), 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    left join (select set_id, card_id, count(*) as n from cps.variants
               where account_id = a.id group by 1, 2) v
      on v.set_id = c.set_id and v.card_id = c.card_id
    where c.account_id = a.id and k.rarity = any (rars) and c.count > 0;

  tickets := total / rate;
  if tickets < 1 then
    raise exception 'Not enough duplicate cards — you need % per spin ticket.', rate; end if;

  need := tickets * rate;
  -- deduct from the sets with the most dupes first
  for rec in
    select c.set_id, c.card_id, c.count as n, c.holo_count as h, coalesce(v.n, 0) as v
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      left join (select set_id, card_id, count(*) as n from cps.variants
                 where account_id = a.id group by 1, 2) v
        on v.set_id = c.set_id and v.card_id = c.card_id
      where c.account_id = a.id and k.rarity = any (rars) and c.count > 1
      order by (c.count - greatest(1, coalesce(v.n, 0))) desc, c.set_id, c.card_id
  loop
    exit when need <= 0;
    -- numbered variant copies are never traded in: keep every one of them
    keep_n := least(rec.n, greatest(1, rec.v));
    take_total := least(need, greatest(rec.n - keep_n, 0));
    take_nh := least(greatest(rec.n - rec.h, 0), take_total);
    take_h := take_total - take_nh;
    need := need - take_total;
    update cps.collection
       set count = rec.n - take_total,
           holo_count = rec.h - take_h
     where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
  end loop;

  perform cps.quest_bump(a.id, 'dupe_trade', 1);

  update cps.accounts set spins = spins + tickets where id = a.id returning spins into spins_now;
  insert into cps.spin_grants (account_id, spins, reason) values (a.id, tickets, 'dupe_tickets');

  return jsonb_build_object('ok', true, 'tier', p_tier,
    'tickets', tickets, 'dupes_used', tickets * rate, 'spins_now', spins_now);
end $$;

grant execute on function public.cps_trade_dupes_tickets(text, text) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
