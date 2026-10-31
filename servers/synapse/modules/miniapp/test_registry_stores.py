"""Тесты реестра app и in-memory сторов (без Synapse).

Запуск из чистой копии (без пакета): pytest test_registry_stores.py
"""

from __future__ import annotations

import asyncio

import pytest

from _registry import AppRegistry, map_portal_apps
from _stores import NonceStore, RateLimiter


# --- AppRegistry ---


def test_static_lookup_and_listed():
    reg = AppRegistry({"prodamus-store": {"url": "u", "name": "n"}})
    assert reg.get("prodamus-store")["name"] == "n"
    assert reg.is_listed("prodamus-store") is True
    assert reg.get("nope") is None
    assert reg.is_listed("nope") is False


def test_suspended_kill_switch():
    reg = AppRegistry({"x": {"status": "suspended"}})
    assert reg.get("x") is not None
    assert reg.is_listed("x") is False
    assert "x" not in reg.all_listed()


def test_dynamic_overrides_static():
    reg = AppRegistry({"x": {"name": "static"}})
    reg.apply_snapshot({"x": {"name": "dynamic"}, "y": {"name": "new"}})
    assert reg.get("x")["name"] == "dynamic"
    assert reg.get("y")["name"] == "new"
    assert set(reg.all_listed()) == {"x", "y"}


def test_refresh_failure_keeps_cache():
    calls = {"n": 0}
    t = {"now": 1000.0}

    async def bad_fetch():
        calls["n"] += 1
        raise RuntimeError("network down")

    reg = AppRegistry({"x": {"name": "static"}}, ttl=10, fetcher=bad_fetch, clock=lambda: t["now"])
    # первый снимок
    reg.apply_snapshot({"x": {"name": "snap"}})
    t["now"] = 1020.0  # TTL истёк
    assert reg.needs_refresh() is True
    asyncio.run(reg.maybe_refresh())
    # реестр не упал — остался последний снимок
    assert reg.get("x")["name"] == "snap"
    # метка сдвинута, чтобы не долбить упавший источник
    assert reg.needs_refresh() is False


def test_no_fetcher_never_refreshes():
    reg = AppRegistry({"x": {}})
    assert reg.needs_refresh() is False


# --- NonceStore ---


def test_nonce_one_time_use():
    s = NonceStore()
    n = s.create("@u:hs", "app-a", "!room:hs")
    assert s.validate_and_consume(n) is True
    # повторно — уже израсходован
    assert s.validate_and_consume(n) is False


def test_nonce_binding_app_mismatch():
    s = NonceStore()
    n = s.create("@u:hs", "app-a", "!room:hs")
    # nonce app-A нельзя предъявить от app-B
    assert s.validate_and_consume(n, app_id="app-b") is False


def test_nonce_binding_room_match():
    s = NonceStore()
    n = s.create("@u:hs", "app-a", "!room:hs")
    assert s.validate_and_consume(n, app_id="app-a", room_id="!room:hs") is True


def test_nonce_ttl_expiry():
    t = {"now": 0.0}
    s = NonceStore(ttl=5, clock=lambda: t["now"])
    n = s.create("@u:hs", "a", None)
    t["now"] = 10.0
    assert s.validate_and_consume(n) is False


def test_nonce_cleanup():
    t = {"now": 0.0}
    s = NonceStore(ttl=5, clock=lambda: t["now"])
    s.create("@u:hs", "a", None)
    s.create("@u:hs", "a", None)
    t["now"] = 100.0
    assert s.cleanup() == 2


# --- RateLimiter ---


def test_rate_limiter_blocks_after_max():
    t = {"now": 0.0}
    r = RateLimiter(max_requests=3, window=60, clock=lambda: t["now"])
    assert all(r.check("@u:hs") for _ in range(3))
    assert r.check("@u:hs") is False  # 4-й заблокирован


def test_rate_limiter_window_slides():
    t = {"now": 0.0}
    r = RateLimiter(max_requests=2, window=60, clock=lambda: t["now"])
    assert r.check("@u:hs") is True
    assert r.check("@u:hs") is True
    assert r.check("@u:hs") is False
    t["now"] = 61.0  # окно ушло
    assert r.check("@u:hs") is True


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))


def test_portal_type_first_party_only_when_explicit():
    apps = map_portal_apps([
        {"app_id": "capsules", "base_url": "https://c/", "state": "listed", "type": "first_party"},
        {"app_id": "ext", "base_url": "https://e/", "state": "listed"},
        {"app_id": "junk", "base_url": "https://j/", "state": "listed", "type": "FIRST_PARTY"},
        {"slug": "noid", "state": "suspended"},
        "garbage",
    ])
    assert apps["capsules"]["type"] == "first_party"
    assert apps["ext"]["type"] == "third_party"
    assert apps["junk"]["type"] == "third_party"
    assert apps["noid"]["status"] == "suspended"
    assert set(apps) == {"capsules", "ext", "junk", "noid"}
    assert map_portal_apps({"apps": [{"app_id": "w"}]})["w"]["type"] == "third_party"
