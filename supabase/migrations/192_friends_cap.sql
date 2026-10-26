-- =====================================================================
-- 192_friends_cap.sql — Friends list: 30-friend cap (+ collapsible menu)
--
-- Franklin's calls (2026-10-25): the account-dropdown Friends section
-- becomes a collapsible, closed by default (client-side, in this same
-- ship: friends.js / friends.css) and the list is capped so it can't
-- grow forever — "Should we cap it at, say, 30?"
--
-- This migration replaces ONLY public.cps_toggle_friend (190) with the
-- identical body plus ONE inserted block: on the ADD path only, when
-- the owner already has 30 friends, the toggle refuses with a friendly
-- error — the same raise-exception style as 190's self / not-found
-- rejects, and the message reaches the player through the client's
-- normal cloudError path. Removing a friend is never blocked, so a
-- full list can always shrink. cps_list_friends is NOT touched, no
-- table changes, and validation proves the insertion-only diff (192
-- minus the marked block == 190's function statement, byte for byte).
--
-- Honest limit: the count check and the insert are not atomic against
-- two adds landing in the same instant. At this player base the cap is
-- a UX guardrail, not a security boundary; a same-millisecond double
-- add is the only way past it (worst case 31 until one is removed).
-- =====================================================================

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
    -- >>> 192 INSERT (the only change vs 190) >>>
    if (select count(*) from cps.friends where owner_id = a.id) >= 30 then
      raise exception 'Your friends list is full (30). Remove someone to add another.';
    end if;
    -- <<< 192 INSERT <<<
    insert into cps.friends (owner_id, friend_id) values (a.id, p_friend);
    did := true;
  end if;
  select count(*) into n from cps.friends where owner_id = a.id;
  return jsonb_build_object('friended', did, 'count', n);
end $$;

-- let the API pick up the change right away
-- (execute grants persist across CREATE OR REPLACE; 190 granted anon)
notify pgrst, 'reload schema';
