#!/usr/bin/env python3
"""Опыт Ф1.0 (howItWoks/pushes/pushes.md §27, часть A): два APNs-баннера с ОДНИМ
`apns-collapse-id` на Мак — звучит ли замена второй раз.

Шлёт alert-пуш прямо в APNs (без Synapse и Sygnal), чтобы проверить поведение
системы, а не нашего кода. Секреты — только из окружения, в аргументы и вывод не
попадают:
  APNS_KEY_FILE  путь к AuthKey_<KEYID>.p8 (secrets/sygnal/)
  APNS_KEY_ID    10 символов, из имени файла ключа
  APNS_TEAM_ID   H77D732S9L (ru.prodamus.liza) или D3PPB6B842 (com.prodamus.laba.liza)
  APNS_TOPIC     bundle id приложения на этом Маке
  DEVICE_TOKEN   hex APNs-токен Мака (pushkey pusher'а macOS)

  python3 -I apns_replace_experiment.py --collapse-id exp1 --text "первый"
  python3 -I apns_replace_experiment.py --collapse-id exp1 --text "второй"   # замена
  python3 -I apns_replace_experiment.py --collapse-id exp2 --text "другой"   # новый баннер
  --dry-run — собрать запрос и показать его без отправки (токен и JWT скрыты).
"""
import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time

HOST = "https://api.push.apple.com"


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """ECDSA-подпись openssl (DER SEQUENCE{r,s}) → r||s по 32 байта (JWS ES256)."""
    if der[0] != 0x30:
        raise ValueError("not a DER sequence")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        value = der[i + 2:i + 2 + n].lstrip(b"\x00")
        parts.append(value.rjust(32, b"\x00"))
        i += 2 + n
    return parts[0] + parts[1]


def jwt(key_file: str, key_id: str, team_id: str, now: int) -> str:
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": now}).encode())
    signing_input = f"{header}.{claims}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_file],
                         input=signing_input, capture_output=True, check=True).stdout
    return f"{header}.{claims}.{b64url(der_to_raw(der))}"


def payload(text: str) -> dict:
    return {"aps": {"alert": {"title": "Liza Ф1.0", "body": text}, "sound": "liza_ding.aiff"}}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--collapse-id", required=True)
    ap.add_argument("--text", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    env = {k: os.environ.get(k, "") for k in ("APNS_KEY_FILE", "APNS_KEY_ID", "APNS_TEAM_ID", "APNS_TOPIC",
                                              "DEVICE_TOKEN")}
    missing = [k for k, v in env.items() if not v]
    if missing:
        print("нет переменных окружения: " + ", ".join(missing), file=sys.stderr)
        return 2
    token = jwt(env["APNS_KEY_FILE"], env["APNS_KEY_ID"], env["APNS_TEAM_ID"], int(time.time()))
    body = json.dumps(payload(args.text), ensure_ascii=False)
    headers = {
        "authorization": f"bearer {token}",
        "apns-topic": env["APNS_TOPIC"],
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-collapse-id": args.collapse_id,
    }
    url = f"{HOST}/3/device/{env['DEVICE_TOKEN']}"
    if args.dry_run:
        shown = {**headers, "authorization": "bearer <скрыт>"}
        print(json.dumps({"url": f"{HOST}/3/device/<скрыт>", "headers": shown, "body": json.loads(body)},
                         ensure_ascii=False, indent=2))
        return 0
    # Заголовок с JWT — через файл (-H @file), а не аргументом: не светится в `ps`.
    with tempfile.NamedTemporaryFile("w", delete=True) as hfile:
        hfile.write("\n".join(f"{k}: {v}" for k, v in headers.items()))
        hfile.flush()
        res = subprocess.run(["curl", "-sS", "--http2", "-o", "-", "-w", "\nHTTP %{http_code}\n",
                              "-H", f"@{hfile.name}", "--data-binary", body, url],
                             capture_output=True, text=True)
    out = res.stdout.strip() or res.stderr.strip()
    print(f"[{time.strftime('%H:%M:%S')}] collapse-id={args.collapse_id} text={args.text!r} → {out}")
    return 0 if "HTTP 200" in out else 1


if __name__ == "__main__":
    sys.exit(main())
