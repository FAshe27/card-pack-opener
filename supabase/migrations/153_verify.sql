-- =====================================================================
-- 153_verify.sql -- post-run smoke test for 153. Run AFTER
-- 153_oneofone_provenance.sql. Everything happens inside one
-- transaction that ROLLS BACK: the planted session, the planted
-- One-of-One and its planted opening all vanish. Expect one row at
-- the end: 153 VERIFY PASS.
-- =====================================================================
begin;

insert into cps.sessions (token_hash, account_id, expires_at)
select cps.hash_text('smoke153-token-00000001'), id, now() + interval '1 hour'
  from cps.accounts where display_name = 'Admin Account';

do $$
declare
  v_admin  uuid;
  v_puller uuid;
  v_pname  text;
  v_set    text;
  v_card   text;
  r        jsonb;
  o        jsonb;
begin
  select id into v_admin from cps.accounts where display_name = 'Admin Account';
  if v_admin is null then raise exception 'VERIFY FAIL: no Admin Account fixture'; end if;
  select id, display_name into v_puller, v_pname
    from cps.accounts where not is_admin and not disabled and id <> v_admin
   order by id limit 1;
  -- a card with no One-of-One yet, so the fixture cannot collide
  -- with a real 1/1 (the first was pulled today!)
  select c.set_id, c.card_id into v_set, v_card
    from cps.cards c
   where not exists (select 1 from cps.variants v
                      where v.set_id = c.set_id and v.card_id = c.card_id
                        and v.tier = 'oneofone')
   order by c.set_id, c.num limit 1;

  -- the 1/1: owned by the admin, but PULLED by v_puller
  insert into cps.variants (account_id, set_id, card_id, tier, serial)
  values (v_admin, v_set, v_card, 'oneofone', 1);
  insert into cps.pack_openings (account_id, set_id, cards)
  values (v_puller, v_set,
          jsonb_build_array(jsonb_build_object('id', v_card, 'set_id', v_set,
            'rarity', 'rare', 'holo', false, 'variant', 'oneofone', 'serial', 1)));

  r := public.cps_variant_census('smoke153-token-00000001', v_set);
  if r -> v_card ->> 'oneofone_by' <> 'Admin Account' then
    raise exception 'VERIFY FAIL: census owner = %', r -> v_card ->> 'oneofone_by';
  end if;
  if r -> v_card ->> 'oneofone_puller' <> v_pname then
    raise exception 'VERIFY FAIL: census puller = % (expected %)', r -> v_card ->> 'oneofone_puller', v_pname;
  end if;

  o := public.cps_variant_owners('smoke153-token-00000001', v_set, v_card, 'oneofone');
  if jsonb_array_length(o) <> 1 then raise exception 'VERIFY FAIL: owners rows = %', o; end if;
  if o -> 0 ->> 'puller' <> v_pname then
    raise exception 'VERIFY FAIL: owners puller = %', o -> 0 ->> 'puller';
  end if;
  if o -> 0 ->> 'owner' <> 'Admin Account' then
    raise exception 'VERIFY FAIL: owners owner = %', o -> 0 ->> 'owner';
  end if;
end $$;

select '153 VERIFY PASS' as result;
rollback;
