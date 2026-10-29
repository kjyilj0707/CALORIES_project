# 세션 인수인계 (2026-10-29, 3차 세션 반영)

## 지금까지 한 일
### 1~2차 세션 (2026-10-19, Windows)
- 방향: **내 군것질 목록** + 결제 금액·가맹점 기반 **후보 예측** + **[예][아니요][다른 거예요] 원탭 확인** → 군것질 칼로리·당류 스택. 응답은 학습 데이터.
- 결제 흐름 검토: 카드 승인 데이터에는 품목이 없고 품목은 POS·영수증에만 있음. 결제 순간 NFC 감지는 불가능.
- v0.3: "여러 신호를 합친 확률 + 원탭 확인"으로 전환. Notion MY PROJECTS 허브 정리.
  - MY PROJECTS: https://app.notion.com/p/3febcdd75fcc81989322c5134c3e4c83
  - CALORIES_project: https://app.notion.com/p/3fdbcdd75fcc80708f8ec7908a9443ef (아직 v0.3 기준, v0.4 미반영)

### 3차 세션 (2026-10-29, Mac) → PLAN v0.4
1. **최종 산출물 = iPhone 네이티브 앱 (SwiftUI)** 로 확정.
2. 사용자 요구: **결제 알림이 핵심**. iOS는 다른 앱 알림·화면을 읽을 수 없음(OCR·화면 녹화·브라우저 모두 불가) → **카드사 승인 내역을 서버에서 직접 조회**(CODEF로 시작 → 마이데이터로 확장)하고 **우리 앱이 직접 푸시**하는 구조로 전환.
3. **카드 연결은 온보딩 첫 단계** (사용자 결정). 마케팅: *"당신이 결제하는 순간, 당신의 군것질을 알아차립니다."* 연결 직후 **지난 30일 군것질 리포트**로 가치를 바로 보여 줌.
4. **지오펜스**로 편의점 진입 감지 → 잠금화면 **라이브 액티비티** → 사용자가 탭하면 서버가 즉시 1회 조회 → "결제 순간" 감지 (B안, 연속 조회는 IP 차단 위험으로 폐기). **위치 정보 수집함** (위치정보법 검토 필요).
5. PLAN.md v0.4로 전면 갱신 (2·3·4·6·8·9·10·11·12장).

6. **백엔드 = Supabase 확정.** 조직 `CALORIES_PROJECT`(gtjxppsclhpuuakuhvla)에 프로젝트 **`calories`** 생성
   - ref: `uzhtkykhkfcqsswfityg`, 리전 **ap-northeast-2 (서울)**, Postgres 17, 무료 플랜, 아직 빈 DB
   - 무료 프로젝트 한도는 **계정당 2개** (조직별 아님). 현재: STUDY_IN_UNIV 프로젝트(도쿄, 운영 중) + calories
   - Claude Code의 Supabase 커넥터는 인증할 때 고른 조직만 보임 → 지금은 CALORIES_PROJECT만 연결됨

7. **DB 스키마 적용**: `supabase/migrations/0001_init.sql` (표 11개 + RLS), 보안 점검 이상 없음.
8. **CODEF 조사 결과** (공식 개발가이드 기준, 2026-10-29)
   - 환경: 샌드박스(가짜 데이터, 공용 키, 무료) / **데모(실제 데이터, 하루 100회, 1개월 무료, 계정당 1회만)** / 정식(건당 과금 후불, 영업일 3일 내 승인, 개인 대상 서비스는 헥토데이터와 개인정보처리 위탁계약 필요). 단가는 비공개("별도 상담").
   - 승인내역 API: `POST /v1/kr/card/p/account/approval-list` (KR_CD_P_002), 계정 등록 `/v1/account/create` (businessType CD, clientType P), 토큰 7일 유효.
   - 인증: **공동인증서 또는 아이디 로그인만** (간편인증 미지원으로 보임). 현대카드·일부 KB는 카드번호+카드 비밀번호 필요, 롯데·씨티는 SMS 추가인증 가능.
   - 과거 조회: 국민·삼성·NH·우리 12개월, 신한·롯데 6개월, 현대 3개월 → 30일 리포트는 모든 카드사에서 가능.
   - ⚠️ **과도한·배치형 호출 시 카드사가 IP를 차단할 수 있다는 공식 경고** → 연속 집중 조회 폐기, 라이브 액티비티 탭 시 1회 조회(B안)로 확정.
