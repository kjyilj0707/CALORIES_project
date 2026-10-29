// CODEF API 최소 클라이언트 (Deno). experiments/codef_latency/codef_client.py 와 같은 규칙.
// 시크릿: CODEF_ENV(sandbox|demo|prod), CODEF_CLIENT_ID, CODEF_CLIENT_SECRET, CODEF_PUBLIC_KEY
// CODEF는 요청 본문과 응답을 URL 인코딩된 JSON으로 주고받는다.

const HOSTS: Record<string, string> = {
  sandbox: "https://sandbox.codef.io",
  demo: "https://development.codef.io",
  prod: "https://api.codef.io",
};
const TOKEN_URL = "https://oauth.codef.io/oauth/token";

// 카드사 기관코드 (개발가이드 "카드 개요 > 카드사 목록"에서 확인, 2026-10-29). 카카오뱅크·토스뱅크는 없음
export const CARD_ORGS: Record<string, string> = {
  "KB국민": "0301", "현대": "0302", "삼성": "0303", "NH농협": "0304", "BC": "0305",
  "신한": "0306", "씨티": "0307", "우리": "0309", "롯데": "0311", "하나": "0313",
};

export class CodefError extends Error {}

function env(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new CodefError(`${name} 시크릿이 없습니다.`);
  return v;
}

let cachedToken: { value: string; at: number } | null = null;

async function token(): Promise<string> {
  // 토큰은 7일 유효. 함수 인스턴스가 살아 있는 동안만 재사용한다.
  if (cachedToken && Date.now() - cachedToken.at < 6 * 86400_000) return cachedToken.value;
  const basic = btoa(`${env("CODEF_CLIENT_ID")}:${env("CODEF_CLIENT_SECRET")}`);
  const r = await fetch(TOKEN_URL, {
    method: "POST",
    headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded" },
    body: "grant_type=client_credentials&scope=read",
  });
  if (!r.ok) throw new CodefError(`토큰 발급 실패 ${r.status}`);
  cachedToken = { value: (await r.json()).access_token, at: Date.now() };
  return cachedToken.value;
}

export async function codefRequest(path: string, params: unknown): Promise<any> {
  const host = HOSTS[Deno.env.get("CODEF_ENV") ?? "sandbox"];
  const r = await fetch(host + path, {
    method: "POST",
    headers: { Authorization: `Bearer ${await token()}`, "Content-Type": "application/json" },
    body: encodeURIComponent(JSON.stringify(params)),
  });
  if (!r.ok) throw new CodefError(`HTTP ${r.status}`);
  const body = JSON.parse(decodeURIComponent((await r.text()).replace(/\+/g, " ")));
  const code = body?.result?.code;
  if (code !== "CF-00000") throw new CodefError(`${code}: ${body?.result?.message}`);
  return body.data;
}

/** 계정 등록 시 비밀번호를 RSA(PKCS#1 v1.5)로 암호화한다. Web Crypto는 PKCS#1 v1.5 암호화를 지원하지 않아 직접 구현한다. */
export async function encryptPassword(plain: string): Promise<string> {
  const der = Uint8Array.from(atob(env("CODEF_PUBLIC_KEY")), (c) => c.charCodeAt(0));
  const { n, e } = parseRsaPublicKey(der);
  const k = Math.ceil(n.toString(16).length / 2);
  const msg = new TextEncoder().encode(plain);
  if (msg.length > k - 11) throw new CodefError("비밀번호가 너무 깁니다.");
  // EM = 0x00 || 0x02 || PS(0이 아닌 난수) || 0x00 || M
  const ps = new Uint8Array(k - msg.length - 3);
  for (let i = 0; i < ps.length; i++) {
    let b = 0;
    while (b === 0) b = crypto.getRandomValues(new Uint8Array(1))[0];
    ps[i] = b;
  }
  const em = new Uint8Array([0x00, 0x02, ...ps, 0x00, ...msg]);
  const c = modPow(bytesToBigInt(em), e, n);
  return btoa(String.fromCharCode(...bigIntToBytes(c, k)));
}

// ---- RSA 공개키(SubjectPublicKeyInfo DER) 파싱과 큰 수 연산 ----

function readTlv(buf: Uint8Array, pos: number) {
  const tag = buf[pos++];
  let len = buf[pos++];
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let i = 0; i < n; i++) len = (len << 8) | buf[pos++];
  }
  return { tag, start: pos, end: pos + len };
}

