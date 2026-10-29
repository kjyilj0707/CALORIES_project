// 라이브 액티비티 탭 → 카드 승인 내역 조회 (PLAN.md 2.3 B안).
// 바로 202를 돌려주고, 백그라운드에서 0·20·45·90초에 조회한다 (새 승인을 찾으면 멈춤).
// 결과는 payment_events / predictions 에 저장되고, 앱은 Realtime으로 받는다.
import { admin, json, requestUser } from "../_shared/supabase.ts";
import { type CardConnection, DAILY_QUERY_LIMIT, queriesToday, queryAndIngest } from "../_shared/ingest.ts";

const RETRY_AT_SEC = [0, 20, 45, 90];
const LOOKBACK_MS = 10 * 60_000; // 탭 10분 전 이후 승인만 '이번 결제'로 본다

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = await requestUser(req);
  if (!user) return json({ error: "로그인이 필요해요" }, 401);
  const { store_chain: storeChain } = await req.json().catch(() => ({}));

  const db = admin();
  const { data: conns } = await db.from("card_connections")
    .select("id, user_id, card_company, connected_id")
    .eq("user_id", user.id).eq("status", "active").not("connected_id", "is", null);
  if (!conns?.length) return json({ error: "연결된 카드가 없어요" }, 409);

  const used = await queriesToday(db, user.id);
  const budget = DAILY_QUERY_LIMIT - used;
  if (budget <= 0) return json({ error: "오늘 조회 한도를 다 썼어요", limit: DAILY_QUERY_LIMIT }, 429);

  const tapAt = Date.now();
  const run = async () => {
    let calls = 0;
    for (const sec of RETRY_AT_SEC) {
      const wait = tapAt + sec * 1000 - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      let found = 0;
      for (const c of conns as CardConnection[]) {
        if (calls >= budget) return;
        calls++;
        try {
          found += (await queryAndIngest(db, c, new Date(tapAt - LOOKBACK_MS), new Date(), { trigger: "tap", storeChain })).length;
        } catch (e) {
          console.error("tap-check 조회 실패", c.id, String(e));
        }
      }
      if (found > 0) return;
    }
  };
  // @ts-ignore EdgeRuntime은 Supabase Edge Functions 실행 환경에만 있다
  EdgeRuntime.waitUntil(run());
  return json({ status: "checking", retry_at_sec: RETRY_AT_SEC, queries_left_today: budget }, 202);
});
