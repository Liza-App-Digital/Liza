"""Исходящие запросы поиска к соседним homeserver-ам."""

import logging

from synapse.util.async_helpers import yieldable_gather_results

from ._company import POLICY_PATH, CompanyPolicy, parse_policy_payload
from ._search import belongs_to_domain

logger = logging.getLogger(__name__)

FEDERATION_PATH = "/_matrix/federation/v1/com.liza/user_search"
_FED_TIMEOUT_MS = 5000


class FederatedUserSearchClient:
    """Опрашивает соседей из federation_domain_whitelist параллельно."""

    def __init__(self, hs) -> None:
        self._fed_http = hs.get_federation_http_client()

    async def search(
        self, query: str, domains: list[str], searcher: str | None = None,
    ) -> list[dict]:
        """Собрать результаты со всех доменов. Недоступный сосед даёт [].

        searcher уходит соседу, чтобы тот показал людей своей скрытой
        компании её участникам (иначе он считает ищущего посторонним).

        Ошибка любого соседа не должна ронять поиск целиком — best-effort
        по каждому домену независимо.
        """
        if not domains or not query:
            return []

        args = {"query": query}
        if searcher:
            args["searcher"] = searcher

        async def fetch_domain(destination: str) -> list[dict]:
            try:
                response = await self._fed_http.get_json(
                    destination=destination,
                    path=FEDERATION_PATH,
                    args=args,
                    timeout=_FED_TIMEOUT_MS,
                )
            except Exception as e:  # noqa: BLE001 — best-effort по каждому домену
                logger.warning(
                    "user_search_guard: поиск на %s не удался: %s", destination, e
                )
                return []

            out: list[dict] = []
            for item in (response or {}).get("results", []):
                user_id = item.get("user_id")
                # Анти-spoofing: сосед вправе отдавать только своих.
                if not belongs_to_domain(user_id or "", destination):
                    logger.warning(
                        "user_search_guard: %s попытался отдать чужой mxid %s",
                        destination, user_id,
                    )
                    continue
                out.append({
                    "user_id": user_id,
                    "display_name": item.get("display_name"),
                    "avatar_url": item.get("avatar_url"),
                    "homeserver": destination,
                })
            return out

        per_domain = await yieldable_gather_results(fetch_domain, domains)
        results: list[dict] = []
        for lst in per_domain:
            results.extend(lst)
        return results

    async def fetch_policies(self, domains: list[str]) -> dict[str, CompanyPolicy]:
        """Политики поиска соседей. Не ответивший или ответивший криво сосед
        в результат не попадает — вызывающий держит его прошлую политику."""
        if not domains:
            return {}

        async def fetch_domain(destination: str) -> tuple[str, CompanyPolicy | None]:
            try:
                response = await self._fed_http.get_json(
                    destination=destination,
                    path=POLICY_PATH,
                    timeout=_FED_TIMEOUT_MS,
                )
            except Exception as e:  # noqa: BLE001 — старый сосед отвечает 404
                logger.debug(
                    "user_search_guard: политика %s не получена: %s", destination, e
                )
                return destination, None
            return destination, parse_policy_payload(response)

        pairs = await yieldable_gather_results(fetch_domain, domains)
        return {d: p for d, p in pairs if p is not None}
