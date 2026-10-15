-- 155_verify.sql -- smoke test for migration 155 (CotD wording + activity
-- grants). One transaction, ROLLS BACK -- net effect zero: today's real
-- CotD row, inventories and notifications are all restored on rollback.
--
-- Inside the transaction it removes today's CotD row, marks one real
-- player "active" (a fake pack opening yesterday, Chicago time) and a
-- second player "inactive" (their yesterday openings removed, in-txn
-- only), then runs the rollover and checks:
--   * the CotD row is recreated and a second call changes nothing;
--   * the active player gained exactly 15 packs (+5 of the CotD set),
--     got the long CotD text and the Activity bonus notification;
--   * the inactive player gained 0 packs and got only the short text.
-- Expected: SMOKE PASSED at the end.
begin;

do $$
declare
  today  date := (now() at time zone 'America/Chicago')::date;
  active_acct uuid; idle_acct uuid;
  cotd_set text;
  a_before int; a_after int;
  i_before int; i_after int;
  g_cotd int; g_bonus int;
  a_notifs int; i_notifs int; n_cotd int;
begin
  select id into active_acct from cps.accounts
   where not is_admin and not disabled order by created_at limit 1;
  select id into idle_acct from cps.accounts
   where not is_admin and not disabled and id <> active_acct
   order by created_at limit 1;
  if active_acct is null or idle_acct is null then
    raise exception 'SMOKE FAILED: need at least two non-admin players';
  end if;

  -- fixture (in-transaction only): active opened a pack yesterday,
  -- idle did not
  delete from cps.pack_openings
   where account_id in (active_acct, idle_acct)
     and (opened_at at time zone 'America/Chicago')::date = today - 1;
  insert into cps.pack_openings (account_id, set_id, cards, opened_at)
    select active_acct, id, '[]'::jsonb,
           ((today - 1)::timestamp + interval '12 hours') at time zone 'America/Chicago'
      from cps.card_sets where active and id <> 'jumbled' order by id limit 1;

  select coalesce(sum(packs), 0) into a_before from cps.pack_inventory where account_id = active_acct;
  select coalesce(sum(packs), 0) into i_before from cps.pack_inventory where account_id = idle_acct;
  select count(*) into a_notifs from cps.notifications where account_id = active_acct;
  select count(*) into i_notifs from cps.notifications where account_id = idle_acct;

  -- force the rollover inside this transaction
  delete from cps.cotd_days where cotd_date = today;
  perform cps.ensure_cotd_today();
  perform cps.ensure_cotd_today(); -- second call must be a no-op

  select set_id into cotd_set from cps.cotd_days where cotd_date = today;
  if cotd_set is null then raise exception 'SMOKE FAILED: no CotD row created'; end if;
  select count(*) into n_cotd from cps.cotd_days where cotd_date = today;
  if n_cotd <> 1 then raise exception 'SMOKE FAILED: % CotD rows for today', n_cotd; end if;

  select coalesce(sum(packs), 0) into a_after from cps.pack_inventory where account_id = active_acct;
  select coalesce(sum(packs), 0) into i_after from cps.pack_inventory where account_id = idle_acct;

  -- grants ledger: exactly +5 CotD-set packs and +10 random packs for
  -- the active player, both stamped with today's date as ref
  select coalesce(sum(packs), 0) into g_cotd from cps.pack_grants
   where account_id = active_acct and reason = 'cotd_daily' and ref = today::text and set_id = cotd_set;
  select coalesce(sum(packs), 0) into g_bonus from cps.pack_grants
   where account_id = active_acct and reason = 'activity_bonus' and ref = today::text;
  if g_cotd <> 5 then
    raise exception 'SMOKE FAILED: cotd_daily grants sum to %, expected 5', g_cotd;
  end if;
  if g_bonus <> 10 then
    raise exception 'SMOKE FAILED: activity_bonus grants sum to %, expected 10', g_bonus;
  end if;
  if exists (select 1 from cps.pack_grants
              where account_id = idle_acct and ref = today::text
                and reason in ('cotd_daily', 'activity_bonus')) then
    raise exception 'SMOKE FAILED: inactive player has grant rows for today';
  end if;

  if a_after - a_before <> 15 then
    raise exception 'SMOKE FAILED: active player gained % packs, expected 15', a_after - a_before;
  end if;
  if i_after - i_before <> 0 then
    raise exception 'SMOKE FAILED: inactive player gained % packs, expected 0', i_after - i_before;
  end if;

  if (select count(*) from cps.notifications where account_id = active_acct) - a_notifs <> 2 then
    raise exception 'SMOKE FAILED: active player should get 2 notifications (CotD + activity bonus)';
  end if;
  if (select count(*) from cps.notifications where account_id = idle_acct) - i_notifs <> 1 then
    raise exception 'SMOKE FAILED: inactive player should get 1 notification (CotD only)';
  end if;
  if not exists (select 1 from cps.notifications
                  where account_id = active_acct and kind = 'cotd'
                    and text like '%Pull it from a pack to win%'
                    and text like '%You''ve been given 5 % packs to help your search.') then
    raise exception 'SMOKE FAILED: active CotD text wrong: %',
      (select text from cps.notifications where account_id = active_acct and kind = 'cotd' order by created_at desc limit 1);
  end if;
  if not exists (select 1 from cps.notifications
                  where account_id = idle_acct and kind = 'cotd'
                    and text like '%Pull it from a pack to win%'
                    and text not like '%been given 5%') then
    raise exception 'SMOKE FAILED: inactive CotD text wrong';
  end if;
  if not exists (select 1 from cps.notifications
                  where account_id = active_acct and kind = 'activity_bonus'
                    and text = 'Activity bonus! For being an active user, you''ve been granted 10 random packs!') then
    raise exception 'SMOKE FAILED: activity bonus notification missing/wrong';
  end if;

  raise notice 'SMOKE PASSED: CotD set % | active +15 packs (+5 CotD set), long text + bonus note | inactive +0, short text only', cotd_set;
end $$;

rollback;
