-- 영문자 경계 검사는 패턴의 첫·끝 글자가 영문자일 때만 한다 ("이마트24 R역삼" 매칭, "SECURITY"는 CU로 안 봄).
-- 원문 그대로와 공백을 지운 형태 둘 다 검사한다 ("GS 25"와 "CU R역삼" 모두 대응).
create or replace function public.match_merchant(raw text)
returns bigint
language sql
stable
set search_path = ''
as $$
  with p as (
    select m.id, m.raw_pattern,
           (case when upper(left(m.raw_pattern, 1)) ~ '[A-Z]' then '(^|[^A-Z])' else '' end)
           || upper(m.raw_pattern)
           || (case when upper(right(m.raw_pattern, 1)) ~ '[A-Z]' then '([^A-Z]|$)' else '' end) as re
    from public.merchants m
  )
  select p.id
  from p
  where upper(raw) ~ p.re or upper(replace(raw, ' ', '')) ~ p.re
  order by length(p.raw_pattern) desc
  limit 1;
$$;
