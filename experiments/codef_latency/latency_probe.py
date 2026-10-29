"""확정된 흐름(B안)을 그대로 흉내 내서 '결제 → 승인 내역에 잡히기까지' 지연을 잰다.

  python latency_probe.py            # 편의점에서 결제한 직후 엔터 = 라이브 액티비티 탭
  python latency_probe.py --dry-run  # 호출 없이 일정만 출력
  python latency_probe.py --watch 40 --interval 30
      # 감시 모드: 노트북 없이 편의점에 다녀오는 동안 40분간 30초마다 조회.
      # 시작 전에 있던 승인은 무시하고, 새 승인이 처음 보인 시각 - 카드사 승인 시각 = 지연 (오차 ±interval)

탭 순간 1회 조회하고, 못 찾으면 RETRY_AT 일정대로 재시도한다 (최대 len(RETRY_AT)회).
결과는 results.csv 에 한 줄씩 쌓인다.
"""
import argparse
import csv
import json
import time
from datetime import datetime, timedelta
from pathlib import Path

from codef_client import Codef, CodefError

HERE = Path(__file__).parent
STATE = HERE / ".state.json"
RESULTS = HERE / "results.csv"

RETRY_AT = [0, 30, 60, 120, 240, 480]  # 탭 후 몇 초에 조회할지 (탭 1번당 최대 6회)
LOOKBACK = timedelta(minutes=10)       # 탭 10분 전 이후 승인만 '이번 결제'로 본다

# 승인내역 요청 파라미터. 필수 칸 이름은 개발가이드(KR_CD_P_002)에서 다시 확인할 것.
APPROVAL_PATH = "/v1/kr/card/p/account/approval-list"


def approval_params(conn, day):
    ymd = day.strftime("%Y%m%d")
    return {
        "organization": conn["organization"],
        "connectedId": conn["connectedId"],
        "startDate": ymd,
        "endDate": ymd,
        "orderBy": "0",       # 0 = 최신순
        "inquiryType": "1",   # 1 = 전체 카드
        "memberStoreInfoType": member_store_info_type(conn["organization"]),
    }


# 가맹점 상세 정보 옵션. 우리카드(0309)는 제공하지 않아 "0" 고정 (개발가이드 KR_CD_P_002).
# 현대카드는 이 값에 따라 실시간승인/결제확정 조회가 갈린다.
NO_MEMBER_STORE_INFO = {"0309"}


def member_store_info_type(org):
    return "0" if org in NO_MEMBER_STORE_INFO else "1"


def pick(row, *needles):
    """needle 순서대로 찾는다: 정확히 같은 칸 → 이름에 needle이 들어간 칸.
    (그냥 순서대로 훑으면 "Amount"가 resCancelAmount에 먼저 걸린다)"""
    for n in needles:
        if n in row:
            return row[n]
    for n in needles:
        for k, v in row.items():
            if n.lower() in k.lower():
                return v
    return None


def parse_approvals(data):
    rows = data if isinstance(data, list) else (data or {}).get("resApprovalList", []) or [data]
    out = []
    for r in rows:
        if not isinstance(r, dict):
            continue
        d = str(pick(r, "resUsedDate", "UsedDate", "ApprovalDate") or "")
        t = str(pick(r, "resUsedTime", "UsedTime", "ApprovalTime") or "000000").replace(":", "").ljust(6, "0")[:6]
        if not (d[:8].isdigit() and t.isdigit()):
            continue  # 샌드박스는 값을 '****'로 가려서 준다
        out.append({
            "approved_at": datetime.strptime(d[:8] + t, "%Y%m%d%H%M%S"),
            "approval_no": pick(r, "resApprovalNo", "ApprovalNo"),
            "merchant": pick(r, "resMemberStoreName", "MemberStoreName"),
            "amount": pick(r, "resUsedAmount", "UsedAmount"),
            "cancel": pick(r, "resCancelYN", "CancelYN"),
        })
    return out


WATCH_RESULTS = HERE / "results_watch.csv"
WATCH_MAX_CALLS = 90  # 데모는 하루 100회 → 다른 시험용으로 10회 남긴다


