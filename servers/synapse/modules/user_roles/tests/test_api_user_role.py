"""Unit tests for UserRoleHandler and RolesListHandler logic."""

import asyncio
import unittest

from synapse_modules.user_roles._api import RolesListHandler, UserRoleHandler


def _run(coro):
    return asyncio.run(coro)


class _FakeCatalog:
    def __init__(self):
        self.rows = {
            "user": {"code": "user", "label": "Пользователь", "color": None},
            "ai": {"code": "ai", "label": "ИИ", "color": "#4CAF50"},
            "developer": {"code": "developer", "label": "Разработчик", "color": None},
        }

    async def enrich(self, code):
        return self.rows.get(code)

    async def list_all(self):
        return [
            {"code": r["code"], "display_name": r["label"], "color": r["color"]}
            for r in self.rows.values()
        ]


class _FakeAccountDataManager:
    """Returns content as immutabledict, matching real Synapse.

    Synapse's ``module_api.account_data_manager.get_global`` wraps the result
    through ``synapse.util.frozenutils.freeze``, which returns ``immutabledict``.
    A plain ``isinstance(data, dict)`` check returns False for immutabledict -
    we had that bug in production before this fixture was tightened. Tests now
    use the same type to keep production semantics in sync with the suite.
    """

    def __init__(self):
        # user_id -> {type: content}
        self._store: dict[str, dict[str, dict]] = {}

    async def get_global(self, user_id: str, type_: str):
        from immutabledict import immutabledict

        raw = self._store.get(user_id, {}).get(type_)
        return None if raw is None else immutabledict(raw)

    async def put_global(self, user_id: str, type_: str, content: dict):
        self._store.setdefault(user_id, {})[type_] = content


class _FakeBroadcaster:
    def __init__(self):
        self.role_changes: list[str] = []

    async def broadcast_role_change(self, user_id: str):
        self.role_changes.append(user_id)


class _FakeUserExistence:
    """Stand-in for module_api.check_user_exists."""

    def __init__(self, existing: set[str]):
        self.existing = existing

    async def __call__(self, user_id: str) -> str | None:
        return user_id if user_id in self.existing else None


# --- UserRoleHandler.get -----------------------------------------------------


class UserRoleGetTestCase(unittest.TestCase):
    def setUp(self):
        self.catalog = _FakeCatalog()
        self.adm = _FakeAccountDataManager()
        self.broadcaster = _FakeBroadcaster()
        self.handler = UserRoleHandler(
            catalog=self.catalog,
            account_data=self.adm,
            broadcaster=self.broadcaster,
            check_user_exists=_FakeUserExistence({"@alice:test"}),
        )

    def test_get_v1_returns_legacy_string(self):
        # No account_data -> default "user"
        status, body = _run(self.handler.get("@alice:test", v2=False))
        self.assertEqual(status, 200)
        self.assertEqual(body, {"user_id": "@alice:test", "role": "user"})

    def test_get_v2_returns_object(self):
        status, body = _run(self.handler.get("@alice:test", v2=True))
        self.assertEqual(status, 200)
        self.assertEqual(
            body["role"], {"code": "user", "label": "Пользователь", "color": None}
        )

    def test_get_v2_reads_role_v2_if_present(self):
        # Stored role_v2 contains stale label; GET should prefer fresh catalog
        # enrich(code) so that GET is consistent with the current catalog state.
        self.adm._store["@alice:test"] = {
            "com.liza.user_role": {
                "role": "developer",
                "role_v2": {
                    "code": "developer",
                    "label": "Custom Dev",
                    "color": "#FF0000",
                },
            }
        }
        status, body = _run(self.handler.get("@alice:test", v2=True))
        self.assertEqual(body["role"]["code"], "developer")
        self.assertEqual(body["role"]["label"], "Разработчик")  # from catalog

    def test_get_unknown_user_returns_404(self):
        status, body = _run(self.handler.get("@nonexistent:test", v2=False))
        self.assertEqual(status, 404)


