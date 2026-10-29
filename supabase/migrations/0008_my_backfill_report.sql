-- 온보딩 "지난 30일 리포트". 카드 연결 직후 가져온 과거 결제(is_backfill)를 업종별로 센다.
-- 품목을 모르므로 칼로리는 금액 기반 대략 추정: 편의점·카페·베이커리 군것질 1,000원당 약 150kcal (화면에 '추정'으로 표시).
-- 15,000원 이상은 장보기로 보고 군것질 추정에서 뺀다 (match.ts LARGE_AMOUNT와 같음).
create or replace function public.my_backfill_report()
returns table (total_payments int, snack_payments int, snack_amount int, est_kcal int,
               top_chains jsonb, top_hours jsonb)
language sql
stable
security invoker
set search_path = ''
as $$
  with e as (
    select pe.amount, pe.paid_at, m.chain, m.category
    from public.payment_events pe
    left join public.merchants m on m.id = pe.merchant_id
    where pe.user_id = (select auth.uid()) and pe.is_backfill and not pe.is_cancel
  ),
  s as (
    select * from e
    where category in ('convenience', 'cafe', 'bakery', 'icecream') and coalesce(amount, 0) < 15000
  )
  select
    (select count(*) from e)::int,
    (select count(*) from s)::int,
    (select coalesce(sum(amount), 0) from s)::int,
    (select round(coalesce(sum(amount), 0) * 0.15) from s)::int,
    (select coalesce(jsonb_agg(jsonb_build_object('chain', chain, 'count', n) order by n desc), '[]')
       from (select chain, count(*) n from s group by chain order by n desc limit 3) t),
    (select coalesce(jsonb_agg(jsonb_build_object('hour', h, 'count', n) order by n desc), '[]')
       from (select extract(hour from paid_at at time zone 'Asia/Seoul')::int h, count(*) n
             from s group by h order by n desc limit 3) t);
$$;
