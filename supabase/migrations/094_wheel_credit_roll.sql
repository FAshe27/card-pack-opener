-- =====================================================================
-- 094_wheel_credit_roll.sql — Fix cps.roll_wheel() to handle credit segments.
-- The 051 version handles packs/tokens; credit falls through to NULL wheel.
-- =====================================================================

create or replace function cps.roll_wheel() returns jsonb
language plpgsql volatile set search_path = cps, pg_temp as $$
declare
  cfg   jsonb := cps.wheel_config();
  hops  jsonb := '[]'::jsonb;
  wid   text  := 'w1';
  w     jsonb;
  segs  jsonb;
  total int;
  r     int;
  acc   int;
  seg   jsonb;
  s     jsonb;
  guard int := 0;
begin
  loop
    guard := guard + 1;
    if guard > 25 then raise exception 'Wheel chain too long.'; end if;
    select v into w from jsonb_array_elements(cfg -> 'wheels') v where v ->> 'id' = wid;
    if w is null then raise exception 'Unknown wheel: %', wid; end if;
    segs := w -> 'segments';
    select coalesce(sum((x ->> 'weight')::int), 0) into total
      from jsonb_array_elements(segs) x;
    if total <= 0 then raise exception 'Wheel % has no segments.', wid; end if;
    r := floor(cps.rand01() * total)::int;
    acc := 0;
    seg := null;
    for s in select value from jsonb_array_elements(segs) loop
      acc := acc + (s ->> 'weight')::int;
      if r < acc then seg := s; exit; end if;
    end loop;
    if seg is null then raise exception 'Wheel roll failed.'; end if;
    hops := hops || jsonb_build_object(
      'wheel', wid, 'key', seg ->> 'key', 'kind', seg ->> 'kind',
      'set_id', seg -> 'set_id', 'packs', (seg ->> 'packs')::int,
      'tokens', (seg ->> 'tokens')::int,
      'credit', (seg ->> 'credit')::int,
      'label', seg ->> 'label', 'goto_wheel', seg ->> 'wheel');
    if seg ->> 'kind' = 'packs' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('kind', 'packs', 'set_id', seg ->> 'set_id',
                                    'packs', (seg ->> 'packs')::int));
    elsif seg ->> 'kind' = 'tokens' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('kind', 'tokens',
                                    'tokens', (seg ->> 'tokens')::int));
    elsif seg ->> 'kind' = 'credit' then
      return jsonb_build_object('hops', hops,
        'prize', jsonb_build_object('kind', 'credit',
                                    'credit', (seg ->> 'credit')::int));
    end if;
    wid := seg ->> 'wheel';
  end loop;
end $$;

notify pgrst, 'reload schema';
