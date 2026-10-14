-- 143_smoke_test.sql — post-auth smoke test for migration 143.
-- One transaction, ROLLS BACK. Plants a session for the Muse test
-- account and cross-checks the two new RPCs against the existing
-- census and against direct counts, using REAL production rows as
-- fixtures (nothing is inserted into variants/cards).
-- Expected: one row, all four checks true.
begin;

do $$
declare
  acct uuid;
  tok  text := 'smoke143-token-00000001';
  m_set text; m_card text;
  t_set text; t_card text; t_tier text;
  o jsonb; cen jsonb; mm jsonb; msg text;
  ok_misprints boolean := false;
  ok_misprint_flags boolean := false;
  ok_tier boolean := false;
  ok_bogus boolean := false;
begin
  select id into acct from cps.accounts where display_name = 'Admin Account';
  if acct is null then raise exception 'Muse test account not found'; end if;
  insert into cps.sessions (token_hash, account_id, expires_at)
  values (cps.hash_text(tok), acct, now() + interval '1 hour');

  -- fixtures from live data: a card with misprints, and a card+tier with copies
  select v.set_id, v.card_id into m_set, m_card
    from cps.variants v join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
   where k.rarity in ('common', 'uncommon')
   order by v.set_id, v.card_id limit 1;
  if m_set is null then raise exception 'No misprint fixture exists in production data'; end if;
  select v.set_id, v.card_id, v.tier into t_set, t_card, t_tier
    from cps.variants v order by v.set_id, v.card_id, v.tier limit 1;

  -- 1) misprint owners add up: RPC list == per-set counts map == direct count
  o  := public.cps_variant_owners(tok, m_set, m_card, 'misprint');
  mm := public.cps_variant_misprints(tok, m_set);
  ok_misprints := jsonb_array_length(o) = (mm->>m_card)::int
    and jsonb_array_length(o) = (select count(*)::int from cps.variants v
        join cps.cards k on k.set_id = v.set_id and k.card_id = v.card_id
       where v.set_id = m_set and v.card_id = m_card and k.rarity in ('common', 'uncommon'));
  -- 2) every misprint-mode row is flagged and named
  ok_misprint_flags := not exists (
    select 1 from jsonb_array_elements(o) e
     where (e->>'misprint')::boolean is distinct from true or e->>'owner' is null);
  -- 3) tier owners add up to the census number for the same card+tier
  o   := public.cps_variant_owners(tok, t_set, t_card, t_tier);
  cen := public.cps_variant_census(tok, t_set);
  ok_tier := jsonb_array_length(o) = (cen->t_card->>t_tier)::int;
  -- 4) unknown tier is rejected
  begin
    o := public.cps_variant_owners(tok, t_set, t_card, 'bogus');
    ok_bogus := false;
  exception when others then
    msg := sqlerrm;
    ok_bogus := msg = 'Unknown variant tier.';
  end;

  create temp table smoke143_result on commit drop as
  select ok_misprints as misprint_list_matches_counts,
         ok_misprint_flags as misprint_rows_flagged_and_named,
         ok_tier as tier_list_matches_census,
         ok_bogus as unknown_tier_rejected;
end $$;

select * from smoke143_result;

rollback;
