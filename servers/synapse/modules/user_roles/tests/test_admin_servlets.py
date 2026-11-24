# ledger:RL-user-roles-admin-route-reachable
# AC:RL-user-roles-admin-route-reachable/1 AC:RL-user-roles-admin-route-reachable/2
"""Admin-маршруты user_roles должны регистрироваться на admin-JsonResource.

Регресс: пути ``/_synapse/admin/v1/user_roles/*`` регистрировались через
``ModuleApi.register_web_resource`` и были недостижимы — ``/_synapse/admin``
это ``JsonResource`` с ``isLeaf = True``, Twisted не обходит его детей и отдаёт
404 ``M_UNRECOGNIZED``. Тест фиксирует servlet-регистрацию на самом
admin-JsonResource (и что на воркерах её нет).
"""

from __future__ import annotations

import asyncio
import re
import unittest
from types import SimpleNamespace
from unittest import mock

from synapse_modules.user_roles._admin_servlets import (
    _delegate,
    _register_for_hs,
    install_admin_servlets,
    register_admin_routes,
)

_ADMIN_PREFIX = "/_synapse/admin/v1/user_roles"


def _deps():
    # Конструкторы ресурсов только сохраняют зависимости; поведение не нужно.
    return (SimpleNamespace(), object(), object(), object())


class _FakeHttpServer:
    def __init__(self) -> None:
        self.calls: list[tuple[str, str, object, str]] = []

    def register_paths(self, method, path_patterns, callback, servlet_classname):
        self.calls.append(
            (method, path_patterns[0].pattern, callback, servlet_classname)
        )


class _FakeHs:
    def __init__(self, worker_app=None) -> None:
        self.config = SimpleNamespace(
            worker=SimpleNamespace(worker_app=worker_app)
        )


class AdminRouteRegistrationTests(unittest.TestCase):
    def test_routes_cover_role_catalog_and_reload(self) -> None:
        """AC-1: все админ-ручки снова зарегистрированы (ровно 7 маршрутов)."""
        server = _FakeHttpServer()
        register_admin_routes(server, *_deps())

        got = {(method, pattern) for method, pattern, _, _ in server.calls}
        expected = {
            ("GET", rf"^{_ADMIN_PREFIX}/role$"),
            ("GET", rf"^{_ADMIN_PREFIX}/role/(?P<user_id>[^/]+)$"),
            ("PUT", rf"^{_ADMIN_PREFIX}/role/(?P<user_id>[^/]+)$"),
            ("POST", rf"^{_ADMIN_PREFIX}/catalog$"),
            ("PATCH", rf"^{_ADMIN_PREFIX}/catalog/(?P<code>(?!reload$)[^/]+)$"),
            ("DELETE", rf"^{_ADMIN_PREFIX}/catalog/(?P<code>(?!reload$)[^/]+)$"),
            ("POST", rf"^{_ADMIN_PREFIX}/catalog/reload$"),
        }
        # AC:RL-user-roles-admin-route-reachable/1
        self.assertEqual(got, expected)

    def test_catalog_item_pattern_does_not_swallow_reload(self) -> None:
        """POST /catalog/reload не должен ловиться generic-паттерном каталога.

        JsonResource на первом совпавшем паттерне без метода отдаёт 405 и до
        reload-маршрута не доходит — это был реальный баг после первой версии
        регистрации.
        """
        server = _FakeHttpServer()
        register_admin_routes(server, *_deps())
        item_pattern = next(
            pattern for method, pattern, _, _ in server.calls if method == "PATCH"
        )
        reload_pattern = next(
            pattern
            for method, pattern, _, _ in server.calls
            if method == "POST" and pattern.endswith("/catalog/reload$")
        )
        reload_path = f"{_ADMIN_PREFIX}/catalog/reload"
        # AC:RL-user-roles-admin-route-reachable/4
        self.assertIsNone(re.fullmatch(item_pattern, reload_path))
        self.assertIsNotNone(re.fullmatch(reload_pattern, reload_path))

    def test_registration_is_idempotent(self) -> None:
        """Повторный вызов на том же JsonResource не плодит дубли."""
        server = _FakeHttpServer()
        register_admin_routes(server, *_deps())
        register_admin_routes(server, *_deps())
        self.assertEqual(len(server.calls), 7)

    def test_delegate_calls_inner_render_and_returns_none(self) -> None:
        """AC-2: servlet-callback отдаёт ответ внутренним ресурсом, не дублируя."""
        seen = []

        def render(request):
            seen.append(request)
            return 0  # NOT_DONE_YET в реальном ресурсе, значение не важно

        request = object()
        result = asyncio.run(_delegate(render)(request))
        # AC:RL-user-roles-admin-route-reachable/2
        self.assertIsNone(result)
        self.assertEqual(seen, [request])

    def test_worker_does_not_register_admin_routes(self) -> None:
        """На воркерах admin-API не поднимаем — запись идёт через main."""
        main_server = _FakeHttpServer()
        _register_for_hs(_FakeHs(worker_app=None), main_server, _deps())
        self.assertEqual(len(main_server.calls), 7)

        worker_server = _FakeHttpServer()
        _register_for_hs(
            _FakeHs(worker_app="synapse.app.generic_worker"),
            worker_server,
            _deps(),
        )
        self.assertEqual(worker_server.calls, [])


class InstallAdminServletsTests(unittest.TestCase):
    def test_patch_registers_routes_after_original(self) -> None:
        """``admin.register_servlets`` вызывает original, затем наши маршруты."""
        hs = _FakeHs(worker_app=None)
        api = SimpleNamespace(_hs=hs)
        original_calls = []

        def original(fake_hs, http_server):
            original_calls.append((fake_hs, http_server))

        from synapse.rest import admin as admin_rest

        with mock.patch.object(admin_rest, "register_servlets", original):
            install_admin_servlets(api, object(), object(), object())
            server = _FakeHttpServer()
            admin_rest.register_servlets(hs, server)

        # AC:RL-user-roles-admin-route-reachable/2
        self.assertEqual(original_calls, [(hs, server)])
        self.assertEqual(len(server.calls), 7)


if __name__ == "__main__":
    unittest.main()
