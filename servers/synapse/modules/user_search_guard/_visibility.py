"""Видимость ботов в поиске пользователей (private-bots-by-default).

Без импортов synapse — модуль грузится в тестах напрямую по пути, без
живого HomeServer. HTTP-клиент передаётся снаружи (``http_get``), поэтому
кэш тестируется на подставном async-callable.
"""

import logging
from typing import Awaitable, Callable, Collection, Mapping, Optional

logger = logging.getLogger(__name__)

HIDDEN_PATH = "/registry/v1/hidden"

# Ключ верхнего уровня в secrets-оверлее инстанса
# (/run/secrets/synapse/homeserver-secrets.yaml). Synapse незнакомые ключи
# верхнего уровня игнорирует, поэтому секрет модуля живёт рядом с остальными
# секретами инстанса и не требует отдельного volume-mount.
SECRET_KEY = "liza_registry_secret"


def is_hidden(
    user_id: str,
    searcher: Optional[str],
    hidden_bots: Mapping[str, Optional[str]],
    deny_list: Collection[str],
) -> bool:
    """Скрыт ли user_id от searcher в выдаче поиска.

    deny_list — служебные аккаунты, скрытые от всех без исключения.
    hidden_bots — приватные боты {mxid: owner}; владелец свою запись видит.
    searcher=None — запрашивающий неизвестен (federation-ответ): владельцем
    не может быть никто, поэтому скрыт каждый приватный бот.
    """
    if user_id in deny_list:
        return True
    if user_id not in hidden_bots:
        return False
    owner = hidden_bots[user_id]
    return searcher is None or not owner or owner != searcher


def parse_hidden_payload(payload: object) -> Optional[dict[str, Optional[str]]]:
    """Ответ /registry/v1/hidden → {mxid: owner}; None, если формат не тот.

    Кривая структура (не объект, нет списка bots) отвергается целиком —
    вызывающий держит прошлый набор. Отдельная битая строка (нет mxid)
    пропускается: одна плохая запись реестра не должна замораживать
    обновление видимости всех остальных ботов.
    """
    if not isinstance(payload, dict):
        return None
    bots = payload.get("bots")
    if not isinstance(bots, list):
        return None
    out: dict[str, Optional[str]] = {}
    for item in bots:
        if not isinstance(item, dict):
            continue
        mxid = item.get("mxid")
        if not isinstance(mxid, str) or not mxid.startswith("@"):
            continue
        owner = item.get("owner")
        out[mxid] = owner if isinstance(owner, str) and owner else None
    return out


def read_secret_file(path: str) -> str:
    """Достать liza_registry_secret из YAML-оверлея секретов инстанса.

    Пустая строка, если файла/ключа нет: модуль тогда работает только по
    deny-list (реестр ответит 401), а не роняет старт Synapse.
    """
    import yaml  # зависимость Synapse; импорт здесь, чтобы чистые функции грузились без неё

    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError) as e:
        logger.warning("user_search_guard: не прочитан файл секрета %s: %s", path, e)
        return ""
    value = data.get(SECRET_KEY) if isinstance(data, dict) else None
    if not isinstance(value, str) or not value:
        logger.warning("user_search_guard: в %s нет ключа %s", path, SECRET_KEY)
        return ""
    return value


class HiddenBotsCache:
    """In-memory набор приватных ботов, обновляемый фоном из liza-bot-api.

    Запрос поиска только читает ``hidden_bots`` — сеть на пути запроса не
    участвует. При ошибке или кривом ответе держим последний удачный набор
    (fail-safe из спеки: поиск не падает, фильтр не «открывается»).
    """

    def __init__(
        self,
        registry_url: str,
        secret: str,
        http_get: Callable[[str, dict], Awaitable[object]],
    ) -> None:
        self._url = registry_url.rstrip("/") + HIDDEN_PATH
        self._secret = secret
        self._http_get = http_get
        self.hidden_bots: dict[str, Optional[str]] = {}
        self.loaded = False

    async def refresh(self) -> bool:
        """Один запрос к реестру. True — набор обновлён."""
        try:
            payload = await self._http_get(self._url, {"X-Registry-Secret": self._secret})
        except Exception as e:  # noqa: BLE001 — сеть/401/5xx: держим прошлый набор
            logger.warning("user_search_guard: реестр скрытых ботов недоступен: %s", e)
            return False
        parsed = parse_hidden_payload(payload)
        if parsed is None:
            logger.warning("user_search_guard: кривой ответ реестра скрытых ботов, держим прошлый набор")
            return False
        if parsed != self.hidden_bots or not self.loaded:
            logger.info("user_search_guard: скрытых ботов %d", len(parsed))
        self.hidden_bots = parsed
        self.loaded = True
        return True

    async def initial_load(
        self,
        sleep: Callable[[float], Awaitable[None]],
        attempts: int = 3,
        delay_seconds: float = 2.0,
    ) -> bool:
        """Старт: несколько быстрых попыток, чтобы не ждать первого тика (60 с)."""
        for i in range(attempts):
            if await self.refresh():
                return True
            if i + 1 < attempts:
                await sleep(delay_seconds)
        return False