# --- UserRoleHandler.set -----------------------------------------------------


class UserRoleSetTestCase(unittest.TestCase):
    def setUp(self):
        self.catalog = _FakeCatalog()
        self.adm = _FakeAccountDataManager()
        self.broadcaster = _FakeBroadcaster()
        self.handler = UserRoleHandler(
            catalog=self.catalog,
            account_data=self.adm,
            broadcaster=self.broadcaster,
            check_user_exists=_FakeUserExistence({"@alice:test"}),
        )

    def test_set_writes_both_legacy_and_v2(self):
        status, body = _run(self.handler.set("@alice:test", {"role": "ai"}))
        self.assertEqual(status, 200)
        self.assertEqual(body["updated"], True)
        # Account data has both fields
        stored = self.adm._store["@alice:test"]["com.liza.user_role"]
        self.assertEqual(stored["role"], "ai")
        self.assertEqual(stored["role_v2"]["label"], "ИИ")
        # Broadcast triggered
        self.assertEqual(self.broadcaster.role_changes, ["@alice:test"])

    def test_set_unknown_role_returns_404(self):
        status, body = _run(
            self.handler.set("@alice:test", {"role": "nonexistent_role"})
        )
        self.assertEqual(status, 404)
        self.assertEqual(self.broadcaster.role_changes, [])

    def test_set_unknown_user_returns_404(self):
        status, body = _run(self.handler.set("@nonexistent:test", {"role": "ai"}))
        self.assertEqual(status, 404)

    def test_set_invalid_body_returns_400(self):
        status, body = _run(self.handler.set("@alice:test", {}))
        self.assertEqual(status, 400)


# --- extra_roles: персональные доп. роли поверх основной ---------------------


