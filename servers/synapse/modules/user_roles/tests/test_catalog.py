"""Storage tests for RoleCatalog without the full Synapse HomeServer.

We bypass HomeserverTestCase because the upstream SQLite schema preparation in
this Synapse fork is broken on 1.151 ("no such table: pushers"). Instead we
drive RoleCatalog through a minimal in-memory SQLite that mimics just the
db_pool.runInteraction API surface used by the catalog.
"""

import asyncio
import sqlite3
import unittest
from typing import Any, Callable, TypeVar

from synapse_modules.user_roles._catalog import RoleCatalog

T = TypeVar("T")


class _SqliteCursorShim:
    """Adapter for sqlite3.Cursor that accepts Synapse-style "?"" placeholders
    and the ON CONFLICT (...) DO NOTHING syntax (SQLite 3.24+ supports it
    natively, so this is mostly a pass-through)."""

    def __init__(self, cursor: sqlite3.Cursor) -> None:
        self._cursor = cursor

    def execute(self, sql: str, params: tuple = ()) -> None:
        self._cursor.execute(sql, params)

    def executescript(self, sql: str) -> None:
        self._cursor.executescript(sql)

    def __iter__(self):
        return iter(self._cursor)

    @property
    def rowcount(self) -> int:
        return self._cursor.rowcount


class _MockEngine:
    """Stand-in for Synapse's database engine type. Catalog only checks
    isinstance(..., PostgresEngine), so any non-Postgres object steers us to
    the SQLite SQL variant."""


class _SqliteDbPool:
    """Minimal stand-in for Synapse's db_pool.runInteraction.

    Real Synapse pool ships work onto a thread and wraps it in a Twisted
    Deferred. For unit tests we run synchronously inside one shared
    connection and wrap the result in an already-resolved asyncio future so
    the catalog's `await self._db.runInteraction(...)` works under
    asyncio.run.
    """

    def __init__(self) -> None:
        self._conn = sqlite3.connect(":memory:")
        # autocommit: tests are single-threaded. NB: tests that rely on
        # transactional rollback on constraint violation will NOT match
        # real Postgres semantics in this shim - by Task 3 (CRUD with
        # duplicates) we'll need to either wrap operations in BEGIN/COMMIT
        # here or switch to a Postgres test container.
        self._conn.isolation_level = None
        self.engine = _MockEngine()

    async def runInteraction(
        self, desc: str, func: Callable[[Any], T], *args, **kwargs
    ) -> T:
        cur = _SqliteCursorShim(self._conn.cursor())
        return func(cur, *args, **kwargs)

    def close(self) -> None:
        self._conn.close()


def _run(coro):
    """Run an async coroutine in a fresh event loop. unittest's
    IsolatedAsyncioTestCase would also work but keeps less explicit setup."""
    return asyncio.run(coro)


