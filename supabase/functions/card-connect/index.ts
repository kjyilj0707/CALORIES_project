// 카드 연결: 카드사 아이디·비밀번호를 받아 CODEF 계정 등록 → connected_id 저장 → 지난 30일 승인 내역 가져오기.
// 비밀번호는 서버에서 RSA로 암호화해 CODEF로만 보내고, 어디에도 저장하지 않는다.
import { admin, json, requestUser } from "../_shared/supabase.ts";
import { codefRequest, encryptPassword } from "../_shared/codef.ts";
import { cardOrg, queryAndIngest } from "../_shared/ingest.ts";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const user = await requestUser(req);
  if (!user) return json({ error: "로그인이 필요해요" }, 401);

  const body = await req.json().catch(() => null);
  const { card_company: company, login_id: loginId, password, card_no: cardNo, card_password: cardPassword } = body ?? {};
  if (!company || !loginId || !password) return json({ error: "카드사, 아이디, 비밀번호가 필요해요" }, 400);

  let org: string;
  try {
    org = cardOrg(company);
  } catch {
    return json({ error: "지원하지 않는 카드사예요" }, 400);
  }

  const account: Record<string, string> = {
    countryCode: "KR", businessType: "CD", clientType: "P", organization: org,
    loginType: "1", // 아이디 로그인 (0 = 공동인증서)
    id: loginId, password: await encryptPassword(password),
  };
  if (cardNo && cardPassword) { // 현대카드, 일부 KB카드
    account.cardNo = cardNo;
    account.cardPassword = await encryptPassword(cardPassword);
  }

  let connectedId: string;
  try {
    connectedId = (await codefRequest("/v1/account/create", { accountList: [account] })).connectedId;
  } catch (e) {
    // CODEF 오류 메시지(아이디·비밀번호 불일치, 추가 인증 필요 등)를 그대로 보여 준다
    return json({ error: "카드사 연결에 실패했어요", detail: String(e) }, 502);
  }

  const db = admin();
  const { data: conn, error } = await db.from("card_connections").insert({
    user_id: user.id, provider: "codef", card_company: company, connected_id: connectedId,
    auth_method: "id_pw", status: "active",
  }).select("id, user_id, card_company, connected_id").single();
  if (error) return json({ error: error.message }, 500);

  // 지난 30일 → 온보딩 리포트 (예측·푸시는 하지 않고 is_backfill로만 저장)
  const to = new Date();
  const from = new Date(to.getTime() - 30 * 86400_000);
  let backfilled = 0;
  try {
    backfilled = (await queryAndIngest(db, conn, from, to, { trigger: "backfill", backfill: true })).length;
  } catch (e) {
    console.error("30일 내역 가져오기 실패", String(e));
  }
  return json({ card_connection_id: conn.id, backfilled });
});
