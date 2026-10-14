-- 141_verify.sql — run AFTER 141_bounty_any_number.sql.
-- Every check below should come back true.

-- 1) The bounties check swap: the named "a serial needs a tier" check is
--    in place, and the old both-or-neither check (the only other check
--    mentioning both want_tier and want_serial) is gone.
select exists (select 1 from pg_constraint
               where conrelid = 'cps.bounties'::regclass
                 and conname = 'bounties_serial_needs_tier') as new_check_present,
       not exists (select 1 from pg_constraint
                   where conrelid = 'cps.bounties'::regclass and contype = 'c'
                     and conname <> 'bounties_serial_needs_tier'
                     and pg_get_constraintdef(oid) like '%want_tier%'
                     and pg_get_constraintdef(oid) like '%want_serial%') as old_check_gone;

-- 2) cps_claim_bounty has exactly the new signature — one function,
--    (text, uuid, integer) with p_serial; the old two-argument
--    signature is gone (no overload left behind).
select (select count(*) from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'cps_claim_bounty') = 1
       and exists (select 1 from pg_proc p
                   join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname = 'cps_claim_bounty'
                     and pg_get_function_identity_arguments(p.oid)
                         = 'p_token text, p_bounty_id uuid, p_serial integer') as claim_signature_ok;

-- 3) cps_post_bounty carries the tier-only path (the serial-range check
--    is guarded on a serial actually being given).
select position('if wserial is not null and (wserial < 1 or wserial > cps.variant_run(wtier))'
                in p.prosrc) > 0 as post_tier_only_path
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'cps_post_bounty';

-- 4) cps_claim_bounty carries the any-number resolution (the pick-one
--    error text only exists in the new body).
select position('Pick which numbered copy to hand over.' in p.prosrc) > 0 as claim_any_number_live
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'cps_claim_bounty';

-- 5) cps_list_bounties carries the tier-any can_claim case.
select position('any number of the tier (141)' in p.prosrc) > 0 as list_tier_any_can_claim
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' and p.proname = 'cps_list_bounties';
