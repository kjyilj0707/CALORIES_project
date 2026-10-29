-- CALORIES_project 초기 스키마 (PLAN.md v0.4, 4장)
-- 카탈로그(products 등)는 로그인 사용자 읽기 전용, 쓰기는 서버(service role)만.
-- 사용자 데이터는 RLS로 본인 행만. 카드 승인 조회·예측은 서버가 쓴다.

create extension if not exists pg_trgm with schema extensions;

-- ---------- 4.1 마스터 카탈로그 ----------

create table public.products (
  id            bigint generated always as identity primary key,
  name          text not null,
  brand         text,
  manufacturer  text,
  category      text,                 -- 과자, 음료, 아이스크림, 빵, 삼각김밥, 커피 등
  barcode       text unique,
  serving_g_ml  numeric,
  kcal          numeric,
  sugar_g       numeric,
  carb_g        numeric,
  protein_g     numeric,
  fat_g         numeric,
  sat_fat_g     numeric,
  sodium_mg     numeric,
  caffeine_mg   numeric,
  aliases       text[] not null default '{}',   -- 검색용 별칭 ("뚱바")
  source        text not null default 'manual'
                check (source in ('mfds', 'barcode_api', 'manual', 'user_report')),
  verified      boolean not null default false,
  updated_at    timestamptz not null default now()
);
create index products_name_trgm on public.products using gin (name extensions.gin_trgm_ops);

create table public.product_prices (
  id          bigint generated always as identity primary key,
  product_id  bigint not null references public.products (id) on delete cascade,
  chain       text not null,          -- GS25 / CU / 세븐일레븐 / 이마트24 / 기타
  price       integer not null check (price >= 0),
  promo_type  text check (promo_type in ('1+1', '2+1', 'discount')),
  valid_from  date,
  valid_to    date
);
create index product_prices_product_idx on public.product_prices (product_id);
create index product_prices_chain_price_idx on public.product_prices (chain, price);

create table public.merchants (
  id                bigint generated always as identity primary key,
  raw_pattern       text not null unique,   -- 승인 내역 가맹점명 패턴 ("지에스25")
  chain             text,
  category          text,                   -- convenience / cafe / bakery / mart / icecream / other
  snack_likelihood  real not null default 0 check (snack_likelihood between 0 and 1)
);

create table public.stores (
  id      bigint generated always as identity primary key,
  chain   text not null,
  name    text not null,
  lat     double precision not null,
  lng     double precision not null,
  source  text
);
create index stores_lat_lng_idx on public.stores (lat, lng);

-- ---------- 4.2 사용자 데이터 ----------

create table public.card_connections (
  id                     uuid primary key default gen_random_uuid(),
  user_id                uuid not null references auth.users (id) on delete cascade,
  provider               text not null default 'codef' check (provider in ('codef', 'mydata')),
  card_company           text not null,
  connected_id           text,          -- 조회용 연결 ID. 카드사 자격 증명 원문은 저장하지 않는다
  auth_method            text,          -- id_pw / cert / simple_auth 등
  status                 text not null default 'active' check (status in ('active', 'expired', 'error', 'revoked')),
  last_polled_at         timestamptz,
  last_seen_approval_at  timestamptz,
  created_at             timestamptz not null default now()
);
create index card_connections_user_idx on public.card_connections (user_id);

create table public.user_snacks (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references auth.users (id) on delete cascade,
  product_id        bigint not null references public.products (id),
  custom_name       text,
  usual_price       integer,
  usual_stores      text[] not null default '{}',
  occasions         text[] not null default '{}',   -- 출근길, 점심 후, 공부·야근, 스트레스, 야식 ...
  usual_time_slots  text[] not null default '{}',   -- "15:00-16:00" 형식
  frequency_hint    text,
  is_active         boolean not null default true,
  created_at        timestamptz not null default now(),
  unique (user_id, product_id)
);
create index user_snacks_product_idx on public.user_snacks (product_id);

