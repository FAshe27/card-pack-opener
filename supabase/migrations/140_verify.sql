-- 140_verify.sql — run AFTER 140_variant_notif_emojis.sql.
-- Each tier's announcement in cps_open_pack should now lead with its own
-- emoji: one-of-one = crown, Obsidian = new moon, Prism = gem, and the
-- Rainbow line should still lead with the rainbow. Expect all four true.
select
  p.prosrc like '%👑 %pulled a one-of-one%' as oneofone_crown,
  p.prosrc like '%🌑 %pulled Obsidian #%' as obsidian_moon,
  p.prosrc like '%💠 %pulled Prism #%' as prism_gem,
  p.prosrc like '%🌈 %pulled Rainbow #%' as rainbow_unchanged
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'cps_open_pack';
