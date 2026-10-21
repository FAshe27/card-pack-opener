-- 170_remove_matchmaker.sql
-- Removes the Wantlist + Trade Matchmaker feature (built in 167 + 168,
-- live 2026-10-21) at Franklin's direction the same day: he is shelving
-- it until he has more time to work on it, and chose full removal
-- including the data ('Remove everything, including the data').
-- The only wantlist rows in existence were Franklin's own (44 rows, one
-- account). Client surface was reverted in the same ship (app.js /
-- market.js / index.html inverses of the 167 hooks; js/matchmaker.js
-- and css/matchmaker.css deleted).
-- Restore path: re-run 167_matchmaker.sql then
-- 168_matchmaker_turnedin.sql and re-push the client files from the
-- matchmaker package (~/workspace/your_files/matchmaker-package/).

drop function if exists public.cps_matchmaker_wanted_mine(text);
drop function if exists public.cps_matchmaker_matches(text);
drop function if exists public.cps_wantlist_list(text);
drop function if exists public.cps_wantlist_remove(text, text, text);
drop function if exists public.cps_wantlist_add(text, text, text, text);
drop function if exists cps.mm_purge_turned_in(uuid);
drop function if exists cps.mm_spare(uuid, text, text, integer, integer, integer, integer);
drop function if exists cps.mm_rarity_rank(text);
drop table if exists cps.wantlist;

notify pgrst, 'reload schema';