class UserRoleExtraRolesTestCase(unittest.TestCase):
    """Владельцу — admin + developer, не задевая остальных admin/developer.
    AC:RL-developer-gates-strict/8"""

    def setUp(self):
        self.catalog = _FakeCatalog()
        self.catalog.rows["admin"] = {
            "code": "admin", "label": "Администратор", "color": None,
        }
        self.adm = _FakeAccountDataManager()
        self.broadcaster = _FakeBroadcaster()
        self.handler = UserRoleHandler(
            catalog=self.catalog,
            account_data=self.adm,
            broadcaster=self.broadcaster,
            check_user_exists=_FakeUserExistence({"@owner:test", "@other:test"}),
        )

    def _stored(self, uid):
        return self.adm._store[uid]["com.liza.user_role"]

    def test_set_with_extra_roles_writes_top_level_and_view(self):
        status, body = _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        self.assertEqual(status, 200)
        self.assertEqual(body["role"]["code"], "admin")
        self.assertEqual(body["role"]["label"], "Администратор")
        self.assertEqual(body["role"]["extra_roles"], ["developer"])
        stored = self._stored("@owner:test")
        self.assertEqual(stored["role"], "admin")
        self.assertEqual(stored["extra_roles"], ["developer"])
        self.assertEqual(stored["role_v2"]["extra_roles"], ["developer"])

    def test_set_same_role_without_key_preserves_extras(self):
        """AC:RL-developer-gates-strict/15"""
        _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        _run(self.handler.set("@owner:test", {"role": "admin"}))
        self.assertEqual(self._stored("@owner:test")["extra_roles"], ["developer"])

    def test_main_role_change_without_key_drops_extras(self):
        """liza-roles/liza-bot-api шлют только {"role"}: понижение не должно
        оставлять «висящий» developer. AC:RL-developer-gates-strict/15"""
        _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        _run(self.handler.set("@owner:test", {"role": "user"}))
        stored = self._stored("@owner:test")
        self.assertEqual(stored, {"role": "user", "role_v2": self.catalog.rows["user"]})

    def test_main_role_change_with_key_keeps_given_extras(self):
        """AC:RL-developer-gates-strict/15"""
        _run(self.handler.set(
            "@owner:test", {"role": "ai", "extra_roles": ["developer"]}
        ))
        _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        self.assertEqual(self._stored("@owner:test")["extra_roles"], ["developer"])

    def test_admin_as_extra_role_rejected(self):
        """Серверные гейты читают только основную роль — admin доп. ролью дал бы
        в клиенте кнопки с 403 на сервере. AC:RL-developer-gates-strict/15"""
        self.catalog.rows["developer"] = {
            "code": "developer", "label": "Разработчик", "color": None,
        }
        status, _ = _run(self.handler.set(
            "@owner:test", {"role": "developer", "extra_roles": ["admin"]}
        ))
        self.assertEqual(status, 400)
        self.assertNotIn("@owner:test", self.adm._store)

    def test_users_without_extras_keep_exact_contract(self):
        """Байт-в-байт прежние запись, PUT-ответ, GET v2 и batch v2 для
        пользователей без доп. ролей. AC:RL-developer-gates-strict/14"""
        self.catalog.rows["developer"] = {
            "code": "developer", "label": "Разработчик", "color": None,
        }
        for role in ("user", "admin", "developer"):
            uid = "@other:test"
            status, body = _run(self.handler.set(uid, {"role": role}))
            view = self.catalog.rows[role]
            self.assertEqual(status, 200)
            self.assertEqual(
                body, {"user_id": uid, "role": view, "updated": True}, role
            )
            self.assertEqual(self._stored(uid), {"role": role, "role_v2": view})
            _, got = _run(self.handler.get(uid, v2=True))
            self.assertEqual(got, {"user_id": uid, "role": view}, role)
            _, batch = _run(self.handler.batch([uid], v2=True))
            self.assertEqual(batch, {"roles": {uid: view}}, role)
        # legacy-запись без role_v2
        self.adm._store["@other:test"] = {"com.liza.user_role": {"role": "admin"}}
        _, got = _run(self.handler.get("@other:test", v2=True))
        self.assertEqual(got["role"], self.catalog.rows["admin"])

    def test_set_empty_list_clears_extras(self):
        _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        _run(self.handler.set("@owner:test", {"role": "admin", "extra_roles": []}))
        stored = self._stored("@owner:test")
        self.assertNotIn("extra_roles", stored)
        self.assertNotIn("extra_roles", stored["role_v2"])

    def test_extra_equal_to_main_role_dropped(self):
        _run(self.handler.set(
            "@owner:test", {"role": "developer", "extra_roles": ["developer"]}
        ))
        self.assertNotIn("extra_roles", self._stored("@owner:test"))

    def test_unknown_extra_role_rejected(self):
        status, _ = _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["nope"]}
        ))
        self.assertEqual(status, 404)
        self.assertNotIn("@owner:test", self.adm._store)

    def test_invalid_extra_roles_rejected(self):
        for bad in ("developer", [""], [1]):
            status, _ = _run(self.handler.set(
                "@owner:test", {"role": "admin", "extra_roles": bad}
            ))
            self.assertEqual(status, 400, bad)

    def test_get_and_batch_expose_extras_only_for_owner(self):
        _run(self.handler.set(
            "@owner:test", {"role": "admin", "extra_roles": ["developer"]}
        ))
        _run(self.handler.set("@other:test", {"role": "admin"}))
        _, got = _run(self.handler.get("@owner:test", v2=True))
        self.assertEqual(got["role"]["extra_roles"], ["developer"])
        _, batch = _run(self.handler.batch(["@owner:test", "@other:test"], v2=True))
        self.assertEqual(batch["roles"]["@owner:test"]["extra_roles"], ["developer"])
        # Другой admin — прежний контракт, без ключа.
        self.assertEqual(
            batch["roles"]["@other:test"],
            {"code": "admin", "label": "Администратор", "color": None},
        )
        _, v1 = _run(self.handler.batch(["@owner:test"], v2=False))
        self.assertEqual(v1["roles"]["@owner:test"], "admin")


# --- UserRoleHandler.batch ---------------------------------------------------


