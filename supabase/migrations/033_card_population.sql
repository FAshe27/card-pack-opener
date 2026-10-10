-- =====================================================================
-- 033_card_population.sql — total copies of a card across all players.
-- (Run after 032.)
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
                         and not ac.is_admin and not ac.disabled), 0)
  );
end $$;

grant execute on function public.cps_card_population(text, text, text) to anon;