9. **방향 확정: B안 + 마이데이터.** 마이데이터는 정식 API라 IP 차단이 없고 통합인증(카카오·네이버·토스·PASS 등)으로 여러 카드사를 한 번에 연결 → CODEF의 두 문제를 동시에 해결. 조사 결과: 비허가 1인 개발자용 공개 B2B 상품은 없음, 직접 허가는 자본금 5억 원 등으로 비현실적 → **MVP~초기 사업은 CODEF**, 규모가 생기면 허가 사업자 제휴를 문의. 라이브 액티비티 탭은 앱을 여는 구조로 설계(마이데이터 비정기적 전송 규칙과 맞춤).
10. **CODEF 지연 측정 도구** `experiments/codef_latency/` 작성 (register_account.py, latency_probe.py: 탭 후 0·30·60·120·240·480초 조회). 오프라인 점검(응답 파싱, RSA 암호화)만 통과, **실제 호출은 키 발급 후**. 실행: `.venv/bin/python` (Python 3.9 venv). 승인내역 요청 칸 이름은 개발가이드로 재확인 필요.
   - 고정 IP는 의무 아님 (선택 기능).

11. **식약처 수집 스크립트** `catalog/mfds_collect.py` (fetch → categories → load). API는 **v03** (`FoodNtrCpntDbInfo03/getFoodNtrCpntDbInq03`), 상용제품을 받아 `DB_GRP_NM=="가공식품"` + 군것질 분류 키워드로 거름. AMT 값은 SERVING_SIZE(100g/100mL)당 → 포장 전체 중량(Z10500)으로 환산해 "한 개"당 값으로 적재 (환산 불가 시 기준량당 값, verified=false). 영양 필드: AMT_NUM1 kcal, 3 단백질, 4 지방, 6 탄수화물, 7 당류, 13 나트륨, 24 포화지방, 100 카페인. 오프라인 변환 점검만 통과, 실제 호출은 키 발급 후.
12. DB 마이그레이션 0002·0003 적용: products에 source_code·serving_basis·total_weight, unique(source, source_code).
13. 가맹점 분류 사전(마이그레이션 0004·0005): 32개 패턴 + `match_merchant(raw)` 함수, 시험 10건 통과.
14. **iOS 앱 뼈대** `ios/` (XcodeGen: `cd ios && xcodegen`, 빌드는 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 필요 — xcode-select 전환 전). iOS 17+, SwiftUI, supabase-swift 2.x. 온보딩(약속→카드사 선택→연결 자리→30일 리포트 예시→권한), 홈(오늘 스택·당류 게이지, 예시 데이터), 지오펜스(주변 20곳, 진입 시 라이브 액티비티), 위젯 확장(잠금화면·다이내믹 아일랜드, 탭하면 `calories://tap?store=` 로 앱 열림), 알림 액션 [예][아니요][다른 거예요]. 시뮬레이터용 빌드 성공. 서버 연동(TODO 주석)은 다음 단계. 번들 ID 임시값 `com.caloriesproject.app`.
15. **Edge Functions 배포** (`supabase/functions/`, verify_jwt on): `card-connect`(아이디·비번 → 서버에서 RSA 암호화 → CODEF 계정 등록 → connected_id 저장 → 30일 backfill), `tap-check`(202 즉시 응답, 백그라운드 0·20·45·90초 조회, 사용자별 하루 10회 상한, payment_events·predictions 저장). 공용: `_shared/codef.ts`(RSA PKCS#1 v1.5 직접 구현), `match.ts`(Stage 1 조합 매칭), `ingest.ts`. 오프라인 테스트 4개 통과(`deno test --allow-env --allow-read --allow-write --allow-run=openssl supabase/functions/_shared/`), 배포 후 비로그인 요청 401 확인. 마이그레이션 0006: `card_queries`(조회 기록·상한), payment_events·predictions Realtime 공개. **CODEF 시크릿 미설정** → 키 발급 후 Edge Function secrets에 CODEF_ENV/CLIENT_ID/CLIENT_SECRET/PUBLIC_KEY.
16. **iOS 서버 연동**: 익명 로그인 → 카드 연결 폼(card-connect) → 탭 딥링크(tap-check) → Realtime으로 predictions 수신 → ConfirmSheet [예][아니요][다른 거예요] → confirmations + consumption_log 저장 → 오늘 스택. 빌드 성공. **Supabase 익명 로그인이 꺼져 있음** (대시보드에서 켜야 앱 로그인 가능). 푸시(APNs)는 Apple 개발자 계정 후.
17. **CODEF 샌드박스 연동 확인**: 토큰·계정 등록·승인내역 OK. 실제 응답 칸 = resUsedDate/resUsedTime/resApprovalNo/resMemberStoreName/resUsedAmount/resCancelYN/resMemberStoreType (샌드박스는 값을 `****`로 가림). `pick()`이 resCancelAmount를 금액으로 읽던 버그 수정(테스트 추가). Supabase CLI 로그인 완료 → 함수는 `supabase functions deploy <name> --project-ref uzhtkykhkfcqsswfityg --use-api`로 로컬 파일 배포, CODEF 시크릿은 `.env`에서 `supabase secrets set --env-file`로 값 노출 없이 설정. **CLI는 STUDY_IN_UNIV 프로젝트도 보이므로 항상 --project-ref 명시.** 익명 테스트 사용자로 E2E: 연결 전 409 → card-connect 200 → tap-check 202 → 0·20·45·90초 재시도 기록 확인, RLS(본인만·card_api 직접 삽입 403) 확인.
18. **카탈로그 적재**: 식약처 상용제품 326,741건 수집 → 사용자 결정으로 **스낵류만**(FOOD_REF_NM: 비스킷/쿠키/크래커, 일반과자, 스낵과자, 전통과자, 강냉이/팝콘, 웨이퍼, 프레즐, 젤리, 사탕, 기타 사탕, 캐러멜, 마시멜로, 양갱, 껌, 초콜릿, 초콜릿과자, 초코파이) **46,799개** products 적재 (포장 1개 기준 환산 39,955개). 음료·우유·빵·아이스크림·식사류는 제외(나중에 SNACK_REFS에 추가). 같은 이름 상품이 용량·제조사별로 여러 개.
19. 마이그레이션 0007 `search_products(q)`(공백 무시·별칭·trigram), 0008 `my_backfill_report()`(30일 리포트, 칼로리는 1,000원당 150kcal 추정, 15,000원 이상 제외). iOS: 내 군것질 목록(카탈로그 검색 → 가격·주로 사는 곳·먹는 상황 입력 → user_snacks), "다른 거예요"에서 카탈로그 검색, 온보딩 30일 리포트 연결. **식약처에는 가격이 없어 사용자가 입력한 usual_price로 매칭.** 빌드 성공.
20. **지오펜스 매장 찾기 = Apple 지도(MKLocalSearch "편의점")** 기기 안에서 처리 (API 키·서버 좌표 저장 불필요, `stores` 표는 현재 미사용). significant location change마다 반경 1km에서 GS25·CU·세븐일레븐·이마트24만 골라 가까운 20곳 감시. 진입·이탈 → `location_visits`(체인+시각만). 라이브 액티비티 상태: 대기 → 탭 시 "확인 중" → 예측 수신 시 "알림 확인". 빌드 성공.
21. **검색 품질 개선** (마이그레이션 0009~0010): 상품명 꼬리 관리번호(`(sku…)`, `_123456`) 제거, `normalize_name()`(공백·대소문자·오리지날→오리지널·쵸코→초코), 순위 = 정확히 같음/별칭 1.0 > 시작 0.8 > 포함 0.5 + 유사도 + **검수 +0.3** − 박스(1kg 초과) 0.4. 결과에 `per_package`(false면 100g당 값)·`verified`. 수집 스크립트는 다시 적재해도 **verified 상품을 덮어쓰지 않음**. 사용자 제보로 검수: 킷캣 오리지널 36.5g **185kcal**(포장 표시값, 식약처 179.94) id 46289, 마이구미 오리지널 = 식약처명 "포도과즙그대로마이구미" 66g 221.76kcal id 29442 (별칭 등록). ⚠️ 남은 문제: 100g당 값인 상품을 고르면 스택에 100g 기준 칼로리가 1개로 기록됨 → 무게 입력 또는 환산 필요.
22. **사용자 본인 군것질 (시뮬레이터·도그푸딩 초기 데이터)**: 킷캣 오리지널(id 46289) **2,000원**, 마이구미 오리지널(id 29442) 가격 미확인 (웹 검색으로 GS25·CU 가격 확인 못 함, 세븐·이마트24는 청포도맛 2+1 행사 기록만) → 다음에 편의점에서 확인.
23. **시뮬레이터 실행 확인** (iOS 27.1 런타임 설치, 지원 iPhone은 **iPhone Duo**뿐, 27.0 런타임 다운로드는 중단). ⚠️ `CODE_SIGNING_ALLOWED=NO`로 빌드하면 키체인이 안 돼서 **실행할 때마다 새 익명 사용자가 생김** → 시뮬레이터 빌드는 `CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual`(로컬 서명)로. 시연 사용자 677044cc에 카드 연결(sandbox-demo)·내 목록(킷캣 2,000원, 마이구미)·마이구미 기록 1건을 넣고, GS25 4,000원 결제+예측을 DB에 넣자 앱이 Realtime으로 받아 "킷캣 오리지널 (36.5g) 2개 사 드셨나요?" 확인 화면 표시 확인. 빈 테스트 익명 사용자 3명 삭제.
24. **앱 다듬기(C)**: 마이그레이션 0011·0012 — `user_snacks.serving_g`, `is_per_package(product)`, `add_consumption(items, event, origin)`(스택 기록 단일 경로, 100g당 상품은 grams→내 목록 serving_g 순으로 환산, 없으면 needs_weight), `revoke_card(card)`·`delete_my_data()`(security definer, 본인 것만), `my_stats(days)`(KST 기준 합계·날짜별·TOP5·시간대). 트랜잭션 롤백 테스트로 계산 확인(킷캣 2개 370, 36.5g 환산 185.1). iOS: 카탈로그에서 100g당 상품 고르면 무게 입력, 홈 툴바 [+ 직접 기록][통계][내 목록][설정], 통계(7/30일, Swift Charts), 설정(카드 해제, 데이터 전체 삭제→로그아웃→새 익명 사용자). 빌드 성공.
25. **시연 도구** `experiments/sim_demo.py <UDID> <user>`: 앱 실행 → `-demoTap GS25`(디버그 빌드 전용, 라이브 액티비티 탭과 같음; simctl openurl은 "열겠습니까?" 창 때문에 자동 시연이 멈춤) → GS25 4,000원 결제·예측 삽입 → 확인 화면, `simctl io recordVideo`로 녹화. Xcode 27에는 Simulator.app이 없고 **DeviceHub.app**(`/Applications/Xcode.app/Contents/Applications/DeviceHub.app`)이 시뮬레이터 화면을 띄움. 사용자 요청으로 **iPhone 16**으로 바꾸는 중: iOS 27.1 런타임은 iPhone Duo 전용 → iOS 27.0 런타임(24A434) 내려받는 중.
26. 🐞 **확인 화면이 안 뜨던 버그 수정**: "결제 내역을 확인하고 있어요"를 alert로 띄우면, 결제를 찾았을 때 alert 닫기와 sheet 열기가 겹쳐 확인 화면이 무시됨 → 화면을 막지 않는 상단 안내 띠(safeAreaInset)로 교체. 시연 영상 `experiments/sim_demo.mp4`(iPhone Duo, 19초): 홈 → 안내 띠 → "킷캣 오리지널 (36.5g) 2개 사 드셨나요?" 확인. iOS 27.0 런타임(iPhone 16용)은 다운로드 속도가 느려 3~4시간 예상.
27. **iPhone 16 시뮬레이터로 전환**: iOS 27.0 런타임 설치(다운로드 로그에 "Registering … failed"가 찍혔지만 런타임은 정상 등록·iPhone 16 지원). 시뮬레이터 "Calories iPhone 16"(64470DE9-B589-4481-A6E5-0FE07D111453), 시연 사용자 75496d62에 같은 시연 데이터. `experiments/sim_demo_iphone16.mp4` 녹화 성공. DeviceHub를 열면 마지막에 쓴 기기(iPhone Duo)도 같이 부팅하므로 Duo는 shutdown. 서버 통합 테스트 `supabase/functions/tests/` 추가, 승인 취소 시 스택 되돌리기 구현. git 저장소 생성(main).

28. **측정용 카드 = 우리카드**(0309, 공식 확인). 주 카드 카카오뱅크는 CODEF 미지원(공식 카드사 목록 14개에 없음). 우리카드는 가맹점 정보 미제공 → memberStoreInfoType "0", 가맹점명이 비면 지오펜스 방문 체인으로 분류. 측정 도구에 `--watch` 감시 모드 추가.
29. **세션 종료 시점**: 우리카드 **웹 아이디·비밀번호를 모르는 상태** (앱은 Face ID 로그인만 됨, 아이디 찾기 중 비밀번호 3회 틀림 → 더 시도하지 말고 본인인증 재설정). README.md, docs/media(시연 캡처·영상) 추가, GitHub 비공개 저장소에 올림, Notion 반영.

## 사용자가 할 일 (2026-10-29 종료 기준)
- [x] ~~CODEF 가입·샌드박스 키~~ / ~~Supabase 익명 로그인~~ / ~~Xcode~~ / ~~식약처 키~~ / ~~Supabase secret 키~~
- [ ] **우리카드 웹 아이디·비밀번호 확보**: 우리WON카드 앱 → 전체메뉴 검색 "비밀번호" → 본인인증으로 재설정 (추측 입력 금지, 5회 잠김 주의). 아이디가 없으면 회원가입(아이디 만들기). 지문·간편비밀번호는 CODEF에 못 씀
- [ ] 측정 가능한 날 정하기 → 그날 **CODEF 데모 신청**(계정당 1회·1개월·하루 100회) → 데모 키를 `.env`에 (`CODEF_ENV=demo`)
- [ ] CODEF 문의: 계정당 안전한 조회 빈도·IP 차단 기준, 건당 단가, 정식 전환 조건, 카카오뱅크·토스뱅크 지원 계획
- [ ] Apple Developer Program 가입 여부 결정 (실기기 장기 설치·푸시·TestFlight)
- [ ] 마이구미 평소 가격 확인, 자주 먹는 군것질과 가격 더 모으기
- [ ] 주변 설문: 카드 연결 의향, 군것질용 카드 개수, 주 카드 은행·카드사(카카오뱅크·토스뱅크 비율)

## 다음 개발 순서
1. **CODEF 데모 측정**: `.env` 데모 키 → `supabase secrets set --env-file`(값 노출 없이) → `experiments/codef_latency/register_account.py`로 우리카드 연결 → `latency_probe.py --watch 40 --interval 30` → 편의점 결제 → 지연·가맹점명 확인
2. 실기기 설치(무료 계정 7일) → 지오펜스·라이브 액티비티 확인
3. 확인 대기함, UI/UX 정리 (사용자 결정: 나중에)
4. APNs (개발자 계정 후)

---

## 새 세션 시작 프롬프트 (복사해서 사용)

```
CALORIES_project 이어서 하자. 먼저 /Users/yeobby/MY_PROJECT/CALORIES_project/HANDOFF.md, PLAN.md(v0.4.1), README.md를 읽고 지금까지의 결정과 다음 단계를 파악해줘.

요약: iPhone 앱 "군것질 스택". 편의점 진입 → 잠금화면 라이브 액티비티 탭 → 서버(Supabase Edge Function tap-check)가 카드 승인 내역(CODEF, 장기 마이데이터)을 조회 → 금액으로 군것질 조합 매칭 → "킷캣 2개 사 드셨나요?" 원탭 → 칼로리·당류 스택.
백엔드: Supabase calories (ref uzhtkykhkfcqsswfityg, 서울). GitHub: kjyilj0707/CALORIES_project (비공개). 시뮬레이터: Calories iPhone 16 (iOS 27.0).

현재 진행 상황: [우리카드 아이디·비번 확보 여부 / CODEF 데모 신청 여부 / 개발자 계정]
이번 세션 목표: [예: CODEF 데모로 지연 측정 / 실기기 설치 / UI 정리]
```