function parseRsaPublicKey(der: Uint8Array): { n: bigint; e: bigint } {
  const spki = readTlv(der, 0);                      // SEQUENCE
  const algo = readTlv(der, spki.start);             // SEQUENCE (rsaEncryption)
  const bitStr = readTlv(der, algo.end);             // BIT STRING
  const rsaKey = readTlv(der, bitStr.start + 1);     // SEQUENCE (앞의 1바이트는 unused bits)
  const nTlv = readTlv(der, rsaKey.start);           // INTEGER n
  const eTlv = readTlv(der, nTlv.end);               // INTEGER e
  return { n: bytesToBigInt(der.slice(nTlv.start, nTlv.end)), e: bytesToBigInt(der.slice(eTlv.start, eTlv.end)) };
}

function bytesToBigInt(b: Uint8Array): bigint {
  let x = 0n;
  for (const v of b) x = (x << 8n) | BigInt(v);
  return x;
}

function bigIntToBytes(x: bigint, len: number): Uint8Array {
  const out = new Uint8Array(len);
  for (let i = len - 1; i >= 0; i--) {
    out[i] = Number(x & 0xffn);
    x >>= 8n;
  }
  return out;
}

function modPow(base: bigint, exp: bigint, mod: bigint): bigint {
  let result = 1n;
  base %= mod;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % mod;
    base = (base * base) % mod;
    exp >>= 1n;
  }
  return result;
}

// ---- 승인내역 ----

export interface Approval {
  approvalNo: string | null;
  merchant: string | null;
  amount: number | null;
  paidAt: Date;
  isCancel: boolean;
}

const ymd = (d: Date) => kst(d).toISOString().slice(0, 10).replaceAll("-", "");
/** UTC Date → KST 벽시계 시각을 UTC 필드에 담은 Date (날짜 문자열 계산용) */
const kst = (d: Date) => new Date(d.getTime() + 9 * 3600_000);

/** needle 순서대로 찾는다: 정확히 같은 칸 → 이름에 needle이 들어간 칸.
 *  (그냥 순서대로 훑으면 "Amount"가 resCancelAmount에 먼저 걸린다) */
export function pick(row: Record<string, unknown>, ...needles: string[]): string | null {
  const str = (v: unknown) => (v == null ? null : String(v));
  for (const n of needles) if (n in row) return str(row[n]);
  for (const n of needles) {
    const k = Object.keys(row).find((k) => k.toLowerCase().includes(n.toLowerCase()));
    if (k) return str(row[k]);
  }
  return null;
}

// 가맹점 상세 정보 옵션. 우리카드(0309)는 제공하지 않아 "0" 고정 (개발가이드 KR_CD_P_002).
// 현대카드는 이 값에 따라 실시간승인/결제확정 조회가 갈린다.
const NO_MEMBER_STORE_INFO = new Set(["0309"]);

/** 승인내역 조회 (KR_CD_P_002). */
export async function fetchApprovals(org: string, connectedId: string, from: Date, to: Date): Promise<Approval[]> {
  const data = await codefRequest("/v1/kr/card/p/account/approval-list", {
    organization: org,
    connectedId,
    startDate: ymd(from),
    endDate: ymd(to),
    orderBy: "0",              // 최신순
    inquiryType: "1",          // 전체 카드
    memberStoreInfoType: NO_MEMBER_STORE_INFO.has(org) ? "0" : "1",
  });
  const rows: Record<string, unknown>[] = Array.isArray(data) ? data : data?.resApprovalList ?? (data ? [data] : []);
  const out: Approval[] = [];
  for (const r of rows) {
    // 실제 칸 이름 (샌드박스 응답으로 확인): resUsedDate, resUsedTime, resApprovalNo, resMemberStoreName, resUsedAmount, resCancelYN
    const d = pick(r, "resUsedDate", "UsedDate", "ApprovalDate") ?? "";
    const t = (pick(r, "resUsedTime", "UsedTime", "ApprovalTime") ?? "000000").replaceAll(":", "").padEnd(6, "0");
    if (!/^\d{8}/.test(d) || !/^\d{6}/.test(t)) continue; // 샌드박스는 값을 '****'로 가려서 준다
    const iso = `${d.slice(0, 4)}-${d.slice(4, 6)}-${d.slice(6, 8)}T${t.slice(0, 2)}:${t.slice(2, 4)}:${t.slice(4, 6)}+09:00`;
    const amountRaw = (pick(r, "resUsedAmount", "UsedAmount") ?? "").replaceAll(",", "");
    const amount = amountRaw === "" ? NaN : Number(amountRaw);
    const cancel = pick(r, "resCancelYN", "CancelYN");
    out.push({
      approvalNo: pick(r, "resApprovalNo", "ApprovalNo"),
      merchant: pick(r, "resMemberStoreName", "MemberStoreName"),
      amount: Number.isFinite(amount) ? amount : null,
      paidAt: new Date(iso),
      isCancel: cancel != null && !["0", "N", "n", ""].includes(cancel),
    });
  }
  return out;
}
