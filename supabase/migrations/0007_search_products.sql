-- 카탈로그 검색 ("바나나" → 바나나맛우유, "뚱바" → 별칭). 이름·별칭 부분일치 + trigram 유사도 순.
-- 공백을 무시해서 "바나나 우유"도 "바나나맛우유"를 찾는다.
create index products_aliases_idx on public.products using gin (aliases);

create or replace function public.search_products(q text, lim int default 20)
returns table (id bigint, name text, manufacturer text, category text, kcal numeric, sugar_g numeric,
               serving_g_ml numeric, score real)
language sql
stable
security invoker
set search_path = ''
as $$
  with term as (select replace(trim(q), ' ', '') as t)
  select p.id, p.name, p.manufacturer, p.category, p.kcal, p.sugar_g, p.serving_g_ml,
         greatest(
           extensions.similarity(replace(p.name, ' ', ''), term.t),
           case when replace(p.name, ' ', '') ilike '%' || term.t || '%' then 0.5 else 0 end,
           case when term.t = any (p.aliases) then 1 else 0 end
         )::real as score
  from public.products p, term
  where length(term.t) > 0
    and (replace(p.name, ' ', '') ilike '%' || term.t || '%'
         or term.t = any (p.aliases)
         or p.name operator(extensions.%) term.t)
  order by score desc, p.verified desc, length(p.name)
  limit least(lim, 50);
$$;
