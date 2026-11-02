-- 220: "Pull 2 holos in one pack" (pull_2_holos_pack) demanded the feat TWICE.
-- The pack-open bump already requires >= 2 holos in ONE pack and adds +1 per
-- qualifying pack (proven 2026-11-02 against the opening ledger: Franklin 1
-- qualifying pack in 189 -> progress 1; Ciera 1 in 42 -> progress 1). The "2"
-- belongs to the holo count inside the pack, not the target. quest_target
-- drops the key (else-branch = 1), and today's board is corrected to match:
-- the two affected players (Franklin, Ciera — the only progress holders, both
-- unclaimed) become done at 1/1 and can claim their 3 tickets.
create or replace function cps.quest_target(p_key text)
returns integer language sql immutable set search_path to 'cps', 'pg_temp' as $function$
  select case p_key when 'open_packs' then 3 when 'open_packs_set' then 2 when 'pull_holos_3' then 3
    when 'pull_3_sets' then 3 when 'win_3_rounds' then 3 else 1 end $function$;

update cps.daily_quests
   set target = 1,
       progress = least(progress, 1),
       done = (progress >= 1 or done)
 where day = (now() at time zone 'America/Chicago')::date
   and quest_key = 'pull_2_holos_pack'
   and claimed_at is null;
