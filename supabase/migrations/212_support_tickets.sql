-- =====================================================================
-- 212: Support tickets — a super basic Help section ticket system.
--
-- Franklin's ask (2026-10-27): "A help section - submit a ticket.
-- Can we build a super basic ticket system? Only admins can see the
-- tickets submitted, but users can see every ticket they themselves
-- have submitted. Active tickets are shown in an open menu, closed
-- tickets are seen in a closed menu so it's not cluttered. End goal
-- is to link it in the top right drop down."
--
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * TWO new tables (nothing existing is touched, no existing
--    function is rebuilt):
--      cps.support_tickets  — one row per ticket: owner, subject,
--                             status ('open' / 'closed'), timestamps,
--                             who closed it.
--      cps.support_messages — the thread: the submit message plus
--                             every follow-up from the player or an
--                             admin, oldest first.
--  * SIX new public RPCs, all following the house pattern
--    (a cps.accounts%rowtype; a := cps.auth(p_token);):
--      cps_submit_ticket(p_token, p_subject, p_body)
--        Any logged-in player. Subject 1..120 chars, body 1..2000.
--        Cap: 5 OPEN tickets per player (spam brake; closed ones
--        don't count). Creates the ticket + first message and
--        notifies every admin (existing cps.notify, kind 'support',
--        target view 'help').
--      cps_list_my_tickets(p_token)
--        ONLY the caller's own tickets, split {open:[], closed:[]},
--        most recently active first. This is the privacy core of the
--        feature: there is no code path where a non-admin can read
--        another player's ticket.
--      cps_admin_list_tickets(p_token)
--        Admin-only via cps.auth(p_token, true) (non-admins get
--        42501). EVERY player's tickets, same {open, closed} split,
--        each row carrying the owner's display name (+ username,
--        which only ever leaves the server on this admin call).
--      cps_get_ticket(p_token, p_ticket)
--        One ticket + its full message thread. Owner or admin only;
--        anyone else gets 42501 'Not your ticket.'
--      cps_reply_ticket(p_token, p_ticket, p_body)
--        Owner or admin, OPEN tickets only (a closed ticket is
--        read-only until an admin reopens it). Body 1..2000 chars.
--        An admin reply notifies the owner; a player reply notifies
--        every admin (kind 'support', view 'help').
--      cps_admin_set_ticket_status(p_token, p_ticket, p_status)
--        Admin-only. 'closed' stamps closed_at / closed_by;
--        'open' (reopen) clears both. Notifies the owner when an
--        admin changes it (unless the admin owns the ticket).
--  * Both tables get RLS enabled with no policies (the 001 lock
--    model: the private cps schema is only reachable through these
--    SECURITY DEFINER RPCs anyway).
--
-- Player-facing name note: in PackRipper "ticket" already means the
-- spin ticket (🎟️), so the client labels this "Help & Support" and
-- calls these "support tickets" in full wherever there's room.
--
-- EMERGENCY OFF (any time, SQL editor / connector, no client push
-- needed): drop the six RPCs and the two tables —
--   drop function if exists public.cps_submit_ticket(text, text, text);
--   drop function if exists public.cps_list_my_tickets(text);
--   drop function if exists public.cps_admin_list_tickets(text);
--   drop function if exists public.cps_get_ticket(text, uuid);
--   drop function if exists public.cps_reply_ticket(text, uuid, text);
--   drop function if exists public.cps_admin_set_ticket_status(text, uuid, text);
--   drop table if exists cps.support_messages;
--   drop table if exists cps.support_tickets;
-- =====================================================================

