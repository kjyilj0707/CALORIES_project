// 승인 내역 → payment_events 저장 → (새 결제면) predictions 저장. tap-check와 card-connect(30일)가 함께 쓴다.
import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { type Approval, CARD_ORGS, fetchApprovals } from "./codef.ts";
import { LARGE_AMOUNT, matchCombos, type Snack } from "./match.ts";

export const DAILY_QUERY_LIMIT = 10; // 사용자별 하루 카드 조회 상한 (IP 차단·비용 방지)

export interface CardConnection {
  id: string;
  user_id: string;
  card_company: string;
  connected_id: string;
}

export const cardOrg = (company: string): string => {
  const org = CARD_ORGS[company];
  if (!org) throw new Error(`알 수 없는 카드사: ${company}`);
  return org;
};

/** 오늘(KST) 이 사용자가 쓴 카드 조회 횟수 */
export async function queriesToday(db: SupabaseClient, userId: string): Promise<number> {
  const now = new Date(Date.now() + 9 * 3600_000);
  const startKst = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - 9 * 3600_000);
  const { count } = await db.from("card_queries").select("id", { count: "exact", head: true })
    .eq("user_id", userId).neq("trigger", "backfill").gte("called_at", startKst.toISOString());
  return count ?? 0;
}

/** 한 카드를 조회해 새 승인을 저장하고, 새로 저장된 이벤트 id 목록을 돌려준다. */
export async function queryAndIngest(
  db: SupabaseClient,
  conn: CardConnection,
  from: Date,
  to: Date,
  opts: { trigger: "tap" | "backfill" | "nightly" | "manual"; storeChain?: string; backfill?: boolean },
  fetcher: typeof fetchApprovals = fetchApprovals, // 테스트에서 가짜 승인 내역을 넣는 자리
): Promise<string[]> {
  let approvals: Approval[] = [];
  try {
    approvals = await fetcher(cardOrg(conn.card_company), conn.connected_id, from, to);
  } catch (e) {
    await db.from("card_queries").insert({
      user_id: conn.user_id, card_connection_id: conn.id, trigger: opts.trigger,
      store_chain: opts.storeChain, ok: false, error: String(e).slice(0, 500),
    });
    throw e;
  }

  const fresh: string[] = [];
  for (const a of approvals) {
    if (a.paidAt < from) continue;
    const { data: matched } = await db.rpc("match_merchant", { raw: a.merchant ?? "" });
    // 가맹점명이 아예 없으면(우리카드는 가맹점 정보 미제공) 결제 시각에 머물던 편의점(지오펜스 방문)으로 대신 판단.
    // 이름이 있는데 사전에 없는 곳(김밥천국 등)은 근처 편의점으로 잘못 붙이지 않도록 그대로 미분류.
    const merchantId = matched ?? (a.merchant?.trim() ? null : await merchantFromVisit(db, conn.user_id, a.paidAt));
    const { data, error } = await db.from("payment_events").insert({
      user_id: conn.user_id,
      source: "card_api",
      card_connection_id: conn.id,
      approval_no: a.approvalNo,
      merchant_raw: a.merchant,
      merchant_id: merchantId,
      amount: a.amount,
      paid_at: a.paidAt.toISOString(),
      is_cancel: a.isCancel,
      is_backfill: !!opts.backfill,
    }).select("id").single();
    if (error) {
      if (error.code === "23505") continue; // 이미 저장된 승인 (승인번호 중복)
      throw error;
    }
    fresh.push(data.id);
    if (a.isCancel) await revertCancelled(db, conn, a.approvalNo);
    else if (!opts.backfill) await predict(db, conn.user_id, data.id, a, merchantId);
  }

  await db.from("card_queries").insert({
    user_id: conn.user_id, card_connection_id: conn.id, trigger: opts.trigger,
    store_chain: opts.storeChain, ok: true, found: fresh.length,
  });
  await db.from("card_connections").update({ last_polled_at: new Date().toISOString() }).eq("id", conn.id);
  return fresh;
}

/** 결제 시각에 사용자가 들어가 있던(또는 나온 지 5분 안의) 편의점 체인 → merchants id */
async function merchantFromVisit(db: SupabaseClient, userId: string, paidAt: Date): Promise<number | null> {
  const t = paidAt.toISOString();
  const { data: visit } = await db.from("location_visits").select("store_chain")
    .eq("user_id", userId).lte("entered_at", t)
    .or(`exited_at.is.null,exited_at.gte.${new Date(paidAt.getTime() - 5 * 60_000).toISOString()}`)
    .order("entered_at", { ascending: false }).limit(1).maybeSingle();
  if (!visit) return null;
  const { data: m } = await db.from("merchants").select("id")
    .eq("chain", visit.store_chain).order("snack_likelihood", { ascending: false }).limit(1).maybeSingle();
  return m?.id ?? null;
}

/** 승인이 취소되면 원래 결제로 쌓인 스택 기록을 지운다 (PLAN 4.2 is_cancel). 응답(라벨)은 학습용으로 남긴다. */
async function revertCancelled(db: SupabaseClient, conn: CardConnection, approvalNo: string | null) {
  if (!approvalNo) return;
  const { data: original } = await db.from("payment_events").select("id")
    .eq("card_connection_id", conn.id).eq("approval_no", approvalNo).eq("is_cancel", false).maybeSingle();
  if (original) await db.from("consumption_log").delete().eq("event_id", original.id);
}

async function predict(db: SupabaseClient, userId: string, eventId: string, a: Approval, merchantId: number | null) {
  const merchant = merchantId
    ? (await db.from("merchants").select("chain, snack_likelihood").eq("id", merchantId).single()).data
    : null;
  const amount = a.amount ?? 0;
  const isSnackScore = amount >= LARGE_AMOUNT ? 0 : merchant?.snack_likelihood ?? 0;
  const candidates = isSnackScore > 0 ? matchCombos(amount, await loadSnacks(db, userId, merchant?.chain), merchant?.chain ?? null, a.paidAt) : [];
  await db.from("predictions").insert({
    event_id: eventId, user_id: userId, is_snack_score: isSnackScore, candidates, model_version: "stage1",
  });
  // TODO: is_snack_score > 0 이면 APNs 푸시 (Apple 개발자 계정 필요). 지금은 앱이 Realtime으로 predictions를 받는다.
}

async function loadSnacks(db: SupabaseClient, userId: string, chain?: string | null): Promise<Snack[]> {
  const { data: rows } = await db.from("user_snacks")
    .select("product_id, custom_name, usual_price, usual_stores, usual_time_slots, products(name, product_prices(chain, price))")
    .eq("user_id", userId).eq("is_active", true);
  const since = new Date(Date.now() - 30 * 86400_000).toISOString();
  const { data: eaten } = await db.from("consumption_log").select("product_id").eq("user_id", userId).gte("consumed_at", since);
  const counts = new Map<number, number>();
  (eaten ?? []).forEach((r: { product_id: number }) => counts.set(r.product_id, (counts.get(r.product_id) ?? 0) + 1));

  return (rows ?? []).map((r: any) => {
    const prices: { chain: string; price: number }[] = r.products?.product_prices ?? [];
    const chainPrice = prices.find((p) => p.chain === chain)?.price ?? prices[0]?.price ?? 0;
    return {
      productId: r.product_id,
      name: r.custom_name ?? r.products?.name ?? "",
      price: r.usual_price ?? chainPrice,
      usualStores: r.usual_stores ?? [],
      usualTimeSlots: r.usual_time_slots ?? [],
      recentCount: counts.get(r.product_id) ?? 0,
    };
  });
}
