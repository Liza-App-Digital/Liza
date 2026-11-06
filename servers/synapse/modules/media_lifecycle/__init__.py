"""Synapse-модуль media_lifecycle — quarantine медиа в MMR при m.room.redaction.

Хук on_new_event перехватывает события; для m.room.redaction извлекает
оригинальное событие, находит mxc-URI и шлёт quarantine в MMR Admin API.
Quarantine — мягкое удаление: блокирует отдачу, blob остаётся в S3
до storage cleanup MMR. Hard-delete (если потребуется) — отдельная
итерация со сменой endpoint.

Ограничения:
- Работает ТОЛЬКО на dev.liza.laba.prodamus.tech (fail-fast в __init__).
  Папка servers/synapse/modules/ маунтится во все инстансы; модуль обязан
  отказаться загружаться на чужом server_name.
- Работает только для non-E2EE медиа. В E2EE-комнатах event.content
  зашифрован, mxc:// внутри ciphertext не виден серверу. Удаление E2EE
  attachment'ов требует hint от клиента (custom field в redaction event) —
  отдельная задача.
- Idempotency через таблицу media_lifecycle_processed (создаётся на старте).
  Повторный redact того же события — no-op.

Конфигурация (homeserver.yaml, только на dev):

    modules:
      - module: synapse_modules.media_lifecycle.MediaLifecycleModule
        config:
          mmr_admin_url: http://mmr:8000
          mmr_admin_token_path: /data/secrets/mmr_admin.token
          dry_run: true   # первые 3-7 дней — только лог, без реального DELETE
"""

import logging
from typing import Any, Dict

from synapse.config import ConfigError
from synapse.events import EventBase
from synapse.module_api import ModuleApi
from synapse.types import StateMap

from synapse_modules._ha import register_on_new_event_once

logger = logging.getLogger(__name__)

