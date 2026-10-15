-- =====================================================================
-- 156_verify.sql — post-run smoke test for 156. Run AFTER
-- 156_milestone_seen_sync.sql. Everything happens inside one
-- transaction that ROLLS BACK: planted sessions and turn-ins vanish.
-- Expect one row at the end: 156 VERIFY PASS.
--
-- Checks, in order:
--   1. First cps_milestone_sync for an account is a silent baseline
--      (baseline=true, nothing fresh) — even for an account that
--      already has completions.
--   2. After planting turn-ins that complete one rarity, the next
--      sync reports exactly that rarity as fresh (and not the set).
--   3. THE CROSS-DEVICE CHECK: an immediate second sync (what a
--      phone logging in after the PC would call) reports NOTHING
--      fresh — the pop-up can only ever fire on the first device.
--   4. Completing the whole set reports the set in fresh_full once,
--      and a repeat sync reports nothing.
--   5. A different account still gets its own silent baseline first
--      (snapshots are per-account).
--   6. A bogus token is rejected by cps.auth.
-- =====================================================================
begin;

insert into cps.sessions (token_hash, account_id, expires_at)
select cps.hash_text('smoke156-token-admin-01'), id, now() + interval '1 hour'
  from cps.accounts where display_name = 'Admin Account';
insert into cps.sessions (token_hash, account_id, expires_at)
select cps.hash_text('smoke156-token-other-02'), id, now() + interval '1 hour'
  from cps.accounts
 where not is_admin and not disabled
 order by id limit 1;

do $$
declare
  v_admin  uuid;
  v_set    text;
  v_rarity text;
  r        jsonb;
begin
  select id into v_admin from cps.accounts where display_name = 'Admin Account';
  if v_admin is null then raise exception 'VERIFY FAIL: no Admin Account fixture'; end if;

  -- Start from no snapshot for Admin (rolled back afterwards).
  delete from cps.milestone_snapshots where account_id = v_admin;

  -- 1. first sync = silent baseline
  r := public.cps_milestone_sync('smoke156-token-admin-01');
  if coalesce((r ->> 'baseline')::boolean, false) is not true
     or jsonb_array_length(r -> 'fresh_rar') <> 0
     or jsonb_array_length(r -> 'fresh_full') <> 0 then
    raise exception 'VERIFY FAIL: first sync not a silent baseline: %', r;
  end if;

  -- Pick the smallest rarity pool that (a) its set has other cards
  -- too, so completing the rarity does not complete the set, and
  -- (b) Admin has not already completed (else there is nothing to
  -- plant and the crossing check below would see no change).
  select t.set_id, t.rarity into v_set, v_rarity
    from (select set_id, rarity, count(*) as n from cps.cards
           group by set_id, rarity) t
    join (select set_id, count(*) as n from cps.cards group by set_id) s
      on s.set_id = t.set_id
   where s.n > t.n
     and (select count(*) from cps.turn_ins ti
           join cps.cards c
             on c.set_id = ti.set_id and c.card_id = ti.card_id
          where ti.account_id = v_admin
            and ti.set_id = t.set_id and c.rarity = t.rarity) < t.n
   order by t.n asc, t.set_id, t.rarity
   limit 1;
  if v_set is null then raise exception 'VERIFY FAIL: no rarity-pool fixture'; end if;

  -- 2. plant turn-ins completing that rarity; next sync reports it
  insert into cps.turn_ins (account_id, set_id, card_id, via)
  select v_admin, set_id, card_id, 'manual'
    from cps.cards
   where set_id = v_set and rarity = v_rarity
  on conflict do nothing;

  r := public.cps_milestone_sync('smoke156-token-admin-01');
  if coalesce((r ->> 'baseline')::boolean, true) is not false
     or jsonb_array_length(r -> 'fresh_rar') <> 1
     or (r -> 'fresh_rar' -> 0 ->> 'set') <> v_set
     or (r -> 'fresh_rar' -> 0 ->> 'rarity') <> v_rarity
     or jsonb_array_length(r -> 'fresh_full') <> 0 then
    raise exception 'VERIFY FAIL: crossing sync wrong: % (expected fresh %:%)', r, v_set, v_rarity;
  end if;

  -- 3. second device: nothing fresh, ever
  r := public.cps_milestone_sync('smoke156-token-admin-01');
  if jsonb_array_length(r -> 'fresh_rar') <> 0
     or jsonb_array_length(r -> 'fresh_full') <> 0 then
    raise exception 'VERIFY FAIL: second sync replayed a milestone: %', r;
  end if;

  -- 4. complete the whole set; fresh_full fires once, then silence
  insert into cps.turn_ins (account_id, set_id, card_id, via)
  select v_admin, set_id, card_id, 'manual'
    from cps.cards
   where set_id = v_set
  on conflict do nothing;

  r := public.cps_milestone_sync('smoke156-token-admin-01');
  if not (r -> 'fresh_full' @> to_jsonb(v_set)) then
    raise exception 'VERIFY FAIL: full-set sync missing % in fresh_full: %', v_set, r;
  end if;
  r := public.cps_milestone_sync('smoke156-token-admin-01');
  if jsonb_array_length(r -> 'fresh_rar') <> 0
     or jsonb_array_length(r -> 'fresh_full') <> 0 then
    raise exception 'VERIFY FAIL: full-set milestone replayed: %', r;
  end if;

  -- 5. another account: its first sync is still its own baseline
  r := public.cps_milestone_sync('smoke156-token-other-02');
  if coalesce((r ->> 'baseline')::boolean, false) is not true then
    raise exception 'VERIFY FAIL: other account first sync not baseline: %', r;
  end if;

  -- 6. bogus token rejected
  begin
    r := public.cps_milestone_sync('smoke156-token-BOGUS');
    raise exception 'VERIFY FAIL: bogus token was accepted: %', r;
  exception when others then
    if sqlerrm like 'VERIFY FAIL%' then raise; end if;
    -- expected: auth raises (28000 Not logged in)
  end;
end $$;

select '156 VERIFY PASS' as result;
rollback;
