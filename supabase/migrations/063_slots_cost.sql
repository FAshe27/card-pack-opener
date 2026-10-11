-- =====================================================================
-- 063_slots_cost.sql — reduce slot spin cost 3 -> 2 tokens (Franklin, 2026-10-11).
-- (Run after 062.)
--
--   Full replace of public.cps_slot_spin from 061; only the charge changes:
--     balance check < 3  -> < 2
--     deduction   - 3    -> - 2
--     error text '(need 3)' -> '(need 2)'
--
--   Economy note: EV ≈ 0.33 packs/spin at 2 tokens/spin ≈ 6 tokens per pack.
--   More generous than the 3-token pricing — Franklin's call to sit closer
--   to High/Low payouts; tune later if pack inflation shows up.
-- =====================================================================

create or replace function public.cps_slot_spin(p_token text) returns jsonb
language plpgsql security definer set search_path = cps, pg_temp as $$
declare
  a           cps.accounts%rowtype;
  bal         int;
  s1 text; s2 text; s3 text;
  tier        text := null;
  n_random    int := 0;
  n_jumbled   int := 0;
  active_sets text[];
  grants      jsonb := '[]';
  i           int;
  rset        text;
  vtext       text;
begin
  a := cps.auth(p_token);

  -- lock the account row and charge 2 tokens
  select game_tokens into bal from cps.accounts where id = a.id for update;
  if coalesce(bal, 0) < 2 then
    raise exception 'Not enough game tokens (need 2).';
  end if;
  update cps.accounts set game_tokens = game_tokens - 2 where id = a.id;

  -- roll the reels (server-authoritative)
  s1 := cps.slot_reel();
  s2 := cps.slot_reel();
  s3 := cps.slot_reel();
  if s1 = s2 and s2 = s3 then tier := s1; end if;

  if tier is not null then
    case tier
      when 'common'    then n_random := 0;  n_jumbled := 3;
      when 'uncommon'  then n_random := 3;  n_jumbled := 3;
      when 'rare'      then n_random := 5;  n_jumbled := 5;
      when 'epic'      then n_random := 10; n_jumbled := 10;
      when 'legendary' then n_random := 20; n_jumbled := 20;
      when 'chase'     then n_random := 50; n_jumbled := 25;
    end case;

    -- jumbled packs first (single grant)
    if n_jumbled > 0 then
      perform cps.add_packs(a.id, 'jumbled', n_jumbled, 'slot_win', tier, null);
    end if;

    -- random-set packs: uniform-random active set per pack
    if n_random > 0 then
      select coalesce(array_agg(id order by id), '{}') into active_sets
        from cps.card_sets where active and id <> 'jumbled';
      if coalesce(array_length(active_sets, 1), 0) = 0 then
        raise exception 'No active sets available for slot prizes.';
      end if;
      for i in 1..n_random loop
        rset := active_sets[1 + floor(cps.rand01() * array_length(active_sets, 1))::int];
        perform cps.add_packs(a.id, rset, 1, 'slot_win', tier, null);
        grants := grants || jsonb_build_object('set_id', rset, 'packs', 1);
      end loop;
    end if;

    -- daily quest hook: 'win_slots' (registered by 062)
    perform cps.quest_bump(a.id, 'win_slots', 1);

    -- global announcement for legendary + chase tiers (everyone but winner)
    if tier in ('legendary', 'chase') then
      vtext := '🎰 ' || a.display_name || ' hit ' || upper(tier) ||
               ' on the slots and won ' || (n_random + n_jumbled) || ' packs!';
      insert into cps.notifications (account_id, kind, text, target_view)
        select xx.id, 'slot_win', vtext, 'arcade'
        from cps.accounts xx where xx.id <> a.id and not coalesce(xx.disabled, false);
    end if;
  end if;

  insert into cps.slot_spins (account_id, tier, symbols, packs_random, packs_jumbled)
    values (a.id, tier, array[s1, s2, s3], n_random, n_jumbled);

  select coalesce(game_tokens, 0) into bal from cps.accounts where id = a.id;
  return jsonb_build_object(
    'symbols',       jsonb_build_array(s1, s2, s3),
    'tier',          tier,
    'win',           tier is not null,
    'packs_random',  n_random,
    'packs_jumbled', n_jumbled,
    'grants',        grants,
    'tokens_now',    bal
  );
end $$;

-- --- verification (run after executing) --------------------------------------
-- (spin once from a test account and check 2 tokens were deducted)

notify pgrst, 'reload schema';