class CatalogMigrationTestCase(unittest.TestCase):
    """Schema migration + seed of default roles."""

    def setUp(self) -> None:
        self.pool = _SqliteDbPool()
        self.catalog = RoleCatalog(self.pool)

    def tearDown(self) -> None:
        self.pool.close()

    def test_migration_creates_table_and_seeds_defaults(self) -> None:
        _run(self.catalog.ensure_schema())
        # Repeated call must be idempotent
        _run(self.catalog.ensure_schema())

        rows = _run(self.catalog.list_all())
        codes = {r["code"] for r in rows}
        self.assertEqual(
            codes,
            {"user", "ai", "developer", "moderator", "manager", "admin"},
        )

        ai = next(r for r in rows if r["code"] == "ai")
        self.assertEqual(ai["display_name"], "ИИ")
        self.assertEqual(ai["color"], "#4CAF50")

        # Тег «Разработчик» отличим от зелёного «ИИ»/«Бот» с первого старта инстанса.
        developer = next(r for r in rows if r["code"] == "developer")
        self.assertEqual(developer["color"], "#1565C0")

    def test_seed_keeps_existing_rows_unchanged(self) -> None:
        _run(self.catalog.ensure_schema())
        # simulate an operator UPDATE outside the catalog API
        self.pool._conn.execute(
            "UPDATE user_roles_catalog SET display_name = 'Custom' WHERE code = 'ai'"
        )
        # Bust the cache so list_all sees the row that's now divergent
        # from the seed.
        self.catalog._cache.clear()
        _run(self.catalog.ensure_schema())
        rows = _run(self.catalog.list_all())
        ai = next(r for r in rows if r["code"] == "ai")
        self.assertEqual(ai["display_name"], "Custom")

    def test_list_all_lazy_loads_on_first_call(self) -> None:
        # Schema/seed via raw SQL, then verify list_all populates the cache
        # without an explicit ensure_schema() warmup.
        for stmt in (
            "CREATE TABLE user_roles_catalog ("
            "code TEXT PRIMARY KEY, display_name TEXT NOT NULL, color TEXT, "
            "created_ts BIGINT NOT NULL, updated_ts BIGINT NOT NULL)",
            "INSERT INTO user_roles_catalog VALUES ('only', 'Только', NULL, 1, 1)",
        ):
            self.pool._conn.execute(stmt)
        rows = _run(self.catalog.list_all())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["code"], "only")


class CatalogEnrichTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.pool = _SqliteDbPool()
        self.catalog = RoleCatalog(self.pool)
        _run(self.catalog.ensure_schema())

    def tearDown(self) -> None:
        self.pool.close()

    def test_enrich_known_role(self) -> None:
        view = _run(self.catalog.enrich("ai"))
        self.assertEqual(view, {"code": "ai", "label": "ИИ", "color": "#4CAF50"})

    def test_enrich_unknown_role(self) -> None:
        view = _run(self.catalog.enrich("nonexistent"))
        self.assertIsNone(view)

    def test_enrich_none(self) -> None:
        view = _run(self.catalog.enrich(None))
        self.assertIsNone(view)

    def test_enrich_role_without_color(self) -> None:
        view = _run(self.catalog.enrich("user"))
        self.assertEqual(view, {"code": "user", "label": "Пользователь", "color": None})

    def test_enrich_lazy_loads_cache(self) -> None:
        # ensure_schema seeded rows but did not warm the cache (Task 1 review
        # removed the eager _reload_cache from ensure_schema). enrich must
        # trigger the lazy load on first call.
        self.assertEqual(self.catalog._cache, {})
        view = _run(self.catalog.enrich("ai"))
        self.assertEqual(view, {"code": "ai", "label": "ИИ", "color": "#4CAF50"})
        self.assertNotEqual(self.catalog._cache, {})


class CatalogCRUDTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.pool = _SqliteDbPool()
        self.catalog = RoleCatalog(self.pool)
        _run(self.catalog.ensure_schema())

    def tearDown(self) -> None:
        self.pool.close()

    def test_add_role_with_color(self) -> None:
        _run(self.catalog.add("cyber_agronom", "Кибер-Агроном", "#7CB342"))
        view = _run(self.catalog.enrich("cyber_agronom"))
        self.assertEqual(
            view,
            {"code": "cyber_agronom", "label": "Кибер-Агроном", "color": "#7CB342"},
        )

    def test_add_role_without_color(self) -> None:
        _run(self.catalog.add("temp", "Временный", None))
        view = _run(self.catalog.enrich("temp"))
        self.assertEqual(view, {"code": "temp", "label": "Временный", "color": None})

    def test_add_duplicate_raises(self) -> None:
        _run(self.catalog.add("dup", "Дубль", None))
        with self.assertRaises(sqlite3.IntegrityError):
            _run(self.catalog.add("dup", "Другой", None))
        # The original row must survive the failed add
        view = _run(self.catalog.enrich("dup"))
        self.assertEqual(view["label"], "Дубль")

    def test_patch_display_name(self) -> None:
        updated = _run(self.catalog.patch("ai", display_name="Искусственный Интеллект"))
        self.assertTrue(updated)
        view = _run(self.catalog.enrich("ai"))
        self.assertEqual(view["label"], "Искусственный Интеллект")
        # Color must remain unchanged
        self.assertEqual(view["color"], "#4CAF50")

    def test_patch_color(self) -> None:
        updated = _run(self.catalog.patch("user", color="#000000"))
        self.assertTrue(updated)
        self.assertEqual(_run(self.catalog.enrich("user"))["color"], "#000000")

    def test_patch_clear_color(self) -> None:
        updated = _run(self.catalog.patch("ai", clear_color=True))
        self.assertTrue(updated)
        self.assertIsNone(_run(self.catalog.enrich("ai"))["color"])

    def test_patch_unknown_returns_false(self) -> None:
        updated = _run(self.catalog.patch("nonexistent", display_name="X"))
        self.assertFalse(updated)

    def test_patch_no_kwargs_returns_true_without_writes(self) -> None:
        # Contract: patch returns True iff the code existed at call time, even
        # if no columns were actually changed. Important for HTTP 404 vs 200.
        # Also: no kwargs must NOT bump updated_ts on the row.
        # Snapshot updated_ts directly from the row to detect unwanted writes.
        ai_before = self.pool._conn.execute(
            "SELECT updated_ts FROM user_roles_catalog WHERE code = 'ai'"
        ).fetchone()[0]
        updated = _run(self.catalog.patch("ai"))
        self.assertTrue(updated)
        ai_after = self.pool._conn.execute(
            "SELECT updated_ts FROM user_roles_catalog WHERE code = 'ai'"
        ).fetchone()[0]
        self.assertEqual(ai_before, ai_after)

    def test_delete_role(self) -> None:
        _run(self.catalog.add("temp", "Временный", None))
        deleted = _run(self.catalog.delete("temp"))
        self.assertTrue(deleted)
        self.assertIsNone(_run(self.catalog.enrich("temp")))

    def test_delete_unknown_returns_false(self) -> None:
        deleted = _run(self.catalog.delete("nonexistent"))
        self.assertFalse(deleted)


class CatalogValidatorsTestCase(unittest.TestCase):
    """Pure-function validators, no DB."""

    def test_is_valid_code_accepts(self) -> None:
        for code in ("user", "cyber_agronom", "a", "x_1", "0" * 64):
            self.assertTrue(RoleCatalog.is_valid_code(code), code)

    def test_is_valid_code_rejects(self) -> None:
        for code in ("", "CyberAgronom", "with space", "x-y", "0" * 65, "юникод", None):
            self.assertFalse(RoleCatalog.is_valid_code(code), code)

    def test_is_valid_color_accepts(self) -> None:
        for color in (None, "#abcdef", "#ABCDEF", "#123456", "#000000", "#FFFFFF"):
            self.assertTrue(RoleCatalog.is_valid_color(color), color)

    def test_is_valid_color_rejects(self) -> None:
        for color in ("abcdef", "#abc", "#abcdefg", "#zzzzzz", "", "  #abcdef", 0xFFFFFF):
            self.assertFalse(RoleCatalog.is_valid_color(color), color)


