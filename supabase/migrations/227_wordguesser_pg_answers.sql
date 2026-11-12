-- 227_wordguesser_pg_answers.sql
-- Franklin, 2026-11-12: today's dealt answer was SPERM. His ruling:
-- keep WordGuesser PG -- no dealt word a parent could get mad about,
-- medical or not. These 21 words are demoted from the answer bank
-- (is_answer = false): they can never be dealt again, but they stay
-- legal guesses, so a real word never draws "not in word list".
-- A full read-through of all 2,334 answers produced a second,
-- borderline list (STRIP, DEMON, DEATH, IDIOT, ...) which Franklin
-- reviewed and chose to KEEP -- this migration is the clear list only.
-- In-progress games are unaffected (their answers are locked into
-- cps.wordle_games at deal time; none held any of these words).

update cps.wordle_words
   set is_answer = false
 where is_answer
   and word in ('SPERM','ERECT','HORNY','LUSTY','GONAD','GROIN','PUBIC',
                'BOOBY','THONG','BAWDY','TRAMP','ENEMA','URINE','VOMIT',
                'ABORT','OPIUM','BOOZE','BOOZY','VODKA','DRUNK','JOINT');
