"""Федеративный поиск пользователей по всем инстансам Liza.

Штатный /_matrix/client/v3/user_directory/search не федерируется: Synapse
ищет только по локальной таблице user_directory, а remote-профили попадают
в неё лишь при наличии общей комнаты. Поэтому пользователя со свежего
инстанса нельзя найти иначе как вводом полного MXID.

Модуль добавляет веер по federation_domain_whitelist: свои результаты
берём из штатного search_user_dir, чужие спрашиваем у соседей через
собственный federation-эндпоинт.

Он же прячет приватных ботов (private-bots-by-default): один фильтр
is_hidden на трёх путях — колбэк check_username_for_spam штатного
/user_directory/search, локальная часть федеративного поиска (ищущий
известен) и federation-ответ соседям (ищущий неизвестен → скрыты все).
Набор приватных ботов {mxid: owner} фон раз в 60 с тянет из реестра
liza-bot-api; статический hidden_users скрывает служебные аккаунты от всех.

И людей приватной компании (решение постановщика 14.10): они не находятся по
имени у тех, кто не в компании; точный MXID и телефон фильтр не видит.
Своя политика считается из single_space_guard, политики соседей — фоном
раз в 60 с по federation (_company.py, спека
docs/superpowers/specs/2026-10-14-hidden-company-members-search-design.md).
"""

import json
import logging
from typing import Any, Optional

from synapse.api.errors import AuthError, SynapseError
from synapse.logging.context import run_in_background
from synapse.module_api import ModuleApi
from twisted.web import resource, server

from ._company import (
    OPEN,
    CompanyPolicy,
    domain_of,
    is_company_instance,
    is_hidden_company_member,
    needs_membership,
)
from ._federation import FederatedUserSearchClient
from ._federation_servlet import install_servlet
from ._search import (
    MIN_FEDERATED_QUERY_LEN,
    deduplicate_users,
    matches_prefix,
)
from ._visibility import HiddenBotsCache, is_hidden, read_secret_file

logger = logging.getLogger(__name__)

_MAX_RESULTS = 50
# Как часто перечитываем набор приватных ботов: спека обещает, что смена
# видимости в BotFather доходит до поиска не дольше чем за 2 минуты.
_HIDDEN_REFRESH_MS = 60_000
# Как часто перечитываем свою и соседские политики скрытой компании: смена
# публичности компании доходит до поиска не дольше чем за минуту.
_POLICY_REFRESH_MS = 60_000


