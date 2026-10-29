-- 1) 100g(mL)당 값인 상품: 사용자가 정한 1개 무게(g)로 환산한다.
alter table public.user_snacks add column serving_g numeric check (serving_g > 0);

-- 상품 영양값이 포장 1개 기준인지 (search_products의 per_package와 같은 규칙)
create or replace function public.is_per_package(p public.products)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select coalesce(p.source <> 'mfds' or p.serving_basis is null
    or p.serving_g_ml <> nullif(substring(p.serving_basis from '[0-9.]+'), '')::numeric, true);
$$;

-- 오늘 스택에 기록. items = [{"product_id": 46289, "qty": 2, "grams": 40}] (grams는 100g당 상품에만 의미 있음).
-- grams가 없으면 내 목록의 serving_g를 쓰고, 그것도 없으면 100g당 값을 1개로 본다(needs_weight로 알려 줌).
create or replace function public.add_consumption(items jsonb, event uuid default null, origin text default 'manual')
returns table (product_id bigint, kcal numeric, sugar_g numeric, needs_weight boolean)
language sql
security invoker
set search_path = ''
as $$
  with i as (
    select (x->>'product_id')::bigint as product_id,
           coalesce((x->>'qty')::numeric, 1) as qty,
           (x->>'grams')::numeric as grams
    from jsonb_array_elements(items) x
  ),
  calc as (
    select i.product_id, i.qty, p.kcal, p.sugar_g,
           case when public.is_per_package(p) then 1
                else coalesce(i.grams, us.serving_g) / 100.0 end as scale,
           not public.is_per_package(p) and coalesce(i.grams, us.serving_g) is null as needs_weight
    from i
    join public.products p on p.id = i.product_id
    left join public.user_snacks us on us.product_id = i.product_id and us.user_id = (select auth.uid())
  ),
  ins as (
    insert into public.consumption_log (user_id, product_id, event_id, qty, kcal, sugar_g, origin)
    select (select auth.uid()), product_id, event, qty,
           round(kcal * coalesce(scale, 1) * qty, 1), round(sugar_g * coalesce(scale, 1) * qty, 1), origin
    from calc
    returning product_id, kcal, sugar_g
  )
  select ins.product_id, ins.kcal, ins.sugar_g, calc.needs_weight
  from ins join calc using (product_id);
$$;

-- 2) 설정: 카드 연결 해제 (조회 즉시 중단, connected_id 삭제). 앱에는 card_connections 쓰기 권한이 없어 함수로 연다.
create or replace function public.revoke_card(card uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.card_connections
  set status = 'revoked', connected_id = null
  where id = card and user_id = (select auth.uid());
$$;
revoke execute on function public.revoke_card(uuid) from public, anon;
grant execute on function public.revoke_card(uuid) to authenticated;

-- 설정: 내 데이터 전체 삭제 (결제·예측·응답·스택·방문·목록·카드 연결). 계정 자체는 앱이 로그아웃한다.
create or replace function public.delete_my_data()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare uid uuid := (select auth.uid());
begin
  if uid is null then raise exception 'not signed in'; end if;
  delete from public.consumption_log where user_id = uid;
  delete from public.payment_events where user_id = uid;      -- predictions·confirmations는 cascade
  delete from public.location_visits where user_id = uid;
  delete from public.user_snacks where user_id = uid;
  delete from public.card_queries where user_id = uid;
  delete from public.card_connections where user_id = uid;
end;
$$;
revoke execute on function public.delete_my_data() from public, anon;
grant execute on function public.delete_my_data() to authenticated;

-- 3) 통계: 최근 N일 (KST 기준)
create or replace function public.my_stats(days int default 7)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (
    select cl.*, p.name, (cl.consumed_at at time zone 'Asia/Seoul') as kst
    from public.consumption_log cl
    join public.products p on p.id = cl.product_id
    where cl.user_id = (select auth.uid())
      and cl.consumed_at >= (date_trunc('day', now() at time zone 'Asia/Seoul') - make_interval(days => days - 1))
                            at time zone 'Asia/Seoul'
  )
  select jsonb_build_object(
    'days', days,
    'total_kcal', coalesce((select round(sum(kcal)) from c), 0),
    'total_sugar_g', coalesce((select round(sum(sugar_g)) from c), 0),
    'count', (select coalesce(sum(qty), 0) from c),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('date', d, 'kcal', k, 'sugar_g', s) order by d)
                       from (select kst::date d, round(sum(kcal)) k, round(sum(sugar_g)) s from c group by 1) t), '[]'),
    'top', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'count', n, 'kcal', k) order by n desc, k desc)
                     from (select name, sum(qty) n, round(sum(kcal)) k from c group by name order by n desc, k desc limit 5) t), '[]'),
    'hours', coalesce((select jsonb_agg(jsonb_build_object('hour', h, 'count', n) order by h)
                       from (select extract(hour from kst)::int h, sum(qty) n from c group by 1) t), '[]')
  );
$$;
