-- 검색 결과에 '포장 1개 기준인지(per_package)'를 함께 준다. 식약처 값을 포장 중량으로 환산하지 못한 상품은
-- 100g(mL)당 값이므로 앱에서 "100g당"으로 표시한다. 반환 칸이 바뀌어 함수를 다시 만든다.
drop function public.search_products(text, int);

create function public.search_products(q text, lim int default 20)
returns table (id bigint, name text, manufacturer text, category text, kcal numeric, sugar_g numeric,
               serving_g_ml numeric, per_package boolean, verified boolean, score real)
language sql
stable
security invoker
set search_path = ''
as $$
  with term as (select public.normalize_name(trim(q)) as t)
  select p.id, p.name, p.manufacturer, p.category, p.kcal, p.sugar_g, p.serving_g_ml,
         -- 환산된 상품은 serving_g_ml에 포장 중량이 들어 있다 (mfds_collect.to_product)
         coalesce(p.source <> 'mfds' or p.serving_basis is null
          or p.serving_g_ml <> nullif(substring(p.serving_basis from '[0-9.]+'), '')::numeric, true) as per_package,
         p.verified,
         (case
            when public.normalize_name(p.name) = term.t or term.t = any (p.aliases) then 1.0
            when public.normalize_name(p.name) like term.t || '%' then 0.8
            when public.normalize_name(p.name) like '%' || term.t || '%' then 0.5
            else 0
          end
          + 0.3 * extensions.similarity(public.normalize_name(p.name), term.t)
          + case when p.verified then 0.3 else 0 end   -- 사람이 검수한 상품(실제 포장 확인) 우선
          - case when p.serving_g_ml > 1000 then 0.4 else 0 end)::real as score
  from public.products p, term
  where length(term.t) > 0
    and (public.normalize_name(p.name) like '%' || term.t || '%'
         or term.t = any (p.aliases)
         or p.name operator(extensions.%) q)
  order by score desc, p.verified desc, length(p.name)
  limit least(lim, 50);
$$;