class UserSearchGuardModule:
    def __init__(self, config: dict[str, Any], api: ModuleApi) -> None:
        self._api = api
        # Корпоративный инстанс может не отдавать своих людей наружу,
        # продолжая при этом искать у других.
        self.share_users_over_federation = bool(
            config.get("share_users_over_federation", True)
        )
        self._fed_client = FederatedUserSearchClient(api._hs)

        # Служебные аккаунты (не боты), скрытые из поиска для всех, без
        # исключения для владельца — напр. @admin:bots.liza.ru.
        self.deny_list: frozenset[str] = frozenset(config.get("hidden_users") or ())
        # Приватные боты приходят из реестра liza-bot-api. Без registry_url
        # (локальный стенд) фильтр работает только по deny_list.
        self.hidden_cache: Optional[HiddenBotsCache] = None
        registry_url = (config.get("registry_url") or "").strip()
        if registry_url:
            secret = config.get("registry_secret") or ""
            secret_path = config.get("registry_secret_path")
            if not secret and secret_path:
                secret = read_secret_file(secret_path)
            self.hidden_cache = HiddenBotsCache(registry_url, secret, self._http_get_json)
            api.run_as_background_process(
                "user_search_guard_hidden_initial",
                self.hidden_cache.initial_load,
                api.sleep,
            )
            # run_on_all_instances: у prod есть generic_worker с тем же
            # конфигом модулей — его кэш тоже должен жить, иначе на воркере
            # приватные боты были бы видны всем.
            api.looping_background_call(
                self.hidden_cache.refresh,
                _HIDDEN_REFRESH_MS,
                desc="user_search_guard_hidden_refresh",
                run_on_all_instances=True,
            )

        # Скрытие людей скрытой компании выключено по умолчанию: Надежда 15.10
        # — «пока мы решили пользователей не скрывать, пока там только свои».
        # Включает только литерал true: опечатка в конфиге не прячет людей.
        # Выключенный флаг глушит и свою политику (соседи получат OPEN), и
        # чужие (_policy_for): иначе этот сервер прятал бы людей соседа, у
        # которого флаг ещё включён.
        self.hide_company_members = config.get("hide_company_members") is True
        # Класс инстанса читаем из конфига single_space_guard (не свой флаг —
        # второй источник истины), id главного пространства кэшируем навсегда,
        # как и сам single_space_guard.
        self._is_company = self.hide_company_members and is_company_instance(
            self._loaded_modules()
        )
        self._main_root_id: Optional[str] = None
        self._own_policy: Optional[CompanyPolicy] = None
        self._remote_policies: dict[str, CompanyPolicy] = {}
        api.run_as_background_process(
            "user_search_guard_policy_initial", self.refresh_policies,
        )
        api.looping_background_call(
            self.refresh_policies,
            _POLICY_REFRESH_MS,
            desc="user_search_guard_policy_refresh",
            run_on_all_instances=True,
        )

        # Штатный /user_directory/search зовёт колбэк на каждую строку выдачи
        # с MXID ищущего; True = «спам» = строка выкидывается.
        api.register_spam_checker_callbacks(
            check_username_for_spam=self.check_username_for_spam,
        )

        install_servlet(api, self)
        api.register_web_resource(
            "/_synapse/client/user_search/v1/search",
            _UserSearchResource(api, self),
        )
        logger.info(
            "UserSearchGuardModule loaded (share_over_federation=%s, registry=%s, hidden_users=%d, hide_company_members=%s, company=%s)",
            self.share_users_over_federation,
            registry_url or "-",
            len(self.deny_list),
            self.hide_company_members,
            self._is_company,
        )

    def _loaded_modules(self) -> list:
        # _hs.config — internal API; публичного пути к конфигу через ModuleApi нет.
        config = getattr(self._api._hs, "config", None)
        modules = getattr(config, "modules", None)
        return list(getattr(modules, "loaded_modules", None) or ())

    async def own_policy(self) -> CompanyPolicy:
        """Своя политика; при первом обращении считается сразу."""
        if self._own_policy is None:
            self._own_policy = await self._compute_own_policy()
        return self._own_policy

    async def _compute_own_policy(self) -> CompanyPolicy:
        if not self._is_company:
            return OPEN
        if self._main_root_id is None:
            from ..single_space_guard import SingleSpaceGuardModule

            self._main_root_id = await self._api.run_db_interaction(
                "user_search_guard_main_root",
                SingleSpaceGuardModule._find_main_root_space_txn,
            )
        if self._main_root_id is None:
            return OPEN
        # get_room -> (is_public, has_auth_chain_index) | None; тот же признак
        # приватности, что single_space_guard._own_company_entry.
        room = await self._api._store.get_room(self._main_root_id)
        if room is None or room[0]:
            return OPEN
        return CompanyPolicy(hidden=True, room_id=self._main_root_id)

    async def refresh_policies(self) -> None:
        """Пересчитать свою политику и опросить соседей.

        Ошибка не сбрасывает прошлые значения: сосед, не ответивший сейчас,
        остаётся с последней известной политикой.
        """
        try:
            self._own_policy = await self._compute_own_policy()
        except Exception as e:  # noqa: BLE001 — БД моргнула: держим прошлую
            logger.warning("user_search_guard: своя политика не пересчитана: %s", e)
        own = self._api._hs.hostname
        domains = [d for d in self._federation_whitelist() if d != own]
        fetched = await self._fed_client.fetch_policies(domains)
        self._remote_policies.update(fetched)

    def _policy_for(self, user_id: str) -> Optional[CompanyPolicy]:
        if not self.hide_company_members:
            return None
        domain = domain_of(user_id)
        if domain == self._api._hs.hostname:
            return self._own_policy
        return self._remote_policies.get(domain)

    async def _http_get_json(self, url: str, headers: dict[str, str]) -> Any:
        # SimpleHttpClient Synapse — Twisted-клиент, reactor не блокирует.
        raw_headers = {k.encode(): [v.encode()] for k, v in headers.items()}
        return await self._api.http_client.get_json(url, headers=raw_headers)

    def is_hidden(self, user_id: str, searcher: Optional[str]) -> bool:
        hidden_bots = self.hidden_cache.hidden_bots if self.hidden_cache else {}
        return is_hidden(user_id, searcher, hidden_bots, self.deny_list)

    async def is_hidden_from(
        self,
        user_id: str,
        searcher: Optional[str],
        *,
        federated: bool = False,
    ) -> bool:
        """is_hidden + скрытая компания. Порядок: hidden_users → приватный бот →
        компания; запрос к БД (кэш get_rooms_for_user) — только для людей
        скрытой компании и чужого ищущего. federated=True: для приватных ботов
        ищущий неизвестен всегда (RL-private-bots)."""
        if self.is_hidden(user_id, None if federated else searcher):
            return True
        if not self.hide_company_members:
            return False
        # Начальный пересчёт идёт фоном: до него (или после его сбоя)
        # _own_policy пуст и колбэк директории пропускал бы людей скрытой
        # компании (fail-open). Своя политика считается лениво на месте.
        if self._own_policy is None:
            await self.own_policy()
        policy = self._policy_for(user_id)
        rooms: frozenset = frozenset()
        if needs_membership(user_id, searcher, policy):
            rooms = await self._api._store.get_rooms_for_user(searcher)
        return is_hidden_company_member(user_id, searcher, policy, rooms)

    async def filter_hidden(self, users: list[dict], searcher: Optional[str]) -> list[dict]:
        out = []
        for u in users:
            if not await self.is_hidden_from(u.get("user_id", ""), searcher):
                out.append(u)
        return out

    async def check_username_for_spam(self, user_profile: dict, requester_id: str) -> bool:
        return await self.is_hidden_from(user_profile.get("user_id", ""), requester_id)

    def _federation_whitelist(self) -> list[str]:
        """Домены из federation_domain_whitelist.

        None означает «все домены разрешены» — в этом режиме веер не
        запускаем, чтобы не обходить весь интернет.
        """
        # _hs.config — internal API; публичного пути к конфигу через ModuleApi нет.
        wl = self._api._hs.config.federation.federation_domain_whitelist
        if not wl:
            return []
        return list(wl.keys())

    async def search_local_users(
        self,
        query: str,
        limit: int,
        searcher: Optional[str] = None,
        *,
        federated: bool = False,
    ) -> list[dict]:
        """Локальные пользователи этого HS, совпадающие с query по префиксу.

        Идёт мимо UserDirectoryHandler, а значит и мимо колбэка
        check_username_for_spam, — поэтому скрытых фильтруем здесь сами.
        searcher=None скрывает всех приватных ботов и людей скрытой компании.
        federated=True (ответ соседу): приватные боты считают ищущего
        неизвестным всегда, а скрытая компания пускает названного соседом
        участника — это «свои видят своих» через федерацию.
        """
        server_name = self._api._hs.hostname
        # search_user_dir требует user_id запрашивающего; для федеративного
        # вызова подставляем служебный локальный id — фильтрация по общим
        # комнатам всё равно снята через search_all_users: true.
        result = await self._api._store.search_user_dir(
            f"@user_search_guard:{server_name}", query, limit,
        )

        out: list[dict] = []
        for item in result.get("results", []):
            user_id = item.get("user_id", "")
            if not user_id.endswith(":" + server_name):
                continue
            display_name = item.get("display_name")
            if not matches_prefix(display_name, user_id, query):
                continue
            if await self.is_hidden_from(user_id, searcher, federated=federated):
                continue
            out.append({
                "user_id": user_id,
                "display_name": display_name,
                "avatar_url": item.get("avatar_url"),
                "homeserver": server_name,
            })
        return out

    async def search(self, query: str, requester_id: str) -> list[dict]:
        """Свои + федеративные результаты, дедуп по user_id."""
        query = (query or "").strip()
        if not query:
            return []

        results = await self.search_local_users(query, _MAX_RESULTS, requester_id)

        if len(query) >= MIN_FEDERATED_QUERY_LEN:
            domains = self._federation_whitelist()
            remote = await self._fed_client.search(query, domains, requester_id)
            # Сосед фильтрует свою выдачу сам, но ещё не обновлённый инстанс
            # может отдать приватного бота или человека скрытой компании —
            # добиваем своим набором.
            results.extend(await self.filter_hidden(remote, requester_id))

        return deduplicate_users(results)[:_MAX_RESULTS]


class _UserSearchResource(resource.Resource):
    """GET /_synapse/client/user_search/v1/search?query= -> {results: [...]}."""

    isLeaf = True

    def __init__(self, api: ModuleApi, module: UserSearchGuardModule) -> None:
        super().__init__()
        self._api = api
        self._module = module

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        requester = await self._api.get_user_by_req(request)  # требует валидный токен
        raw = request.args.get(b"query", [b""])[0]
        query = raw.decode("utf-8", "ignore").strip()
        results = await self._module.search(query, requester.user.to_string())
        self._json(request, {"results": results})

    def _json(self, request: server.Request, data: dict, status: int = 200) -> None:
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        request.write(json.dumps(data).encode())
        request.finish()

    def _on_errback(self, failure, request: server.Request) -> None:
        if request.finished:
            return
        ex = failure.value
        if isinstance(ex, AuthError):
            self._json(request, {"error": "unauthorized"}, 401)
        elif isinstance(ex, SynapseError):
            self._json(request, {"error": ex.errcode}, ex.code)
        else:
            logger.error("user_search_guard endpoint error: %s", failure)
            self._json(request, {"error": "internal_error"}, 500)
