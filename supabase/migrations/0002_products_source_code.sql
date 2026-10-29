-- 외부 출처의 상품 코드 (식약처 식품코드 등). 수집 스크립트가 (source, source_code)로 upsert 한다.
alter table public.products add column source_code text;
alter table public.products add column serving_basis text;      -- 영양성분 기준량 원문 ("100g", "1회 제공량 200ml")
alter table public.products add column total_weight text;       -- 식품 전체 중량 원문 ("200ml")
create unique index products_source_code_uniq on public.products (source, source_code)
  where source_code is not null;
