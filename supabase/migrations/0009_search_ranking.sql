-- 검색 개선 (2026-10-29, "킷캣 오리지날" 검색 실패에서 발견)
-- 1) 식약처 상품명 꼬리의 관리번호 제거: "킷캣 오리지널 (36.5g)(sku12535321)", "킷캣 골드_12374755"
update public.products
set name = trim(regexp_replace(regexp_replace(name, '\s*\(sku\d+\)', '', 'gi'), '_\d{6,}$', ''))
where name ~* '\(sku\d+\)|_\d{6,}$';

-- 2) 표기 흔들림 정규화 (오리지날→오리지널 등) + 공백 제거 + 소문자
create or replace function public.normalize_name(s text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(replace(replace(replace(replace(s, ' ', ''), '오리지날', '오리지널'), '쵸코', '초코'), '쵸콜릿', '초콜릿'));
$$;

-- 3) 순위: 정확히 같음 > 검색어로 시작 > 포함 > 유사, 박스 단위(1kg/1L 초과)는 아래로
create or replace function public.search_products(q text, lim int default 20)
returns table (id bigint, name text, manufacturer text, category text, kcal numeric, sugar_g numeric,
               serving_g_ml numeric, score real)
language sql
stable
security invoker
set search_path = ''
as $$
  with term as (select public.normalize_name(trim(q)) as t)
  select p.id, p.name, p.manufacturer, p.category, p.kcal, p.sugar_g, p.serving_g_ml,
         (case
            when public.normalize_name(p.name) = term.t or term.t = any (p.aliases) then 1.0
            when public.normalize_name(p.name) like term.t || '%' then 0.8
            when public.normalize_name(p.name) like '%' || term.t || '%' then 0.5
            else 0
          end
          + 0.3 * extensions.similarity(public.normalize_name(p.name), term.t)
          - case when p.serving_g_ml > 1000 then 0.4 else 0 end)::real as score
  from public.products p, term
  where length(term.t) > 0
    and (public.normalize_name(p.name) like '%' || term.t || '%'
         or term.t = any (p.aliases)
         or p.name operator(extensions.%) q)
  order by score desc, p.verified desc, length(p.name)
  limit least(lim, 50);
$$;
