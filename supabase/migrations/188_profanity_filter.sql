-- =====================================================================
-- 188: Profanity / obscenity filter for the game's user-visible free
-- text: usernames, display names, and Trading Post listing notes.
--
-- Franklin's go (2026-10-25): "Build it — filter usernames, display
-- names, and Trading Post notes." Standing rule: Franklin sees this
-- SQL (and the word lists in wordlists/) before it runs.
--
-- What this does, and ONLY this:
--  * Word lists as cps.app_config rows (editable later with no
--    migration): 'profanity_hard' (substring tier), 'profanity_soft'
--    (whole-token tier), 'reserved_names'. Curated from the LDNOOBW
--    'en' list; every removal is documented in the package SPEC.
--    Inserted ON CONFLICT DO NOTHING so Franklin's later edits to
--    the lists are never clobbered by a re-run.
--  * Internal helpers (schema cps, never granted out): normalize
--    (lowercase, accent fold, leet translate, zero-width strip,
--    3+-run collapse), cps.text_is_clean (hard substring on the
--    squashed text + soft token equality), cps.name_is_clean (adds
--    the reserved test), and assert wrappers that raise friendly
--    P0001 errors (P0001, like maintenance 187, so cloud.js never
--    treats a rejection as an auth failure / clears a token).
--    Matching is position()/equality only — no LIKE patterns and no
--    dynamic SQL built from user text (see SPEC 'Injection
--    posture'). All values arrive as bound plpgsql variables.
--  * Surgical [188 INSERT] blocks in exactly four functions, each
--    assembled by validation/build_188.py from the verbatim LATEST
--    body and proven insertion-only by validation/check_sql.py:
--      - cps.create_account (latest: 015) — username + effective
--        display name. This one insert also covers
--        public.cps_admin_create_account and cps.bootstrap_admin,
--        which delegate here (verified in 015).
--      - public.cps_set_display_name (latest: 001) — self rename.
--      - public.cps_admin_update_account (latest: 002) — it updates
--        username/display directly, so both of its write branches
--        get the gate.
--      - public.cps_trade_post (latest: 108) — the public listing
--        note (assert_clean only; reserved names don't apply).
--  * Nothing else is rebuilt: cps.auth (with the 187 maintenance
--    insert), cps_login, cps_open_pack are untouched. Existing
--    accounts and listings are NOT modified — the filter bites
--    only on create / rename / new listing (see SWEEP.md).
-- =====================================================================

-- ------------------------------------------------------------ word lists
insert into cps.app_config (key, value) values
  ('profanity_hard', '["anilingus", "arsehole", "asshole", "bdsm", "beaner", "beastiality", "bestiality", "bitch", "blowjob", "brownshower", "bukkake", "cameltoe", "creampie", "cumshot", "cunnilingus", "darkie", "deepthroat", "dildo", "doggystyle", "dominatrix", "donkeypunch", "doublepenetration", "dryhump", "faggot", "felch", "fellatio", "fingerbang", "fingering", "fisting", "fuck", "gangbang", "goldenshower", "handjob", "honkey", "incest", "jackoff", "jailbait", "jerkoff", "jigaboo", "jiggaboo", "jiggerboo", "jizz", "kike", "masturbat", "milf", "nazi", "neonazi", "nigga", "nigger", "paki", "poontang", "porn", "queef", "raghead", "rimjob", "shemale", "shit", "slut", "sodomize", "sodomy", "strapon", "swastika", "teabagging", "threesome", "towelhead", "tranny", "twat", "vibrator", "wetback", "whitepower"]'::jsonb),
  ('profanity_soft', '["alabamahotpocket", "alaskanpipeline", "anal", "anus", "ass", "assmunch", "autoerotic", "babeland", "bangbros", "bangbus", "bareback", "barelylegal", "barenaked", "bastard", "bastardo", "bastinado", "bimbos", "birdlock", "blumpkin", "bollocks", "bondage", "boner", "boob", "boobs", "bulldyke", "bunghole", "busty", "butt", "buttcheeks", "butthole", "camgirl", "camwhore", "carpetmuncher", "cialis", "circlejerk", "clevelandsteamer", "clit", "clitoris", "cock", "cocks", "coon", "coons", "cum", "cumming", "cunt", "daterape", "dick", "dingleberries", "dingleberry", "dirtysanchez", "doggiestyle", "dolcett", "domination", "dommes", "dyke", "ecchi", "ejaculation", "erotic", "erotism", "eunuch", "fag", "fecal", "feltch", "femdom", "figging", "footjob", "frotting", "fudgepacker", "futanari", "genitals", "goatcx", "goatse", "goddamn", "gokkun", "goodpoop", "goregasm", "grope", "guro", "hentai", "homo", "homoerotic", "hooker", "humping", "intercourse", "juggs", "kinbaku", "kinkster", "kinky", "knobbing", "lemonparty", "livesex", "lolita", "lovemaking", "mong", "muffdiving", "nambla", "nawashi", "negro", "nimphomania", "nipple", "nipples", "nsfw", "nude", "nudity", "nutten", "nympho", "nymphomania", "octopussy", "omorashi", "orgasm", "orgy", "paedophile", "panties", "panty", "pedobear", "pedophile", "pegging", "penis", "pikey", "piss", "pissing", "pisspig", "playboy", "ponyplay", "poof", "poon", "poopchute", "pubes", "punany", "pussy", "queaf", "quim", "rape", "raping", "rapist", "rectum", "retard", "retarded", "rimming", "rustytrombone", "sadism", "santorum", "schlong", "scissoring", "semen", "sex", "sexcam", "sexo", "sexual", "sexuality", "sexually", "sexy", "shibari", "shota", "shrimping", "skeet", "slanteye", "smut", "spastic", "spic", "splooge", "spooge", "spunk", "strappado", "suck", "sucks", "swinger", "throating", "thumbzilla", "tit", "tits", "titties", "titty", "topless", "tosser", "tribadism", "tubgirl", "tushy", "twink", "twinkie", "undressing", "upskirt", "vagina", "viagra", "voyeur", "voyeurweb", "voyuer", "vulva", "wank", "whore", "worldsex", "yaoi", "yiffy", "zoophilia"]'::jsonb),
  ('reserved_names', '["admin", "administrator", "franklin", "mod", "moderator", "official", "owner", "packripper", "staff", "support", "system"]'::jsonb)
on conflict (key) do nothing;

-- ------------------------------------------------------------ normalize
create or replace function cps.normalize_base(p_text text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select translate(
           replace(replace(replace(replace(
             translate(lower(coalesce(p_text, '')), 'àáâãäåæèéêëìíîïòóôõöøùúûüýÿñçß', 'aaaaaaaeeeeiiiioooooouuuuyyncs'),
             chr(8203), ''), chr(8204), ''), chr(8205), ''), chr(65279), ''),
           '0134578@$'::text, 'oieastbas'::text)
$$;

create or replace function cps.collapse_runs(p_text text) returns text
language plpgsql immutable set search_path = cps, pg_temp as $$
declare out text := ''; run_ch text := ''; run_n int := 0; ch text; i int;
begin
  if p_text is null then return null; end if;
  for i in 1 .. length(p_text) loop
    ch := substr(p_text, i, 1);
    if ch = run_ch then
      run_n := run_n + 1;
    else
      if run_n >= 3 then out := out || run_ch;
      elsif run_n > 0 then out := out || repeat(run_ch, run_n); end if;
      run_ch := ch; run_n := 1;
    end if;
  end loop;
  if run_n >= 3 then out := out || run_ch;
  elsif run_n > 0 then out := out || repeat(run_ch, run_n); end if;
  return out;
end $$;

create or replace function cps.normalize_squash(p_text text) returns text
language sql immutable set search_path = cps, pg_temp as $$
  select cps.collapse_runs(regexp_replace(cps.normalize_base(p_text), '[^a-z0-9]', '', 'g'))
$$;

create or replace function cps.normalize_tokens(p_text text) returns text[]
language plpgsql immutable set search_path = cps, pg_temp as $$
declare parts text[]; out text[] := '{}'; x text;
begin
  parts := string_to_array(regexp_replace(cps.normalize_base(p_text), '[^a-z0-9]+', ' ', 'g'), ' ');
  if parts is not null then
    foreach x in array parts loop
      if x <> '' then out := out || cps.collapse_runs(x); end if;
    end loop;
  end if;
  return out;
end $$;

-- ------------------------------------------------------------ word lists
create or replace function cps.profanity_words(p_key text) returns text[]
language plpgsql stable set search_path = cps, pg_temp as $$
declare v jsonb; out text[] := '{}';
begin
  begin
    v := cps.cfg(p_key);
  exception when others then
    return out;
  end;
  if v is null or jsonb_typeof(v) <> 'array' then return out; end if;
  select coalesce(array_agg(lower(e)), '{}') into out
    from jsonb_array_elements_text(v) e where btrim(e) <> '';
  return out;
end $$;

-- ------------------------------------------------------------ the checks
create or replace function cps.text_is_clean(p_text text) returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
declare sq text; toks text[]; w text; h text;
begin
  if p_text is null or btrim(p_text) = '' then return true; end if;
  sq := cps.normalize_squash(p_text);
  foreach w in array cps.profanity_words('profanity_hard') loop
    h := cps.normalize_squash(w);
    if h <> '' and position(h in sq) > 0 then return false; end if;
  end loop;
  toks := cps.normalize_tokens(p_text);
  foreach w in array cps.profanity_words('profanity_soft') loop
    if cps.normalize_squash(w) = any (toks) then return false; end if;
  end loop;
  return true;
end $$;

create or replace function cps.name_is_reserved(p_text text) returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
declare sq text; toks text[]; w text; r text;
begin
  if p_text is null or btrim(p_text) = '' then return false; end if;
  sq := cps.normalize_squash(p_text);
  toks := cps.normalize_tokens(p_text);
  foreach w in array cps.profanity_words('reserved_names') loop
    r := cps.normalize_squash(w);
    if r <> '' and (r = sq or r = any (toks)) then return true; end if;
  end loop;
  return false;
end $$;

create or replace function cps.name_is_clean(p_text text) returns boolean
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  return cps.text_is_clean(p_text) and not cps.name_is_reserved(p_text);
end $$;

create or replace function cps.assert_clean(p_text text, p_what text) returns void
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  if not cps.text_is_clean(p_text) then
    raise exception 'That % contains language we don''t allow. Please choose another.', p_what
      using errcode = 'P0001';
  end if;
end $$;

create or replace function cps.assert_name_clean(p_text text, p_what text) returns void
language plpgsql stable set search_path = cps, pg_temp as $$
begin
  if not cps.text_is_clean(p_text) then
    raise exception 'That % contains language we don''t allow. Please choose another.', p_what
      using errcode = 'P0001';
  end if;
  if cps.name_is_reserved(p_text) then
    raise exception 'That % is reserved. Please choose another.', p_what
      using errcode = 'P0001';
  end if;
end $$;

revoke execute on all functions in schema cps from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on all functions in schema cps from anon, authenticated';
  end if;
end $$;

-- ------------------------------------------------- gated functions
-- cps.create_account (verbatim 015 body + [188 INSERT])
create or replace function cps.create_account(p_username text, p_display text, p_pin text, p_admin boolean, p_packs int, p_sets text[], p_by uuid)
returns uuid language plpgsql set search_path = cps, pg_temp as $$
declare uid uuid; u text := cps.clean_username(p_username); sid text;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception 'PIN must be exactly 4 digits.'; end if;
  -- [188 INSERT] Profanity / reserved-name gate: the username and
  -- the effective display name (explicit display, else username).
  perform cps.assert_name_clean(u, 'username');
  perform cps.assert_name_clean(left(coalesce(nullif(btrim(p_display), ''), u), 32), 'display name');
  -- [/188 INSERT]
  if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u))) then
    raise exception 'That username is taken. Pick another.';
  end if;
  insert into cps.accounts (username_hash, username_hint, username, display_name, is_admin, created_by)
    values (cps.hash_text(cps.norm_username(u)), cps.make_hint(u), u, left(coalesce(nullif(btrim(p_display), ''), u), 32), coalesce(p_admin, false), p_by)
    returning id into uid;
  perform cps.set_pin(uid, p_pin);
  if coalesce(p_packs, 0) > 0 and p_sets is not null then
    foreach sid in array p_sets loop
      if exists (select 1 from cps.card_sets where id = sid) then
        perform cps.add_packs(uid, sid, p_packs, 'welcome', null, p_by);
      end if;
    end loop;
  end if;
  return uid;