class CatalogUsersByRoleTestCase(unittest.TestCase):
    """users_with_role: query account_data table for users having this role.

    Fixtures encode payloads through ``synapse.util.json.json_encoder`` so the
    test stays in sync if upstream Synapse ever changes its JSON separators.
    """

    def setUp(self) -> None:
        from synapse.util.json import json_encoder

        self._encode = json_encoder.encode
        self.pool = _SqliteDbPool()
        self.catalog = RoleCatalog(self.pool)
        _run(self.catalog.ensure_schema())
        # Synapse account_data table - emulate the minimal schema we need
        # (the real one has more columns but users_with_role only touches
        # account_data_type, user_id and content::text).
        self.pool._conn.execute(
            "CREATE TABLE account_data ("
            "user_id TEXT NOT NULL, account_data_type TEXT NOT NULL, "
            "content TEXT NOT NULL, "
            "PRIMARY KEY (user_id, account_data_type))"
        )

    def tearDown(self) -> None:
        self.pool.close()

    def _insert(self, user_id: str, account_data_type: str, payload: dict) -> None:
        self.pool._conn.execute(
            "INSERT INTO account_data VALUES (?, ?, ?)",
            (user_id, account_data_type, self._encode(payload)),
        )

    def test_users_with_role_returns_empty_initially(self) -> None:
        users = _run(self.catalog.users_with_role("cyber_agronom"))
        self.assertEqual(users, [])

    def test_users_with_role_finds_assigned(self) -> None:
        self._insert("@alice:test", "com.liza.user_role", {"role": "ai"})
        self._insert("@bob:test", "com.liza.user_role", {"role": "user"})
        users = _run(self.catalog.users_with_role("ai"))
        self.assertEqual(users, ["@alice:test"])

    def test_users_with_role_ignores_other_account_data_types(self) -> None:
        self._insert("@a:test", "m.read_marker", {"role": "ai"})
        users = _run(self.catalog.users_with_role("ai"))
        self.assertEqual(users, [])

    def test_users_with_role_does_not_match_underscore_wildcard(self) -> None:
        # Regression: SQL LIKE treats `_` as any-single-char. Without escape,
        # users_with_role("a_i") would also match users carrying role "abi"
        # or "axi". Our implementation escapes _ and %.
        self._insert("@alice:test", "com.liza.user_role", {"role": "a_i"})
        self._insert("@bob:test", "com.liza.user_role", {"role": "ami"})
        users = _run(self.catalog.users_with_role("a_i"))
        self.assertEqual(users, ["@alice:test"])

    def test_users_with_role_matches_json_with_spaces(self) -> None:
        # Регрессия: на проде есть записи, сохранённые мимо json_encoder —
        # {"role": "developer"} с пробелами; подстрочный LIKE их не находил,
        # и рассылка после PATCH каталога обходила этих носителей.
        self.pool._conn.execute(
            "INSERT INTO account_data VALUES (?, ?, ?)",
            ("@daniel:test", "com.liza.user_role", '{"role": "developer", "role_v2": null}'),
        )
        self._insert("@nadezhda:test", "com.liza.user_role", {"role": "developer"})
        self._insert("@x:test", "com.liza.user_role", {"role": "developerx"})
        users = _run(self.catalog.users_with_role("developer"))
        self.assertEqual(sorted(users), ["@daniel:test", "@nadezhda:test"])

    def test_users_with_role_ignores_code_in_other_fields(self) -> None:
        # Код в extra_roles/role_v2 не делает человека носителем основной роли.
        self._insert(
            "@owner:test",
            "com.liza.user_role",
            {"role": "admin", "extra_roles": ["developer"]},
        )
        users = _run(self.catalog.users_with_role("developer"))
        self.assertEqual(users, [])


class CatalogSnapshotTestCase(unittest.TestCase):
    """snapshot() exposes a defensive copy of the cache without triggering DB."""

    def setUp(self) -> None:
        self.pool = _SqliteDbPool()
        self.catalog = RoleCatalog(self.pool)
        _run(self.catalog.ensure_schema())

    def tearDown(self) -> None:
        self.pool.close()

    def test_snapshot_returns_independent_copy(self) -> None:
        _run(self.catalog.list_all())  # прогреваем кэш
        snap = self.catalog.snapshot()
        self.assertIn("ai", snap)
        # Мутируем snapshot - оригинальный кэш должен остаться нетронутым
        snap["ai"]["display_name"] = "Hacked"
        snap.pop("user")
        original = self.catalog.snapshot()
        self.assertEqual(original["ai"]["display_name"], "ИИ")
        self.assertIn("user", original)

    def test_snapshot_empty_when_no_warmup(self) -> None:
        # snapshot не триггерит lazy load - это просто зеркало кэша
        fresh = RoleCatalog(self.pool)
        self.assertEqual(fresh.snapshot(), {})


if __name__ == "__main__":
    unittest.main()
