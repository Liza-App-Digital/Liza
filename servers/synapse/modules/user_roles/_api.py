"""Twisted web resources for user roles HTTP endpoints."""

import json
import logging
from collections.abc import Mapping
from typing import TYPE_CHECKING

from twisted.internet import defer
from twisted.web import resource, server

from synapse.api.errors import AuthError, SynapseError
from synapse.logging.context import run_in_background

if TYPE_CHECKING:
    from synapse.module_api import ModuleApi

    from ._broadcast import RoleBroadcaster
    from ._catalog import RoleCatalog

from ._roles import (
    ACCOUNT_DATA_TYPE,
    ADMIN_ROLE,
    DEFAULT_ROLE,
    EXTRA_ROLES_KEY,
    stored_extra_roles,
    with_extra_roles,
)

logger = logging.getLogger(__name__)


def _is_v2_request(request: "server.Request") -> bool:
    """Return True if the request has ``?v=2`` query argument.

    Без флага оставляем legacy-формат (голые строки) ради совместимости со
    старыми клиентами. v=2 переключает payload на объекты {code,label,color}.
    """
    try:
        return request.args.get(b"v", [b""])[0] == b"2"
    except Exception:
        return False


class _JsonResource(resource.Resource):
    """Base with JSON helpers."""

    def _json_response(self, request: server.Request, data: dict, status: int = 200) -> None:
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        # CORS на сам ответ: preflight за модуль отдаёт Synapse, а ответ пишет этот
        # голый Twisted-ресурс. Без заголовка браузер блокировал ответ — в веб-клиенте
        # (web.liza.ru) роли не грузились: не было бейджей и кнопок ботов, которые
        # рисуются только у отправителя с ролью «ИИ». Авторизация — заголовком
        # Authorization, без cookie, поэтому «*» безопасен (как у Synapse).
        request.setHeader(b"Access-Control-Allow-Origin", b"*")
        request.write(json.dumps(data).encode())
        request.finish()

    def _error(self, request: server.Request, error: str, message: str, status: int) -> None:
        self._json_response(request, {"error": error, "message": message}, status)

    def _on_errback(self, failure, request: server.Request) -> None:
        logger.error("Roles API error: %s", failure)
        if not request.finished:
            ex = failure.value
            if isinstance(ex, AuthError):
                self._error(request, "unauthorized", "Missing or invalid access token", 401)
            elif isinstance(ex, SynapseError):
                self._error(request, ex.errcode, str(ex), ex.code)
            else:
                self._error(request, "internal_error", "Internal server error", 500)

    async def _authenticate(self, request: server.Request):
        """Authenticate request, return requester."""
        return await self._module_api.get_user_by_req(request)

    async def _require_admin(self, request: server.Request) -> str:
        """Authenticate and require admin. Returns user_id."""
        requester = await self._authenticate(request)
        user_id = requester.user.to_string()
        is_admin = await self._module_api.is_user_admin(user_id)
        if not is_admin:
            raise PermissionError("Admin access required")
        return user_id

    def _read_body(self, request: server.Request) -> dict:
        request.content.seek(0)
        body = request.content.read()
        if not body:
            return {}
        return json.loads(body)


