-- =====================================================================
-- PackRipper -- migration 137: card page gains "Times pulled".
-- Run AFTER 136. Rebuilds public.cps_card_population (migration
-- 033's body, insertion-only) adding one key to its result:
--
--   'pulled' -- how many copies of the card have ever come out of a
--   pack, counting only openings by real players (non-admin, not
--   disabled) -- the same population the existing 'total' (copies
--   currently existing) is counted over, so the two numbers subtract
--   cleanly: pulled - existing = copies burned to turn-ins and
--   dupe sales. The count reads cps.pack_openings, which has
--   recorded every opening since migration 001, and uses the same
--   query shape Franklin ran by hand for Brad Perez on 2026-10-13
--   (13 pulled / 5 existing / 0 holos at the time).
--
-- Machine proof: removing the inserted 'pulled' entry reproduces
-- 033's body byte-for-byte; paren walk + pglast clean.
-- =====================================================================

create or replace function public.cps_card_population(p_token text, p_set text, p_card text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'total', coalesce((select sum(c.count)::int from cps.collection c
                       join cps.accounts ac on ac.id = c.account_id
                       where c.set_id = p_set and c.card_id = p_card
                         and not ac.is_admin and not ac.disabled), 0),
    'holos', coalesce((select sum(c.holo_count)::int from cps.collection c
                       join cps.accounts ac on ac.id = c.account_id
                       where c.set_id = p_set and c.card_id = p_card
                         and not ac.is_admin and not ac.disabled), 0),
    'pulled', (select count(*) from cps.pack_openings o, jsonb_array_elements(o.cards) e
                       where e->>'set_id' = p_set and e->>'id' = p_card
                         and o.account_id in (select id from cps.accounts
                                                where not is_admin and not disabled))
  );
end $$;

grant execute on function public.cps_card_population(text, text, text) to anon;

notify pgrst, 'reload schema';
