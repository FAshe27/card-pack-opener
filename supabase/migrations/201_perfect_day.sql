-- 201_perfect_day.sql
-- Franklin, 2026-10-27: completing the WHOLE daily board earns a
-- Perfect Day. When a claim leaves every quest on today's board
-- claimed (cps_claim_quest), the server records the day in
-- cps.daily_perfect_days (primary key account+day: it can only ever
-- pay once per day) and awards a bonus of 5 spin tickets, reported
-- back in the claim response as perfect_day {tickets, quests,
-- total_days} so the client can pop the celebration right after the
-- last Claim click. The Trophy Case gains a Special tile, Perfect
-- Day, fed by two new keys in cps_get_trophies that mirror the
-- Card of the Day pair (perfect_days count + perfect_first date).
-- Function bodies are the live definitions with only the marked
-- insertions (CRLF preserved).

create table if not exists cps.daily_perfect_days (
  account_id  uuid not null,
  day         date not null,
  awarded_at  timestamptz not null default now(),
  primary key (account_id, day)
);

CREATE OR REPLACE FUNCTION public.cps_claim_quest(p_token text, p_key text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare a cps.accounts%rowtype; d date := (now() at time zone 'America/Chicago')::date;
        q cps.daily_quests%rowtype;
        currency text; amount int;
        spins_now int; tokens_now int;
        v_pday date; v_pcount int; v_board int; v_perfect jsonb;
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

  -- [201] Perfect day: if this claim leaves today's whole board claimed
  -- and no perfect-day bonus is on record yet, award 5 spin tickets.
  if not exists (select 1 from cps.daily_quests
                  where account_id = a.id and day = d and claimed_at is null) then
    insert into cps.daily_perfect_days (account_id, day) values (a.id, d)
      on conflict do nothing returning day into v_pday;
    if v_pday is not null then
      update cps.accounts set spins = spins + 5 where id = a.id returning spins into spins_now;
      insert into cps.spin_grants (account_id, spins, reason, ref)
        values (a.id, 5, 'perfect_day', d::text);
      select count(*) into v_pcount from cps.daily_perfect_days where account_id = a.id;
      select count(*) into v_board from cps.daily_quests where account_id = a.id and day = d;
      v_perfect := jsonb_build_object('tickets', 5, 'quests', v_board, 'total_days', v_pcount);
    end if;
  end if;

  return jsonb_build_object('ok', true,
    'currency', currency,
    'amount', amount,
    'tickets', case when currency = 'ticket' then amount else 0 end,
    'tokens', case when currency = 'token' then amount else 0 end,
    'spins_now', spins_now,
    'tokens_now', tokens_now,
    'perfect_day', v_perfect);
end $function$;

CREATE OR REPLACE FUNCTION public.cps_get_trophies(p_token text, p_account uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'cps', 'pg_temp'
AS $function$
declare
  a cps.accounts%rowtype;
  v_target uuid;
  v_is_admin boolean := false;
  v_oneofone jsonb := null;
  v_turned_ts timestamptz[];
  v_packs_ts timestamptz[];
begin
  a := cps.auth(p_token);
  select id, coalesce(is_admin, false) into v_target, v_is_admin
    from cps.accounts where id = p_account and not coalesce(disabled, false);
  if v_target is null then
    raise exception 'Player not found.';
  end if;

  -- 1-of-1: the FIRST one the player ever PULLED (big_pulls ledger).
  select jsonb_build_object(
           'card_id', bp.card_id,
           'set_id', bp.set_id,
           'card_name', c.name,
           'set_name', cs.name,
           'serial', bp.variant_serial,
           'at', bp.pulled_at)
    into v_oneofone
    from cps.big_pulls bp
    left join cps.cards c on c.set_id = bp.set_id and c.card_id = bp.card_id
    left join cps.card_sets cs on cs.id = bp.set_id
   where bp.account_id = v_target and bp.variant_tier = 'oneofone'
   order by bp.pulled_at asc
   limit 1;

  -- Fallback for variant pulls that predate big_pulls variant columns:
  -- the earliest one-of-one variant the player owns.
  if v_oneofone is null then
    select jsonb_build_object(
             'card_id', v.card_id,
             'set_id', v.set_id,
             'card_name', c.name,
             'set_name', cs.name,
             'serial', v.serial,
             'at', v.pulled_at)
      into v_oneofone
      from cps.variants v
      left join cps.cards c on c.set_id = v.set_id and c.card_id = v.card_id
      left join cps.card_sets cs on cs.id = v.set_id
     where v.account_id = v_target and v.tier = 'oneofone'
       and not exists (select 1 from cps.big_pulls bp
                        where bp.set_id = v.set_id and bp.card_id = v.card_id
                          and bp.variant_tier = 'oneofone'
                          and bp.variant_serial = v.serial)
     order by v.pulled_at asc nulls last
     limit 1;
  end if;

  -- Ordered event timestamps: index N is when the Nth event happened,
  -- i.e. the day the matching tier was crossed.
  select array_agg(created_at order by created_at) into v_turned_ts
    from cps.turn_ins where account_id = v_target;
  select array_agg(opened_at order by opened_at) into v_packs_ts
    from cps.pack_openings where account_id = v_target;

  return jsonb_build_object(
    'sets', coalesce((
      select jsonb_agg(x order by x->>'set_name')
        from (
          select jsonb_build_object(
                   'set_id', t.set_id,
                   'set_name', cs.name,
                   'turned', t.turned,
                   'total', (select count(*) from cps.cards c where c.set_id = t.set_id),
                   'at', t.last_at) as x
            from (select set_id, count(*) as turned, max(created_at) as last_at
                    from cps.turn_ins where account_id = v_target group by set_id) t
            join cps.card_sets cs on cs.id = t.set_id
           where t.turned >= (select count(*) from cps.cards c where c.set_id = t.set_id)
             and (select count(*) from cps.cards c where c.set_id = t.set_id) > 0
        ) s), '[]'::jsonb),
    'progress', coalesce((
      select jsonb_agg(x order by x->>'set_id')
        from (
          select jsonb_build_object(
                   'set_id', t.set_id,
                   'turned', t.turned,
                   'total', (select count(*) from cps.cards c where c.set_id = t.set_id)) as x
            from (select set_id, count(*) as turned
                    from cps.turn_ins where account_id = v_target group by set_id) t
        ) s), '[]'::jsonb),
    'turned_total', coalesce(array_length(v_turned_ts, 1), 0),
    'turned_dates', jsonb_build_object(
      '1000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 1000 then v_turned_ts[1000] end,
      '2500', case when coalesce(array_length(v_turned_ts, 1), 0) >= 2500 then v_turned_ts[2500] end,
      '5000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 5000 then v_turned_ts[5000] end,
      '10000', case when coalesce(array_length(v_turned_ts, 1), 0) >= 10000 then v_turned_ts[10000] end),
    'packs_opened', coalesce(array_length(v_packs_ts, 1), 0),
    'packs_dates', jsonb_build_object(
      '10', case when coalesce(array_length(v_packs_ts, 1), 0) >= 10 then v_packs_ts[10] end,
      '100', case when coalesce(array_length(v_packs_ts, 1), 0) >= 100 then v_packs_ts[100] end,
      '1000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 1000 then v_packs_ts[1000] end,
      '2500', case when coalesce(array_length(v_packs_ts, 1), 0) >= 2500 then v_packs_ts[2500] end,
      '5000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 5000 then v_packs_ts[5000] end,
      '10000', case when coalesce(array_length(v_packs_ts, 1), 0) >= 10000 then v_packs_ts[10000] end),
    'oneofone', v_oneofone,
    'cotd_days', (select count(*) from cps.cotd_claims where account_id = v_target),
    'cotd_first', (select min(cotd_date) from cps.cotd_claims where account_id = v_target),
    'perfect_days', (select count(*) from cps.daily_perfect_days where account_id = v_target),
    'perfect_first', (select min(day) from cps.daily_perfect_days where account_id = v_target)
  );
end;
$function$;
