"""Synapse module for user role management."""

import logging
from typing import Any

from twisted.internet import defer

from synapse.module_api import ModuleApi

from ._admin_servlets import install_admin_servlets
from ._api import (
    CatalogHandler,
    CatalogReloadHandler,
    RoleDispatcher,
    RolesBatchResource,
    RolesListHandler,
    RolesListResource,
    UserRoleHandler,
)
from ._broadcast import RoleBroadcaster
from ._catalog import RoleCatalog
from ._federation import FederationRolesClient
from ._federation_servlet import install_servlet as install_federation_servlet
from ._roles import ACCOUNT_DATA_TYPE, DEFAULT_ROLE

logger = logging.getLogger(__name__)


class UserRolesModule:
    """Synapse module that provides user role management.

    Configuration in homeserver.yaml:

        modules:
          - module: synapse_modules.user_roles.UserRolesModule
            config:
              default_role: "user"
    """

    def __init__(self, config: dict[str, Any], api: ModuleApi) -> None:
        self._api = api
        self._default_role = config.get("default_role", DEFAULT_ROLE)

        # Catalog + broadcaster + admin CRUD handler
        self._catalog = RoleCatalog.from_homeserver(api._hs)
        self._broadcaster = RoleBroadcaster(api._hs, self._catalog)
        self._handler = CatalogHandler(self._catalog, self._broadcaster)

        # Federation-проксирование ролей (Task 9): для batch с remote
        # user_ids ходим в federation к чужим HS вместо отдачи default-роли.
        self._federation_client = FederationRolesClient(
            api._hs, self._catalog
        )

        # User-role handlers (Task 7) - чистая логика, общая для legacy
        # client-эндпоинтов и admin-алиаса.
        self._user_role_handler = UserRoleHandler(
            catalog=self._catalog,
            account_data=api.account_data_manager,
            broadcaster=self._broadcaster,
            check_user_exists=api.check_user_exists,
            server_name=api._hs.hostname,
            federation=self._federation_client,
        )
        self._roles_list_handler = RolesListHandler(self._catalog)

        # Bootstrap schema lazily on the reactor; ensure_schema is idempotent
        # and module __init__ must not block, но silent-фейл означал бы, что
        # все последующие чтения/записи каталога будут падать в рантайме - логируем.
        # Дополнительно после bootstrap проверяем что default_role существует
        # в каталоге; миграция могла ещё не закончиться (особенно при первом
        # старте после деплоя), поэтому это error-лог, а не падение модуля.
        async def _bootstrap_and_validate():
            try:
                await self._catalog.ensure_schema()
                view = await self._catalog.enrich(self._default_role)
                if view is None:
                    logger.error(
                        "UserRolesModule: default_role '%s' is not in user_roles_catalog. "
                        "Add it via POST /_synapse/admin/v1/user_roles/catalog before "
                        "operations relying on the default role work correctly.",
                        self._default_role,
                    )
            except Exception as e:
                logger.error("UserRolesModule: bootstrap failed: %s", e)

        defer.ensureDeferred(_bootstrap_and_validate())

        # Register callback for new user registration
        api.register_account_validity_callbacks(
            on_user_registration=self._on_user_registration,
        )

        # Legacy client endpoints (deprecated: PUT уезжает на admin alias ниже)
        api.register_web_resource(
            "/_synapse/client/roles/v1/role",
            RoleDispatcher(
                api,
                self._user_role_handler,
                "/_synapse/client/roles/v1/role",
            ),
        )
        api.register_web_resource(
            "/_synapse/client/roles/v1/roles",
            RolesListResource(api, self._roles_list_handler),
        )
        api.register_web_resource(
            "/_synapse/client/roles/v1/batch",
            RolesBatchResource(api, self._user_role_handler),
        )

        # Reload endpoint (Task 8): подхватывает изменения, сделанные через
        # прямой SQL мимо HTTP API, и рассылает to-device по изменённым кодам.
        self._reload_handler = CatalogReloadHandler(
            self._catalog, self._broadcaster
        )

        # Admin-эндпоинты (роль + CRUD каталога + reload).
        # NB: не api.register_web_resource - /_synapse/admin это JsonResource
        # с isLeaf=True, вложенные ресурсы Twisted не обходит и отдаёт 404.
        # Регистрируем servlet-маршруты на самом admin-JsonResource; подробности
        # и ловушка - в _admin_servlets.py.
        install_admin_servlets(
            api,
            self._user_role_handler,
            self._handler,
            self._reload_handler,
        )

        # Federation endpoint: чужие HS приходят сюда за ролями наших юзеров.
        # Аутентификация - X-Matrix federation signing (без admin-токена,
        # без user access_token). Возвращает только локальных юзеров;
        # запросы по чужим user_ids молча игнорируются (анти-loop).
        # NB: не через api.register_web_resource - TransportLayerServer на
        # /_matrix/federation/* это JsonResource с isLeaf=True, дочерние
        # ресурсы там недостижимы. Регистрируемся monkey-patch'ем
        # register_servlets ДО того как Synapse создаст TransportLayerServer.
        install_federation_servlet(api, self._catalog)

        logger.info(
            "UserRolesModule loaded (default_role=%s)",
            self._default_role,
        )

    async def _on_user_registration(self, user_id: str) -> None:
        """Assign default role when a new user registers.

        Пишем оба поля: ``role`` (legacy string) и ``role_v2`` (catalog view)
        чтобы новые клиенты с v=2 сразу получили объект без дополнительного
        enrich-вызова, а старые продолжали читать строку из ``role``.
        Если catalog ещё не прогрелся (enrich вернул None), запишем только
        legacy, чтобы регистрация не падала.
        """
        try:
            content: dict = {"role": self._default_role}
            view = await self._catalog.enrich(self._default_role)
            if view is not None:
                content["role_v2"] = view
            await self._api.account_data_manager.put_global(
                user_id, ACCOUNT_DATA_TYPE, content
            )
            logger.info(
                "Assigned role %s to new user %s", self._default_role, user_id
            )
        except Exception as e:
            logger.error("Failed to assign role to %s: %s", user_id, e)
