-- =====================================================================
-- 213: Support notifications deep-link to their ticket.
--
-- Franklin's ask (2026-10-27, while fleshing out the 212 ticket
-- system): "Clicking a notification should take you directly to
-- the ticket."
--
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * New internal helper cps.support_notify(p_account, p_text,
--    p_ticket): inserts a 'support' notification exactly like
--    cps.notify did in 212, but ALSO stores meta =
--    {"ticket_id": <uuid>} (the meta column 122 added; the same
--    mechanism pull notifications use to open the pulled card).
--    cps_list_notifications already returns meta for every kind —
--    verified live — so no list change is needed.
--  * cps.support_notify_admins gains the ticket id as a third
--    parameter (the 212 two-argument version is DROPPED first, so
--    exactly one signature exists) and forwards it to the helper.
--  * cps_submit_ticket / cps_reply_ticket /
--    cps_admin_set_ticket_status are replaced with their 212 bodies
--    VERBATIM except the notify call sites, which switch to the
--    meta-carrying helper. (Machine-checked: removing the changed
--    call lines reproduces the 212 text exactly.)
--  * Notifications written before 213 carry no meta; clicking one
--    still lands on the Help view, as today. Only new notifications
--    deep-link.
--  * Nothing else is touched: no table, no other function, no
--    cps.notify change (every other kind keeps using it as-is).
-- =====================================================================

-- The one new helper: a support notification that knows its ticket.
create or replace function cps.support_notify(p_account uuid, p_text text, p_ticket uuid)
returns void language sql set search_path = cps, pg_temp as $$
  insert into cps.notifications (account_id, kind, text, target_view, meta)
  values (p_account, 'support', p_text, 'help', jsonb_build_object('ticket_id', p_ticket));
$$;

-- The admins helper changes signature: drop the 212 version first.
drop function if exists cps.support_notify_admins(uuid, text);

create or replace function cps.support_notify_admins(p_actor uuid, p_text text, p_ticket uuid)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare adm uuid;
begin
  for adm in select id from cps.accounts
              where is_admin and not disabled and id <> p_actor loop
    perform cps.support_notify(adm, p_text, p_ticket);
  end loop;
end $$;

create or replace function public.cps_submit_ticket(p_token text, p_subject text, p_body text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  sub text := left(btrim(coalesce(p_subject, '')), 120);
  bod text := btrim(coalesce(p_body, ''));
  t   cps.support_tickets%rowtype;
begin
  a := cps.auth(p_token);
  if sub = '' then raise exception 'Give your ticket a subject.'; end if;
  if bod = '' then raise exception 'Describe what you need help with.'; end if;
  if length(bod) > 2000 then raise exception 'That message is too long (2000 characters max).'; end if;
  if (select count(*) from cps.support_tickets
       where account_id = a.id and status = 'open') >= 5 then
    raise exception 'You already have 5 open tickets. Please wait for a reply on one of those first.';
  end if;
  insert into cps.support_tickets (account_id, subject)
    values (a.id, sub) returning * into t;
  insert into cps.support_messages (ticket_id, author_id, body)
    values (t.id, a.id, bod);
  perform cps.support_notify_admins(a.id,
    a.display_name || ' opened a support ticket: ' || sub, t.id);
  return cps.support_ticket_json(t, a.is_admin);
end $$;

create or replace function public.cps_reply_ticket(p_token text, p_ticket uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a   cps.accounts%rowtype;
  t   cps.support_tickets%rowtype;
  bod text := btrim(coalesce(p_body, ''));
begin
  a := cps.auth(p_token);
  if bod = '' then raise exception 'Write a message first.'; end if;
  if length(bod) > 2000 then raise exception 'That message is too long (2000 characters max).'; end if;
  select * into t from cps.support_tickets where id = p_ticket for update;
  if not found then raise exception 'Ticket not found.'; end if;
  if t.account_id <> a.id and not a.is_admin then
    raise exception 'Not your ticket.' using errcode = '42501';
  end if;
  if t.status <> 'open' then
    raise exception 'This ticket is closed. An admin can reopen it.';
  end if;
  insert into cps.support_messages (ticket_id, author_id, body)
    values (t.id, a.id, bod);
  update cps.support_tickets set updated_at = now() where id = t.id;
  if a.id = t.account_id then
    perform cps.support_notify_admins(a.id,
      a.display_name || ' replied to a support ticket: ' || t.subject, t.id);
  else
    perform cps.support_notify(t.account_id,
      'An admin replied to your support ticket: ' || t.subject, t.id);
  end if;
  select * into t from cps.support_tickets where id = p_ticket;
  return cps.support_ticket_json(t, a.is_admin);
end $$;

create or replace function public.cps_admin_set_ticket_status(p_token text, p_ticket uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a  cps.accounts%rowtype;
  t  cps.support_tickets%rowtype;
  st text := lower(btrim(coalesce(p_status, '')));
begin
  a := cps.auth(p_token, true);
  if st not in ('open', 'closed') then raise exception 'Status must be open or closed.'; end if;
  select * into t from cps.support_tickets where id = p_ticket for update;
  if not found then raise exception 'Ticket not found.'; end if;
  if t.status <> st then
    if st = 'closed' then
      update cps.support_tickets
         set status = 'closed', closed_at = now(), closed_by = a.id, updated_at = now()
       where id = t.id;
    else
      update cps.support_tickets
         set status = 'open', closed_at = null, closed_by = null, updated_at = now()
       where id = t.id;
    end if;
    if t.account_id <> a.id then
      perform cps.support_notify(t.account_id,
        'Your support ticket was ' || st || ': ' || t.subject, t.id);
    end if;
  end if;
  select * into t from cps.support_tickets where id = p_ticket;
  return cps.support_ticket_json(t, true);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';