ALLOWED_SERVER_NAME = "dev.liza.laba.prodamus.tech"
SUPPORTED_MSGTYPES = frozenset({"m.image", "m.video", "m.audio", "m.file"})

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS media_lifecycle_processed (
    redacted_event_id TEXT PRIMARY KEY,
    mxc_uri TEXT NOT NULL,
    room_id TEXT NOT NULL,
    processed_at BIGINT NOT NULL,
    delete_status TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS media_lifecycle_processed_by_mxc
    ON media_lifecycle_processed (mxc_uri);
"""


class MediaLifecycleModule:
    """Удаляет blob из MMR/S3 при m.room.redaction (non-E2EE)."""

    @staticmethod
    def parse_config(config: Dict[str, Any]) -> Dict[str, Any]:
        mmr_admin_url = config.get("mmr_admin_url")
        if not mmr_admin_url:
            raise ConfigError("media_lifecycle: требуется mmr_admin_url")
        if not isinstance(mmr_admin_url, str) or not mmr_admin_url.startswith("http"):
            raise ConfigError(
                "media_lifecycle: mmr_admin_url должен быть http(s)-URL, "
                f"получено: {mmr_admin_url!r}"
            )
        mmr_admin_token_path = config.get("mmr_admin_token_path")
        if not mmr_admin_token_path:
            raise ConfigError("media_lifecycle: требуется mmr_admin_token_path")
        return {
            "mmr_admin_url": mmr_admin_url.rstrip("/"),
            "mmr_admin_token_path": mmr_admin_token_path,
            "dry_run": bool(config.get("dry_run", True)),
        }

    def __init__(self, config: Dict[str, Any], api: ModuleApi) -> None:
        # Главный fail-fast: модуль допустим ТОЛЬКО на dev-инстансе.
        # servers/synapse/modules/ — общая директория, маунтится и в prod.
        # Если кто-то скопирует регистрацию в prod homeserver.yaml — Synapse
        # упадёт на старте. Это намеренно.
        if api.server_name != ALLOWED_SERVER_NAME:
            raise ConfigError(
                f"media_lifecycle: модуль допустим ТОЛЬКО на server_name="
                f"{ALLOWED_SERVER_NAME!r}, текущий — {api.server_name!r}. "
                "Модуль удаляет медиа из общего bucket — на prod это опасно."
            )

        self._api = api
        self._mmr_admin_url = config["mmr_admin_url"]
        self._mmr_admin_token_path = config["mmr_admin_token_path"]
        self._dry_run = config["dry_run"]

        # Admin-token читаем здесь, на старте модуля (single-threaded init).
        # В hot path (_on_new_event → _quarantine_via_mmr) sync-open блокировал бы
        # реактор; держать токен в памяти безопасно — secrets/ mount-ится :ro,
        # ротация требует рестарта Synapse в любом случае.
        try:
            with open(self._mmr_admin_token_path, "r", encoding="utf-8") as f:
                self._mmr_admin_token = f.read().strip()
        except OSError as exc:
            raise ConfigError(
                f"media_lifecycle: не могу прочитать admin-token из "
                f"{self._mmr_admin_token_path!r}: {exc}"
            ) from exc
        if not self._mmr_admin_token:
            raise ConfigError(
                f"media_lifecycle: admin-token пуст ({self._mmr_admin_token_path})"
            )

        # HA: эффект выполняет один процесс инстанса (см. synapse_modules._ha).
        register_on_new_event_once(api, self._on_new_event)

        # Schema init — отложенный async-вызов на старте модуля.
        # ModuleApi не даёт sync-точку входа для DDL, поэтому шлём через
        # run_as_background_process — стартует и не блокирует Synapse.
        api.run_as_background_process(
            "media_lifecycle_schema_init", self._ensure_schema
        )

        logger.info(
            "MediaLifecycleModule loaded (server=%s, dry_run=%s, mmr=%s)",
            api.server_name,
            self._dry_run,
            self._mmr_admin_url,
        )

    async def _ensure_schema(self) -> None:
        """Создаёт таблицу media_lifecycle_processed, если её нет."""
        try:
            await self._api.run_db_interaction(
                "media_lifecycle_schema",
                lambda txn: txn.execute(_SCHEMA_SQL),
            )
            logger.info("media_lifecycle: schema готова")
        except Exception:
            logger.exception("media_lifecycle: ошибка создания schema")

    async def _already_processed(self, redacted_event_id: str) -> bool:
        def _check(txn) -> bool:
            txn.execute(
                "SELECT 1 FROM media_lifecycle_processed WHERE redacted_event_id = %s",
                (redacted_event_id,),
            )
            return txn.fetchone() is not None

        return await self._api.run_db_interaction(
            "media_lifecycle_check_processed", _check
        )

    async def _mark_processed(
        self, redacted_event_id: str, mxc: str, room_id: str, status: str
    ) -> None:
        ts = self._api.current_milliseconds_msec()

        def _insert(txn) -> None:
            txn.execute(
                "INSERT INTO media_lifecycle_processed "
                "(redacted_event_id, mxc_uri, room_id, processed_at, delete_status) "
                "VALUES (%s, %s, %s, %s, %s) "
                "ON CONFLICT (redacted_event_id) DO NOTHING",
                (redacted_event_id, mxc, room_id, ts, status),
            )

        await self._api.run_db_interaction("media_lifecycle_mark", _insert)

    async def _quarantine_via_mmr(self, mxc: str) -> str:
        """Quarantine blob через MMR Admin API. Возвращает строку-статус.

        Идемпотентность: 404 от MMR считаем успехом (уже карантинно).
        """
        # mxc://server/id → server, id
        without_scheme = mxc[len("mxc://") :]
        server_name, _, media_id = without_scheme.partition("/")
        if not server_name or not media_id:
            return "skip_invalid_mxc"

        # MMR Admin endpoint: /_matrix/media/unstable/admin/quarantine/{server}/{id}
        # Quarantine — мягкое удаление: блокирует отдачу, blob останется
        # в S3 пока не пройдёт MMR storage cleanup. Это безопаснее для
        # первой итерации, чем hard-delete.
        url = (
            f"{self._mmr_admin_url}/_matrix/media/unstable/admin/quarantine/"
            f"{server_name}/{media_id}"
        )
        headers = {"Authorization": [f"Bearer {self._mmr_admin_token}"]}

        http = self._api.http_client
        try:
            # Synapse SimpleHttpClient: post_json_get_json, get_json и т.д.
            # Для произвольного метода — request().
            response = await http.request(
                "POST", url, headers=headers, json_body=None
            )
            status_code = response.code
        except Exception:
            logger.exception("media_lifecycle: ошибка quarantine-запроса к MMR")
            return "error_network"

        if 200 <= status_code < 300:
            return "quarantined"
        if status_code == 404:
            return "already_absent"
        logger.warning(
            "media_lifecycle: MMR ответил %s на quarantine %s", status_code, mxc
        )
        return f"error_http_{status_code}"

    async def _on_new_event(
        self,
        event: EventBase,
        state_events: StateMap[EventBase],
    ) -> None:
        if event.type != "m.room.redaction":
            return

        redacted_event_id = getattr(event, "redacts", None)
        if not redacted_event_id:
            return

        # ModuleApi не выставляет get_event; используем DataStore напрямую.
        # check_room_id — защита от cross-room redaction подделок:
        # вернёт None, если event_id лежит не в room_id текущего redaction-а.
        original = await self._api._store.get_event(
            redacted_event_id,
            allow_none=True,
            check_room_id=event.room_id,
        )
        if original is None:
            logger.debug(
                "media_lifecycle: redacted event %s not found in %s",
                redacted_event_id,
                event.room_id,
            )
            return

        # E2EE: content зашифрован, mxc не виден — пропускаем
        if original.type == "m.room.encrypted":
            logger.debug(
                "media_lifecycle: encrypted event %s — skip (E2EE)",
                redacted_event_id,
            )
            return

        if original.type != "m.room.message":
            return

        msgtype = original.content.get("msgtype")
        if msgtype not in SUPPORTED_MSGTYPES:
            return

        mxc = original.content.get("url")
        if not mxc or not isinstance(mxc, str) or not mxc.startswith("mxc://"):
            return

        # Idempotency check — если уже обработано, выходим без вызова MMR
        if await self._already_processed(redacted_event_id):
            logger.debug(
                "media_lifecycle: %s уже обработан, skip", redacted_event_id
            )
            return

        if self._dry_run:
            logger.info(
                "media_lifecycle [DRY-RUN]: would quarantine %s "
                "(redacted_event=%s, room=%s)",
                mxc,
                redacted_event_id,
                event.room_id,
            )
            await self._mark_processed(
                redacted_event_id, mxc, event.room_id, "dry_run"
            )
            return

        status = await self._quarantine_via_mmr(mxc)
        logger.info(
            "media_lifecycle: quarantine %s status=%s (event=%s, room=%s)",
            mxc,
            status,
            redacted_event_id,
            event.room_id,
        )
        await self._mark_processed(redacted_event_id, mxc, event.room_id, status)