create table public.payment_events (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references auth.users (id) on delete cascade,
  source              text not null check (source in ('card_api', 'sms', 'wallet', 'geofence', 'habit', 'manual')),
  card_connection_id  uuid references public.card_connections (id) on delete set null,
  approval_no         text,             -- 카드 승인번호 (중복 방지, 취소 매칭)
  merchant_raw        text,
  merchant_id         bigint references public.merchants (id),
  amount              integer,          -- 지오펜스·습관 이벤트는 비어 있을 수 있음
  paid_at             timestamptz,
  detected_at         timestamptz not null default now(),   -- paid_at과의 차이 = 감지 지연
  is_cancel           boolean not null default false,
  is_backfill         boolean not null default false,       -- 온보딩 30일 리포트용 과거 내역
  created_at          timestamptz not null default now()
);
create index payment_events_user_paid_idx on public.payment_events (user_id, paid_at desc);
create index payment_events_card_connection_idx on public.payment_events (card_connection_id);
create index payment_events_merchant_idx on public.payment_events (merchant_id);
create unique index payment_events_approval_uniq
  on public.payment_events (card_connection_id, approval_no, is_cancel)
  where approval_no is not null;

create table public.location_visits (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  store_chain  text not null,           -- 좌표는 저장하지 않는다
  entered_at   timestamptz not null,
  exited_at    timestamptz
);
create index location_visits_user_entered_idx on public.location_visits (user_id, entered_at desc);

create table public.predictions (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references public.payment_events (id) on delete cascade,
  user_id         uuid not null references auth.users (id) on delete cascade,
  is_snack_score  real,
  candidates      jsonb not null default '[]',   -- [{items:[{product_id, qty}], score}]
  model_version   text not null default 'stage1',
  notified_at     timestamptz,
  created_at      timestamptz not null default now()
);
create index predictions_event_idx on public.predictions (event_id);
create index predictions_user_idx on public.predictions (user_id);

create table public.confirmations (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null unique references public.payment_events (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  response      text not null check (response in ('yes', 'no', 'different', 'ignored')),
  final_items   jsonb not null default '[]',   -- [{product_id, qty}]
  responded_at  timestamptz not null default now(),
  latency_sec   integer
);
create index confirmations_user_idx on public.confirmations (user_id);

create table public.consumption_log (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  product_id   bigint not null references public.products (id),
  event_id     uuid references public.payment_events (id) on delete set null,
  qty          numeric not null default 1 check (qty > 0),
  consumed_at  timestamptz not null default now(),
  kcal         numeric,        -- 기록 시점 영양값 스냅샷
  sugar_g      numeric,
  origin       text not null default 'manual' check (origin in ('auto_confirm', 'manual', 'receipt', 'backfill'))
);
create index consumption_log_user_consumed_idx on public.consumption_log (user_id, consumed_at desc);
create index consumption_log_product_idx on public.consumption_log (product_id);
create index consumption_log_event_idx on public.consumption_log (event_id);

-- ---------- RLS ----------

alter table public.products          enable row level security;
alter table public.product_prices    enable row level security;
alter table public.merchants         enable row level security;
alter table public.stores            enable row level security;
alter table public.card_connections  enable row level security;
alter table public.user_snacks       enable row level security;
alter table public.payment_events    enable row level security;
alter table public.location_visits   enable row level security;
alter table public.predictions       enable row level security;
alter table public.confirmations     enable row level security;
alter table public.consumption_log   enable row level security;

-- 카탈로그: 로그인 사용자 읽기 전용
create policy "catalog read" on public.products       for select to authenticated using (true);
create policy "catalog read" on public.product_prices for select to authenticated using (true);
create policy "catalog read" on public.merchants      for select to authenticated using (true);
create policy "catalog read" on public.stores         for select to authenticated using (true);

-- 카드 연결·예측: 본인 것 읽기만 (쓰기는 서버)
create policy "own read" on public.card_connections for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own read" on public.predictions for select to authenticated
  using (user_id = (select auth.uid()));

-- 결제 이벤트: 본인 것 읽기, 앱에서 만드는 이벤트(card_api 제외)만 추가
create policy "own read" on public.payment_events for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own insert from app" on public.payment_events for insert to authenticated
  with check (user_id = (select auth.uid()) and source <> 'card_api' and card_connection_id is null);

-- 지오펜스 방문: 본인 것 읽기·추가·이탈 시각 갱신
create policy "own read" on public.location_visits for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own insert" on public.location_visits for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "own update" on public.location_visits for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- 응답(라벨): 본인 것 읽기·추가·수정
create policy "own read" on public.confirmations for select to authenticated
  using (user_id = (select auth.uid()));
create policy "own insert" on public.confirmations for insert to authenticated
  with check (user_id = (select auth.uid())
              and exists (select 1 from public.payment_events e
                          where e.id = event_id and e.user_id = (select auth.uid())));
create policy "own update" on public.confirmations for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- 내 군것질 목록·스택: 본인 것 전부
create policy "own all" on public.user_snacks for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own all" on public.consumption_log for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
