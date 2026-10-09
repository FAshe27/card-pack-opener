-- =====================================================================
-- 024_grant_spins_all.sql — admin grants spin tickets to every
-- non-admin, non-disabled player at once. Each recipient gets the usual
-- "You've been gifted N spin tickets!" notification.
-- (Run after 023.)
-- =====================================================================

create or replace function public.cps_admin_grant_spins_all(p_token text, p_spins int)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; n int := 0; r record;
begin
  a := cps.auth(p_token, true);
  if p_spins is null or p_spins < 1 or p_spins > 999 then raise exception 'Spins must be between 1 and 999.'; end if;
  for r in select id from cps.accounts where not is_admin and not disabled loop
    update cps.accounts set spins = spins + p_spins where id = r.id;
    insert into cps.spin_grants (account_id, spins, reason, granted_by)
      values (r.id, p_spins, 'admin_all', a.id);
    perform cps.notify(r.id, 'gift_spin',
      'You''ve been gifted ' || case when p_spins = 1 then 'a spin ticket' else p_spins || ' spin tickets' end || '!',
      'wheel');
    n := n + 1;
  end loop;
  return jsonb_build_object('spins_each', p_spins, 'players', n);
end $$;

grant execute on function public.cps_admin_grant_spins_all(text, int) to anon;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
