-- add_consumption: 같은 상품이 여러 번 들어오면 결과가 중복되던 문제 (ins ⨝ calc를 product_id로 조인) → 계산 결과를 바로 돌려준다.
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
    select i.product_id, i.qty,
           round(p.kcal * coalesce(s.scale, 1) * i.qty, 1) as kcal,
           round(p.sugar_g * coalesce(s.scale, 1) * i.qty, 1) as sugar_g,
           not public.is_per_package(p) and s.scale is null as needs_weight
    from i
    join public.products p on p.id = i.product_id
    left join public.user_snacks us on us.product_id = i.product_id and us.user_id = (select auth.uid())
    cross join lateral (
      select case when public.is_per_package(p) then 1 else coalesce(i.grams, us.serving_g) / 100.0 end as scale
    ) s
  ),
  ins as (
    insert into public.consumption_log (user_id, product_id, event_id, qty, kcal, sugar_g, origin)
    select (select auth.uid()), product_id, event, qty, kcal, sugar_g, origin from calc
  )
  select product_id, kcal, sugar_g, needs_weight from calc;
$$;
