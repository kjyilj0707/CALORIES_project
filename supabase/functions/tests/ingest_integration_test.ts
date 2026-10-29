// 서버 통합 테스트: 가짜 카드 승인 내역 → queryAndIngest → payment_events·predictions를 실제 DB(calories)로 검증한다.
// 테스트 사용자를 새로 만들고 끝나면 지운다 (cascade로 관련 행도 삭제).
//
//   deno test --allow-net --allow-env --allow-read supabase/functions/tests/
//
// CALORIES_project/.env 의 SUPABASE_URL, SUPABASE_SECRET_KEY를 쓴다.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { load } from "jsr:@std/dotenv@0.225";
import { createClient } from "jsr:@supabase/supabase-js@2";
import type { Approval } from "../_shared/codef.ts";

const env = await load({ envPath: new URL("../../../.env", import.meta.url).pathname });
Deno.env.set("SUPABASE_URL", env.SUPABASE_URL);
Deno.env.set("SUPABASE_SERVICE_ROLE_KEY", env.SUPABASE_SECRET_KEY); // admin()이 읽는 이름
const { admin } = await import("../_shared/supabase.ts");
const { queryAndIngest } = await import("../_shared/ingest.ts");

const KITKAT = 46289; // 킷캣 오리지널 (36.5g)
const MYGUMMY = 29442; // 포도과즙그대로마이구미

Deno.test("승인 내역 → 결제 저장·가맹점 분류·매칭·예측, 중복·취소·지난 승인 처리", async (t) => {
  const db = admin();
  const authAdmin = createClient(env.SUPABASE_URL, env.SUPABASE_SECRET_KEY, { auth: { persistSession: false } }).auth.admin;
  const { data: created, error: userErr } = await authAdmin.createUser({
    email: `ingest-test-${crypto.randomUUID().slice(0, 8)}@example.com`, email_confirm: true,
  });
  if (userErr) throw userErr;
  const userId = created.user.id;

  try {
    const { data: conn } = await db.from("card_connections").insert({
      user_id: userId, card_company: "신한", connected_id: "test", status: "active",
    }).select("id, user_id, card_company, connected_id").single();
    await db.from("user_snacks").insert([
      { user_id: userId, product_id: KITKAT, usual_price: 2000, usual_stores: ["GS25"] },
      { user_id: userId, product_id: MYGUMMY, usual_price: 1500, usual_stores: ["CU"] },
    ]);

    const now = Date.now();
    const at = (minAgo: number) => new Date(now - minAgo * 60_000);
    const approvals: Approval[] = [
      { approvalNo: "T1", merchant: "GS25 강남역점", amount: 4000, paidAt: at(2), isCancel: false },    // 킷캣 ×2
      { approvalNo: "T2", merchant: "CU 역삼점", amount: 3500, paidAt: at(3), isCancel: false },        // 킷캣 + 마이구미
      { approvalNo: "T3", merchant: "스타벅스코리아", amount: 6500, paidAt: at(4), isCancel: false },   // 카페, 맞는 조합 없음
      { approvalNo: "T4", merchant: "GS25 강남역점", amount: 32000, paidAt: at(5), isCancel: false },   // 15,000원 이상 → 장보기
      { approvalNo: "T5", merchant: "김밥천국", amount: 8000, paidAt: at(6), isCancel: false },         // 사전에 없는 가맹점
      { approvalNo: "T7", merchant: "GS25 강남역점", amount: 2000, paidAt: at(30), isCancel: false },   // 조회 범위(10분) 밖
    ];
    const fake = () => Promise.resolve(approvals);
    const cancelT1: Approval = { approvalNo: "T1", merchant: "GS25 강남역점", amount: 4000, paidAt: at(1), isCancel: true };
    const from = at(10), to = new Date(now);

    const fresh = await queryAndIngest(db, conn!, from, to, { trigger: "tap", storeChain: "GS25" }, fake);

    await t.step("범위 안 승인 5건 저장 (30분 전 승인은 제외)", () => assertEquals(fresh.length, 5));

    const { data: events } = await db.from("payment_events")
      .select("id, approval_no, is_cancel, amount, merchants(chain, category), predictions(is_snack_score, candidates)")
      .eq("user_id", userId);
    // deno-lint-ignore no-explicit-any
    const ev = (no: string, cancel = false): any => events!.find((e) => e.approval_no === no && e.is_cancel === cancel)!;
    // deno-lint-ignore no-explicit-any
    const pred = (e: any) => e.predictions[0];
    // deno-lint-ignore no-explicit-any
    const topLabel = (e: any) => pred(e).candidates[0]?.items.map((i: any) => `${i.product_id}x${i.qty}`).sort().join("+");

    await t.step("GS25 4,000원 → 킷캣 2개", () => {
      assertEquals(ev("T1").merchants?.chain, "GS25");
      assertEquals(pred(ev("T1")).is_snack_score, 0.8);
      assertEquals(topLabel(ev("T1")), `${KITKAT}x2`);
    });
    await t.step("CU 3,500원 → 킷캣 + 마이구미", () => {
      assertEquals(topLabel(ev("T2")), [`${KITKAT}x1`, `${MYGUMMY}x1`].sort().join("+"));
    });
    await t.step("스타벅스 6,500원 → 군것질 가능성은 있지만 맞는 조합 없음", () => {
      assertEquals(pred(ev("T3")).is_snack_score, 0.6);
      assertEquals(pred(ev("T3")).candidates, []);
    });
    await t.step("GS25 32,000원 → 장보기로 보고 묻지 않음", () => assertEquals(pred(ev("T4")).is_snack_score, 0));
    await t.step("김밥천국 → 가맹점 미분류, 묻지 않음", () => {
      assertEquals(ev("T5").merchants, null);
      assertEquals(pred(ev("T5")).is_snack_score, 0);
    });
    await t.step("같은 내역을 다시 조회해도 중복 저장 안 됨", async () => {
      const again = await queryAndIngest(db, conn!, from, to, { trigger: "tap" }, fake);
      assertEquals(again.length, 0);
    });

    await t.step("T1을 [예]로 기록한 뒤 승인이 취소되면 스택에서 빠짐 (취소 내역은 저장, 예측은 안 함)", async () => {
      await db.from("consumption_log").insert({
        user_id: userId, product_id: KITKAT, event_id: ev("T1").id, qty: 2, kcal: 370, sugar_g: 34, origin: "auto_confirm",
      });
      const got = await queryAndIngest(db, conn!, from, to, { trigger: "tap" }, () => Promise.resolve([...approvals, cancelT1]));
      assertEquals(got.length, 1);
      const { data: left } = await db.from("consumption_log").select("id").eq("event_id", ev("T1").id);
      assertEquals(left, []);
      const { data: cancelled } = await db.from("payment_events").select("predictions(id)")
        .eq("user_id", userId).eq("approval_no", "T1").eq("is_cancel", true).single();
      assert(cancelled);
      assertEquals(cancelled.predictions, []);
    });

    await t.step("조회 기록(card_queries) 3건, 모두 성공", async () => {
      const { data: q } = await db.from("card_queries").select("ok, found").eq("user_id", userId).order("called_at");
      assertEquals(q!.map((r) => [r.ok, r.found]), [[true, 5], [true, 0], [true, 1]]);
    });
  } finally {
    await authAdmin.deleteUser(userId);
  }
});
