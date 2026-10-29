-- PostgREST upsert(on_conflict=source,source_code)는 부분 인덱스를 쓰지 못한다 → 일반 unique로 바꾼다 (NULL끼리는 겹치지 않음)
drop index public.products_source_code_uniq;
alter table public.products add constraint products_source_code_key unique (source, source_code);