end $$;

-- public.cps_set_display_name (verbatim 001 body + [188 INSERT])
create or replace function public.cps_set_display_name(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; n text := left(btrim(coalesce(p_name, '')), 32);
begin
  a := cps.auth(p_token);
  if n = '' then raise exception 'Name cannot be empty.'; end if;
  -- [188 INSERT] Profanity / reserved-name gate.
  perform cps.assert_name_clean(n, 'display name');
  -- [/188 INSERT]
  update cps.accounts set display_name = n where id = a.id;
  return jsonb_build_object('ok', true, 'display_name', n);
end $$;

-- public.cps_admin_update_account (verbatim 002 body + [188 INSERT]s)
create or replace function public.cps_admin_update_account(p_token text, p_account uuid, p_display_name text default null,
  p_new_username text default null, p_disabled boolean default null, p_is_admin boolean default null, p_pin text default null) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; u text;
begin
  a := cps.auth(p_token, true);
  if not exists (select 1 from cps.accounts where id = p_account) then raise exception 'No such account.'; end if;
  if p_account = a.id and (p_disabled is true or p_is_admin is false) then raise exception 'You can''t disable or demote yourself.'; end if;
  if p_display_name is not null and btrim(p_display_name) <> '' then
    -- [188 INSERT] Profanity / reserved-name gate (display name).
    perform cps.assert_name_clean(left(btrim(p_display_name), 32), 'display name');
    -- [/188 INSERT]
    update cps.accounts set display_name = left(btrim(p_display_name), 32) where id = p_account;
  end if;
  if p_new_username is not null and btrim(p_new_username) <> '' then
    u := cps.clean_username(p_new_username);
    -- [188 INSERT] Profanity / reserved-name gate (username).
    perform cps.assert_name_clean(u, 'username');
    -- [/188 INSERT]
    if exists (select 1 from cps.accounts where username_hash = cps.hash_text(cps.norm_username(u)) and id <> p_account) then
      raise exception 'That username is taken.';
    end if;
    update cps.accounts set username_hash = cps.hash_text(cps.norm_username(u)), username_hint = cps.make_hint(u), username = u where id = p_account;
  end if;
  if p_pin is not null then
    perform cps.set_pin(p_account, p_pin);   -- also clears any lockout
    delete from cps.sessions where account_id = p_account and token_hash <> cps.hash_text(p_token);  -- old PIN's sessions end
  end if;
  if p_disabled is not null then
    update cps.accounts set disabled = p_disabled where id = p_account;
    if p_disabled then delete from cps.sessions where account_id = p_account; end if;
  end if;
  if p_is_admin is not null then update cps.accounts set is_admin = p_is_admin where id = p_account; end if;
  return jsonb_build_object('ok', true);
end $$;

-- public.cps_trade_post (verbatim 108 body + [188 INSERT])
create or replace function public.cps_trade_post(p_token text, p_card jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a       cps.accounts%rowtype;
  cset    text;
  ccard   text;
  cholo   boolean;
  ctier   text;
  cserial int;
  new_id  uuid := gen_random_uuid();
  vrar    text;
  vopen   int;
  c       cps.collection%rowtype;
begin
  a := cps.auth(p_token);
  -- [188 INSERT] Profanity gate for the public listing note
  -- (name/reserved rules do not apply to notes).
  perform cps.assert_clean(p_note, 'note');
  -- [/188 INSERT]

  cset    := p_card->>'set';
  ccard   := p_card->>'card';
  cholo   := coalesce((p_card->>'holo')::boolean, false);
  ctier   := nullif(p_card->>'tier', '');
  cserial := nullif(p_card->>'serial', '')::int;
  if cset is null or ccard is null then raise exception 'Pick a card to list.'; end if;
  select k.rarity into vrar from cps.cards k where k.set_id = cset and k.card_id = ccard;
  if not found then raise exception 'That card is not on the server.'; end if;

  if ctier is not null then
    if ctier not in ('rainbow', 'prism', 'obsidian', 'oneofone') then raise exception 'Unknown variant tier.'; end if;
    if vrar not in ('rare', 'epic', 'legendary', 'chase') then
      raise exception 'Numbered variants only exist for rare cards and up.'; end if;
    if cserial is null or cserial < 1 or cserial > cps.variant_run(ctier) then
      raise exception 'Serial must be between 1 and % for %.', cps.variant_run(ctier), cps.variant_name(ctier); end if;
    if not exists (select 1 from cps.variants
                   where account_id = a.id and set_id = cset and card_id = ccard
                     and tier = ctier and serial = cserial) then
      raise exception 'You don''t hold that numbered copy.'; end if;
    if exists (select 1 from cps.variants
               where account_id = a.id and set_id = cset and card_id = ccard
                 and tier = ctier and serial = cserial and vaulted) then
      raise exception 'That numbered copy is in your Vault — release it before listing it.';
    end if;
    if cps.trade_variant_escrowed(cset, ccard, ctier, cserial) then
      raise exception 'That numbered copy is already listed or offered.'; end if;
  elsif cserial is not null then
    raise exception 'A serial needs a variant tier.'; end if;

  select count(*) into vopen from cps.trade_listings where lister = a.id and status = 'open';
  if vopen >= 5 then raise exception 'You already have 5 open listings — accept or cancel one first.'; end if;

  -- escrow the card: one specific copy leaves the collection
  select * into c from cps.collection
    where account_id = a.id and set_id = cset and card_id = ccard for update;
  if not found or c.count - c.vaulted_count < 1 then raise exception 'You don''t hold that card (on hand).'; end if;
  if cholo and coalesce(c.holo_count, 0) - c.vaulted_holo < 1 then raise exception 'You don''t have a holo copy to list (on hand).'; end if;
  -- non-variant listings can't take a variant copy's base slot
  if ctier is null then
    declare vn int;
    begin
      select count(*) into vn from cps.variants
        where account_id = a.id and set_id = cset and card_id = ccard;
      if coalesce(c.count, 0) - c.vaulted_count - vn < 1 then
        raise exception 'Your only copies are numbered — list it as a numbered card instead.'; end if;
    end;
  end if;
  update cps.collection
    set count = count - 1,
        holo_count = case when cholo then holo_count - 1
                          else least(holo_count, count - 1) end
    where account_id = a.id and set_id = cset and card_id = ccard;
  insert into cps.trade_listings (id, lister, set_id, card_id, holo, variant_tier, variant_serial, note)
    values (new_id, a.id, cset, ccard, cholo, ctier, cserial, left(coalesce(p_note, ''), 140));

  insert into cps.trade_escrow (listing_id, offer_id, account_id, set_id, card_id, holo,
                               variant_tier, variant_serial, qty)
    values (new_id, null, a.id, cset, ccard, cholo, ctier, cserial, 1);

  return jsonb_build_object('ok', true, 'id', new_id);
end $$;

-- let the API pick up the rebuilt functions right away
notify pgrst, 'reload schema';