-- ---------------------------------------------------------------- tables
create table if not exists cps.support_tickets (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references cps.accounts(id) on delete cascade,
  subject    text not null,
  status     text not null default 'open' check (status in ('open', 'closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at  timestamptz,
  closed_by  uuid references cps.accounts(id) on delete set null
);
create index if not exists support_tickets_owner_idx
  on cps.support_tickets (account_id, status, updated_at desc);
create index if not exists support_tickets_status_idx
  on cps.support_tickets (status, updated_at desc);
alter table cps.support_tickets enable row level security;

create table if not exists cps.support_messages (
  id         uuid primary key default gen_random_uuid(),
  ticket_id  uuid not null references cps.support_tickets(id) on delete cascade,
  author_id  uuid not null references cps.accounts(id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now()
);
create index if not exists support_messages_ticket_idx
  on cps.support_messages (ticket_id, created_at);
alter table cps.support_messages enable row level security;

-- ------------------------------------------------------- internal helper
-- One ticket as the list RPCs return it: identity + activity summary,
-- never the full thread (cps_get_ticket is the only thread reader).
-- p_admin_view adds the owner's username (admin calls only).
create or replace function cps.support_ticket_json(p_t cps.support_tickets, p_admin_view boolean)
returns jsonb language sql stable set search_path = cps, pg_temp as $$
  select jsonb_build_object(
    'id', p_t.id,
    'subject', p_t.subject,
    'status', p_t.status,
    'created_at', p_t.created_at,
    'updated_at', p_t.updated_at,
    'closed_at', p_t.closed_at,
    'owner_id', p_t.account_id,
    'owner_name', (select display_name from cps.accounts where id = p_t.account_id),
    'owner_username', case when p_admin_view
                           then (select username from cps.accounts where id = p_t.account_id)
                           else null end,
    'message_count', (select count(*) from cps.support_messages m where m.ticket_id = p_t.id),
    'last_body', (select left(m.body, 140) from cps.support_messages m
                   where m.ticket_id = p_t.id order by m.created_at desc limit 1),
    'last_at', (select m.created_at from cps.support_messages m
                 where m.ticket_id = p_t.id order by m.created_at desc limit 1)
  );
$$;

-- Tell every admin (except the actor) something happened.
create or replace function cps.support_notify_admins(p_actor uuid, p_text text)
returns void language plpgsql set search_path = cps, pg_temp as $$
declare adm uuid;
begin
  for adm in select id from cps.accounts
              where is_admin and not disabled and id <> p_actor loop
    perform cps.notify(adm, 'support', p_text, 'help');
  end loop;
end $$;

-- ---------------------------------------------------------------- submit
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
    a.display_name || ' opened a support ticket: ' || sub);
  return cps.support_ticket_json(t, a.is_admin);
end $$;

-- ------------------------------------------------------------- my tickets
create or replace function public.cps_list_my_tickets(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token);
  return jsonb_build_object(
    'is_admin', a.is_admin,
    'open', coalesce((select jsonb_agg(cps.support_ticket_json(t, false) order by t.updated_at desc)
                        from cps.support_tickets t
                       where t.account_id = a.id and t.status = 'open'), '[]'),
    'closed', coalesce((select jsonb_agg(cps.support_ticket_json(t, false) order by t.updated_at desc)
                          from cps.support_tickets t
                         where t.account_id = a.id and t.status = 'closed'), '[]'));
end $$;

-- ---------------------------------------------------------- admin tickets
create or replace function public.cps_admin_list_tickets(p_token text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype;
begin
  a := cps.auth(p_token, true);
  return jsonb_build_object(
    'open', coalesce((select jsonb_agg(cps.support_ticket_json(t, true) order by t.updated_at desc)
                        from cps.support_tickets t
                       where t.status = 'open'), '[]'),
    'closed', coalesce((select jsonb_agg(cps.support_ticket_json(t, true) order by t.updated_at desc)
                          from cps.support_tickets t
                         where t.status = 'closed'), '[]'));
end $$;

-- -------------------------------------------------------------- one ticket
create or replace function public.cps_get_ticket(p_token text, p_ticket uuid)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a cps.accounts%rowtype;
  t cps.support_tickets%rowtype;
begin
  a := cps.auth(p_token);
  select * into t from cps.support_tickets where id = p_ticket;
  if not found then raise exception 'Ticket not found.'; end if;
  if t.account_id <> a.id and not a.is_admin then
    raise exception 'Not your ticket.' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'ticket', cps.support_ticket_json(t, a.is_admin),
    'mine', t.account_id = a.id,
    'messages', coalesce((select jsonb_agg(jsonb_build_object(
                'id', m.id,
                'body', m.body,
                'created_at', m.created_at,
                'author_id', m.author_id,
                'author_name', x.display_name,
                'author_is_admin', x.is_admin,
                'mine', m.author_id = a.id)
              order by m.created_at asc)
            from cps.support_messages m
            join cps.accounts x on x.id = m.author_id
            where m.ticket_id = t.id), '[]'));
end $$;

-- ------------------------------------------------------------------ reply
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
      a.display_name || ' replied to a support ticket: ' || t.subject);
  else
    perform cps.notify(t.account_id, 'support',
      'An admin replied to your support ticket: ' || t.subject, 'help');
  end if;
  select * into t from cps.support_tickets where id = p_ticket;
  return cps.support_ticket_json(t, a.is_admin);
end $$;

-- ------------------------------------------------------- admin open/close
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
      perform cps.notify(t.account_id, 'support',
        'Your support ticket was ' || st || ': ' || t.subject, 'help');
    end if;
  end if;
  select * into t from cps.support_tickets where id = p_ticket;
  return cps.support_ticket_json(t, true);
end $$;

-- let the API pick up the change right away
notify pgrst, 'reload schema';

-- anon key needs execute rights on the new functions
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.cps_submit_ticket(text, text, text) to anon;
    grant execute on function public.cps_list_my_tickets(text) to anon;
    grant execute on function public.cps_admin_list_tickets(text) to anon;
    grant execute on function public.cps_get_ticket(text, uuid) to anon;
    grant execute on function public.cps_reply_ticket(text, uuid, text) to anon;
    grant execute on function public.cps_admin_set_ticket_status(text, uuid, text) to anon;
  end if;
end $$;
