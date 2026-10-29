"""CODEF API 최소 클라이언트 (토큰 발급, 요청, 비밀번호 RSA 암호화).

키는 CALORIES_project/.env 에서 읽는다:
  CODEF_ENV=sandbox | demo | prod
  CODEF_CLIENT_ID=...
  CODEF_CLIENT_SECRET=...
  CODEF_PUBLIC_KEY=...   (키 관리 화면의 RSA 공개키, base64 한 줄)

CODEF는 요청 본문과 응답을 URL 인코딩된 JSON으로 주고받는다.
"""
import base64
import json
import os
import time
import urllib.parse
from pathlib import Path

import requests
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding
from dotenv import load_dotenv

load_dotenv(Path(__file__).resolve().parents[2] / ".env")

HOSTS = {
    "sandbox": "https://sandbox.codef.io",
    "demo": "https://development.codef.io",
    "prod": "https://api.codef.io",
}
TOKEN_URL = "https://oauth.codef.io/oauth/token"

# 카드사 기관코드 (개발가이드 "카드 개요 > 카드사 목록"에서 확인, 2026-10-29). 카카오뱅크·토스뱅크는 없음
CARD_ORGS = {
    "KB국민": "0301", "현대": "0302", "삼성": "0303", "NH농협": "0304", "BC": "0305",
    "신한": "0306", "씨티": "0307", "우리": "0309", "롯데": "0311", "하나": "0313",
}


class CodefError(Exception):
    pass


class Codef:
    def __init__(self):
        self.env = os.environ.get("CODEF_ENV", "sandbox")
        self.host = HOSTS[self.env]
        self.client_id = os.environ.get("CODEF_CLIENT_ID")
        self.client_secret = os.environ.get("CODEF_CLIENT_SECRET")
        self.public_key = os.environ.get("CODEF_PUBLIC_KEY")
        if not (self.client_id and self.client_secret):
            raise CodefError("CODEF_CLIENT_ID / CODEF_CLIENT_SECRET 가 .env 에 없습니다.")
        self._token = None
        self._token_at = 0.0
        self.calls = 0  # 이번 실행에서 보낸 API 호출 수 (데모는 하루 100회 한도)

    def token(self):
        # 토큰은 7일 유효. 실험 스크립트는 하루 단위로 돌리므로 6일이 지나면 새로 받는다.
        if self._token and time.time() - self._token_at < 6 * 86400:
            return self._token
        basic = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        r = requests.post(
            TOKEN_URL,
            headers={"Authorization": f"Basic {basic}",
                     "Content-Type": "application/x-www-form-urlencoded"},
            data="grant_type=client_credentials&scope=read",
            timeout=30,
        )
        r.raise_for_status()
        self._token, self._token_at = r.json()["access_token"], time.time()
        return self._token

    def request(self, path, params):
        self.calls += 1
        r = requests.post(
            self.host + path,
            headers={"Authorization": f"Bearer {self.token()}",
                     "Content-Type": "application/json"},
            data=urllib.parse.quote(json.dumps(params, ensure_ascii=False)),
            timeout=300,  # 승인내역 API timeout 300초
        )
        r.raise_for_status()
        body = json.loads(urllib.parse.unquote_plus(r.text))
        code = body.get("result", {}).get("code")
        if code != "CF-00000":
            raise CodefError(f"{code}: {body.get('result', {}).get('message')}")
        return body.get("data")

    def encrypt(self, plain):
        """계정 등록 시 비밀번호를 RSA(PKCS#1 v1.5)로 암호화한다."""
        if not self.public_key:
            raise CodefError("CODEF_PUBLIC_KEY 가 .env 에 없습니다.")
        key = serialization.load_der_public_key(base64.b64decode(self.public_key))
        return base64.b64encode(key.encrypt(plain.encode(), padding.PKCS1v15())).decode()