class UserRoleHandler:
    """Pure logic for GET/PUT role, batch.

    HTTP-обвязка (Twisted Resource) делегирует сюда; этот класс не знает про
    request/response и тестируется fake-зависимостями.
    """

    def __init__(
        self,
        *,
        catalog: "RoleCatalog",
        account_data,
        broadcaster: "RoleBroadcaster",
        check_user_exists,
        server_name: str | None = None,
        federation=None,
    ) -> None:
        self._catalog = catalog
        self._account_data = account_data
        self._broadcaster = broadcaster
        self._check_user_exists = check_user_exists
        # server_name + federation - опциональны для backwards-compat с
        # тестами, которые конструируют handler без них (только локальные
        # юзеры). В проде оба значения передаются из __init__.py модуля.
        self._server_name = server_name
        self._federation = federation

    async def get(self, user_id: str, *, v2: bool) -> tuple[int, dict]:
        exists = await self._check_user_exists(user_id)
        if not exists:
            return 404, {"error": "not_found", "message": "User not found"}

        data = await self._account_data.get_global(user_id, ACCOUNT_DATA_TYPE)
        # Synapse's AccountDataManager.get_global returns immutabledict, not
        # plain dict - check Mapping protocol instead.
        role_code = (
            data.get("role") if isinstance(data, Mapping) else None
        ) or DEFAULT_ROLE

        if v2:
            # Каталог - source of truth; игнорируем stored role_v2, чтобы GET
            # отдавал актуальный label/color, даже если admin поменял каталог
            # уже после записи в account_data.
            view = await self._catalog.enrich(role_code)
            view = with_extra_roles(view, stored_extra_roles(data))
            return 200, {"user_id": user_id, "role": view}
        return 200, {"user_id": user_id, "role": role_code}

    async def set(self, target_user_id: str, body: dict) -> tuple[int, dict]:
        new_role = body.get("role")
        if not isinstance(new_role, str) or not new_role:
            return 400, {
                "error": "bad_request",
                "message": "role must be a non-empty string",
            }

        exists = await self._check_user_exists(target_user_id)
        if not exists:
            return 404, {"error": "not_found", "message": "User not found"}

        view = await self._catalog.enrich(new_role)
        if view is None:
            return 404, {
                "error": "not_found",
                "message": f"Role '{new_role}' not found in catalog",
            }

        # Ключа нет в теле — доп. роли сохраняются, только пока основная роль та
        # же. Смена основной роли без ключа их снимает: liza-roles и liza-bot-api
        # шлют только {"role"}, и понижение до user не должно оставлять
        # «висящий» developer. [] — снять все.
        if EXTRA_ROLES_KEY in body:
            raw_extras = body[EXTRA_ROLES_KEY]
            if not isinstance(raw_extras, list) or not all(
                isinstance(r, str) and r for r in raw_extras
            ):
                return 400, {
                    "error": "bad_request",
                    "message": "extra_roles must be a list of non-empty strings",
                }
            # Серверные гейты (channel_guard, access_admin) читают только
            # основную роль: admin доп. ролью дал бы в клиенте кнопки, на
            # которые сервер отвечает 403.
            if ADMIN_ROLE in raw_extras:
                return 400, {
                    "error": "bad_request",
                    "message": "admin can only be the main role",
                }
            for code in raw_extras:
                if await self._catalog.enrich(code) is None:
                    return 404, {
                        "error": "not_found",
                        "message": f"Role '{code}' not found in catalog",
                    }
        else:
            stored = await self._account_data.get_global(
                target_user_id, ACCOUNT_DATA_TYPE
            )
            old_role = stored.get("role") if isinstance(stored, Mapping) else None
            raw_extras = stored_extra_roles(stored)
            if raw_extras and old_role != new_role:
                logger.info(
                    "Extra roles dropped on main role change: %s %s -> %s (extra=%s)",
                    target_user_id,
                    old_role,
                    new_role,
                    raw_extras,
                )
                raw_extras = []
        extras = [r for r in dict.fromkeys(raw_extras) if r != new_role]

        view = with_extra_roles(view, extras)
        content: dict = {"role": new_role, "role_v2": view}
        if extras:
            content[EXTRA_ROLES_KEY] = extras
        await self._account_data.put_global(
            target_user_id, ACCOUNT_DATA_TYPE, content
        )

        # Broadcast async; failure must not block request - админ увидит 200,
        # клиенты потом подберут изменение через next /role вызов.
        try:
            await self._broadcaster.broadcast_role_change(target_user_id)
        except Exception:
            logger.exception(
                "broadcast_role_change failed for %s", target_user_id
            )

        logger.info(
            "Role updated: %s -> %s (extra=%s)", target_user_id, new_role, extras
        )
        return 200, {
            "user_id": target_user_id,
            "role": view,
            "updated": True,
        }

    async def batch(
        self, user_ids: list[str], *, v2: bool
    ) -> tuple[int, dict]:
        # Разделяем на локальные/удалённые по domain, чтобы для federated
        # юзеров не возвращать default-роль с потолка (account_data чужого
        # юзера хранится только на его HS). Если server_name не задан -
        # считаем всех локальными (backwards-compat со старыми тестами).
        local_ids: list[str] = []
        remote_ids: list[str] = []
        for uid in user_ids:
            if not isinstance(uid, str):
                continue
            if self._server_name and ":" in uid:
                domain = uid.split(":", 1)[1]
                if domain != self._server_name:
                    remote_ids.append(uid)
                    continue
            local_ids.append(uid)

        roles: dict[str, object] = {}

        for uid in local_ids:
            try:
                data = await self._account_data.get_global(uid, ACCOUNT_DATA_TYPE)
            except Exception:
                data = None
            # See note in get(): get_global returns immutabledict.
            role_code = (
                data.get("role") if isinstance(data, Mapping) else None
            ) or DEFAULT_ROLE
            if v2:
                roles[uid] = with_extra_roles(
                    await self._catalog.enrich(role_code),
                    stored_extra_roles(data),
                )
            else:
                roles[uid] = role_code

        if remote_ids:
            if v2 and self._federation is not None:
                remote_roles = await self._federation.fetch_roles(remote_ids)
                for uid in remote_ids:
                    # Может быть RoleView dict или None (federation timeout,
                    # юзер не найден на remote, etc.).
                    roles[uid] = remote_roles.get(uid)
            else:
                # v1 (legacy): клиент ждёт строку, не объект. Возвращаем
                # DEFAULT_ROLE как было раньше, чтобы старые клиенты не
                # падали. v2 без federation client - возвращаем None.
                for uid in remote_ids:
                    roles[uid] = None if v2 else DEFAULT_ROLE

        return 200, {"roles": roles}