class UserRoleBatchTestCase(unittest.TestCase):
    def setUp(self):
        self.catalog = _FakeCatalog()
        self.adm = _FakeAccountDataManager()
        self.adm._store["@alice:test"] = {"com.liza.user_role": {"role": "ai"}}
        self.adm._store["@bob:test"] = {"com.liza.user_role": {"role": "developer"}}
        self.handler = UserRoleHandler(
            catalog=self.catalog,
            account_data=self.adm,
            broadcaster=_FakeBroadcaster(),
            check_user_exists=_FakeUserExistence(set()),  # not used by batch
        )

    def test_batch_v1_returns_strings(self):
        status, body = _run(
            self.handler.batch(["@alice:test", "@bob:test"], v2=False)
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["roles"]["@alice:test"], "ai")
        self.assertEqual(body["roles"]["@bob:test"], "developer")

    def test_batch_v2_returns_objects(self):
        status, body = _run(
            self.handler.batch(["@alice:test", "@bob:test"], v2=True)
        )
        self.assertEqual(status, 200)
        self.assertEqual(body["roles"]["@alice:test"]["label"], "ИИ")
        self.assertEqual(body["roles"]["@bob:test"]["label"], "Разработчик")

    def test_batch_v2_unknown_user_returns_default_object(self):
        # Default role "user" exists in catalog -> object payload
        status, body = _run(self.handler.batch(["@carol:test"], v2=True))
        self.assertEqual(body["roles"]["@carol:test"]["code"], "user")

    def test_batch_v1_unknown_user_returns_default(self):
        # Legacy contract: missing user -> default "user" role
        status, body = _run(self.handler.batch(["@carol:test"], v2=False))
        self.assertEqual(body["roles"]["@carol:test"], "user")


# --- RolesListHandler --------------------------------------------------------


class RolesListTestCase(unittest.TestCase):
    def setUp(self):
        self.catalog = _FakeCatalog()
        self.handler = RolesListHandler(self.catalog)

    def test_list_v1_returns_codes(self):
        status, body = _run(self.handler.list(v2=False))
        self.assertEqual(status, 200)
        self.assertEqual(set(body["roles"]), {"user", "ai", "developer"})

    def test_list_v2_returns_objects(self):
        status, body = _run(self.handler.list(v2=True))
        self.assertEqual(status, 200)
        codes = {r["code"] for r in body["roles"]}
        self.assertEqual(codes, {"user", "ai", "developer"})
        ai = next(r for r in body["roles"] if r["code"] == "ai")
        self.assertEqual(ai, {"code": "ai", "label": "ИИ", "color": "#4CAF50"})


# --- CORS для веб-клиента ---------------------------------------------------


class _FakeRequest:
    def __init__(self):
        self.headers = {}
        self.code = None
        self.body = b""
        self.finished = False

    def setResponseCode(self, code):
        self.code = code

    def setHeader(self, name, value):
        self.headers[name] = value

    def write(self, data):
        self.body += data

    def finish(self):
        self.finished = True


class JsonResponseCorsTests(unittest.TestCase):
    """Ответы модуля ролей несут Access-Control-Allow-Origin.

    Инцидент 02.10: POST /roles/v1/batch отвечал без CORS → в web.liza.ru роли не
    грузились, кнопки ботов (рисуются только у роли «ИИ») не показывались.
    ledger:RL-user-roles-web-cors
    """

    def test_success_and_error_responses_allow_any_origin(self):
        from synapse_modules.user_roles._api import _JsonResource

        resource = _JsonResource()
        for send in (
            lambda r: resource._json_response(r, {"roles": {}}),
            lambda r: resource._error(r, "unauthorized", "no token", 401),
        ):
            request = _FakeRequest()
            send(request)
            # AC:RL-user-roles-web-cors/1
            self.assertEqual(request.headers[b"Access-Control-Allow-Origin"], b"*")
            self.assertTrue(request.finished)


if __name__ == "__main__":
    unittest.main()
