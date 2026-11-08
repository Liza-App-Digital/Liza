import asyncio

from .._version_gate_client import VersionGateThresholds


def test_get_min_build_returns_value_from_http():
    async def fake_get(url):
        assert url == "https://version.test/version/android"
        return {"platform": "android", "build": 3700, "min_stories_build": 3675}

    client = VersionGateThresholds(
        base_url="https://version.test", http_get=fake_get, platforms=("android",)
    )
    result = asyncio.run(client.get_min_build("android"))
    assert result == 3675


def test_get_min_build_null_threshold_returns_none():
    async def fake_get(url):
        return {"platform": "android", "build": 3700, "min_stories_build": None}

    client = VersionGateThresholds(
        base_url="https://version.test", http_get=fake_get, platforms=("android",)
    )
    result = asyncio.run(client.get_min_build("android"))
    assert result is None


def test_get_min_build_http_failure_is_fail_closed_none():
    async def fake_get(url):
        return None  # сеть упала / не-200

    client = VersionGateThresholds(
        base_url="https://version.test", http_get=fake_get, platforms=("android",)
    )
    result = asyncio.run(client.get_min_build("android"))
    assert result is None


def test_get_min_build_unknown_platform_returns_none_without_http_call():
    calls = []

    async def fake_get(url):
        calls.append(url)
        return {"min_stories_build": 1}

    client = VersionGateThresholds(
        base_url="https://version.test", http_get=fake_get, platforms=("android",)
    )
    result = asyncio.run(client.get_min_build("linux"))
    assert result is None
    assert calls == []


def test_get_min_build_caches_within_ttl():
    calls = []

    async def fake_get(url):
        calls.append(url)
        return {"min_stories_build": 3675}

    client = VersionGateThresholds(
        base_url="https://version.test",
        http_get=fake_get,
        platforms=("android",),
        ttl_seconds=300,
    )
    asyncio.run(client.get_min_build("android"))
    asyncio.run(client.get_min_build("android"))
    assert len(calls) == 1


def test_get_min_build_uses_last_known_value_when_http_fails_after_success():
    responses = [{"min_stories_build": 3675}, None]

    async def fake_get(url):
        return responses.pop(0)

    client = VersionGateThresholds(
        base_url="https://version.test",
        http_get=fake_get,
        platforms=("android",),
        ttl_seconds=0,  # TTL=0 чтобы второй вызов форсировал повторный HTTP-запрос
    )
    first = asyncio.run(client.get_min_build("android"))
    second = asyncio.run(client.get_min_build("android"))
    assert first == 3675
    assert second == 3675  # используется последнее известное значение, не None


def test_apple_request_carries_bundle():
    """На iOS/macOS строка адресуется bundle id — без него сервис даст 404,
    и гейт закрылся бы fail-closed у всех владельцев Apple-устройств."""
    seen = []

    async def http_get(url):
        seen.append(url)
        return {"min_stories_build": 3674}

    client = VersionGateThresholds("https://version.test", http_get)

    assert asyncio.run(client.get_min_build("ios")) == 3674
    assert seen == ["https://version.test/version/ios?bundle=ru.prodamus.liza"]


def test_apple_falls_back_to_other_bundle():
    """Если строка нового приложения ещё не заведена, порог берём у старого:
    пустой порог закрыл бы гейт всем."""
    seen = []

    async def http_get(url):
        seen.append(url)
        if "ru.prodamus.liza" in url:
            return None
        return {"min_stories_build": 3674}

    client = VersionGateThresholds("https://version.test", http_get)

    assert asyncio.run(client.get_min_build("macos")) == 3674
    assert len(seen) == 2
    assert seen[1].endswith("bundle=com.prodamus.laba.liza")


def test_non_apple_request_has_no_bundle():
    seen = []

    async def http_get(url):
        seen.append(url)
        return {"min_stories_build": 3674}

    client = VersionGateThresholds("https://version.test", http_get)

    asyncio.run(client.get_min_build("android"))
    assert seen == ["https://version.test/version/android"]


def test_get_min_build_failure_is_cached_for_failure_ttl(monkeypatch):
    calls = []
    now = [1000.0]
    monkeypatch.setattr("time.monotonic", lambda: now[0])

    async def fake_get(url):
        calls.append(url)
        return None

    client = VersionGateThresholds(
        base_url="https://version.test",
        http_get=fake_get,
        platforms=("android",),
        failure_ttl_seconds=30,
    )
    assert asyncio.run(client.get_min_build("android")) is None
    assert asyncio.run(client.get_min_build("android")) is None
    assert len(calls) == 1  # повтор в пределах failure TTL — без HTTP
    now[0] += 31
    assert asyncio.run(client.get_min_build("android")) is None
    assert len(calls) == 2


def test_get_min_build_failure_keeps_last_known_value(monkeypatch):
    now = [1000.0]
    monkeypatch.setattr("time.monotonic", lambda: now[0])
    answers = [{"min_stories_build": 3675}, None]

    async def fake_get(url):
        return answers.pop(0)

    client = VersionGateThresholds(
        base_url="https://version.test", http_get=fake_get, platforms=("android",), ttl_seconds=60
    )
    assert asyncio.run(client.get_min_build("android")) == 3675
    now[0] += 61
    assert asyncio.run(client.get_min_build("android")) == 3675  # сбой — последнее известное
    assert answers == []


def test_module_does_not_gate_web_through_version_gate():
    from .. import GATED_PLATFORMS, KNOWN_PLATFORMS

    assert "web" in KNOWN_PLATFORMS
    assert "web" not in GATED_PLATFORMS
