-- =====================================================================
-- 154_verify.sql -- post-run smoke test for 154. Run AFTER
-- 154_oneofone_provenance_fix.sql. Everything happens inside one
-- transaction that ROLLS BACK. Expect one row at the end:
-- 154 VERIFY PASS.
--
-- Unlike 153's verify, the fixture is planted in the shape
-- production ACTUALLY writes: a cps.big_pulls row for the pull,
-- and a cps.pack_openings row whose entries carry ONLY
-- {id, set_id, rarity, holo} -- no variant/serial stamps, because
-- cps_open_pack's stored insert has never kept them. If the
-- puller resolves here, it resolves for real pulls.
-- =====================================================================
begin;

insert into cps.sessions (token_hash, account_id, expires_at)
select cps.hash_text('smoke154-token-00000001'), id, now() + interval '1 hour'
  from cps.accounts where display_name = 'Admin Account';

do $$
declare
  v_admin  uuid;
  v_puller uuid;
  v_pname  text;
  v_set    text;
  v_card   text;
  v_rarity text;
  r        jsonb;
  o        jsonb;
  t        jsonb;
begin
  select id into v_admin from cps.accounts where display_name = 'Admin Account';
  if v_admin is null then raise exception 'VERIFY FAIL: no Admin Account fixture'; end if;

  -- a real player who has never pulled a One-of-One (so the
  -- trophy assertions below cannot collide with a real pull)
  select a.id, a.display_name into v_puller, v_pname
    from cps.accounts a
   where not a.is_admin and not a.disabled and a.id <> v_admin
     and not exists (select 1 from cps.big_pulls bp
                      where bp.account_id = a.id and bp.variant_tier = 'oneofone')
   order by a.id limit 1;
  if v_puller is null then raise exception 'VERIFY FAIL: no puller fixture'; end if;

  -- a card with no One-of-One variant and no big_pulls One-of-One
  select c.set_id, c.card_id, c.rarity into v_set, v_card, v_rarity
    from cps.cards c
   where not exists (select 1 from cps.variants v
                      where v.set_id = c.set_id and v.card_id = c.card_id
                        and v.tier = 'oneofone')
     and not exists (select 1 from cps.big_pulls bp
                      where bp.set_id = c.set_id and bp.card_id = c.card_id
                        and bp.variant_tier = 'oneofone')
   order by c.set_id, c.num limit 1;

  -- the pull, recorded the way cps_open_pack really records it:
  -- the variants row (already traded to the admin), a big_pulls
  -- row naming the puller, and a pack_openings row in the stored
  -- {id, set_id, rarity, holo} shape -- NO variant stamps.
  insert into cps.variants (account_id, set_id, card_id, tier, serial)
  values (v_admin, v_set, v_card, 'oneofone', 1);
  insert into cps.big_pulls (account_id, set_id, card_id, rarity, variant_tier, variant_serial)
  values (v_puller, v_set, v_card, v_rarity, 'oneofone', 1);
  insert into cps.pack_openings (account_id, set_id, cards)
  values (v_puller, v_set,
          jsonb_build_array(jsonb_build_object('id', v_card, 'set_id', v_set,
            'rarity', v_rarity, 'holo', false)));

  -- (b) the provenance line: puller must resolve despite the
  -- unstamped opening
  if cps.variant_puller(v_set, v_card, 'oneofone', 1) <> v_pname then
    raise exception 'VERIFY FAIL: variant_puller = % (expected %)',
      cps.variant_puller(v_set, v_card, 'oneofone', 1), v_pname;
  end if;

  r := public.cps_variant_census('smoke154-token-00000001', v_set);
  if r -> v_card ->> 'oneofone_by' <> 'Admin Account' then
    raise exception 'VERIFY FAIL: census owner = %', r -> v_card ->> 'oneofone_by';
  end if;
  if r -> v_card ->> 'oneofone_puller' <> v_pname then
    raise exception 'VERIFY FAIL: census puller = % (expected %)', r -> v_card ->> 'oneofone_puller', v_pname;
  end if;

  o := public.cps_variant_owners('smoke154-token-00000001', v_set, v_card, 'oneofone');
  if jsonb_array_length(o) <> 1 then raise exception 'VERIFY FAIL: owners rows = %', o; end if;
  if o -> 0 ->> 'puller' <> v_pname then
    raise exception 'VERIFY FAIL: owners puller = %', o -> 0 ->> 'puller';
  end if;

  -- (a) the trophy: the PULLER's case carries it even though the
  -- card now sits with the admin...
  t := public.cps_get_trophies('smoke154-token-00000001', v_puller);
  if t -> 'oneofone' ->> 'card_id' <> v_card then
    raise exception 'VERIFY FAIL: puller trophy = %', t -> 'oneofone';
  end if;
  -- ...and the current OWNER's case must NOT claim this card
  t := public.cps_get_trophies('smoke154-token-00000001', v_admin);
  if t -> 'oneofone' ->> 'card_id' = v_card then
    raise exception 'VERIFY FAIL: owner trophy stole the fixture card';
  end if;
end $$;

select '154 VERIFY PASS' as result;
rollback;
