begin;
create temp table smoke215 (k text, v text) on commit drop;
insert into cps.sessions (account_id, token_hash, expires_at)
  values ('51bfb41a-df9a-467b-a287-778e33ea17c7', cps.hash_text('smoke-215-token-abcdefghij'), now() + interval '1 hour');
update cps.accounts set store_credit = 100000 where id = '51bfb41a-df9a-467b-a287-778e33ea17c7';
do $$
declare
  tok text := 'smoke-215-token-abcdefghij';
  st jsonb; b3 int; b4 int; lim3 int; lim4 int;
  ok int; i int; msg text; r jsonb;
begin
  st := public.cps_shop_status(tok);
  select (s->>'bought')::int, (s->>'limit')::int into b3, lim3 from jsonb_array_elements(st->'slots') s where (s->>'slot')::int = 3;
  select (s->>'bought')::int, (s->>'limit')::int into b4, lim4 from jsonb_array_elements(st->'slots') s where (s->>'slot')::int = 4;
  insert into smoke215 values ('limits', lim3 || '/' || lim4), ('bought_start', b3 || '/' || b4);
  ok := 0; msg := '';
  for i in 1 .. (lim3 - b3 + 1) loop
    begin
      perform public.cps_shop_buy(tok, 3); ok := ok + 1;
    exception when others then msg := sqlerrm; exit;
    end;
  end loop;
  insert into smoke215 values ('slot3_singles_ok', ok::text), ('slot3_block_msg', msg);
  begin
    r := public.cps_shop_buy_all(tok, 4);
    insert into smoke215 values ('slot4_buyall_count', (r->>'count'));
  exception when others then
    insert into smoke215 values ('slot4_buyall_error', sqlerrm);
  end;
  begin
    perform public.cps_shop_buy(tok, 4);
    insert into smoke215 values ('slot4_after_buyall', 'BOUGHT (unexpected)');
  exception when others then
    insert into smoke215 values ('slot4_after_buyall', sqlerrm);
  end;
  st := public.cps_shop_status(tok);
  select (s->>'bought')::int into b3 from jsonb_array_elements(st->'slots') s where (s->>'slot')::int = 3;
  select (s->>'bought')::int into b4 from jsonb_array_elements(st->'slots') s where (s->>'slot')::int = 4;
  insert into smoke215 values ('bought_end', b3 || '/' || b4);
end $$;
select k, v from smoke215 order by k;
rollback;
