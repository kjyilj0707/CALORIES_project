"""식약처 식품영양성분DB(가공식품) → products 표 적재.

  python mfds_collect.py fetch        # 상용제품 전체를 raw/ 에 JSONL로 내려받기 (이어받기 가능)
  python mfds_collect.py categories   # 가공식품 대분류·중분류별 건수 보기 → SNACK_CATEGORY_KEYWORDS 조정
  python mfds_collect.py load --dry-run   # 걸러진 건수와 예시만 출력
  python mfds_collect.py load             # products 에 upsert (source='mfds', source_code=FOOD_CD)

.env (CALORIES_project/.env):
  MFDS_API_KEY=...          공공데이터포털 일반 인증키 (Decoding)
  SUPABASE_URL=https://uzhtkykhkfcqsswfityg.supabase.co
  SUPABASE_SECRET_KEY=...   service role / secret 키 (RLS 무시, 서버 전용)

API: 식품의약품안전처_식품영양성분DB정보 v03 (data.go.kr 15127578).
- 서버에서 가공식품만 거를 수 없다 → DB_CLASS_NM=상용제품으로 받고 DB_GRP_NM=="가공식품"을 여기서 거른다.
- AMT_NUM 값은 모두 SERVING_SIZE(보통 100g/100mL)당 값이다. products에는 '한 개(포장 전체)'당 값으로 바꿔 넣는다.
"""
import argparse
import collections
import json
import os
import re
import sys
import time
from datetime import date
from pathlib import Path

import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
RAW_DIR = Path(__file__).with_name("raw")

API_URL = "https://apis.data.go.kr/1471000/FoodNtrCpntDbInfo03/getFoodNtrCpntDbInq03"
PAGE_SIZE = 500  # 실측 최대치 (1000이면 빈 결과)

# 군것질 범위 = 스낵류만 (2026-10-29 사용자 결정: 과자·초콜릿·젤리 등).
# 중분류(CAT2·CAT3)는 비어 있어서 대표식품명(FOOD_REF_NM)으로 고른다. 빵·케이크·떡·음료·우유·아이스크림·식사류는 제외.
SNACK_REFS = {
    # 과자류·빵류 또는 떡류 중 스낵
    "비스킷/쿠키/크래커", "일반과자", "스낵과자", "전통과자", "강냉이/팝콘", "웨이퍼", "프레즐",
    "젤리", "사탕", "기타 사탕", "캐러멜", "마시멜로", "양갱", "껌",
    # 코코아가공품류 또는 초콜릿류 (코코아 가루·원료 제외)
    "초콜릿", "초콜릿과자", "초코파이",
}

# products 칸 ← 응답 필드 (값은 SERVING_SIZE 기준량당)
NUTRIENTS = {
    "kcal": "AMT_NUM1",
    "protein_g": "AMT_NUM3",
    "fat_g": "AMT_NUM4",
    "carb_g": "AMT_NUM6",
    "sugar_g": "AMT_NUM7",
    "sodium_mg": "AMT_NUM13",
    "sat_fat_g": "AMT_NUM24",
    "caffeine_mg": "AMT_NUM100",
}
KEEP_FIELDS = [
    "FOOD_CD", "FOOD_NM_KR", "MAKER_NM", "DB_GRP_NM", "DB_CLASS_NM",
    "FOOD_CAT1_NM", "FOOD_CAT2_NM", "FOOD_CAT3_NM", "FOOD_REF_NM", "ITEM_REPORT_NO",
    "SERVING_SIZE", "NUTRI_AMOUNT_SERVING", "Z10500", "UPDATE_DATE", *NUTRIENTS.values(),
]


# ---------- fetch ----------

def fetch_page(page):
    params = {
        "serviceKey": os.environ["MFDS_API_KEY"],  # Decoding 키 → requests가 한 번만 인코딩
        "pageNo": page, "numOfRows": PAGE_SIZE, "type": "json",
        "DB_CLASS_NM": "상용제품",
    }
    for attempt in range(5):
        try:
            r = requests.get(API_URL, params=params, timeout=120)
        except requests.RequestException as e:  # 공공데이터포털은 가끔 응답이 1분 넘게 멈춘다
            print(f"  page {page} 연결 오류 (재시도 {attempt + 1}/5): {e.__class__.__name__}", file=sys.stderr)
            time.sleep(10 * (attempt + 1))
            continue
        if r.ok and r.text.lstrip().startswith("{"):
            body = r.json().get("body") or r.json().get("response", {}).get("body", {})
            items = body.get("items") or []
            if isinstance(items, dict):  # Swagger 표기(items.item) 대비
                items = items.get("item") or []
            return int(body.get("totalCount") or 0), items
        # 키 오류 등은 HTTP 200 + XML 본문으로 온다
        print(f"  page {page} 실패 ({r.status_code}): {r.text[:200]}", file=sys.stderr)
        time.sleep(2 * (attempt + 1))
    raise SystemExit(f"page {page} 를 받지 못했습니다.")


def cmd_fetch(_):
    RAW_DIR.mkdir(exist_ok=True)
    out = RAW_DIR / f"mfds_{date.today():%Y%m%d}.jsonl"
    done = {json.loads(l)["_page"] for l in out.open()} if out.exists() else set()
    total, items = fetch_page(1)
    pages = (total + PAGE_SIZE - 1) // PAGE_SIZE
    print(f"전체 {total}건, {pages}페이지 (이미 받은 페이지 {len(done)}개)")
    with out.open("a") as f:
        for page in range(1, pages + 1):
            if page in done:
                continue
            if page != 1:
                _, items = fetch_page(page)
            for it in items:
                # 응답에는 AMT_NUM1~157 등 180여 칸이 있다 → 쓰는 칸만 저장 (32만 건)
                kept = {k: it.get(k) for k in KEEP_FIELDS}
                f.write(json.dumps({**kept, "_page": page}, ensure_ascii=False) + "\n")
            print(f"  {page}/{pages} ({len(items)}건)")
    print(f"저장: {out}")


