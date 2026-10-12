-- =====================================================================
-- 086_quest_rewards.sql — Fix cps_claim_quest to award tokens vs tickets
-- correctly, using quest_reward_currency/quest_reward_amount.
-- =====================================================================

create or replace function public.cps_claim_quest(p_token text, p_key text)
returns jsonb language plpgsql security definer set search_path = cps, pg_temp as $$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
        q cps.daily_quests%rowtype;
        currency text; amount int;
        spins_now int; tokens_now int;
begin
  a := cps.auth(p_token);
  select * into q from cps.daily_quests
    where account_id = a.id and day = d and quest_key = p_key for update;
  if not found then raise exception 'Quest not found.'; end if;
  if not q.done then raise exception 'Quest is not complete yet.'; end if;
  if q.claimed_at is not null then raise exception 'Already claimed.'; end if;

  currency := cps.quest_reward_currency(p_key);
  amount := cps.quest_reward_amount(p_key);

  update cps.daily_quests set claimed_at = now()
    where account_id = a.id and day = d and quest_key = p_key;

  if currency = 'token' then
    update cps.accounts set game_tokens = coalesce(game_tokens, 0) + amount
      where id = a.id returning game_tokens into tokens_now;
    insert into cps.token_grants (account_id, tokens, reason)
      values (a.id, amount, 'quest:' || p_key);
  else
    update cps.accounts set spins = spins + amount where id = a.id returning spins into spins_now;
    insert into cps.spin_grants (account_id, spins, reason, ref)
      values (a.id, amount, 'quest', p_key);
  end if;

  return jsonb_build_object('ok', true,
    'currency', currency,
    'amount', amount,
    'tickets', case when currency = 'ticket' then amount else 0 end,
    'tokens', case when currency = 'token' then amount else 0 end,
    'spins_now', spins_now,
    'tokens_now', tokens_now);
end $$;

notify pgrst, 'reload schema';
