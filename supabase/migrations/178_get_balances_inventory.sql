-- 178_get_balances_inventory.sql
-- Extend public.cps_get_balances (migration 177) with the per-set pack
-- inventory map, so the arcade games' refreshPackCounts() can read it from
-- the tiny balances call instead of downloading the full ~1.2 MB get_state.
-- The inventory expression is copied verbatim from cps.state_json.
CREATE OR REPLACE FUNCTION public.cps_get_balances(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'spins', coalesce(a.spins, 0),
    'game_tokens', coalesce(a.game_tokens, 0),
    'store_credit', coalesce(a.store_credit, 0),
    'packs', coalesce((select sum(packs) from cps.pack_inventory where account_id = a.id), 0),
    'inventory', coalesce((select jsonb_object_agg(set_id, packs) from cps.pack_inventory where account_id = a.id), '{}'));
end $function$;
