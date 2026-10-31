"""Реестр зарегистрированных miniApp для Synapse-модуля.

Точка истины app_id — внешний сервис (developer-portal / miniapp-store). Модуль
читает реестр кэшированно (TTL), чтобы НЕ ходить в БД/по сети из reactor на каждый
запрос и не дублировать состояние на три инстанса.

Дизайн:
- статический список из конфига (`apps:`) — всегда доступен, fallback и «системные»
  app (prodamus-store) живут тут даже без сети;
- динамический список из `registry_url` — обновляется не чаще раза в `ttl` секунд,
  fire-and-forget из reactor; ошибка обновления НЕ роняет реестр (используем
  последний успешный снимок / статик).

Логика кэша — синхронная и чистая (тестируема). Сетевой fetch инжектится callable'ом.
"""

from __future__ import annotations

import logging
import time
from typing import Any, Awaitable, Callable

logger = logging.getLogger(__name__)


def map_portal_apps(body: Any) -> dict[str, dict]:
    """Ответ developer-portal `/internal/v1/apps` -> записи реестра модуля.

    `first_party` принимаем только явный: всё остальное (нет поля, мусор) — third_party.
    """
    # Портал отдаёт список; на случай обёртки {"apps": [...]} — разворачиваем.
    items = body if isinstance(body, list) else (body.get("apps", []) if isinstance(body, dict) else [])
    result: dict[str, dict] = {}
    for it in items:
        if not isinstance(it, dict):
            continue
        app_id = it.get("app_id") or it.get("slug")
        if not app_id:
            continue
        result[app_id] = {
            "name": it.get("name"),
            "url": it.get("base_url"),
            "icon": it.get("icon_url"),
            "short_description": it.get("short_description"),
            "scopes": it.get("scopes", []),
            "status": "listed" if it.get("state") == "listed" else it.get("state", "listed"),
            "type": "first_party" if it.get("type") == "first_party" else "third_party",
        }
    return result


class AppRegistry:
    """Кэш реестра app: объединяет статический конфиг и динамический снимок."""

    def __init__(
        self,
        static_apps: dict[str, dict],
        *,
        ttl: float = 60.0,
        fetcher: Callable[[], Awaitable[dict[str, dict]]] | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._static = dict(static_apps)
        self._dynamic: dict[str, dict] = {}
        self._ttl = ttl
        self._fetcher = fetcher
        self._clock = clock
        self._last_refresh = 0.0
        self._refreshing = False

    def get(self, app_id: str) -> dict | None:
        """Возвращает запись app по id (динамика приоритетнее статика) или None."""
        if app_id in self._dynamic:
            return self._dynamic[app_id]
        return self._static.get(app_id)

    def is_listed(self, app_id: str) -> bool:
        """app существует и НЕ suspended (kill-switch)."""
        rec = self.get(app_id)
        if rec is None:
            return False
        return rec.get("status", "listed") != "suspended"

    def all_listed(self) -> dict[str, dict]:
        """Все доступные app (для GET /apps): статик ∪ динамика, без suspended."""
        merged: dict[str, dict] = dict(self._static)
        merged.update(self._dynamic)
        return {k: v for k, v in merged.items() if v.get("status", "listed") != "suspended"}

    def needs_refresh(self) -> bool:
        if self._fetcher is None:
            return False
        return (self._clock() - self._last_refresh) >= self._ttl

    def apply_snapshot(self, snapshot: dict[str, dict]) -> None:
        """Применяет успешно полученный снимок динамического реестра."""
        self._dynamic = dict(snapshot)
        self._last_refresh = self._clock()

    def invalidate(self) -> None:
        """Сбрасывает TTL — следующий ``maybe_refresh()`` форсит ре-fetch.

        Дёргается извне (developer-portal через registry_refresh), когда app
        только что опубликован: иначе init_data для него 404 до истечения TTL.
        """
        self._last_refresh = 0.0

    async def maybe_refresh(self) -> None:
        """Обновляет динамический снимок, если истёк TTL. Ошибки гасит."""
        if self._fetcher is None or self._refreshing or not self.needs_refresh():
            return
        self._refreshing = True
        try:
            snapshot = await self._fetcher()
            if isinstance(snapshot, dict):
                self.apply_snapshot(snapshot)
                logger.debug("MiniApp registry обновлён: %d app", len(snapshot))
        except Exception:
            # Не роняем реестр — продолжаем со старым снимком/статиком.
            logger.warning("MiniApp registry: обновление не удалось, используем кэш", exc_info=True)
            # Сдвигаем метку, чтобы не долбить упавший источник каждый запрос.
            self._last_refresh = self._clock()
        finally:
            self._refreshing = False
