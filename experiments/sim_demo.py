"""시뮬레이터에서 '결제하는 순간' 흐름을 재생하고 영상으로 녹화한다.

  python experiments/sim_demo.py <시뮬레이터 UDID> <시연 사용자 UUID> [영상 경로]

1) 앱 실행(홈) → 2) 라이브 액티비티 탭과 같은 동작(디버그 빌드 실행 옵션 -demoTap GS25) → "확인하고 있어요"
3) 서버가 GS25 4,000원 결제를 찾은 것처럼 payment_events·predictions 저장 → 앱이 Realtime으로 받아 확인 화면

실제 카드 조회 대신 3)에서 결제를 직접 넣는다 (CODEF 데모 전 시연용). 시연 결제는 approval_no가 DEMO- 로 시작한다.
"""
import os
import signal
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parents[1]
load_dotenv(ROOT / ".env")
URL = os.environ["SUPABASE_URL"].rstrip("/") + "/rest/v1"
KEY = os.environ["SUPABASE_SECRET_KEY"]
H = {"apikey": KEY, "Content-Type": "application/json", "Prefer": "return=representation"}
BUNDLE = "com.caloriesproject.app"


def step(msg):
    print(f"[{datetime.now():%H:%M:%S}] {msg}", flush=True)


def simctl(*args):
    subprocess.run(["xcrun", "simctl", *args], check=True, capture_output=True)


def reset_demo(user_id):
    """이전 시연 결제를 지운다 (predictions·confirmations는 cascade)."""
    requests.delete(f"{URL}/payment_events", headers=H,
                    params={"user_id": f"eq.{user_id}", "approval_no": "like.DEMO-*"}).raise_for_status()


def insert_payment(user_id, amount=4000, merchant="GS25 강남역점"):
    conn = requests.get(f"{URL}/card_connections", headers=H,
                        params={"user_id": f"eq.{user_id}", "select": "id", "limit": 1}).json()[0]
    merchant_id = requests.post(f"{URL}/rpc/match_merchant", headers=H, json={"raw": merchant}).json()
    ev = requests.post(f"{URL}/payment_events", headers=H, json={
        "user_id": user_id, "source": "card_api", "card_connection_id": conn["id"],
        "approval_no": f"DEMO-{uuid.uuid4().hex[:8]}", "merchant_raw": merchant, "merchant_id": merchant_id,
        "amount": amount, "paid_at": (datetime.now(timezone.utc) - timedelta(seconds=40)).isoformat(),
    }).json()[0]
    # tap-check의 Stage 1 매칭과 같은 결과 (킷캣 2,000원 × 2)
    requests.post(f"{URL}/predictions", headers=H, json={
        "event_id": ev["id"], "user_id": user_id, "is_snack_score": 0.8, "model_version": "stage1",
        "candidates": [{"items": [{"product_id": 46289, "name": "킷캣 오리지널 (36.5g)", "qty": 2}], "score": 2.25}],
    }).raise_for_status()


def main():
    sim, user_id = sys.argv[1], sys.argv[2]
    video = sys.argv[3] if len(sys.argv) > 3 else str(ROOT / "experiments" / "sim_demo.mp4")

    reset_demo(user_id)
    rec = subprocess.Popen(["xcrun", "simctl", "io", sim, "recordVideo", "--codec=h264", "--force", video],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    try:
        step("1. 앱 실행 → 홈 (오늘의 스택)")
        simctl("launch", "--terminate-running-process", sim, BUNDLE)
        time.sleep(6)

        step("2. 편의점에서 결제 후 잠금화면 라이브 액티비티 탭 → 앱이 열리며 조회 시작")
        # openurl은 "열겠습니까?" 확인 창이 떠서 멈춘다 → 디버그 빌드의 -demoTap 실행 옵션으로 같은 동작
        simctl("launch", "--terminate-running-process", sim, BUNDLE, "-demoTap", "GS25")
        time.sleep(7)

        step("3. 서버가 카드 승인 내역에서 GS25 4,000원 결제를 찾음 → 예측 저장 → 앱이 실시간으로 받음")
        insert_payment(user_id)
        time.sleep(7)
        step("끝")
    finally:
        rec.send_signal(signal.SIGINT)  # recordVideo는 SIGINT를 받아야 파일을 마무리한다
        rec.wait(timeout=30)
    print(video)


if __name__ == "__main__":
    main()
