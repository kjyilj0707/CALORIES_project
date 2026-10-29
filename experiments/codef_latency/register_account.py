"""내 카드사 계정을 CODEF에 등록하고 connectedId를 .state.json 에 저장한다.

  python register_account.py

비밀번호는 화면에 보이지 않게 입력받고, RSA로 암호화해서 CODEF로만 보낸다 (파일에 저장하지 않음).
"""
import getpass
import json
import os
from pathlib import Path

from codef_client import CARD_ORGS, Codef

STATE = Path(__file__).with_name(".state.json")


def main():
    codef = Codef()
    print(f"[환경] {codef.env} ({codef.host})")
    print("카드사:", ", ".join(CARD_ORGS))
    name = input("카드사 이름: ").strip()
    org = CARD_ORGS[name]

    account = {
        "countryCode": "KR",
        "businessType": "CD",
        "clientType": "P",
        "organization": org,
        "loginType": "1",  # 1 = 아이디 로그인, 0 = 공동인증서
        "id": input("카드사 아이디: ").strip(),
        "password": codef.encrypt(getpass.getpass("카드사 비밀번호 (화면에 안 보임): ")),
    }
    if name in ("현대", "KB국민"):
        # 현대카드(25.10.30부터)와 일부 KB카드는 카드번호 + 카드 비밀번호가 필요하다
        card_no = input("카드번호 (필요 없으면 엔터): ").strip()
        if card_no:
            account["cardNo"] = card_no
            account["cardPassword"] = codef.encrypt(getpass.getpass("카드 비밀번호: "))

    data = codef.request("/v1/account/create", {"accountList": [account]})
    connected_id = data["connectedId"]

    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    state[codef.env] = {"connectedId": connected_id, "organization": org, "card": name}
    STATE.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    os.chmod(STATE, 0o600)
    print(f"등록 완료. connectedId를 {STATE.name} 에 저장했습니다. (API 호출 {codef.calls}회)")


if __name__ == "__main__":
    main()