def watch(minutes, interval):
    codef = Codef()
    conn = json.loads(STATE.read_text())[codef.env]
    calls = min(int(minutes * 60 / interval) + 1, WATCH_MAX_CALLS)
    end = datetime.now() + timedelta(seconds=interval * (calls - 1))
    print(f"[{codef.env} · {conn['card']}] {interval}초마다 {calls}회 조회, {end:%H:%M}까지. 이제 편의점에 다녀오세요.")
    seen = None   # 시작 시점에 이미 있던 승인 (승인번호+취소 여부)
    found = 0
    for i in range(calls):
        if i:
            time.sleep(interval)
        polled = datetime.now()
        try:
            approvals = parse_approvals(codef.request(APPROVAL_PATH, approval_params(conn, polled)))
        except CodefError as e:
            print(f"  {polled:%H:%M:%S} 오류: {e}")
            continue
        keys = {(a["approval_no"], a["cancel"]) for a in approvals}
        if seen is None:
            seen = keys
            print(f"  {polled:%H:%M:%S} 기준선: 오늘 승인 {len(keys)}건 (이건 무시)")
            continue
        for a in approvals:
            if (a["approval_no"], a["cancel"]) in seen:
                continue
            seen.add((a["approval_no"], a["cancel"]))
            found += 1
            latency = round((polled - a["approved_at"]).total_seconds())
            row = {
                "polled_at": polled.isoformat(timespec="seconds"), "interval_sec": interval, "env": codef.env,
                "card": conn["card"], "approved_at": a["approved_at"].isoformat(), "latency_sec": latency,
                "merchant": a["merchant"], "amount": a["amount"], "cancel": a["cancel"],
            }
            new = not WATCH_RESULTS.exists()
            with WATCH_RESULTS.open("a", newline="") as f:
                w = csv.DictWriter(f, fieldnames=row.keys())
                if new:
                    w.writeheader()
                w.writerow(row)
            print(f"  {polled:%H:%M:%S} 새 승인: {a['merchant']} {a['amount']}원, 승인 {a['approved_at']:%H:%M:%S}"
                  f" → 지연 약 {latency}초 (±{interval}초)")
    print(f"끝: 새 승인 {found}건, 호출 {codef.calls}회. 결과 {WATCH_RESULTS.name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--watch", type=float, metavar="MINUTES", help="감시 모드: 이 시간(분) 동안 계속 조회")
    ap.add_argument("--interval", type=int, default=30, help="감시 모드 조회 간격(초)")
    args = ap.parse_args()

    if args.dry_run:
        print("탭 후 조회 시점(초):", RETRY_AT)
        return
    if args.watch:
        watch(args.watch, args.interval)
        return

    codef = Codef()
    conn = json.loads(STATE.read_text())[codef.env]
    input(f"[{codef.env} · {conn['card']}] 결제가 끝나면 엔터 (= 라이브 액티비티 탭) ")
    tap = datetime.now()
    found = None

    for i, sec in enumerate(RETRY_AT, 1):
        wait = (tap + timedelta(seconds=sec) - datetime.now()).total_seconds()
        if wait > 0:
            time.sleep(wait)
        called = datetime.now()
        try:
            approvals = parse_approvals(codef.request(APPROVAL_PATH, approval_params(conn, tap)))
        except CodefError as e:
            print(f"  #{i} +{sec:>3}s 오류: {e}")
            continue
        recent = [a for a in approvals if a["approved_at"] >= tap - LOOKBACK]
        print(f"  #{i} +{sec:>3}s 응답 {(datetime.now() - called).total_seconds():.1f}s, "
              f"최근 승인 {len(recent)}건")
        if recent:
            found = max(recent, key=lambda a: a["approved_at"])
            break

    row = {
        "tap_at": tap.isoformat(timespec="seconds"),
        "env": codef.env,
        "card": conn["card"],
        "calls": codef.calls,
        "found": bool(found),
        "approved_at": found["approved_at"].isoformat() if found else "",
        "found_at": datetime.now().isoformat(timespec="seconds") if found else "",
        # 결제 시각(승인 시각) → 우리가 알아챈 시각. 마케팅 약속("결제하는 순간")의 핵심 지표
        "latency_sec": round((datetime.now() - found["approved_at"]).total_seconds()) if found else "",
        "merchant": found["merchant"] if found else "",
        "amount": found["amount"] if found else "",
    }
    new = not RESULTS.exists()
    with RESULTS.open("a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=row.keys())
        if new:
            w.writeheader()
        w.writerow(row)

    if found:
        print(f"찾음: {row['merchant']} {row['amount']}원, 승인 {row['approved_at']} → 지연 {row['latency_sec']}초")
    else:
        print(f"{RETRY_AT[-1]}초 안에 못 찾음 (호출 {codef.calls}회).")
    print(f"결과를 {RESULTS.name} 에 기록했습니다.")


if __name__ == "__main__":
    main()
