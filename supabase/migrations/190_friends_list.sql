-- =====================================================================
-- 190_friends_list.sql — lightweight Friends list (one-way stars)
--
-- Franklin's design (2026-10-25): players can star other players as
-- "friends"; the list lives in the top-right account dropdown as a
-- quick jump to a friend's profile / gift / trade.
--
-- Explicitly OUT (Franklin, 2026-10-25: "No need for mutual friends
-- or notifications or anything"):
--   * NO mutual consent — adding is one-way and private to the adder.
--   * NO notifications — the other player is never told.
--   * NO presence, NO feed, NO privacy changes — profiles stay
--     exactly as visible as they already are to any logged-in player.
--
-- This migration touches NOTHING existing: one new table and two new
-- RPCs. No existing function is rebuilt, so there is no regression
-- surface in get_profile / list_players / open_pack / state.
--
-- Targets follow the Players-list rule (008/177): a friend target
-- must be a real player account — not disabled, not an admin.
-- =====================================================================

create table if not exists cps.friends (
  owner_id   uuid not null references cps.accounts(id) on delete cascade,
  friend_id  uuid not null references cps.accounts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, friend_id),
  check (owner_id <> friend_id)
);
create index if not exists friends_owner_idx on cps.friends (owner_id);

-- Toggle a friend star. Returns the new state + the owner's total.
create or replace function public.cps_toggle_friend(p_token text, p_friend uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  did boolean;
  n   int;
begin
  a := cps.auth(p_token);
  if p_friend = a.id then
    raise exception 'You can''t add yourself as a friend.';
  end if;
  if not exists (select 1 from cps.accounts
                  where id = p_friend and not disabled and not is_admin) then
    raise exception 'Player not found.';
  end if;
  if exists (select 1 from cps.friends
              where owner_id = a.id and friend_id = p_friend) then
    delete from cps.friends where owner_id = a.id and friend_id = p_friend;
    did := false;
  else
    insert into cps.friends (owner_id, friend_id) values (a.id, p_friend);
    did := true;
  end if;
  select count(*) into n from cps.friends where owner_id = a.id;
  return jsonb_build_object('friended', did, 'count', n);
end $$;

-- The caller's own friends, A–Z by display name (same order as the
-- Players list). Only id + display_name: the dropdown needs nothing
-- else, and profile/gift/trade all re-read what they need themselves.
create or replace function public.cps_list_friends(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', x.id,
      'display_name', x.display_name
    ) order by x.display_name)
    from cps.friends f
    join cps.accounts x on x.id = f.friend_id
    where f.owner_id = a.id and not x.disabled and not x.is_admin), '[]');
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';

-- anon key needs execute rights on the new functions
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_toggle_friend(text, uuid) to anon;
    grant execute on function public.cps_list_friends(text) to anon;
  end if;
end $$;
