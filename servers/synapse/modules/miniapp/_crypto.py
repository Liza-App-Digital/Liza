"""Крипто-ядро Liza Mini Apps — чистые функции, без импорта Synapse.

Вынесено отдельным файлом, чтобы покрывать unit-тестами без поднятия реактора
Synapse (golden-векторы подписи). Здесь живут:

- вывод per-app ключа (`app_key = HMAC(master_secret, app_id)`) — закрывает B5:
  подпись app-A математически невалидна под ключом app-B;
- opaque `user_hash = HMAC(app_key, user_id)` — анти-корреляция между app (152-ФЗ);
- сборка `data_check_string` (сортировка по ключу, разделитель `\n`);
- HMAC-SHA256 подпись (нативная проверка внутри наших сервисов);
- Ed25519-подпись (для офлайн-проверки сторонним бэкендом без знания секрета, §3).

Совместимость: при `per_app_keys=False` ключ совпадает с историческим
`HMAC("LizaWebAppData", master_secret)` — prodamus-store продолжает валидироваться.
"""

from __future__ import annotations

import hashlib
import hmac
import re
from urllib.parse import quote

# Константа-«соль» исторической схемы (один ключ на все app). Сохраняется как
# fallback-режим, чтобы не ломать уже работающий prodamus-store.
_LEGACY_HMAC_LABEL = b"LizaWebAppData"

# Метка вывода per-app ключа. Отличается от legacy-метки намеренно, чтобы
# per-app и legacy ключи нельзя было спутать.
_PER_APP_LABEL = b"LizaMiniAppKey"


def validate_start_param(value: object) -> str | None:
    """Контекст запуска, а не URL-путь или разрешение на доступ к данным."""
    if value is None or value == "":
        return None
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_-]{1,512}", value) is None:
        raise ValueError("start_param must contain 1–512 ASCII letters, digits, '_' or '-'")
    return value


def compute_master_key(master_secret: str) -> bytes:
    """Исторический единый ключ: HMAC-SHA256("LizaWebAppData", master_secret).

    Используется в legacy-режиме (`per_app_keys=False`) — точная копия прежнего
    поведения модуля и того, что проверяет miniapp-store.
    """
    return hmac.new(_LEGACY_HMAC_LABEL, master_secret.encode("utf-8"), hashlib.sha256).digest()


def derive_app_key(master_secret: str, app_id: str) -> bytes:
    """Per-app ключ: HMAC-SHA256(master_secret, "LizaMiniAppKey:" + app_id).

    Подпись, сделанная этим ключом для app-A, невалидна под ключом app-B
    (defense-in-depth к логической сверке app_id). Закрывает B5.
    """
    msg = _PER_APP_LABEL + b":" + app_id.encode("utf-8")
    return hmac.new(master_secret.encode("utf-8"), msg, hashlib.sha256).digest()


def signing_key(master_secret: str, app_id: str, *, per_app_keys: bool) -> bytes:
    """Возвращает ключ подписи для app: per-app или legacy-единый."""
    if per_app_keys:
        return derive_app_key(master_secret, app_id)
    return compute_master_key(master_secret)


def compute_user_hash(key: bytes, user_id: str) -> str:
    """Opaque user_hash = HMAC-SHA256(key, user_id), hex.

    В per-app режиме key — это app_key, поэтому один и тот же пользователь
    получает разный hash в разных app (нельзя кросс-app трекать).
    """
    return hmac.new(key, user_id.encode("utf-8"), hashlib.sha256).hexdigest()


def build_data_check_string(params: dict[str, str]) -> str:
    """data_check_string: ключи по алфавиту, формат "key=value", разделитель \\n.

    Поля `hash` и `signature` НЕ входят в строку (их в `params` быть не должно).
    """
    return "\n".join(f"{k}={params[k]}" for k in sorted(params))


def hmac_sign(key: bytes, data_check_string: str) -> str:
    """HMAC-SHA256 подпись data_check_string, hex."""
    return hmac.new(key, data_check_string.encode("utf-8"), hashlib.sha256).hexdigest()


def hmac_verify(key: bytes, data_check_string: str, received_hash: str) -> bool:
    """Сравнение HMAC за константное время (анти-timing)."""
    expected = hmac_sign(key, data_check_string)
    return hmac.compare_digest(expected, received_hash)


def encode_init_data(params: dict[str, str], hash_value: str, signature: str | None = None) -> str:
    """Собирает финальную query-строку initData (URL-encoded), hash/signature в конце.

    Порядок полей (кроме hash/signature) — по алфавиту, как в data_check_string.
    """
    parts = [f"{k}={quote(params[k], safe='')}" for k in sorted(params)]
    parts.append(f"hash={hash_value}")
    if signature is not None:
        parts.append(f"signature={quote(signature, safe='')}")
    return "&".join(parts)


# ---------------------------------------------------------------------------
# Ed25519 — асимметричная подпись для офлайн-проверки сторонним бэкендом (§3)
# ---------------------------------------------------------------------------


def ed25519_sign_b64url(private_key_bytes: bytes, data_check_string: str) -> str:
    """Ed25519-подпись data_check_string, base64url без паддинга.

    `private_key_bytes` — 32 байта seed приватного ключа Ed25519.
    Используем `cryptography` (рантайм-зависимость Synapse), не pynacl.
    """
    import base64

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    sk = Ed25519PrivateKey.from_private_bytes(private_key_bytes)
    sig = sk.sign(data_check_string.encode("utf-8"))
    return base64.urlsafe_b64encode(sig).rstrip(b"=").decode("ascii")


def ed25519_public_key_b64url(private_key_bytes: bytes) -> str:
    """Публичный ключ (base64url без паддинга) из seed приватного — для .well-known."""
    import base64

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    sk = Ed25519PrivateKey.from_private_bytes(private_key_bytes)
    raw = sk.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def ed25519_verify_b64url(public_key_bytes: bytes, data_check_string: str, signature_b64url: str) -> bool:
    """Проверка Ed25519-подписи (для тестов/эталона; сторонний бэкенд делает то же)."""
    import base64

    from cryptography.exceptions import InvalidSignature
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

    pad = "=" * (-len(signature_b64url) % 4)
    sig = base64.urlsafe_b64decode(signature_b64url + pad)
    pk = Ed25519PublicKey.from_public_bytes(public_key_bytes)
    try:
        pk.verify(sig, data_check_string.encode("utf-8"))
        return True
    except InvalidSignature:
        return False
