-- 카드 승인 조회 기록. 사용자별 하루 호출 상한(IP 차단·비용 방지)과 감지 지연 분석에 쓴다. 서버 전용 (정책 없음).
create table public.card_queries (
  id                  bigint generated always as identity primary key,
  user_id             uuid not null references auth.users (id) on delete cascade,
  card_connection_id  uuid references public.card_connections (id) on delete set null,
  trigger             text not null check (trigger in ('tap', 'backfill', 'nightly', 'manual')),
  store_chain         text,
  called_at           timestamptz not null default now(),
  ok                  boolean not null,
  found               integer not null default 0,     -- 새로 저장된 승인 건수
  error               text
);
create index card_queries_user_called_idx on public.card_queries (user_id, called_at desc);
create index card_queries_card_connection_idx on public.card_queries (card_connection_id);
alter table public.card_queries enable row level security;

-- 앱이 탭 후 결과를 실시간으로 받도록 (RLS가 본인 행만 보내 준다)
alter publication supabase_realtime add table public.payment_events, public.predictions;
