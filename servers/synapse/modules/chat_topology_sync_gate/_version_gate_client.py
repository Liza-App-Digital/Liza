"""TTL-кэш порогов min_stories_build из сервиса version-gate.

Fail-closed: сетевая ошибка возвращает последнее известное значение кэша,
а при полном отсутствии истории — None (= gate недостижим для этой
платформы, см. design doc секция 2 "Порог из version-gate").
"""

import time
from typing import Awaitable, Callable, Optional
from urllib.parse import urlencode

# На iOS/macOS строка version-gate адресуется bundle id приложения: там живут
# два приложения App Store (миграция Apple-аккаунта). Без параметра сервис
# отвечает 404, и гейт закрылся бы fail-closed, вырезав скрытые комнаты из
# /sync у ВСЕХ владельцев iOS/macOS — поэтому bundle обязателен.
#
# Порог здесь общий для обоих приложений: номер сборки у них сквозной
# (bump-build-number.sh не знает про LIZA_ACCOUNT, счётчик один на pubspec),
# поэтому min_stories_build у старого и нового совпадает. Спрашиваем новое
# приложение как основное, старое — запасной вариант на случай, если строка
# нового ещё не заведена: пустой порог закрыл бы гейт всем.
BUNDLES_BY_PLATFORM = {
    "ios": ("ru.prodamus.liza", "com.prodamus.laba.liza"),
    "macos": ("ru.prodamus.liza", "com.prodamus.laba.liza"),
}


class VersionGateThresholds:
    def __init__(
        self,
        base_url: str,
        http_get: Callable[[str], Awaitable[Optional[dict]]],
        ttl_seconds: int = 300,
        platforms: tuple = ("ios", "macos", "android", "windows"),
        failure_ttl_seconds: int = 30,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._http_get = http_get
        self._ttl_seconds = ttl_seconds
        # Неудачный запрос тоже кэшируется, но коротко: без этого при недоступном
        # version-gate HTTP уходил на каждый /sync каждого устройства платформы.
        self._failure_ttl_seconds = failure_ttl_seconds
        self._failed_ts: dict[str, float] = {}
        self._platforms = set(platforms)
        self._cache: dict[str, Optional[int]] = {}
        self._cache_ts: dict[str, float] = {}

    async def get_min_build(self, platform: str) -> Optional[int]:
        if platform not in self._platforms:
            return None

        now = time.monotonic()
        last_fetch = self._cache_ts.get(platform)
        if last_fetch is not None and (now - last_fetch) < self._ttl_seconds:
            return self._cache.get(platform)
        last_failure = self._failed_ts.get(platform)
        if last_failure is not None and (now - last_failure) < self._failure_ttl_seconds:
            return self._cache.get(platform)

        data = None
        for bundle in BUNDLES_BY_PLATFORM.get(platform, (None,)):
            url = f"{self._base_url}/version/{platform}"
            if bundle is not None:
                url = f"{url}?{urlencode({'bundle': bundle})}"
            data = await self._http_get(url)
            if data is not None:
                break

        if data is None:
            # fail-closed: используем последнее известное значение, если есть
            self._failed_ts[platform] = time.monotonic()
            return self._cache.get(platform)

        self._failed_ts.pop(platform, None)

        threshold = data.get("min_stories_build")
        self._cache[platform] = threshold
        self._cache_ts[platform] = time.monotonic()
        return threshold

    async def refresh_if_stale(self) -> None:
        for platform in self._platforms:
            await self.get_min_build(platform)
