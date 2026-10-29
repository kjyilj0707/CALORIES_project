// 오프라인 단위 테스트:  deno test --allow-env --allow-read supabase/functions/_shared/
import { assert, assertEquals } from "jsr:@std/assert@1";
import { matchCombos, type Snack } from "./match.ts";
import { encryptPassword, pick } from "./codef.ts";

Deno.test("pick은 정확한 칸 이름을 먼저 고른다 (취소 금액을 결제 금액으로 읽지 않음)", () => {
  const row = { resCancelAmount: "", resUsedAmount: "2800", resCancelYN: "0" };
  assertEquals(pick(row, "resUsedAmount", "UsedAmount"), "2800");
  assertEquals(pick({ resCancelAmount: "500", fooUsedAmount: "2800" }, "resUsedAmount", "UsedAmount"), "2800");
});

const snack = (productId: number, name: string, price: number, extra: Partial<Snack> = {}): Snack => ({
  productId, name, price, usualStores: [], usualTimeSlots: [], recentCount: 0, ...extra,
});

Deno.test("금액이 정확히 맞는 조합만, 같은 상품 여러 개 포함", () => {
  const snacks = [snack(1, "바나나우유", 1700), snack(2, "초코파이", 1100), snack(3, "삼각김밥", 1400)];
  const got = matchCombos(2800, snacks, "GS25", new Date("2026-10-29T06:30:00Z"));
  assertEquals(got.map((c) => c.items.map((i) => `${i.name}x${i.qty}`).join("+")).sort(),
    ["바나나우유x1+초코파이x1", "삼각김밥x2"]);
});

Deno.test("자주 먹고, 그 가게·그 시간대면 점수가 높다", () => {
  const snacks = [
    snack(1, "바나나우유", 1700, { recentCount: 10, usualStores: ["GS25"], usualTimeSlots: ["15:00-16:00"] }),
    snack(2, "딸기우유", 1700),
  ];
  const got = matchCombos(1700, snacks, "GS25", new Date("2026-10-29T06:30:00Z")); // KST 15:30
  assertEquals(got[0].items[0].name, "바나나우유");
  assert(got[0].score > got[1].score);
});

Deno.test("맞는 조합이 없으면 빈 배열, 최대 3개까지만", () => {
  assertEquals(matchCombos(999, [snack(1, "껌", 500)], null, new Date()), []);
  assertEquals(matchCombos(2000, [snack(1, "껌", 500)], null, new Date()), []); // 4개 필요 → 제외
});

Deno.test("RSA PKCS#1 v1.5 암호화를 개인키로 풀 수 있다", async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSA-OAEP", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true, ["encrypt", "decrypt"],
  );
  const spki = new Uint8Array(await crypto.subtle.exportKey("spki", pair.publicKey));
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  Deno.env.set("CODEF_PUBLIC_KEY", btoa(String.fromCharCode(...spki)));
  const enc = await encryptPassword("pw1234!");
  // Web Crypto는 PKCS#1 v1.5 복호화가 없으므로 openssl로 확인
  const dir = await Deno.makeTempDir();
  await Deno.writeFile(`${dir}/key.der`, pkcs8);
  await Deno.writeFile(`${dir}/enc.bin`, Uint8Array.from(atob(enc), (c) => c.charCodeAt(0)));
  const out = await new Deno.Command("openssl", {
    args: ["pkeyutl", "-decrypt", "-inkey", `${dir}/key.der`, "-keyform", "DER", "-in", `${dir}/enc.bin`,
      "-pkeyopt", "rsa_padding_mode:pkcs1"],
  }).output();
  assertEquals(new TextDecoder().decode(out.stdout), "pw1234!");
});