def latest_raw():
    files = sorted(RAW_DIR.glob("mfds_*.jsonl"))
    if not files:
        raise SystemExit("raw 파일이 없습니다. 먼저 fetch 를 실행하세요.")
    seen = {}
    for line in files[-1].open():
        it = json.loads(line)
        seen[it.get("FOOD_CD")] = it  # 페이지를 다시 받았을 때 중복 제거
    return list(seen.values())


# ---------- 변환 ----------

def num(v):
    try:
        return float(str(v).replace(",", ""))
    except (TypeError, ValueError):
        return None


def amount_unit(v):
    """'100g', '900.000g', '200ml' → (900.0, 'g'). 단위는 g/ml만 인정."""
    m = re.match(r"\s*([\d.,]+)\s*(g|ml|mL|ML)\b", str(v or ""))
    return (float(m.group(1).replace(",", "")), m.group(2).lower()) if m else (None, None)


def clean_name(name):
    """상품명 꼬리의 관리번호 제거: "킷캣 오리지널 (36.5g)(sku12535321)", "킷캣 골드_12374755" (마이그레이션 0009와 같은 규칙)"""
    name = re.sub(r"\s*\(sku\d+\)", "", name, flags=re.I)
    return re.sub(r"_\d{6,}$", "", name).strip()


def is_snack(it):
    return it.get("DB_GRP_NM") == "가공식품" and it.get("FOOD_REF_NM") in SNACK_REFS


def to_product(it):
    basis, basis_unit = amount_unit(it.get("SERVING_SIZE"))
    total, total_unit = amount_unit(it.get("Z10500"))
    # 포장 전체 중량을 알고 단위가 같으면 '한 개'당 값으로 환산, 아니면 기준량당 값 그대로 두고 미검수 표시
    scale = total / basis if basis and total and basis_unit == total_unit else None
    row = {
        "source": "mfds",
        "source_code": it.get("FOOD_CD"),
        "name": clean_name(it.get("FOOD_NM_KR") or ""),
        "manufacturer": (it.get("MAKER_NM") or "").strip() or None,
        "category": it.get("FOOD_REF_NM") or it.get("FOOD_CAT1_NM"),
        "serving_basis": it.get("SERVING_SIZE"),
        "total_weight": it.get("Z10500"),
        "serving_g_ml": total if scale else basis,
        "verified": False,
    }
    for col, field in NUTRIENTS.items():
        v = num(it.get(field))
        row[col] = round(v * scale, 2) if (v is not None and scale) else v
    return row


# ---------- categories / load ----------

def cmd_categories(_):
    items = latest_raw()
    grp = collections.Counter(it.get("DB_GRP_NM") for it in items)
    print("DB 그룹:", dict(grp))
    proc = [it for it in items if it.get("DB_GRP_NM") == "가공식품"]
    cats = collections.Counter((it.get("FOOD_CAT1_NM"), it.get("FOOD_REF_NM")) for it in proc)
    for (c1, ref), n in cats.most_common():
        mark = "●" if ref in SNACK_REFS else " "
        print(f"{mark} {n:>6}  {c1} > {ref}")
    print(f"\n● = 군것질로 적재될 분류 ({sum(1 for it in proc if is_snack(it))}건)")


def upsert(rows):
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/products?on_conflict=source,source_code"
    key = os.environ["SUPABASE_SECRET_KEY"]
    headers = {"apikey": key, "Content-Type": "application/json",
               "Prefer": "resolution=merge-duplicates,return=minimal"}
    if key.count(".") == 2:  # 예전 JWT 형식 service_role 키
        headers["Authorization"] = f"Bearer {key}"
    r = requests.post(url, headers=headers, json=rows, timeout=60)
    if not r.ok:
        raise SystemExit(f"upsert 실패 {r.status_code}: {r.text[:300]}")


def verified_codes():
    """사람이 검수한 상품(verified)은 다시 적재할 때 덮어쓰지 않는다."""
    url = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1/products"
    key = os.environ["SUPABASE_SECRET_KEY"]
    r = requests.get(url, headers={"apikey": key},
                     params={"select": "source_code", "source": "eq.mfds", "verified": "eq.true"}, timeout=60)
    r.raise_for_status()
    return {row["source_code"] for row in r.json()}


def cmd_load(args):
    rows = [to_product(it) for it in latest_raw() if is_snack(it)]
    rows = [r for r in rows if r["name"] and r["source_code"]]
    if not args.dry_run:
        keep = verified_codes()
        rows = [r for r in rows if r["source_code"] not in keep]
        print(f"검수된 상품 {len(keep)}개는 건너뜀")
    converted = sum(1 for r in rows if r["serving_basis"] and r["total_weight"]
                    and r["serving_g_ml"] == amount_unit(r["total_weight"])[0])
    print(f"적재 대상 {len(rows)}건 (포장 전체 기준으로 환산 {converted}건, 나머지는 기준량당 값)")
    if args.dry_run:
        for r in rows[:5]:
            print(json.dumps(r, ensure_ascii=False))
        return
    for i in range(0, len(rows), 500):
        upsert(rows[i:i + 500])
        print(f"  {min(i + 500, len(rows))}/{len(rows)}")
    print("완료")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("fetch").set_defaults(fn=cmd_fetch)
    sub.add_parser("categories").set_defaults(fn=cmd_categories)
    p = sub.add_parser("load")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(fn=cmd_load)
    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
