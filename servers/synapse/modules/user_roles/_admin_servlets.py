"""Admin-эндпоинты модуля ролей: servlet-маршруты на admin-JsonResource.

Почему не ``ModuleApi.register_web_resource``
=============================================

``/_synapse/admin`` — это ``JsonResource`` с ``isLeaf = True``
(``synapse/http/server.py``). ``create_resource_tree`` цепляет ресурсы модуля
детями этого листа, но Twisted не обходит детей листа: запрос сразу уходит в
``render`` админского ``JsonResource``, и вложенный ресурс недостижим. В итоге
``PUT /_synapse/admin/v1/user_roles/role/<uid>`` и весь CRUD каталога молча
отдавали 404 ``M_UNRECOGNIZED``, хотя клиентский deprecated-алиас
``/_synapse/client/roles/v1/role/<uid>`` работал.

Поэтому админ-маршруты регистрируются как servlet'ы **на самом**
admin-JsonResource через ``register_paths`` (его ``render`` матчит полный
``request.path``). Это тот же приём, которым модуль уже обходит такую же
ловушку для federation-сервлета (``_federation_servlet.py``), только здесь
патчится ``synapse.rest.admin.register_servlets``.

Не возвращайте ``register_web_resource`` для путей под ``/_synapse/admin/``:
они снова станут недостижимыми.
"""

from __future__ import annotations

import logging
import re
from typing import TYPE_CHECKING

from ._api import CatalogReloadResource, CatalogResource, RoleDispatcher

if TYPE_CHECKING:
    from synapse.http.server import HttpServer
    from synapse.module_api import ModuleApi

    from ._api import CatalogHandler, CatalogReloadHandler, UserRoleHandler

logger = logging.getLogger(__name__)

_ADMIN_PREFIX = "/_synapse/admin/v1/user_roles"
_ROLE_PREFIX = f"{_ADMIN_PREFIX}/role"
_CATALOG_PREFIX = f"{_ADMIN_PREFIX}/catalog"

# Паттерны якорим на весь путь: admin-JsonResource матчит request.path целиком.
_ROLE_SELF = re.compile(rf"^{re.escape(_ROLE_PREFIX)}$")
_ROLE_ITEM = re.compile(rf"^{re.escape(_ROLE_PREFIX)}/(?P<user_id>[^/]+)$")
_CATALOG = re.compile(rf"^{re.escape(_CATALOG_PREFIX)}$")
# reload — отдельный POST-маршрут; исключаем его из generic-паттерна,
# иначе JsonResource на POST /catalog/reload увидит совпадение item-паттерна
# без POST-обработчика и вернёт 405, не дойдя до reload-маршрута.
_CATALOG_ITEM = re.compile(
    rf"^{re.escape(_CATALOG_PREFIX)}/(?P<code>(?!reload$)[^/]+)$"
)
_CATALOG_RELOAD = re.compile(rf"^{re.escape(_CATALOG_PREFIX)}/reload$")


def _delegate(render):
    """Адаптер Resource.render_* -> servlet-callback JsonResource.

    Внутренние ресурсы модуля сами пишут ответ (``_json_response`` /
    ``_error``) и возвращают ``NOT_DONE_YET``; servlet'у достаточно вернуть
    ``None``, чтобы admin-JsonResource не пытался отправить ответ повторно.
    """

    async def callback(request, **_kwargs):
        render(request)
        return None

    return callback


def register_admin_routes(
    http_server: "HttpServer",
    module_api: "ModuleApi",
    handler: "UserRoleHandler",
    catalog_handler: "CatalogHandler",
    reload_handler: "CatalogReloadHandler",
) -> None:
    """Зарегистрировать админ-маршруты на admin-JsonResource.

    Идемпотентно: повторный вызов на том же ``http_server`` ничего не делает.
    """

    if getattr(http_server, "_user_roles_admin_routes_registered", False):
        return

    role = RoleDispatcher(module_api, handler, _ROLE_PREFIX)
    catalog = CatalogResource(module_api, catalog_handler)
    reload_resource = CatalogReloadResource(module_api, reload_handler)

    routes = (
        # GET своей роли по admin-пути (раньше был только client-алиас).
        ("GET", _ROLE_SELF, role.render_GET, "UserRolesAdminMyRoleServlet"),
        # GET/PUT роли произвольного юзера.
        ("GET", _ROLE_ITEM, role._user_role.render_GET, "UserRolesAdminRoleServlet"),
        ("PUT", _ROLE_ITEM, role._user_role.render_PUT, "UserRolesAdminRoleServlet"),
        # Каталог: создание, reload и правка/удаление кода. Reload — ДО
        # generic item-паттерна: JsonResource на первом совпавшем паттерне без
        # метода отдаёт 405 и до следующего маршрута не доходит.
        ("POST", _CATALOG, catalog.render_POST, "UserRolesAdminCatalogServlet"),
        ("POST", _CATALOG_RELOAD, reload_resource.render_POST, "UserRolesAdminCatalogReloadServlet"),
        ("PATCH", _CATALOG_ITEM, catalog.render_PATCH, "UserRolesAdminCatalogServlet"),
        ("DELETE", _CATALOG_ITEM, catalog.render_DELETE, "UserRolesAdminCatalogServlet"),
    )

    for method, pattern, render, servlet_classname in routes:
        http_server.register_paths(
            method, [pattern], _delegate(render), servlet_classname
        )

    http_server._user_roles_admin_routes_registered = True
    logger.info(
        "user_roles: admin-маршруты зарегистрированы на %s (%d)",
        type(http_server).__name__,
        len(routes),
    )


def _register_for_hs(hs, http_server: "HttpServer", deps: tuple) -> None:
    """Зарегистрировать маршруты только на main-процессе.

    На воркерах admin-API Synapse почти не регистрируется, и наши маршруты там
    не нужны: запись ролей/каталога должна идти через main.
    """

    worker_app = getattr(getattr(hs.config, "worker", None), "worker_app", None)
    if worker_app is not None:
        return
    register_admin_routes(http_server, *deps)


# id(HomeServer) -> (module_api, handler, catalog_handler, reload_handler).
# Модуль инстанцируется на каждый HomeServer в процессе (в проде — один).
_ADMIN_DEPS: dict[int, tuple] = {}


def install_admin_servlets(
    module_api: "ModuleApi",
    handler: "UserRoleHandler",
    catalog_handler: "CatalogHandler",
    reload_handler: "CatalogReloadHandler",
) -> None:
    """Подменить ``synapse.rest.admin.register_servlets`` и добавить наши пути.

    ``HomeServer._configure_named_resource`` создаёт admin-JsonResource и зовёт
    ``admin.register_servlets(hs, admin_resource)`` уже после загрузки модулей,
    поэтому патч успевает встать. Original вызывается первым: стандартные
    admin-ручки не меняются, наши маршруты добавляются следом.
    """

    from synapse.rest import admin as admin_rest

    hs = module_api._hs
    _ADMIN_DEPS[id(hs)] = (module_api, handler, catalog_handler, reload_handler)

    original = admin_rest.register_servlets
    if getattr(original, "_user_roles_admin_patched", False):
        return

    def patched(hs, http_server):
        original(hs, http_server)
        deps = _ADMIN_DEPS.get(id(hs))
        if deps is None:
            return
        _register_for_hs(hs, http_server, deps)

    patched._user_roles_admin_patched = True  # type: ignore[attr-defined]
    admin_rest.register_servlets = patched
    logger.info("user_roles: admin-register_servlets patch installed")
