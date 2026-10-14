-- 142_dupe_tiers.sql — Split the Shop's dupe melt into per-rarity tiers.
-- Was: 'epic' pooled Epic+Legendary+Chase at 4 dupes -> $1, so one click
-- melted Legendary and Chase dupes at the Epic rate. Now (Franklin,
-- 2026-10-14): Epic 4 -> $1 · Legendary 2 -> $1 · Chase 1 -> $2, each
-- tier sold separately. Common/Uncommon/Rare rates unchanged.
--
-- ALSO FIXES a latent under-deduction in the take math, which the new
-- Chase tier turns critical: the old formulas reserved the kept copy
-- by subtracting it AFTER capping the take, so a sale whose batch
-- ended inside a plain-only card removed one card FEWER than it paid
-- for (proven on PG16 stubs: a 9-copy card paid for 8 dupes, removed
-- 7). At the old rates that leaked one deferred dupe per sale; at
-- Chase's rate of 1 it would remove ZERO cards per sale — an infinite
-- $2 printer. The two take lines now cap the take at
-- (on-hand - keep) directly, so a sale removes exactly the cards it
-- pays for and always keeps keep_n copies.
--
-- Base body is migration 108's cps_trade_dupes_credit (the current
-- one: vault-aware counts + dupe_trade quest bump). Everything else —
-- totals formula, ordering, quest bump, result shape — is unchanged.
-- CREATE OR REPLACE keeps the existing grants; no other object moves.

create or replace function public.cps_trade_dupes_credit(p_token text, p_tier text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  rars      text[];
  rate      int;
  dollars   int;
  total     int;
  trades    int;
  need      int;
  rec       record;
  credit_now int;
begin
  a := cps.auth(p_token);
  if p_tier = 'common' then rars := array['common']; rate := 20; dollars := 1;
  elsif p_tier = 'uncommon' then rars := array['uncommon']; rate := 12; dollars := 1;
  elsif p_tier = 'rare' then rars := array['rare']; rate := 6; dollars := 1;
  elsif p_tier = 'epic' then rars := array['epic']; rate := 4; dollars := 1;
  elsif p_tier = 'legendary' then rars := array['legendary']; rate := 2; dollars := 1;
  elsif p_tier = 'chase' then rars := array['chase']; rate := 1; dollars := 2;
  else raise exception 'Unknown trade tier.'; end if;

  -- Total tradable dupes across ALL sets: every copy beyond the first.
  -- Numbered variants are never tradable (they have no dupe value).
  select coalesce(sum(greatest((c.count - c.vaulted_count) - greatest(1, coalesce(v.n, 0)), 0)), 0) into total
    from cps.collection c
    join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
    left join (select set_id, card_id, count(*) as n from cps.variants
               where account_id = a.id and not vaulted group by 1, 2) v
      on v.set_id = c.set_id and v.card_id = c.card_id
    where c.account_id = a.id
      and k.rarity = any (rars)
      and c.count > 0;

  trades := total / rate;
  if trades < 1 then
    raise exception 'Not enough duplicate cards — you need % per $% credit.', rate, dollars;
  end if;

  -- Deduct dupes: non-holos first, always keep one copy.
  need := trades * rate;
  for rec in
    select c.set_id, c.card_id, c.count as n, c.holo_count as h, coalesce(v.n, 0) as v,
             c.vaulted_count as vc, c.vaulted_holo as vh
      from cps.collection c
      join cps.cards k on k.set_id = c.set_id and k.card_id = c.card_id
      left join (select set_id, card_id, count(*) as n from cps.variants
                 where account_id = a.id and not vaulted group by 1, 2) v
        on v.set_id = c.set_id and v.card_id = c.card_id
      where c.account_id = a.id
        and k.rarity = any (rars)
        and (c.count - c.vaulted_count) > greatest(1, coalesce(v.n, 0))
      order by (c.count - coalesce(c.holo_count, 0)) desc, c.count desc
  loop
    exit when need <= 0;
    declare
      take_from_plain int;
      take_from_holo  int;
      keep_n          int := greatest(1, coalesce(rec.v, 0));
      n2              int := rec.n - rec.vc;              -- on-hand copies
      h2              int := coalesce(rec.h, 0) - rec.vh; -- on-hand holos
    begin
      -- keep keep_n copies (1 + variants); take from plain first, then holo
      take_from_plain := greatest(least((n2 - h2) - greatest(keep_n - h2, 0), need), 0);
      need := need - take_from_plain;
      take_from_holo := 0;
      if need > 0 and h2 > 0 then
        take_from_holo := greatest(least(h2 - greatest(keep_n - ((n2 - h2) - take_from_plain), 0), need), 0);
        need := need - take_from_holo;
      end if;
      update cps.collection
        set count = greatest(count - take_from_plain - take_from_holo, 0),
            holo_count = greatest(coalesce(holo_count, 0) - take_from_holo, 0)
        where account_id = a.id and set_id = rec.set_id and card_id = rec.card_id;
    end;
  end loop;

  -- Grant Store Credit: $dollars per trade ($1, except Chase at $2)
  update cps.accounts set store_credit = coalesce(store_credit, 0) + trades * dollars where id = a.id;
  select store_credit into credit_now from cps.accounts where id = a.id;

  -- Daily quest: 'Trade in duplicates' (dupe_trade)
  perform cps.quest_bump(a.id, 'dupe_trade', trades);

  return jsonb_build_object(
    'ok', true,
    'dupes_used', trades * rate,
    'credit', trades * dollars,
    'credit_now', credit_now
  );
end $$;
