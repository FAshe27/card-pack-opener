-- =====================================================================
-- 101_admin_notify.sql — Admin broadcast notifications to players.
-- =====================================================================

-- Send a notification to a specific player (admin only)
create or replace function public.cps_admin_notify(p_token text, p_account uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  admin cps.accounts%rowtype;
begin
  admin := cps.auth(p_token);
  if not admin.is_admin then raise exception 'Admin only.'; end if;
  if p_text is null or length(trim(p_text)) = 0 then
    raise exception 'Message cannot be empty.';
  end if;
  if length(p_text) > 500 then
    raise exception 'Message too long (max 500 characters).';
  end if;
  perform cps.notify(p_account, 'admin', trim(p_text), null);
  return jsonb_build_object('ok', true);
end $$;

-- Send a notification to all non-admin players (admin only)
create or replace function public.cps_admin_notify_all(p_token text, p_text text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  admin cps.accounts%rowtype;
  n int := 0;
  rec record;
begin
  admin := cps.auth(p_token);
  if not admin.is_admin then raise exception 'Admin only.'; end if;
  if p_text is null or length(trim(p_text)) = 0 then
    raise exception 'Message cannot be empty.';
  end if;
  if length(p_text) > 500 then
    raise exception 'Message too long (max 500 characters).';
  end if;
  for rec in select id from cps.accounts where not is_admin and not coalesce(disabled, false) loop
    perform cps.notify(rec.id, 'admin', trim(p_text), null);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'players', n);
end $$;

grant execute on function public.cps_admin_notify(text, uuid, text) to anon;
grant execute on function public.cps_admin_notify_all(text, text) to anon;

notify pgrst, 'reload schema';
