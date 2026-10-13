"""Federation-эндпоинт поиска пользователей.

Почему не register_web_resource: ``/_matrix/federation/*`` обслуживается
``TransportLayerServer``, который наследуется от ``JsonResource`` с
``isLeaf = True``. Twisted никогда не обходит детей такого ресурса —
вызывает render() сразу, поэтому любой web-ресурс под этим префиксом
недостижим и получает 404 Unrecognized request.

Решение: регистрируем сервлет ВНУТРИ TransportLayerServer, наследуясь от
``BaseFederationServlet`` — он автоматически даёт X-Matrix auth,
federation_domain_whitelist и ratelimit. Регистрация — monkey-patch
module-level ``register_servlets``, которую TransportLayerServer.__init__
зовёт сразу после создания.

Паттерн скопирован с modules/user_roles/_federation_servlet.py.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING, Any, Optional

from synapse.federation.transport.server._base import (
    BaseFederationServlet,
)
from synapse.types import JsonDict

if TYPE_CHECKING:
    from synapse.federation.transport.server._base import Authenticator
    from synapse.http.server import HttpServer
    from synapse.module_api import ModuleApi
    from synapse.server import HomeServer
    from synapse.util.ratelimitutils import FederationRateLimiter

logger = logging.getLogger(__name__)

# Больше 50 профилей в выдаче поиска не показываем — незачем гонять по федерации.
_MAX_RESULTS = 50


class UserSearchFederationServlet(BaseFederationServlet):
    """``GET /_matrix/federation/v1/com.liza/user_search?query=...``

    Отдаёт ТОЛЬКО локальных пользователей этого homeserver-а, без
    приватных ботов и аккаунтов из hidden_users.
    X-Matrix-аутентификация, ratelimit и federation_domain_whitelist
    обеспечиваются базовым классом — до on_GET доходят только запросы с
    валидной подписью разрешённого homeserver-а.
    """

    PATH = "/com.liza/user_search"
    CATEGORY = "Liza user search"

    def __init__(self, module: Any = None, **kwargs: Any) -> None:
        super().__init__(**kwargs)
        self._module = module

    async def on_GET(
        self,
        origin: str,
        content: Optional[bytes],
        query: dict[bytes, list[bytes]],
    ) -> tuple[int, JsonDict]:
        raw = query.get(b"query", [b""])[0]
        search_term = raw.decode("utf-8", "ignore").strip()
        if not search_term:
            return 200, {"results": []}

        if self._module is None or not self._module.share_users_over_federation:
            # Инстанс закрыт: своих людей наружу не отдаём, но сами искать можем.
            return 200, {"results": []}

        try:
            # Кто ищет на той стороне, мы не знаем (origin — сервер, не
            # пользователь), поэтому searcher=None: приватные боты не уходят
            # наружу ни к кому, даже к владельцу — он найдёт бота в директории
            # своего HS через общий DM.
            results = await self._module.search_local_users(
                search_term, _MAX_RESULTS, searcher=None,
            )
        except Exception as e:  # noqa: BLE001 — федеративный запрос не должен ронять HS
            logger.warning("user_search_guard: локальный поиск для %s упал: %s", origin, e)
            return 200, {"results": []}

        return 200, {"results": results}


def install_servlet(module_api: "ModuleApi", module: Any) -> None:
    """Зарегистрировать сервлет внутри TransportLayerServer (monkey-patch).

    Идемпотентно: повторный вызов ничего не делает.

    synapse.federation.transport.server — это пакет (__init__.py), а
    register_servlets — в нём же. Импортируем модуль, чтобы patch'ить
    атрибут на самом модуле (не на копии в нашем namespace) — тот же
    приём, что и в modules/user_roles/_federation_servlet.py.
    """
    from synapse.federation.transport import server as fed_server_pkg

    if getattr(fed_server_pkg.register_servlets, "_user_search_patched", False):
        logger.debug("UserSearchFederationServlet patch already installed")
        return

    original_register = fed_server_pkg.register_servlets

    def patched_register_servlets(
        hs: "HomeServer",
        resource: "HttpServer",
        authenticator: "Authenticator",
        ratelimiter: "FederationRateLimiter",
        servlet_groups: Any = None,
    ) -> None:
        original_register(
            hs,
            resource=resource,
            authenticator=authenticator,
            ratelimiter=ratelimiter,
            servlet_groups=servlet_groups,
        )
        # На federation listener Synapse вызывает register_servlets без
        # servlet_groups; на openid listener — с servlet_groups=["openid"].
        # Свой servlet регистрируем только в полном federation-роутере,
        # чтобы не светить пользователями через openid resource.
        if servlet_groups is not None and "openid" in servlet_groups:
            return
        try:
            servlet = UserSearchFederationServlet(
                module=module,
                hs=hs,
                authenticator=authenticator,
                ratelimiter=ratelimiter,
                server_name=hs.hostname,
            )
            servlet.register(resource)
            logger.info(
                "UserSearchFederationServlet registered at %s%s",
                servlet.PREFIX,
                servlet.PATH,
            )
        except Exception as e:  # noqa: BLE001
            logger.error("user_search_guard: регистрация federation-сервлета не удалась: %s", e)

    patched_register_servlets._user_search_patched = True  # type: ignore[attr-defined]
    fed_server_pkg.register_servlets = patched_register_servlets
    logger.info("UserSearchFederationServlet patch installed")
