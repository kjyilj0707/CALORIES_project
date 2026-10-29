-- 가맹점 분류 사전 초기값. 승인 내역 가맹점명에 raw_pattern이 들어 있으면(대소문자·공백 무시) 그 체인으로 본다.
-- 카드사마다 표기가 달라(영문/한글/법인명) 같은 체인에 여러 패턴을 둔다. 실제 승인 내역을 보며 계속 보강한다.
insert into public.merchants (raw_pattern, chain, category, snack_likelihood) values
  -- 편의점
  ('GS25',          'GS25',       'convenience', 0.80),
  ('지에스25',       'GS25',       'convenience', 0.80),
  ('지에스리테일',    'GS25',       'convenience', 0.70),
  ('CU',            'CU',         'convenience', 0.80),
  ('씨유',           'CU',         'convenience', 0.80),
  ('비지에프리테일',   'CU',         'convenience', 0.70),
  ('세븐일레븐',      '세븐일레븐',  'convenience', 0.80),
  ('7-ELEVEN',      '세븐일레븐',  'convenience', 0.80),
  ('코리아세븐',      '세븐일레븐',  'convenience', 0.70),
  ('이마트24',       '이마트24',    'convenience', 0.80),
  ('EMART24',       '이마트24',    'convenience', 0.80),
  -- 카페
  ('스타벅스',        '스타벅스',    'cafe', 0.60),
  ('STARBUCKS',     '스타벅스',    'cafe', 0.60),
  ('투썸플레이스',     '투썸플레이스', 'cafe', 0.60),
  ('이디야',          '이디야',      'cafe', 0.60),
  ('메가엠지씨',       '메가커피',    'cafe', 0.60),
  ('메가커피',        '메가커피',    'cafe', 0.60),
  ('컴포즈커피',       '컴포즈커피',  'cafe', 0.60),
  ('빽다방',          '빽다방',      'cafe', 0.60),
  ('할리스',          '할리스',      'cafe', 0.60),
  ('폴바셋',          '폴바셋',      'cafe', 0.60),
  ('공차',            '공차',        'cafe', 0.65),
  -- 베이커리·디저트
  ('파리바게뜨',       '파리바게뜨',  'bakery', 0.55),
  ('뚜레쥬르',        '뚜레쥬르',    'bakery', 0.55),
  ('던킨',            '던킨',        'bakery', 0.70),
  ('크리스피크림',     '크리스피크림', 'bakery', 0.70),
  ('배스킨라빈스',     '배스킨라빈스', 'icecream', 0.85),
  ('설빙',            '설빙',        'icecream', 0.80),
  -- 마트 (장보기가 많아 낮게)
  ('이마트에브리데이',  '이마트에브리데이', 'mart', 0.25),
  ('홈플러스익스프레스', '홈플러스익스프레스', 'mart', 0.25),
  ('GS더프레시',      'GS더프레시',  'mart', 0.25),
  ('노브랜드',        '노브랜드',    'mart', 0.25)
on conflict (raw_pattern) do nothing;

-- 가맹점명 → merchants 매칭 함수. 공백·대소문자 무시, 여러 패턴이 맞으면 가장 긴 패턴이 이긴다.
-- 패턴 앞뒤가 영문자면 매칭하지 않는다 ("CU"가 "SECURITY"에 걸리지 않게, "CU강남역점"·"씨유(CU)"는 매칭).
create or replace function public.match_merchant(raw text)
returns bigint
language sql
stable
set search_path = ''
as $$
  select m.id
  from public.merchants m
  where upper(replace(raw, ' ', ''))
        ~ ('(^|[^A-Z])' || upper(replace(m.raw_pattern, ' ', '')) || '([^A-Z]|$)')
  order by length(m.raw_pattern) desc
  limit 1;
$$;
