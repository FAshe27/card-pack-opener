-- =====================================================================
-- 156_milestone_seen_sync.sql — turn-in milestone pop-ups fire ONCE
-- per account, across every device (Franklin's report 2026-10-15:
-- "If I get it on the PC, I shouldn't get the pop-up again when I log
-- in on my phone later. The rewards don't duplicate — it's literally
-- just the pop-up message.")
--
-- Root cause: js/milestones.js diffed the turned-in state against a
-- snapshot kept in localStorage ('cps.milestones.v1.<account>'), which
-- is per browser/device. Any device whose stored snapshot predated a
-- crossing saw that crossing as "fresh" on its next visit and popped
-- the 🎉 Rarity Complete / 🏆 Collection Complete pop-up again. (The
-- 🎁 Turn-In Reward pop-up never had this bug: it only fires for
-- prizes cps_award_turnin_rewards actually paid in that call, and the
-- server dedupes payment via cps.turnin_rewards.)
--
-- Fix: the snapshot moves server-side, one row per account in
-- cps.milestone_snapshots. The new RPC cps_milestone_sync:
--   * computes the account's current completions from the server's
--     own ledgers (cps.turn_ins joined to cps.cards — turn_ins is one
--     row per turned-in card, cards carries the rarity, so rarity and
--     full-set completion are exact);
--   * on the FIRST call for an account, stores the current state as a
--     silent baseline and reports nothing fresh — the old per-device
--     baseline semantics, but global: completions that already exist
--     never pop retroactively, on any device;
--   * on later calls, returns only the completions that are new since
--     the stored snapshot, then advances the snapshot — all inside one
--     transaction with the row locked, so when two devices race, the
--     first caller gets the fresh list and every other caller gets
--     nothing. Exactly one device ever pops a given milestone.
--   Turn-ins are permanent, so completions are monotonic and a plain
--   overwrite of the snapshot is safe.
--
-- Client (js/milestones.js, shipped with this migration): check() now
-- asks cps_milestone_sync and pops only what it returns. If the RPC
-- is missing or a call fails, the client stays silent and the server
-- snapshot is untouched, so a fresh milestone stays fresh and pops on
-- the next successful load instead of being lost. The old localStorage
-- snapshot is ignored (and removed) by the new client.
--
-- Deployment order: run this migration FIRST, then push the client.
-- (An old client against this migration is harmless — it just keeps
-- using its local snapshot. A new client before this migration pops
-- nothing, and milestones crossed in the gap baseline silently on the
-- first sync after the migration lands.)
-- =====================================================================

create table if not exists cps.milestone_snapshots (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  rar        jsonb not null default '{}'::jsonb,  -- {"<set>:<rarity>": true}
  full_sets  jsonb not null default '{}'::jsonb,  -- {"<set>": true}
  updated_at timestamptz not null default now(),
  primary key (account_id)
);

create or replace function public.cps_milestone_sync(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a            cps.accounts%rowtype;
  v_rar        jsonb;
  v_full       jsonb;
  v_old_rar    jsonb;
  v_old_full   jsonb;
  v_fresh_rar  jsonb := '[]'::jsonb;
  v_fresh_full jsonb := '[]'::jsonb;
  k            text;
begin
  a := cps.auth(p_token);

  -- Current completions, computed server-side.
  select coalesce(jsonb_object_agg(key, true), '{}'::jsonb) into v_rar
    from (
      select t.set_id || ':' || t.rarity as key
        from (select set_id, rarity, count(*) as n
                from cps.cards group by set_id, rarity) t
        join (select ti.set_id, c.rarity, count(*) as n
                from cps.turn_ins ti
                join cps.cards c
                  on c.set_id = ti.set_id and c.card_id = ti.card_id
               where ti.account_id = a.id
               group by ti.set_id, c.rarity) u
          on u.set_id = t.set_id and u.rarity = t.rarity
       where u.n >= t.n
    ) s;

  select coalesce(jsonb_object_agg(set_id, true), '{}'::jsonb) into v_full
    from (
      select t.set_id
        from (select set_id, count(*) as n
                from cps.cards group by set_id) t
        join (select set_id, count(*) as n
                from cps.turn_ins
               where account_id = a.id
               group by set_id) u
          on u.set_id = t.set_id
       where u.n >= t.n
    ) s;

  -- First ever sync for this account: silent baseline (global).
  insert into cps.milestone_snapshots (account_id, rar, full_sets)
  values (a.id, v_rar, v_full)
  on conflict (account_id) do nothing;
  if found then
    return jsonb_build_object('ok', true, 'baseline', true,
      'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
  end if;

  -- Lock the snapshot row so concurrent devices serialize: the first
  -- caller advances the snapshot, later callers diff against the
  -- advanced snapshot and see nothing fresh.
  select rar, full_sets into v_old_rar, v_old_full
    from cps.milestone_snapshots
   where account_id = a.id
   for update;

  for k in select * from jsonb_object_keys(v_rar) loop
    if not (v_old_rar ? k) then
      v_fresh_rar := v_fresh_rar || jsonb_build_object(
        'set', split_part(k, ':', 1), 'rarity', split_part(k, ':', 2));
    end if;
  end loop;
  for k in select * from jsonb_object_keys(v_full) loop
    if not (v_old_full ? k) then
      v_fresh_full := v_fresh_full || to_jsonb(k);
    end if;
  end loop;

  update cps.milestone_snapshots
     set rar = v_rar, full_sets = v_full, updated_at = now()
   where account_id = a.id;

  return jsonb_build_object('ok', true, 'baseline', false,
    'fresh_rar', v_fresh_rar, 'fresh_full', v_fresh_full);
end $$;

notify pgrst, 'reload schema';

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_milestone_sync(text) to anon;
  end if;
end $$;

-- Sanity after running:
--   select count(*) from cps.milestone_snapshots;  -- grows as players load the site
