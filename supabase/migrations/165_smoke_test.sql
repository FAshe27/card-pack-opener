-- 165_smoke_test.sql — post-auth smoke test for migration 165
-- (gift pop-ups + Say Thanks). Run AFTER 165_gift_pop_thanks.sql.
--
-- Runs ENTIRELY in one transaction and ROLLS BACK: two real accounts
-- are fixtured in-transaction (a giver with 2 copies of a Common, the
-- Muse test account as receiver), the real RPCs are called with
-- planted session tokens, and nothing persists — no player keeps the
-- card, the notifications, or the thank-you.
-- Expected: one row, every check true.
begin;

do $$
declare
  receiver  uuid;
  rname     text;
  giver     uuid;
  gtok      text := 'smoke165-giver-00000001';
  rtok      text := 'smoke165-recv-000000001';
  f_set     text;
  f_card    text;
  f_name    text;
  r         jsonb;
  notif_id  uuid;
  nmeta     jsonb;
  ntext     text;
  ttext     text;
  cnt       int;
  msg       text;
  ok_gift        boolean := false;
  ok_meta        boolean := false;
  ok_thanks      boolean := false;
  ok_thanks_text boolean := false;
  ok_once        boolean := false;
  ok_owner       boolean := false;
begin
  select id, display_name into receiver, rname from cps.accounts where display_name = 'Admin Account';
  if receiver is null then raise exception 'Muse test account (Admin Account) not found'; end if;
  select id into giver from cps.accounts
   where id <> receiver and not is_admin and not disabled
   order by display_name limit 1;
  if giver is null then raise exception 'no second account available for the fixture'; end if;

  insert into cps.sessions (token_hash, account_id, expires_at) values
    (cps.hash_text(gtok), giver, now() + interval '1 hour'),
    (cps.hash_text(rtok), receiver, now() + interval '1 hour');

  -- Fixture: giver holds 2 copies of a Common
  select set_id, card_id, name into f_set, f_card, f_name from cps.cards
   where rarity = 'common' order by set_id, card_id limit 1;
  insert into cps.collection (account_id, set_id, card_id, count, holo_count, vaulted_count, vaulted_holo)
  values (giver, f_set, f_card, 2, 0, 0, 0)
  on conflict (account_id, set_id, card_id) do update set count = 2, holo_count = 0;

  -- 1) Gift it: notification lands with meta (set/card/holo/giver)
  r := public.cps_gift_card(gtok, receiver, f_set, f_card, false, null);
  select id, text, meta into notif_id, ntext, nmeta from cps.notifications
   where account_id = receiver and kind = 'gift_card'
   order by created_at desc limit 1;
  ok_gift := (r ->> 'ok')::boolean and notif_id is not null
             and ntext like '% gifted you ' || f_name || '%';
  ok_meta := nmeta ->> 'set_id' = f_set and nmeta ->> 'card_id' = f_card
             and (nmeta ->> 'from')::uuid = giver
             and coalesce((nmeta ->> 'holo')::boolean, true) = false;

  -- 2) Receiver says thanks: giver gets Franklin's exact wording
  r := public.cps_say_thanks(rtok, notif_id);
  select text into ttext from cps.notifications
   where account_id = giver and kind = 'gift_thanks'
   order by created_at desc limit 1;
  ok_thanks := (r ->> 'ok')::boolean and coalesce((r ->> 'already')::boolean, false) = false;
  ok_thanks_text := ttext = rname || ' said thank you for ' || f_name || '!';
  select coalesce((meta ->> 'thanked')::boolean, false) into ok_once
    from cps.notifications where id = notif_id;

  -- 3) Thanks are once-only: a second call reports already, sends nothing
  r := public.cps_say_thanks(rtok, notif_id);
  select count(*) into cnt from cps.notifications
   where account_id = giver and kind = 'gift_thanks';
  ok_once := ok_once and (r ->> 'already')::boolean and cnt = 1;

  -- 4) Only the gift's owner can thank for it
  begin
    r := public.cps_say_thanks(gtok, notif_id);
    ok_owner := false;
  exception when others then
    ok_owner := sqlerrm = 'Gift not found.';
  end;

  if not (ok_gift and ok_meta and ok_thanks and ok_thanks_text and ok_once and ok_owner) then
    raise exception 'SMOKE FAIL gift=% meta=% thanks=% text=% once=% owner=% (thanks text was: %)',
      ok_gift, ok_meta, ok_thanks, ok_thanks_text, ok_once, ok_owner, coalesce(ttext, '<none>');
  end if;
  raise notice 'SMOKE 165 PASS: gift=%, meta=%, thanks=%, thanks_text=%, once=%, owner=%',
    ok_gift, ok_meta, ok_thanks, ok_thanks_text, ok_once, ok_owner;
end $$;

rollback;
