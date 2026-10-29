// Stage 1 규칙 기반 매칭 (PLAN.md 5장): 내 군것질 목록에서 결제 금액과 정확히 일치하는 1~3개 조합을 찾는다.

export interface Snack {
  productId: number;
  name: string;
  price: number;           // usual_price 또는 체인 가격
  usualStores: string[];
  usualTimeSlots: string[]; // "15:00-16:00"
  recentCount: number;     // 최근 30일 먹은 횟수
}

export interface Candidate {
  items: { product_id: number; name: string; qty: number }[];
  score: number;
}

export const LARGE_AMOUNT = 15_000; // 이 이상이면 장보기로 보고 묻지 않는다
const MAX_ITEMS = 3;

/** 금액이 정확히 맞는 조합(같은 상품 여러 개 포함, 최대 3개)을 점수순으로 돌려준다. */
export function matchCombos(amount: number, snacks: Snack[], chain: string | null, paidAt: Date, top = 3): Candidate[] {
  const usable = snacks.filter((s) => s.price > 0 && s.price <= amount);
  const combos: number[][] = [];
  const walk = (start: number, left: number, picked: number[]) => {
    if (left === 0 && picked.length) return void combos.push([...picked]);
    if (picked.length === MAX_ITEMS) return;
    for (let i = start; i < usable.length; i++) {
      if (usable[i].price > left) continue;
      picked.push(i);
      walk(i, left - usable[i].price, picked); // i부터 다시 → 같은 상품 여러 개 허용
      picked.pop();
    }
  };
  walk(0, amount, []);

  const hour = kstHour(paidAt);
  return combos
    .map((idx) => {
      const counts = new Map<number, number>();
      idx.forEach((i) => counts.set(i, (counts.get(i) ?? 0) + 1));
      let score = 1;
      for (const i of counts.keys()) score *= snackScore(usable[i], chain, hour);
      score /= idx.length; // 같은 점수면 개수가 적은 조합을 먼저
      return {
        items: [...counts].map(([i, qty]) => ({ product_id: usable[i].productId, name: usable[i].name, qty })),
        score: Math.round(score * 1000) / 1000,
      };
    })
    .sort((a, b) => b.score - a.score)
    .slice(0, top);
}

// 점수 = 빈도 × 가맹점 일치 × 시간대 일치 (최근성은 recentCount에 포함)
function snackScore(s: Snack, chain: string | null, hour: number): number {
  const freq = 1 + Math.log1p(s.recentCount);
  const store = chain && s.usualStores.includes(chain) ? 1.5 : 1;
  const time = s.usualTimeSlots.some((slot) => inSlot(slot, hour)) ? 1.5 : 1;
  return freq * store * time;
}

function inSlot(slot: string, hour: number): boolean {
  const m = slot.match(/^(\d{1,2}):\d{2}-(\d{1,2}):\d{2}$/);
  if (!m) return false;
  const [from, to] = [Number(m[1]), Number(m[2])];
  return from <= to ? hour >= from && hour < to : hour >= from || hour < to; // 자정을 넘는 시간대
}

function kstHour(d: Date): number {
  return (d.getUTCHours() + 9) % 24;
}
