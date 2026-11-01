"""Golden-vector тесты крипто-ядра Liza Mini Apps.

Запуск (без Synapse, только cryptography):
    pytest servers/synapse/modules/miniapp/test_crypto.py
"""

from __future__ import annotations

import hashlib
import hmac
import base64

import pytest

from _crypto import (
    build_data_check_string,
    compute_master_key,
    compute_user_hash,
    derive_app_key,
    ed25519_public_key_b64url,
    ed25519_sign_b64url,
    ed25519_verify_b64url,
    encode_init_data,
    hmac_sign,
    hmac_verify,
    signing_key,
    validate_start_param,
)

MASTER = "test-master-secret"


# ledger:RL-miniapp-initdata-signature
# AC:RL-miniapp-initdata-signature/1
@pytest.mark.parametrize("value", [None, "", "order_123-Abc", "x" * 512])
def test_start_param_validated_without_conflating_url_path(value):
    assert validate_start_param(value) == (value or None)


# AC:RL-miniapp-initdata-signature/1
@pytest.mark.parametrize("value", [True, 123, {}, [], "/order/123", "a b", "я", "x" * 513, "a\nb"])
def test_start_param_rejects_invalid_values(value):
    with pytest.raises(ValueError):
        validate_start_param(value)


# AC:RL-miniapp-initdata-signature/2
def test_start_param_is_covered_by_both_signatures():
    params = {"app_id": "test-app", "auth_date": "1700000000", "start_param": "order_123"}
    original = build_data_check_string(params)
    key = derive_app_key(MASTER, params["app_id"])
    seed = bytes(range(32))
    signature = ed25519_sign_b64url(seed, original)
    digest = hmac_sign(key, original)
    params["start_param"] = "order_456"
    changed = build_data_check_string(params)
    assert not hmac_verify(key, changed, digest)
    public_key = ed25519_public_key_b64url(seed)
    assert not ed25519_verify_b64url(base64.urlsafe_b64decode(public_key + "="), changed, signature)


def test_legacy_key_matches_historical_formula():
    # legacy-ключ обязан совпадать с тем, что проверяет miniapp-store,
    # иначе prodamus-store перестанет валидироваться.
    expected = hmac.new(b"LizaWebAppData", MASTER.encode(), hashlib.sha256).digest()
    assert compute_master_key(MASTER) == expected
    assert signing_key(MASTER, "prodamus-store", per_app_keys=False) == expected


def test_per_app_keys_differ_between_apps():
    k_a = derive_app_key(MASTER, "app-a")
    k_b = derive_app_key(MASTER, "app-b")
    assert k_a != k_b
    assert k_a != compute_master_key(MASTER)


def test_signature_of_app_a_invalid_under_app_b():
    # B5: подпись app-A не должна проверяться ключом app-B.
    params = {"app_id": "app-a", "auth_date": "1700000000", "nonce": "n1", "user": '{"id":"h"}'}
    dcs = build_data_check_string(params)
    sig_a = hmac_sign(derive_app_key(MASTER, "app-a"), dcs)
    assert hmac_verify(derive_app_key(MASTER, "app-a"), dcs, sig_a) is True
    assert hmac_verify(derive_app_key(MASTER, "app-b"), dcs, sig_a) is False


def test_user_hash_differs_per_app_key():
    # Анти-корреляция: один user → разный hash в разных app.
    uid = "@user:liza.example"
    h_a = compute_user_hash(derive_app_key(MASTER, "app-a"), uid)
    h_b = compute_user_hash(derive_app_key(MASTER, "app-b"), uid)
    assert h_a != h_b


def test_data_check_string_sorted_and_excludes_nothing_extra():
    params = {"b": "2", "a": "1", "c": "3"}
    assert build_data_check_string(params) == "a=1\nb=2\nc=3"


def test_hmac_verify_constant_time_true_false():
    key = derive_app_key(MASTER, "x")
    dcs = "a=1\nb=2"
    good = hmac_sign(key, dcs)
    assert hmac_verify(key, dcs, good) is True
    assert hmac_verify(key, dcs, "deadbeef") is False
    assert hmac_verify(key, dcs, "") is False


def test_encode_init_data_roundtrip_hash_position():
    params = {"app_id": "a", "auth_date": "1700000000", "nonce": "n", "user": '{"id":"h"}'}
    enc = encode_init_data(params, "ABC123")
    assert "hash=ABC123" in enc
    # поля до hash — по алфавиту
    assert enc.index("app_id=") < enc.index("auth_date=") < enc.index("hash=")


def test_encode_init_data_with_signature():
    params = {"app_id": "a", "auth_date": "1700000000", "nonce": "n", "user": '{"id":"h"}'}
    enc = encode_init_data(params, "HSH", signature="SIG-value")
    assert enc.endswith("signature=SIG-value")
    assert "hash=HSH" in enc


# --- Ed25519 (§3) ---

# Детерминированный seed (32 байта) для golden-вектора.
_SEED = bytes(range(32))


def test_ed25519_sign_verify_roundtrip():
    import base64

    dcs = "app_id=a\nauth_date=1700000000\nnonce=n\nuser={\"id\":\"h\"}"
    sig = ed25519_sign_b64url(_SEED, dcs)
    pub_b64 = ed25519_public_key_b64url(_SEED)
    pad = "=" * (-len(pub_b64) % 4)
    pub = base64.urlsafe_b64decode(pub_b64 + pad)
    assert ed25519_verify_b64url(pub, dcs, sig) is True
    # Любое изменение строки рушит подпись.
    assert ed25519_verify_b64url(pub, dcs + "x", sig) is False


def test_ed25519_signature_is_deterministic_golden():
    # Ed25519 детерминирована: один seed + одна строка → одна подпись.
    dcs = "x=1"
    s1 = ed25519_sign_b64url(_SEED, dcs)
    s2 = ed25519_sign_b64url(_SEED, dcs)
    assert s1 == s2
    # base64url без паддинга
    assert "=" not in s1


def test_third_party_can_verify_without_secret():
    # §3: сторонний бэкенд проверяет initData по публичному ключу, НЕ зная master.
    import base64

    params = {"app_id": "third", "auth_date": "1700000000", "nonce": "n", "user": '{"id":"h"}'}
    dcs = build_data_check_string(params)
    sig = ed25519_sign_b64url(_SEED, dcs)
    pub_b64 = ed25519_public_key_b64url(_SEED)
    pad = "=" * (-len(pub_b64) % 4)
    pub = base64.urlsafe_b64decode(pub_b64 + pad)
    # «Сторона» имеет только публичный ключ:
    assert ed25519_verify_b64url(pub, dcs, sig) is True


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
