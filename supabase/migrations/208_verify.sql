-- 208_verify.sql — post-auth smoke for migration 208 (run AFTER 208).
-- Plants a temp session for a real account, calls cps_get_profile for
-- real, asserts turned_cards mirrors cps.turn_ins, removes the session.
-- Leaves no residue.
do $$
declare
  tgt  cps.accounts%rowtype;
  tok  text := 'diag-208-verify-token';
  prof jsonb;
  n_db int;
  n_js int;
begin
  delete from cps.sessions where token_hash = cps.hash_text(tok);
  select * into tgt from cps.accounts where display_name = 'Ciera' and not disabled;
  if not found then raise exception 'verify: target account not found'; end if;
  insert into cps.sessions (token_hash, account_id, created_at, last_used_at, expires_at)
  values (cps.hash_text(tok), tgt.id, now(), now(), now() + interval '1 hour');
  prof := public.cps_get_profile(tok, tgt.id);
  delete from cps.sessions where token_hash = cps.hash_text(tok);
  if not (prof ? 'turned_cards') then raise exception 'verify: turned_cards key missing'; end if;
  select count(*) into n_db from cps.turn_ins where account_id = tgt.id;
  n_js := jsonb_array_length(prof -> 'turned_cards');
  if n_js <> n_db then
    raise exception 'verify: turned_cards length % <> turn_ins rows %', n_js, n_db;
  end if;
  if n_db > 0 and not ((prof -> 'turned_cards' -> 0) ? 'set_id'
                   and (prof -> 'turned_cards' -> 0) ? 'card_id'
                   and (prof -> 'turned_cards' -> 0) ? 'holo') then
    raise exception 'verify: turned_cards element shape wrong';
  end if;
  raise notice '208 VERIFY PASS: turned_cards=% rows for %', n_js, tgt.display_name;
end $$;
