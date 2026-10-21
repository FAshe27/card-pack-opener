-- =====================================================================
-- 168_matchmaker_turnedin.sql — "Add Missing" by TURNED-IN cards.
--
-- Franklin's request (2026-10-21, minutes after the 167 ship):
-- "Can we change the Add Missing to base itself off of Turned In
-- cards?" House definition (2026-10-12 clarification, never revoked):
-- completion means TURNED IN only — merely owning a copy is not
-- completion. So "missing" for Matchmaker = not yet turned in.
--
-- Run AFTER 167 (which is live). This migration REDEFINES only
-- 167's functions, each rebuilt on its live 167 body verbatim:
--   cps_wantlist_add, cps_wantlist_list, cps_matchmaker_matches,
--   cps_matchmaker_wanted_mine, helper mm_purge_owned.
-- Untouched: cps.wantlist, cps.mm_spare, cps.mm_rarity_rank,
-- cps_wantlist_remove, spare math, admin-visibility, badge math.
-- NO announcement text is baked in anywhere — Matchmaker sends no
-- notifications at all.
--
-- WHAT IT DOES
--   Players keep a wantlist (cap 100, no expiry). Matchmaker computes
--   matches LIVE against other players' true spares and returns them;
--   the client turns a match into a DRAFT trade (existing trade
--   builder) or a DRAFT bounty (existing composer). Nothing is
--   reserved, escrowed or auto-traded; the normal submit/accept
--   ownership re-checks in those flows are unchanged.
--
-- SPARE DEFINITION (mirrors the client's dupe formula in
-- js/app.js dupeCounts / js/shop.js: dupes per card =
--   greatest(0, (count - vaulted_count) - greatest(1, unvaulted
--   variant count)) )
--   Per owner + card, from cps.collection (n/h/v/vh) and cps.variants:
--     on_hand       = count - vaulted_count
--     on_hand_holo  = holo_count - vaulted_holo
--     on_hand_plain = on_hand - on_hand_holo
--     v_uv          = unvaulted variant rows for that owner/card
--   Numbered copies are NEVER spares in v1: their base slots come out
--   of the plain bucket (a numbered copy is counted in `count` but not
--   in `holo_count`), and one keeper is reserved with priority
--   numbered > holo > plain:
--     nv_plain   = greatest(0, on_hand_plain - v_uv)
--     spare_holo = nv_holo minus 1 when a keeper is still needed
--                  (v_uv = 0) and a holo copy exists to be the keeper
--     spare_plain= nv_plain minus 1 when a keeper is still needed and
--                  there is no holo copy to be the keeper
--   spare_holo + spare_plain always equals the dupe formula total
--   (proof cases are exercised in 167_matchmaker_verify.sql and in
--   the staged local-Postgres fixture run).
--
-- ESCROW: copies offered on the Bounty Board / Trading Post are
--   decremented OUT of cps.collection at post/offer/list time and
--   restored on refund (see 056/061/151), so escrowed fungible copies
--   are excluded from spares by construction. Variant PINS are the
--   one conservative exception: a pinned variant's row still sits in
--   cps.variants (unvaulted) while its base slot is already out of
--   the collection, so it can only over-reserve a keeper slot and
--   UNDER-state spares — matches may miss a spare, never invent one.
--   Plain proposed trades lock nothing (house rule), so a spare can
--   legitimately move between match and accept; the trade flow
--   re-verifies ownership at accept, exactly as today.
--
-- ADMIN VISIBILITY: an owner/wanter who is_admin or disabled is
--   hidden from non-admin callers (regular players should not learn
--   the admin account exists — 159/160 principle). An admin caller
--   sees non-admin players normally, so the Muse admin test account
--   can exercise the feature; admins still never see other admins.
--
-- AUTO-REMOVE ON TURN-IN (changed from 167's on-acquire): wants are
--   about a card the caller has not FINISHED. cps_wantlist_list and
--   cps_matchmaker_matches first DELETE the caller's wants for cards
--   they have turned in. The turned-in flag is cps.turn_ins
--   (migration 108, house turned-in storage: primary key
--   (account_id, set_id, card_id), survives owning 0 copies; the
--   client mirrors it as S.turnedIn / ctx.isTurned). Owning a copy no
--   longer clears a want, and adding a want for an owned-but-not-
--   turned-in card is allowed; adding one for an already-turned-in
--   card returns {added:false, reason:'turned_in'}.
--
-- DEPLOY ORDER: run this migration, then
--   168_matchmaker_turnedin_verify.sql (post-auth smoke, rolls back),
--   then push the new js/matchmaker.js (see README-168 for the exact
--   order + hook greps). 167 is a strict prerequisite: this file
--   redefines 167's functions.
--   Old (167) client + this migration: harmless — bulk add would
--   still skip owned cards client-side and the server would accept
--   owned adds it wouldn't ask for; nothing breaks.
--   New client + 167 only: bulk add computes not-turned-in cards from
--   ctx.isTurned (already live) but the server would still reject
--   owned-not-turned-in adds with reason 'owned' — the feature is
--   crippled, not broken; rest of Market untouched.
-- =====================================================================

-- --- wantlist ---------------------------------------------------------
create table if not exists cps.wantlist (
  account_id uuid not null references cps.accounts(id) on delete cascade,
  set_id     text not null,
  card_id    text not null,
  holo_pref  text not null default 'any' check (holo_pref in ('any', 'holo')),
  created_at timestamptz not null default now(),
  primary key (account_id, set_id, card_id),
  foreign key (set_id, card_id) references cps.cards(set_id, card_id) on delete cascade
);
create index if not exists idx_wantlist_card on cps.wantlist(set_id, card_id);

alter table cps.wantlist enable row level security;
revoke all on table cps.wantlist from public;

-- --- internal: rarity rank (client RARITIES order, low -> high) -------
create or replace function cps.mm_rarity_rank(p_rarity text)
returns int language sql immutable set search_path = cps, pg_temp as $$
  select case p_rarity
    when 'chase' then 5 when 'legendary' then 4 when 'epic' then 3
    when 'rare' then 2 when 'uncommon' then 1 else 0 end;
$$;

-- --- internal: spare split for one owner + card -----------------------
-- Returns (spare, spare_holo) of NON-numbered copies beyond the keeper.
-- p_col is the owner's cps.collection row (null = owns nothing).
create or replace function cps.mm_spare(p_account uuid, p_set text, p_card text,
                                        p_count int, p_holo int, p_vaulted int, p_vaulted_holo int)
returns jsonb language plpgsql stable set search_path = cps, pg_temp as $$
declare
  v_uv         int;
  on_hand      int := greatest(0, coalesce(p_count, 0) - coalesce(p_vaulted, 0));
  on_hand_holo int := greatest(0, coalesce(p_holo, 0) - coalesce(p_vaulted_holo, 0));
  nv_plain     int;
  keeper       int;
  spare_holo   int;
  spare_plain  int;
begin
  if coalesce(p_count, 0) <= 0 then
    return jsonb_build_object('spare', 0, 'spare_holo', 0);
  end if;
  select count(*) into v_uv from cps.variants
   where account_id = p_account and set_id = p_set and card_id = p_card
     and not coalesce(vaulted, false);
  nv_plain := greatest(0, (on_hand - on_hand_holo) - v_uv);
  keeper := case when v_uv > 0 then 0 else 1 end;
  spare_holo  := greatest(0, on_hand_holo - case when keeper = 1 and on_hand_holo > 0 then 1 else 0 end);
  spare_plain := greatest(0, nv_plain    - case when keeper = 1 and on_hand_holo = 0 then 1 else 0 end);
  return jsonb_build_object('spare', spare_holo + spare_plain, 'spare_holo', spare_holo);
end $$;

-- --- internal: purge my wants for cards I have turned in -------------
-- 168 replaces 167's mm_purge_owned: a want survives merely owning a
-- copy now, and clears the moment the card lands in cps.turn_ins
-- (the permanent per-player/per-card completion flag from migration
-- 108, PK (account_id, set_id, card_id)).
create or replace function cps.mm_purge_turned_in(p_account uuid)
returns void language sql set search_path = cps, pg_temp as $$
  delete from cps.wantlist w
   where w.account_id = p_account
     and exists (select 1 from cps.turn_ins t
                  where t.account_id = p_account
                    and t.set_id = w.set_id and t.card_id = w.card_id);
$$;

-- 167's helper is dead after this migration; drop it so no code path
-- can still reference the old owned-based basis.
drop function if exists cps.mm_purge_owned(uuid);

-- --- add one want ------------------------------------------------------
create or replace function public.cps_wantlist_add(p_token text, p_set_id text, p_card_id text, p_holo_pref text default 'any')
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  hp  text := coalesce(nullif(lower(p_holo_pref), ''), 'any');
  cnt int;
begin
  a := cps.auth(p_token);
  if hp not in ('any', 'holo') then
    raise exception 'Holo preference must be ''any'' or ''holo''.';
  end if;
  if not exists (select 1 from cps.cards where set_id = p_set_id and card_id = p_card_id) then
    raise exception 'Card not found.';
  end if;
  perform cps.mm_purge_turned_in(a.id);
  if exists (select 1 from cps.turn_ins
              where account_id = a.id and set_id = p_set_id and card_id = p_card_id) then
    return jsonb_build_object('ok', true, 'added', false, 'reason', 'turned_in');
  end if;
  if exists (select 1 from cps.wantlist
              where account_id = a.id and set_id = p_set_id and card_id = p_card_id) then
    -- re-adding updates the holo preference (the client's toggle uses this)
    update cps.wantlist set holo_pref = hp
     where account_id = a.id and set_id = p_set_id and card_id = p_card_id;
    select count(*) into cnt from cps.wantlist where account_id = a.id;
    return jsonb_build_object('ok', true, 'added', false, 'reason', 'exists', 'count', cnt);
  end if;
  select count(*) into cnt from cps.wantlist where account_id = a.id;
  if cnt >= 100 then
    raise exception 'Your wantlist is full (100 cards max) — remove a want before adding another.';
  end if;
  insert into cps.wantlist (account_id, set_id, card_id, holo_pref)
  values (a.id, p_set_id, p_card_id, hp);
  return jsonb_build_object('ok', true, 'added', true, 'count', cnt + 1);
end $$;

-- --- remove one want ---------------------------------------------------
create or replace function public.cps_wantlist_remove(p_token text, p_set_id text, p_card_id text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  cnt int;
begin
  a := cps.auth(p_token);
  delete from cps.wantlist
   where account_id = a.id and set_id = p_set_id and card_id = p_card_id;
  select count(*) into cnt from cps.wantlist where account_id = a.id;
  return jsonb_build_object('ok', true, 'count', cnt);
end $$;

-- --- my wantlist (turned-in wants are purged first: auto-remove) ------
create or replace function public.cps_wantlist_list(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  perform cps.mm_purge_turned_in(a.id);
  return jsonb_build_object('ok', true, 'wants', coalesce((
    select jsonb_agg(jsonb_build_object(
             'set_id', w.set_id, 'card_id', w.card_id, 'holo_pref', w.holo_pref,
             'card_name', k.name, 'rarity', k.rarity, 'set_name', s.name,
             'created_at', w.created_at)
           order by cps.mm_rarity_rank(k.rarity) desc, s.name, k.name)
      from cps.wantlist w
      join cps.cards k on k.set_id = w.set_id and k.card_id = w.card_id
      join cps.card_sets s on s.id = w.set_id
     where w.account_id = a.id), '[]'::jsonb));
end $$;

-- --- my matches: my wants vs other players' spares --------------------
create or replace function public.cps_matchmaker_matches(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  perform cps.mm_purge_turned_in(a.id);
  return jsonb_build_object('ok', true,
    'badge', (select count(distinct w.card_id || ':' || w.set_id)
                from cps.wantlist w
                join cps.collection c
                  on c.set_id = w.set_id and c.card_id = w.card_id
                 and c.account_id <> a.id
                join cps.accounts o on o.id = c.account_id
               where w.account_id = a.id
                 and not coalesce(o.disabled, false)
                 and (coalesce(a.is_admin, false) or not coalesce(o.is_admin, false))
                 and (cps.mm_spare(c.account_id, c.set_id, c.card_id,
                                   c.count, c.holo_count, c.vaulted_count, c.vaulted_holo) ->> 'spare')::int > 0
                 and (w.holo_pref <> 'holo'
                      or (cps.mm_spare(c.account_id, c.set_id, c.card_id,
                                        c.count, c.holo_count, c.vaulted_count, c.vaulted_holo) ->> 'spare_holo')::int > 0)),
    'matches', coalesce((
      select jsonb_agg(item order by rank desc, pct desc, spare desc, owner_name)
        from (
          select jsonb_build_object(
                   'set_id', w.set_id, 'card_id', w.card_id, 'holo_pref', w.holo_pref,
                   'card_name', k.name, 'rarity', k.rarity, 'set_name', s.name,
                   'owner_id', o.id, 'owner_name', o.display_name,
                   'spare', (sp.j ->> 'spare')::int, 'spare_holo', (sp.j ->> 'spare_holo')::int,
                   'pct', comp.pct) as item,
                 cps.mm_rarity_rank(k.rarity) as rank,
                 comp.pct as pct,
                 (sp.j ->> 'spare')::int as spare,
                 o.display_name as owner_name
            from cps.wantlist w
            join cps.cards k on k.set_id = w.set_id and k.card_id = w.card_id
            join cps.card_sets s on s.id = w.set_id
            join cps.collection c
              on c.set_id = w.set_id and c.card_id = w.card_id and c.account_id <> a.id
            join cps.accounts o on o.id = c.account_id
            cross join lateral (select cps.mm_spare(c.account_id, c.set_id, c.card_id,
                                             c.count, c.holo_count, c.vaulted_count, c.vaulted_holo) as j) as sp
            cross join lateral (
              select case when tot.n > 0
                          then round(100.0 * have.n / tot.n, 1) else 0 end as pct
                from (select count(*) as n from cps.cards kk where kk.set_id = w.set_id) tot,
                     (select count(*) as n from cps.cards kk
                       where kk.set_id = w.set_id
                         and (exists (select 1 from cps.collection cc
                                       where cc.account_id = a.id and cc.set_id = kk.set_id
                                         and cc.card_id = kk.card_id and cc.count > 0)
                              or exists (select 1 from cps.turn_ins tt
                                          where tt.account_id = a.id and tt.set_id = kk.set_id
                                            and tt.card_id = kk.card_id))) have
            ) comp
           where w.account_id = a.id
             and not coalesce(o.disabled, false)
             and (coalesce(a.is_admin, false) or not coalesce(o.is_admin, false))
             and (sp.j ->> 'spare')::int > 0
             and (w.holo_pref <> 'holo' or (sp.j ->> 'spare_holo')::int > 0)
        ) m), '[]'::jsonb));
end $$;

-- --- reverse: my spares that other players want ------------------------
create or replace function public.cps_matchmaker_wanted_mine(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object('ok', true, 'wanted', coalesce((
    select jsonb_agg(item order by rank desc, wanter_name)
      from (
        select jsonb_build_object(
                 'set_id', w.set_id, 'card_id', w.card_id, 'holo_pref', w.holo_pref,
                 'card_name', k.name, 'rarity', k.rarity, 'set_name', s.name,
                 'wanter_id', o.id, 'wanter_name', o.display_name,
                 'my_spare', (sp.j ->> 'spare')::int,
                 'my_spare_holo', (sp.j ->> 'spare_holo')::int) as item,
               cps.mm_rarity_rank(k.rarity) as rank,
               o.display_name as wanter_name
          from cps.collection c
          join cps.wantlist w
            on w.set_id = c.set_id and w.card_id = c.card_id and w.account_id <> a.id
          join cps.cards k on k.set_id = w.set_id and k.card_id = w.card_id
          join cps.card_sets s on s.id = w.set_id
          join cps.accounts o on o.id = w.account_id
          cross join lateral (select cps.mm_spare(c.account_id, c.set_id, c.card_id,
                                           c.count, c.holo_count, c.vaulted_count, c.vaulted_holo) as j) as sp
         where c.account_id = a.id
           and not coalesce(o.disabled, false)
           and (coalesce(a.is_admin, false) or not coalesce(o.is_admin, false))
           and (sp.j ->> 'spare')::int > 0
           and (w.holo_pref <> 'holo' or (sp.j ->> 'spare_holo')::int > 0)
           -- a wanter may own the card and still want it (to turn it
           -- in); hide only wanters who have already turned it in
           and not exists (select 1 from cps.turn_ins tt
                            where tt.account_id = o.id and tt.set_id = w.set_id
                              and tt.card_id = w.card_id)
      ) m), '[]'::jsonb));
end $$;

notify pgrst, 'reload schema';