class RolesListHandler:
    """Pure logic for GET /roles."""

    def __init__(self, catalog: "RoleCatalog") -> None:
        self._catalog = catalog

    async def list(self, *, v2: bool) -> tuple[int, dict]:
        rows = await self._catalog.list_all()
        if v2:
            payload = [
                {
                    "code": r["code"],
                    "label": r["display_name"],
                    "color": r["color"],
                }
                for r in rows
            ]
        else:
            payload = [r["code"] for r in rows]
        return 200, {"roles": payload}


class RolesListResource(_JsonResource):
    """GET /_synapse/client/roles/v1/roles"""

    isLeaf = True

    def __init__(
        self, module_api: "ModuleApi", handler: "RolesListHandler"
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        await self._authenticate(request)
        status, payload = await self._handler.list(v2=_is_v2_request(request))
        self._json_response(request, payload, status)


class MyRoleResource(_JsonResource):
    """GET /_synapse/client/roles/v1/role"""

    isLeaf = True

    def __init__(
        self, module_api: "ModuleApi", handler: "UserRoleHandler"
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        requester = await self._authenticate(request)
        user_id = requester.user.to_string()
        status, payload = await self._handler.get(
            user_id, v2=_is_v2_request(request)
        )
        self._json_response(request, payload, status)


class UserRoleResource(_JsonResource):
    """GET/PUT /<prefix>/<user_id>

    Используется и как client-endpoint (legacy alias), и как admin-endpoint;
    префикс пути берётся из параметра ``path_prefix``.
    """

    isLeaf = True

    def __init__(
        self,
        module_api: "ModuleApi",
        handler: "UserRoleHandler",
        path_prefix: str,
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler
        # prefix должен заканчиваться на '/', чтобы _extract_user_id корректно
        # отрезал префикс. Принимаем оба варианта от вызывающего.
        if not path_prefix.endswith("/"):
            path_prefix = path_prefix + "/"
        self._path_prefix = path_prefix

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    def render_PUT(self, request: server.Request) -> int:
        d = run_in_background(self._handle_put, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    def _extract_user_id(self, request: server.Request) -> str:
        path = (
            request.path.decode()
            if isinstance(request.path, bytes)
            else request.path
        )
        if path.startswith(self._path_prefix) and len(path) > len(
            self._path_prefix
        ):
            return path[len(self._path_prefix):]
        raise ValueError("Missing user_id in path")

    async def _handle_get(self, request: server.Request) -> None:
        try:
            await self._authenticate(request)
        except Exception:
            self._error(request, "unauthorized", "Authentication required", 401)
            return

        try:
            target_user_id = self._extract_user_id(request)
        except ValueError:
            self._error(request, "bad_request", "Missing user_id in path", 400)
            return

        status, payload = await self._handler.get(
            target_user_id, v2=_is_v2_request(request)
        )
        self._json_response(request, payload, status)

    async def _handle_put(self, request: server.Request) -> None:
        try:
            await self._require_admin(request)
        except PermissionError:
            self._error(request, "forbidden", "Admin access required", 403)
            return

        try:
            target_user_id = self._extract_user_id(request)
        except ValueError:
            self._error(request, "bad_request", "Missing user_id in path", 400)
            return

        try:
            body = self._read_body(request)
        except (json.JSONDecodeError, Exception):
            self._error(request, "bad_request", "Invalid JSON body", 400)
            return

        status, payload = await self._handler.set(target_user_id, body)
        self._json_response(request, payload, status)


class RolesBatchResource(_JsonResource):
    """POST /_synapse/client/roles/v1/roles/batch"""

    isLeaf = True
    _MAX_BATCH = 100

    def __init__(
        self, module_api: "ModuleApi", handler: "UserRoleHandler"
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler

    def render_POST(self, request: server.Request) -> int:
        d = run_in_background(self._handle_post, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_post(self, request: server.Request) -> None:
        await self._authenticate(request)

        try:
            body = self._read_body(request)
        except Exception:
            self._error(request, "bad_request", "Invalid JSON body", 400)
            return

        user_ids = body.get("user_ids")
        if not isinstance(user_ids, list) or not user_ids:
            self._error(
                request, "bad_request", "user_ids must be a non-empty list", 400
            )
            return

        if len(user_ids) > self._MAX_BATCH:
            self._error(
                request,
                "bad_request",
                f"Maximum {self._MAX_BATCH} user_ids per request",
                400,
            )
            return

        status, payload = await self._handler.batch(
            user_ids, v2=_is_v2_request(request)
        )
        self._json_response(request, payload, status)


class RoleDispatcher(resource.Resource):
    """Dispatcher for /<prefix>/role -> {MyRoleResource, UserRoleResource}.

    Twisted без trailing-slash отдаёт getChild с пустым path для самого
    префикса; с подпутём - getChild с user_id. MyRoleResource обрабатывает
    первый случай (GET текущего юзера), UserRoleResource - второй
    (GET/PUT по чужому user_id).
    """

    def __init__(
        self,
        module_api: "ModuleApi",
        handler: "UserRoleHandler",
        path_prefix: str,
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._my_role = MyRoleResource(module_api, handler)
        self._user_role = UserRoleResource(module_api, handler, path_prefix)

    def getChild(
        self, path: bytes, request: server.Request
    ) -> resource.Resource:
        if not path or path == b"":
            return self._my_role
        return self._user_role

    def render_GET(self, request: server.Request) -> int:
        return self._my_role.render_GET(request)


class CatalogHandler:
    """Pure business logic for catalog admin endpoints. Tested standalone."""

    def __init__(self, catalog: "RoleCatalog", broadcaster: "RoleBroadcaster") -> None:
        self._catalog = catalog
        self._broadcaster = broadcaster

    async def create(self, body: dict) -> tuple[int, dict]:
        code = body.get("code")
        display_name = body.get("display_name")
        color = body.get("color")  # absent or None - both treated as "no color"

        if not self._catalog.is_valid_code(code):
            return 400, {
                "error": "bad_request",
                "message": "Invalid code (lowercase a-z, 0-9, _, 1-64 chars)",
            }
        if not isinstance(display_name, str) or not display_name.strip():
            return 400, {
                "error": "bad_request",
                "message": "display_name is required",
            }
        if not self._catalog.is_valid_color(color):
            return 400, {
                "error": "bad_request",
                "message": "Invalid color (must be #RRGGBB)",
            }

        if await self._catalog.enrich(code) is not None:
            return 409, {"error": "conflict", "message": "Role code already exists"}

        try:
            await self._catalog.add(code, display_name.strip(), color)
        except Exception as e:
            logger.error("Catalog add failed: %s", e)
            return 500, {
                "error": "internal_error",
                "message": "Failed to add role",
            }

        view = await self._catalog.enrich(code)
        return 201, view

    async def update(self, code: str, body: dict) -> tuple[int, dict]:
        display_name = body.get("display_name")
        if display_name is not None:
            if not isinstance(display_name, str) or not display_name.strip():
                return 400, {
                    "error": "bad_request",
                    "message": "display_name cannot be empty",
                }
            display_name = display_name.strip()

        clear_color = "color" in body and body["color"] is None
        color = body.get("color") if not clear_color else None
        if color is not None and not self._catalog.is_valid_color(color):
            return 400, {"error": "bad_request", "message": "Invalid color"}

        updated = await self._catalog.patch(
            code,
            display_name=display_name,
            color=color,
            clear_color=clear_color,
        )
        if not updated:
            return 404, {"error": "not_found", "message": "Role not found"}

        # Broadcast asynchronously; surface error in logs but don't fail the request
        try:
            await self._broadcaster.broadcast_catalog_patch(code)
        except Exception:
            logger.exception("broadcast_catalog_patch failed for %s", code)

        view = await self._catalog.enrich(code)
        return 200, view

    async def remove(self, code: str) -> tuple[int, dict]:
        bearers = await self._catalog.users_with_role(code)
        if bearers:
            return 409, {
                "error": "conflict",
                "message": (
                    f"Cannot delete role: {len(bearers)} user(s) still have it"
                ),
            }
        deleted = await self._catalog.delete(code)
        if not deleted:
            return 404, {"error": "not_found", "message": "Role not found"}
        return 204, {}


class CatalogResource(_JsonResource):
    """POST /_synapse/admin/v1/user_roles/catalog
    PATCH/DELETE /_synapse/admin/v1/user_roles/catalog/<code>
    """

    isLeaf = True

    def __init__(self, module_api: "ModuleApi", handler: "CatalogHandler") -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler

    def render_POST(self, request: server.Request) -> int:
        d = run_in_background(self._handle_post, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    def render_PATCH(self, request: server.Request) -> int:
        d = run_in_background(self._handle_patch, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    def render_DELETE(self, request: server.Request) -> int:
        d = run_in_background(self._handle_delete, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    def _code_from_path(self, request: server.Request) -> str | None:
        from urllib.parse import unquote

        path = request.path.decode() if isinstance(request.path, bytes) else request.path
        prefix = "/_synapse/admin/v1/user_roles/catalog/"
        if path.startswith(prefix) and len(path) > len(prefix):
            return unquote(path[len(prefix):])
        return None

    async def _handle_post(self, request: server.Request) -> None:
        try:
            await self._require_admin(request)
        except PermissionError:
            self._error(request, "forbidden", "Admin access required", 403)
            return
        try:
            body = self._read_body(request)
        except Exception:
            self._error(request, "bad_request", "Invalid JSON body", 400)
            return
        status, payload = await self._handler.create(body)
        self._json_response(request, payload, status)

    async def _handle_patch(self, request: server.Request) -> None:
        try:
            await self._require_admin(request)
        except PermissionError:
            self._error(request, "forbidden", "Admin access required", 403)
            return
        code = self._code_from_path(request)
        if code is None:
            self._error(request, "bad_request", "Missing code in path", 400)
            return
        try:
            body = self._read_body(request)
        except Exception:
            self._error(request, "bad_request", "Invalid JSON body", 400)
            return
        status, payload = await self._handler.update(code, body)
        self._json_response(request, payload, status)

    async def _handle_delete(self, request: server.Request) -> None:
        try:
            await self._require_admin(request)
        except PermissionError:
            self._error(request, "forbidden", "Admin access required", 403)
            return
        code = self._code_from_path(request)
        if code is None:
            self._error(request, "bad_request", "Missing code in path", 400)
            return
        status, payload = await self._handler.remove(code)
        if status == 204:
            request.setResponseCode(204)
            # Тот же CORS, что в _json_response: тело пустое, но без заголовка браузер
            # не отдаст веб-клиенту и статус успешного DELETE.
            request.setHeader(b"Access-Control-Allow-Origin", b"*")
            request.finish()
        else:
            self._json_response(request, payload, status)


class CatalogReloadHandler:
    """Force a catalog cache reload, broadcasting changed rows.

    Сценарий: админ вставил/обновил роль через ``psql -c "INSERT ..."`` мимо
    HTTP API; Synapse'овый кэш про это не знает. Этот эндпоинт делает diff
    "до/после" reload и рассылает to-device только по реально изменившимся
    кодам (новые + изменённые), чтобы не флудить клиентов лишним патчем.

    Удалённые коды в ``changed`` не попадают: broadcast по исчезнувшей роли
    бессмысленен, клиенты подберут актуальный список при следующем
    ``GET /roles``.
    """

    def __init__(
        self, catalog: "RoleCatalog", broadcaster: "RoleBroadcaster"
    ) -> None:
        self._catalog = catalog
        self._broadcaster = broadcaster

    async def reload(self) -> tuple[int, dict]:
        before = self._catalog.snapshot()
        await self._catalog.reload()
        after = self._catalog.snapshot()

        changed: list[str] = []
        for code, row in after.items():
            if before.get(code) != row:
                changed.append(code)

        for code in changed:
            try:
                await self._broadcaster.broadcast_catalog_patch(code)
            except Exception:
                logger.exception("broadcast_catalog_patch failed for %s", code)

        return 200, {
            "reloaded": True,
            "count": len(after),
            "changed": changed,
        }


class CatalogReloadResource(_JsonResource):
    """POST /_synapse/admin/v1/user_roles/catalog/reload"""

    isLeaf = True

    def __init__(
        self, module_api: "ModuleApi", handler: "CatalogReloadHandler"
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._handler = handler

    def render_POST(self, request: server.Request) -> int:
        d = run_in_background(self._handle_post, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_post(self, request: server.Request) -> None:
        try:
            await self._require_admin(request)
        except PermissionError:
            self._error(request, "forbidden", "Admin access required", 403)
            return
        status, payload = await self._handler.reload()
        self._json_response(request, payload, status)


class CatalogCollectionDispatcher(resource.Resource):
    """Routes /catalog (POST) vs /catalog/<code> (PATCH/DELETE).

    Twisted's leaf-resource model means a single CatalogResource handles
    both the collection (no path segments after `catalog`) and the items
    (`catalog/<code>`); the dispatcher just makes sure either form is
    routed there.
    """

    def __init__(self, module_api: "ModuleApi", handler: "CatalogHandler") -> None:
        super().__init__()
        self._resource = CatalogResource(module_api, handler)

    def getChild(self, path: bytes, request: server.Request) -> resource.Resource:
        return self._resource

    def render_POST(self, request: server.Request) -> int:
        return self._resource.render_POST(request)
