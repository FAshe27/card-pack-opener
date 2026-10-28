-- =====================================================================
-- 214: Email alerts for support tickets (Resend, via pg_net).
--
-- Franklin's ask (2026-10-27): "Is there any way I can set it up to
-- email me when a support ticket is submitted or replied to by a
-- user?" — alerts go to the support Gmail, packripperapp@gmail.com
-- (Franklin's call). He chose the instant, in-database route.
--
-- Standing rule applies: Franklin sees this SQL before it runs.
--
-- What this does, and ONLY this:
--  * Enables the pg_net extension (Supabase-supported; verified
--    available-but-not-installed on this project 2026-10-27).
--    pg_net sends HTTP asynchronously from a background queue, so
--    posting a ticket message is never slowed by email.
--  * Two config rows in cps.app_config:
--      support_alert_email = "packripperapp@gmail.com"
--      support_alert_from  = "PackRipper Support <onboarding@resend.dev>"
--    The FROM is Resend's shared test sender. After Franklin
--    verifies packripper.app in Resend (DNS records at Porkbun),
--    changing the second row to a @packripper.app address is all
--    that "graduating" takes — no new migration. Setting
--    support_alert_email to "" disables alerts entirely.
--  * ONE trigger on cps.support_messages (AFTER INSERT): when the
--    author is NOT an admin, it queues one email via Resend:
--      - the ticket's FIRST message  -> "New support ticket: <subject>"
--      - any later player message    -> "<Name> replied to: <subject>"
--    Admin messages never trigger an email (Franklin asked for
--    user submits/replies only). The email is plain text: who,
--    subject, their message, and the https://packripper.app/#help
--    link.
--  * The Resend API key is read from Supabase Vault
--    (vault.decrypted_secrets, name 'resend_api_key'). FRANKLIN
--    creates that secret himself (see RESEND-SETUP.md) — the key
--    never passes through chat, Muse, or this file. If the secret
--    is missing, the trigger quietly does nothing: alerts are
--    dormant until the key exists, and ticket posting is unaffected.
--  * FAILURE ISOLATION: the whole trigger body is wrapped so ANY
--    error (vault, pg_net, config) is swallowed — an email problem
--    can never break or block a player posting a ticket message.
--  * Nothing else is touched: no RPC is rebuilt, no client change.
--    In-game notifications (212/213) keep working exactly as-is.
--
-- EMERGENCY OFF (any time, no migration needed):
--   update cps.app_config set value = '""'::jsonb
--     where key = 'support_alert_email';
--   (or: drop trigger if exists support_alert_email_trg
--          on cps.support_messages;)
-- =====================================================================

-- pg_net: async HTTP from Postgres (creates the `net` schema itself).
create extension if not exists pg_net;

-- ---------------------------------------------------------------- config
insert into cps.app_config (key, value) values
  ('support_alert_email', '"packripperapp@gmail.com"'),
  ('support_alert_from', '"PackRipper Support <onboarding@resend.dev>"')
on conflict (key) do nothing;

-- --------------------------------------------------------- trigger logic
create or replace function cps.support_alert_email() returns trigger
language plpgsql set search_path = cps, pg_temp as $$
declare
  author  cps.accounts%rowtype;
  t       cps.support_tickets%rowtype;
  api_key text;
  to_addr text;
  from_addr text;
  is_first boolean;
  subj text;
  body_text text;
begin
  -- Email must NEVER break posting: everything is wrapped.
  begin
    select * into author from cps.accounts where id = new.author_id;
    if not found or author.is_admin then return new; end if;

    to_addr := cps.cfg('support_alert_email') #>> '{}';
    if coalesce(to_addr, '') = '' then return new; end if;
    from_addr := coalesce(cps.cfg('support_alert_from') #>> '{}',
                          'PackRipper Support <onboarding@resend.dev>');

    -- Dormant until Franklin adds the key to Vault himself.
    select decrypted_secret into api_key
      from vault.decrypted_secrets where name = 'resend_api_key';
    if coalesce(api_key, '') = '' then return new; end if;

    select * into t from cps.support_tickets where id = new.ticket_id;
    if not found then return new; end if;

    is_first := not exists (select 1 from cps.support_messages m
                             where m.ticket_id = new.ticket_id and m.id <> new.id);
    if is_first then
      subj := 'New support ticket: ' || t.subject;
      body_text := author.display_name || ' opened a new support ticket.';
    else
      subj := author.display_name || ' replied to: ' || t.subject;
      body_text := author.display_name || ' replied to a support ticket.';
    end if;
    subj := left('🎫 ' || subj, 120);
    body_text := body_text || E'\n\nSubject: ' || t.subject
              || E'\n\n' || new.body
              || E'\n\nOpen it: https://packripper.app/#help';

    perform net.http_post(
      url := 'https://api.resend.com/emails',
      headers := jsonb_build_object(
        'Authorization', 'Bearer ' || api_key,
        'Content-Type', 'application/json'),
      body := jsonb_build_object(
        'from', from_addr,
        'to', jsonb_build_array(to_addr),
        'subject', subj,
        'text', body_text));
  exception when others then
    return new;  -- swallow: see FAILURE ISOLATION in the header
  end;
  return new;
end $$;

drop trigger if exists support_alert_email_trg on cps.support_messages;
create trigger support_alert_email_trg
  after insert on cps.support_messages
  for each row execute function cps.support_alert_email();
