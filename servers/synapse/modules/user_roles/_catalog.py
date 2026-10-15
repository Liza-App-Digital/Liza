"""User roles catalog: storage, cache, helpers."""

import json
import logging
import re
import time
from typing import TYPE_CHECKING, Any

from synapse.storage.engines import PostgresEngine

from ._roles import ACCOUNT_DATA_TYPE

if TYPE_CHECKING:
    from synapse.server import HomeServer
    from synapse.storage.database import DatabasePool

logger = logging.getLogger(__name__)

_CODE_RE = re.compile(r"^[a-z0-9_]{1,64}$")
_COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")

# Postgres вариант: regex CHECK на code и color.
_SCHEMA_SQL_POSTGRES = (
    """
    CREATE TABLE IF NOT EXISTS user_roles_catalog (
        code         TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        color        TEXT,
        created_ts   BIGINT NOT NULL,
        updated_ts   BIGINT NOT NULL,
        CONSTRAINT user_roles_catalog_code_lowercase
            CHECK (code = lower(code) AND code ~ '^[a-z0-9_]{1,64}$'),
        CONSTRAINT user_roles_catalog_color_hex
            CHECK (color IS NULL OR color ~ '^#[0-9a-fA-F]{6}$')
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS user_roles_catalog_updated_ts
        ON user_roles_catalog (updated_ts)
    """,
)

# SQLite вариант (для unit-тестов на trial): без regex, валидация на уровне Python.
_SCHEMA_SQL_SQLITE = (
    """
    CREATE TABLE IF NOT EXISTS user_roles_catalog (
        code         TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        color        TEXT,
        created_ts   BIGINT NOT NULL,
        updated_ts   BIGINT NOT NULL,
        CONSTRAINT user_roles_catalog_code_lowercase
            CHECK (code = lower(code)),
        CONSTRAINT user_roles_catalog_color_hex
            CHECK (color IS NULL OR (length(color) = 7 AND substr(color, 1, 1) = '#'))
    )
    """,
    """
    CREATE INDEX IF NOT EXISTS user_roles_catalog_updated_ts
        ON user_roles_catalog (updated_ts)
    """,
)

_SEED_ROLES: list[tuple[str, str, str | None]] = [
    ("user", "Пользователь", None),
    ("ai", "ИИ", "#4CAF50"),
    ("developer", "Разработчик", "#1565C0"),
    ("moderator", "Модератор", None),
    ("manager", "Менеджер", None),
    ("admin", "Администратор", None),
]


