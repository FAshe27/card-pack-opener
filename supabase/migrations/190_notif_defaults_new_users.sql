-- =====================================================================
-- PackRipper — migration 190: New-user notification defaults
-- (Numbered 190 because 189 is the staged, not-yet-run OAuth login.)
--
-- Franklin's ask (2026-10-26): "Can we have Chase, Rainbow, and Prism
-- notifications off by default? I don't want to change any active
-- users' notifications — this is just going forward."
--
-- Why this is ONLY a column-default change:
--   * Since migration 129, cps.accounts.notif_prefs defaults to '{}'
--     and cps.notif_wants() resolves a MISSING key to ON. Flipping
--     that fallback would silently change every existing account
--     that never opened Notification Settings — checked live
--     2026-10-26: 21 accounts total, 16 still carry '{}', 4 carry an
--     explicit all-ON object, and 1 carries explicit Chase/Rainbow
--     OFF. Those 16 must keep today's all-ON behavior.
--   * So this migration touches NO existing row and NO function.
--     It only changes what a NEW row gets: instead of '{}', a new
--     account is created with the fully-explicit object below.
--   * Every account-creation path inserts WITHOUT naming notif_prefs
--     (verified live 2026-10-26: cps.create_account, used by
--     cps_admin_create_account; the staged OAuth 189 insert also
--     omits it), so every future account inherits this default.
--   * Because the stored value is explicit booleans, everything
--     downstream already does the right thing with no client change:
--     cps_get_notif_prefs resolves it as-is, the Notification
--     Settings screen renders Chase/Rainbow/Prism unchecked and
--     Obsidian/1-of-1 checked, and cps_list_notifications filters
--     via cps.notif_visible on those booleans.
--   * Obsidian and 1-of-1 stay ON by default (not in Franklin's ask).
-- =====================================================================

alter table cps.accounts
  alter column notif_prefs set default
  '{"chase":false,"rainbow":false,"prism":false,"obsidian":true,"oneofone":true}'::jsonb;

notify pgrst, 'reload schema';

-- Verify after running:
--   1. Existing accounts untouched (counts must match pre-run):
--        select notif_prefs, count(*) from cps.accounts
--         group by notif_prefs order by count(*) desc;
--      Pre-run (2026-10-26): '{}' x16, all-true x4,
--      {chase:false,rainbow:false, others true} x1.
--   2. New default in place:
--        select column_default from information_schema.columns
--         where table_schema='cps' and table_name='accounts'
--           and column_name='notif_prefs';
--      -> the explicit object above.
--   3. Real-world: create a test account in the admin panel — its
--      Notification Settings open with Chase/Rainbow/Prism OFF and
--      Obsidian/1-of-1 ON, and existing players see no change.
