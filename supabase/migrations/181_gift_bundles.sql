-- 181_gift_bundles.sql
-- Gifting grows from cards-only to bundle gifts sent from a player's
-- profile (Franklin, 2026-10-24): ONE send may mix up to FIVE cards
-- (same copy rules as cps_gift_card, incl. holo / numbered copies and
-- the Vault fence), one pack bundle (one set + qty), arcade tokens,
-- and spin tickets. The whole gift moves in one transaction.
-- Jumbled Mess stays out entirely (Franklin): 'jumbled' pack bundles
-- are rejected, and cards from the 'jumbled' set are rejected - the
-- exclusives are never giftable here.
-- The recipient gets ONE notification: kind 'gift_card' when a card is
-- included (so the existing gift pop-up renders the first card; the
-- text lists the full contents), otherwise kind 'gift'. Its meta
-- carries gift_label - the words Say Thanks uses. cps_say_thanks is
-- rebuilt on its live body to accept kind 'gift' and to thank by
-- gift_label when present; a lone-card gift still thanks by card name,
-- word for word as before (legacy notifications have no gift_label
-- and fall back to card_name).
-- Rollback: drop public.cps_gift and restore cps_say_thanks from its
-- live body as of 2026-10-24.

CREATE OR REPLACE FUNCTION public.cps_gift(p_token text, p_to uuid, p_gift jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a         cps.accounts%rowtype;
  tgt       cps.accounts%rowtype;
  vcards    jsonb;
  vn        int;
  vc        jsonb;
  vset      text;
  vcardid   text;
  vholo     boolean;
  vvariant  uuid;
  card_name text;
  set_name  text;
  vtier     text;
  vserial   int;
  vvaulted  boolean;
  vlabel    text;
  fset      text;
  fcard     text;
  fcardname text;
  fholo     boolean;
  ftier     text;
  fserial   int;
  vpackset  text;
  vpackname text;
  vpacks    int;
  vheld     int;
  vtok      int;
  vtic      int;
  parts     text[] := '{}';
  tparts    text[] := '{}';
  fragp     text;
  fragt     text;
  vprev_p   text;
  vprev_t   text;
  vbase_p   text;
  vbase_t   text;
  vrun      int := 0;
  vgiftlabel text;
begin
  a := cps.auth(p_token);
  if p_to = a.id then raise exception 'You cannot gift to yourself.'; end if;
  select * into tgt from cps.accounts where id = p_to and not disabled;
  if not found then raise exception 'Player not found.'; end if;

  vcards := case when jsonb_typeof(p_gift -> 'cards') = 'array'
              then p_gift -> 'cards' else '[]'::jsonb end;
  vn := jsonb_array_length(vcards);
  if vn > 5 then raise exception 'A gift can hold at most 5 cards.'; end if;
  vpackset := nullif(p_gift ->> 'pack_set', '');
  vpacks := greatest(coalesce((p_gift ->> 'packs')::int, 0), 0);
  vtok := greatest(coalesce((p_gift ->> 'tokens')::int, 0), 0);
  vtic := greatest(coalesce((p_gift ->> 'tickets')::int, 0), 0);
  if vn = 0 and vpacks < 1 and vtok < 1 and vtic < 1 then
    raise exception 'Your gift is empty - add a card, packs, tokens, or tickets.';
  end if;
  if (select count(*) from jsonb_array_elements(vcards) e
        where nullif(e ->> 'variant_id', '') is not null)
     <> (select count(distinct nullif(e ->> 'variant_id', ''))
           from jsonb_array_elements(vcards) e
          where nullif(e ->> 'variant_id', '') is not null) then
    raise exception 'The same numbered copy is in the gift twice.';
  end if;

  -- validate and lock the currency balances up front (the account row
  -- lock keeps a concurrent send from double-spending the same balance)
  select * into a from cps.accounts where id = a.id for update;
  if vtok > 0 and a.game_tokens < vtok then
    raise exception 'You do not have that many tokens.';
  end if;
  if vtic > 0 and a.spins < vtic then
    raise exception 'You do not have that many tickets.';
  end if;

  -- packs: one set + quantity, sender balance checked under lock
  if vpacks > 0 then
    if vpackset is null or vpackset = 'jumbled'
       or not exists (select 1 from cps.card_sets where id = vpackset) then
      raise exception 'Bad pack set for the gift.';
    end if;
    select packs into vheld from cps.pack_inventory
      where account_id = a.id and set_id = vpackset for update;
    if coalesce(vheld, 0) < vpacks then
      raise exception 'You do not have that many packs.';
    end if;
    select name into vpackname from cps.card_sets where id = vpackset;
  end if;

  -- validate every card BEFORE anything moves: Jumbled Mess cards stay
  -- out of gifts entirely, and numbered copies follow the card-gift
  -- rules (must be yours, must not be Vaulted)
  for vc in select * from jsonb_array_elements(vcards) loop
    vset := vc ->> 'set';
    vcardid := vc ->> 'card';
    if vset = 'jumbled' then
      raise exception 'Jumbled Mess cards can''t be gifted.';
    end if;
    if not exists (select 1 from cps.cards k where k.set_id = vset and k.card_id = vcardid) then
      raise exception 'Card not found.';
    end if;
    vvariant := nullif(vc ->> 'variant_id', '')::uuid;
    if vvariant is not null then
      select vv.vaulted into vvaulted from cps.variants vv
        where vv.id = vvariant and vv.account_id = a.id
          and vv.set_id = vset and vv.card_id = vcardid;
      if not found then raise exception 'Variant not found.'; end if;
      if coalesce(vvaulted, false) then
        raise exception 'A numbered copy in the gift is in your Vault - release it before gifting it.';
      end if;
    end if;
  end loop;

  -- ---- move everything (one transaction: all of it or none) ----
  for vc in select * from jsonb_array_elements(vcards) loop
    vset := vc ->> 'set';
    vcardid := vc ->> 'card';
    vholo := coalesce((vc ->> 'holo')::boolean, false);
    vvariant := nullif(vc ->> 'variant_id', '')::uuid;
    select k.name, s.name into card_name, set_name
      from cps.cards k join cps.card_sets s on s.id = k.set_id
      where k.set_id = vset and k.card_id = vcardid;
    vtier := null; vserial := null; vlabel := '';
    if vvariant is not null then
      select vv.tier, vv.serial into vtier, vserial from cps.variants vv where vv.id = vvariant;
      vholo := false;  -- a numbered copy is its own thing, never "holo"
    end if;
    perform cps.transfer_card(a.id, tgt.id, vset, vcardid, vholo, 1, 'gift', false);
    if vvariant is not null then
      update cps.variants set account_id = tgt.id where id = vvariant;
      perform cps.auto_turn_in(tgt.id, vset, vcardid);
      vlabel := ' ' || cps.variant_name(vtier) || ' #' || vserial || '/' || cps.variant_run(vtier);
    end if;
    if fset is null then
      fset := vset; fcard := vcardid; fcardname := card_name;
      fholo := vholo; ftier := vtier; fserial := vserial;
    end if;
    fragp := card_name || vlabel || ' (' || set_name || ')'
      || case when vlabel = '' and vholo then ' ✦ holo' else '' end;
    fragt := card_name || vlabel;
    -- collapse runs of the same copy gifted more than once ('Fern x2')
    if vprev_p is not null and fragp = vprev_p and fragt = vprev_t then
      vrun := vrun + 1;
      parts[array_upper(parts, 1)] := vbase_p || ' ×' || vrun;
      tparts[array_upper(tparts, 1)] := vbase_t || ' ×' || vrun;
    else
      vprev_p := fragp; vprev_t := fragt; vbase_p := fragp; vbase_t := fragt; vrun := 1;
      parts := parts || fragp;
      tparts := tparts || fragt;
    end if;
  end loop;
  if vpacks > 0 then
    perform cps.add_packs(a.id, vpackset, -vpacks, 'gift', null, null);
    perform cps.add_packs(tgt.id, vpackset, vpacks, 'gift', null, null);
    parts := parts || (vpacks || ' ' || vpackname || ' pack' || case when vpacks = 1 then '' else 's' end);
    tparts := tparts || (vpacks || ' ' || vpackname || ' pack' || case when vpacks = 1 then '' else 's' end);
  end if;
  if vtok > 0 then
    update cps.accounts set game_tokens = game_tokens - vtok where id = a.id;
    update cps.accounts set game_tokens = game_tokens + vtok where id = tgt.id;
    parts := parts || ('🪙 ' || vtok || ' token' || case when vtok = 1 then '' else 's' end);
    tparts := tparts || (vtok || ' token' || case when vtok = 1 then '' else 's' end);
  end if;
  if vtic > 0 then
    update cps.accounts set spins = spins - vtic where id = a.id;
    update cps.accounts set spins = spins + vtic where id = tgt.id;
    parts := parts || ('🎟️ ' || vtic || ' spin ticket' || case when vtic = 1 then '' else 's' end);
    tparts := tparts || (vtic || ' spin ticket' || case when vtic = 1 then '' else 's' end);
  end if;

  -- The label Say Thanks will use: a lone card and nothing else thanks
  -- by card name exactly as card gifts do today; anything bigger
  -- thanks by its full contents.
  vgiftlabel := case
    when vn = 1 and vpacks < 1 and vtok < 1 and vtic < 1 then tparts[1]
    else array_to_string(tparts, ' + ') end;

  insert into cps.notifications (account_id, kind, text, target_view, meta)
  values (tgt.id, case when vn > 0 then 'gift_card' else 'gift' end,
    a.display_name || ' gifted you ' || array_to_string(parts, ' + '),
    case when vn > 0 then 'collection' else 'packs' end,
    jsonb_build_object('from', a.id, 'from_name', a.display_name,
      'gift_label', vgiftlabel, 'cards', vn,
      'pack_set', case when vpacks > 0 then vpackset end,
      'packs', vpacks, 'tokens', vtok, 'tickets', vtic)
    || case when vn > 0
         then jsonb_build_object('set_id', fset, 'card_id', fcard,
              'holo', fholo,
              'card_name', fcardname, 'set_name',
              (select s.name from cps.card_sets s where s.id = fset))
         else '{}'::jsonb end
    || case when ftier is not null
         then jsonb_build_object('tier', ftier, 'serial', fserial)
         else '{}'::jsonb end);

  perform cps.quest_bump(a.id, 'gift_card', 1);
  return jsonb_build_object('ok', true);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_say_thanks(p_token text, p_notification_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a         cps.accounts%rowtype;
  n         cps.notifications%rowtype;
  giver     uuid;
  card_name text;
begin
  a := cps.auth(p_token);
  select * into n from cps.notifications where id = p_notification_id and account_id = a.id;
  if not found then raise exception 'Gift not found.'; end if;
  if n.kind not in ('gift_card', 'gift') then raise exception 'That notification is not a gift.'; end if;
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
  -- 181: bundle gifts carry gift_label (what the gift was, in words);
  -- card-only gifts keep the exact card-name wording they have today.
  card_name := coalesce(n.meta ->> 'gift_label', n.meta ->> 'card_name', 'a card');

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
    jsonb_build_object('from', a.id, 'from_name', a.display_name)
    || case when n.meta ? 'card_id'
         then jsonb_build_object('set_id', n.meta ->> 'set_id', 'card_id', n.meta ->> 'card_id',
              'holo', coalesce((n.meta ->> 'holo')::boolean, false),
              'card_name', n.meta ->> 'card_name', 'set_name', n.meta ->> 'set_name')
         else '{}'::jsonb end
    || case when n.meta ? 'tier'
         then jsonb_build_object('tier', n.meta ->> 'tier', 'serial', (n.meta ->> 'serial')::int)
         else '{}'::jsonb end);
  return jsonb_build_object('ok', true);
end $function$
;

NOTIFY pgrst, 'reload schema';