class RoleCatalog:
    """Storage layer + in-memory cache for the role catalog."""

    def __init__(self, db_pool: "DatabasePool") -> None:
        self._db = db_pool
        self._cache: dict[str, dict[str, Any]] = {}

    @classmethod
    def from_homeserver(cls, hs: "HomeServer") -> "RoleCatalog":
        return cls(hs.get_datastores().main.db_pool)

    async def ensure_schema(self) -> None:
        """Create the table and seed defaults. Idempotent."""

        if isinstance(self._db.engine, PostgresEngine):
            schema_statements = _SCHEMA_SQL_POSTGRES
        else:
            schema_statements = _SCHEMA_SQL_SQLITE

        def _create(txn):
            for stmt in schema_statements:
                txn.execute(stmt)

        await self._db.runInteraction("user_roles_catalog_schema", _create)
        now = int(time.time() * 1000)

        def _seed(txn):
            for code, label, color in _SEED_ROLES:
                txn.execute(
                    "INSERT INTO user_roles_catalog "
                    "(code, display_name, color, created_ts, updated_ts) "
                    "VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT (code) DO NOTHING",
                    (code, label, color, now, now),
                )

        await self._db.runInteraction("user_roles_catalog_seed", _seed)

    async def list_all(self) -> list[dict[str, Any]]:
        """Returns cached snapshot. Lazy-loads on first call; call
        _reload_cache() to refresh after external SQL writes."""
        if not self._cache:
            await self._reload_cache()
        return [dict(v) for v in self._cache.values()]

    async def enrich(self, code: str | None) -> dict[str, str | None] | None:
        """Return {code, label, color} payload for the given code, or None
        if code is None or not in the catalog."""
        if code is None:
            return None
        if not self._cache:
            await self._reload_cache()
        row = self._cache.get(code)
        if row is None:
            return None
        return {"code": row["code"], "label": row["display_name"], "color": row["color"]}

    async def add(self, code: str, display_name: str, color: str | None) -> None:
        """Insert a new role. Raises if code already exists."""
        now = int(time.time() * 1000)

        def _insert(txn):
            txn.execute(
                "INSERT INTO user_roles_catalog "
                "(code, display_name, color, created_ts, updated_ts) "
                "VALUES (?, ?, ?, ?, ?)",
                (code, display_name, color, now, now),
            )

        await self._db.runInteraction("user_roles_catalog_add", _insert)
        await self._reload_cache()

    async def patch(
        self,
        code: str,
        *,
        display_name: str | None = None,
        color: str | None = None,
        clear_color: bool = False,
    ) -> bool:
        """Update display_name and/or color. Returns True if row existed.

        clear_color=True sets color to NULL (distinct from color=None which
        means 'leave unchanged'). If both color and clear_color are set,
        clear_color wins.

        "row existed" semantics: returns True iff the code was in the
        catalog at call time, even if the payload didn't actually change
        any column. This keeps SQLite and Postgres in agreement (Postgres
        UPDATE rowcount is 0 on no-op writes; SQLite returns 1).
        """
        sets = ["updated_ts = ?"]
        params: list = [int(time.time() * 1000)]
        if display_name is not None:
            sets.append("display_name = ?")
            params.append(display_name)
        if clear_color:
            sets.append("color = NULL")
        elif color is not None:
            sets.append("color = ?")
            params.append(color)
        params.append(code)
        sql = f"UPDATE user_roles_catalog SET {', '.join(sets)} WHERE code = ?"

        def _check_and_update(txn):
            txn.execute("SELECT 1 FROM user_roles_catalog WHERE code = ?", (code,))
            exists = next(iter(txn), None) is not None
            if not exists:
                return False
            # Only run the UPDATE if there's something other than updated_ts
            # to change; bumping updated_ts alone is wasteful and surprising
            # to operators looking at the row history.
            if len(sets) > 1:
                txn.execute(sql, tuple(params))
            return True

        existed = await self._db.runInteraction(
            "user_roles_catalog_patch", _check_and_update
        )
        if existed:
            await self._reload_cache()
        return existed

    async def delete(self, code: str) -> bool:
        """Delete a role. Returns True if row existed."""

        def _delete(txn):
            txn.execute("DELETE FROM user_roles_catalog WHERE code = ?", (code,))
            return txn.rowcount

        rowcount = await self._db.runInteraction("user_roles_catalog_delete", _delete)
        if rowcount > 0:
            await self._reload_cache()
        return rowcount > 0

    async def reload(self) -> None:
        """Public alias for cache reload, for callers outside this module
        (e.g. the /catalog/reload HTTP handler). Same behavior as
        ``_reload_cache``; the underscore version is kept for internal calls.
        """
        await self._reload_cache()

    async def _reload_cache(self) -> None:
        def _select(txn):
            txn.execute(
                "SELECT code, display_name, color FROM user_roles_catalog "
                "ORDER BY code"
            )
            return [
                {"code": code, "display_name": label, "color": color}
                for code, label, color in txn
            ]

        rows = await self._db.runInteraction("user_roles_catalog_list", _select)
        self._cache = {r["code"]: r for r in rows}

    def snapshot(self) -> dict[str, dict[str, Any]]:
        """Return an independent copy of the cached rows keyed by code.

        Не триггерит reload и не ходит в БД. Используется reload-эндпоинтом
        для сравнения "до/после" перед широковещанием изменений; вызывающие,
        которым нужна свежая БД-картинка, должны сперва позвать
        ``_reload_cache`` (или использовать ``list_all`` для lazy-пути).
        """
        return {code: dict(row) for code, row in self._cache.items()}

    @staticmethod
    def is_valid_code(code: Any) -> bool:
        """True iff `code` is a non-empty lowercase ascii [a-z0-9_], <=64 chars."""
        return isinstance(code, str) and _CODE_RE.match(code) is not None

    @staticmethod
    def is_valid_color(color: Any) -> bool:
        """True iff `color` is None or "#RRGGBB" hex (either case)."""
        if color is None:
            return True
        return isinstance(color, str) and _COLOR_RE.match(color) is not None

    async def users_with_role(self, code: str) -> list[str]:
        """Return user_ids whose com.liza.user_role account_data points at this role.

        Synapse stores account_data.content as TEXT (JSON-encoded string), not
        jsonb. LIKE here is only a coarse prefilter on the quoted code; the
        exact match is ``json.loads(content)["role"] == code`` in Python.
        Matching the raw substring ``"role":"<code>"`` missed rows written
        with spaces (``{"role": "developer"}`` — prod has such rows, written
        outside ``json_encoder``), so the catalog-patch broadcast skipped them.

        We escape ``_`` and ``%`` (LIKE metacharacters) in the code so that a
        valid role code containing ``_`` (e.g. ``cyber_agronom``) does not
        wildcard-match unrelated codes of the same length.
        """

        safe = code.replace("\\", "\\\\").replace("_", "\\_").replace("%", "\\%")
        pattern = f'%"{safe}"%'

        def _select(txn):
            txn.execute(
                "SELECT user_id, content FROM account_data "
                "WHERE account_data_type = ? "
                "AND content LIKE ? ESCAPE '\\'",
                (ACCOUNT_DATA_TYPE, pattern),
            )
            result = []
            for user_id, content in txn:
                try:
                    data = json.loads(content)
                except (TypeError, ValueError):
                    continue
                if isinstance(data, dict) and data.get("role") == code:
                    result.append(user_id)
            return result

        return await self._db.runInteraction(
            "user_roles_users_with_role", _select
        )
