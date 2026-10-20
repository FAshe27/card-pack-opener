-- =====================================================================
-- 165_gift_pop_thanks.sql — gift pop-ups + "Say Thanks" (Franklin,
-- 2026-10-20: "Can we add a pop-up notification for when someone gifts
-- you a card?" + "Maybe a 'Say Thanks' button that gives the person
-- who sent it a '(Player) said thank you for (card)!' pop up too")
--
-- Run AFTER 164 (Stuffed Packs). Nothing is removed or renamed.
--
-- WHAT EXISTS TODAY: cps_gift_card already writes a bell notification
-- (kind 'gift_card', text "X gifted you Y (Set)", view 'collection')
-- via cps.notify — but bell rows carry no meta, so the recipient only
-- ever sees it by opening the bell, and clicking it just jumps to the
-- collection. This migration adds the two server pieces the pop-up
-- needs; the pop-up itself is client-only (js/giftpop.js):
--
-- 1. cps_gift_card — rebuilt from migration 108's body (the newest
--    redefinition; verified against the repo: only 013/016/019/108
--    have ever defined it). The ONLY change: the cps.notify(...) call
--    becomes a direct insert that additionally stores meta, in the
--    same shape migration 122 gave pull notifications:
--      {set_id, card_id, holo, card_name, set_name,
--       from (giver account id), from_name, tier+serial when numbered}
--    Machine proof: swapping the new insert back for the 108 notify
--    call reproduces the 108 body byte-for-byte. Text, view, quest
--    bump, transfer and variant handling are untouched.
--    Side benefit: bell rows for new gifts become clickable straight
--    to the card, exactly like pull notifications — the client already
--    opens the card modal for any notification whose meta carries
--    set_id/card_id.
--
-- 2. cps_say_thanks(p_token, p_notification_id) — NEW RPC.
--    The recipient thanks the giver for ONE gift notification:
--      * the notification must belong to the caller and be a gift_card;
--      * gifts from before this migration carry no giver in meta and
--        cannot be thanked (the client hides the button for them);
--      * thanks land exactly once: the gift's meta is stamped
--        thanked=true under a guarded update, so double-taps, two
--        devices racing, or a replayed call can never send two;
--      * the giver receives a notification, kind 'gift_thanks', text
--        "<Thinker> said thank you for <Card>!" (Franklin's wording),
--        with the same card meta, so it pops for the giver too (via
--        the same giftpop client) and its bell row opens the card.
--    cps_list_notifications needs no change: it already returns meta
--    (122/136) and notif_visible passes every non-big-pull kind.
--
-- DEPLOY ORDER: run this migration first, then push the client
-- (js/giftpop.js + one script line in index.html + a gift_thanks icon
-- line in js/notifications.js).
--   * Old client + this migration: harmless — gifts just gain meta.
--   * New client + no migration: gift pops still work from the bell
--     rows (text-only, no card render, no Thanks button, because old
--     rows have no meta), and Say Thanks is simply never offered.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. cps_gift_card (108 body, notify -> meta insert only)
-- ---------------------------------------------------------------------
create or replace function public.cps_gift_card(p_token text, p_to uuid, p_set text, p_card text, p_holo boolean, p_variant_id uuid default null)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  tgt       cps.accounts%rowtype;
  card_name text;
  set_name  text;
  vtier     text;
  vserial   int;
  vvaulted  boolean;
  vlabel    text := '';
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot gift a card to yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;
  select k.name, s.name into card_name, set_name
    from cps.cards k join cps.card_sets s on s.id = k.set_id
    where k.set_id = p_set and k.card_id = p_card;
  if not found then raise exception 'Card not found.'; end if;
  if p_variant_id is not null then
    select vv.tier, vv.serial, vv.vaulted into vtier, vserial, vvaulted from cps.variants vv
      where vv.id = p_variant_id and vv.account_id = a.id and vv.set_id = p_set and vv.card_id = p_card;
    if not found then raise exception 'Variant not found.'; end if;
    if coalesce(vvaulted, false) then
      raise exception 'That numbered copy is in your Vault — release it before gifting it.';
    end if;
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
    update cps.variants set account_id = tgt.id where id = p_variant_id;
    perform cps.auto_turn_in(tgt.id, p_set, p_card);
  else
    -- a regular copy: variants stay put (the gift modal picks serials explicitly)
    perform cps.transfer_card(a.id, tgt.id, p_set, p_card, coalesce(p_holo, false), 1, 'gift', false);
  end if;
  if vtier is not null then
    vlabel := ' ' || cps.variant_name(vtier) || ' #' || vserial || '/' || cps.variant_run(vtier);
  end if;
  insert into cps.notifications (account_id, kind, text, target_view, meta)
  values (tgt.id, 'gift_card',
    a.display_name || ' gifted you ' || card_name || vlabel || ' (' || set_name || ')' ||
    case when vlabel = '' and coalesce(p_holo, false) then ' ✦ holo' else '' end,
    'collection',
    jsonb_build_object('set_id', p_set, 'card_id', p_card,
      'holo', coalesce(p_holo, false), 'card_name', card_name, 'set_name', set_name,
      'from', a.id, 'from_name', a.display_name)
    || case when vtier is not null
         then jsonb_build_object('tier', vtier, 'serial', vserial)
         else '{}'::jsonb end);
  perform cps.quest_bump(a.id, 'gift_card', 1);
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- 2. cps_say_thanks — the recipient thanks the giver, exactly once
-- ---------------------------------------------------------------------
create or replace function public.cps_say_thanks(p_token text, p_notification_id uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a         cps.accounts%rowtype;
  n         cps.notifications%rowtype;
  giver     uuid;
  card_name text;
begin
  a := cps.auth(p_token);
  select * into n from cps.notifications where id = p_notification_id and account_id = a.id;
  if not found then raise exception 'Gift not found.'; end if;
  if n.kind <> 'gift_card' then raise exception 'That notification is not a card gift.'; end if;
  if coalesce(n.meta ->> 'thanked', '') = 'true' then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if n.meta is null or n.meta ->> 'from' is null then
    raise exception 'This gift arrived before thank-yous existed - too old to thank for.';
  end if;
  giver := (n.meta ->> 'from')::uuid;
  if giver = a.id then raise exception 'You cannot thank yourself.'; end if;
  if not exists (select 1 from cps.accounts where id = giver and not disabled) then
    raise exception 'The player who sent this gift is no longer available.';
  end if;
  card_name := coalesce(n.meta ->> 'card_name', 'a card');

  -- claim the thank-you atomically: only the caller whose update
  -- actually flips thanked=false->true goes on to notify the giver
  update cps.notifications
     set meta = meta || jsonb_build_object('thanked', true, 'thanked_at', now())
   where id = n.id and coalesce(meta ->> 'thanked', '') <> 'true';
  if not found then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  insert into cps.notifications (account_id, kind, text, target_view, meta)
  values (giver, 'gift_thanks',
    a.display_name || ' said thank you for ' || card_name || '!',
    'collection',
    jsonb_build_object('set_id', n.meta ->> 'set_id', 'card_id', n.meta ->> 'card_id',
      'holo', coalesce((n.meta ->> 'holo')::boolean, false),
      'card_name', card_name, 'set_name', n.meta ->> 'set_name',
      'from', a.id, 'from_name', a.display_name)
    || case when n.meta ? 'tier'
         then jsonb_build_object('tier', n.meta ->> 'tier', 'serial', (n.meta ->> 'serial')::int)
         else '{}'::jsonb end);
  return jsonb_build_object('ok', true);
end $$;

notify pgrst, 'reload schema';
