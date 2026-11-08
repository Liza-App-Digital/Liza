"""Synapse-модуль: capability-эндпоинт + хранилище device_capabilities
для sync-gate скрытых (hidden) чатов. См. design doc
docs/superpowers/specs/2026-07-01-chat-topology-stories-sync-gate-design.md.

Базовая фильтрация /sync патчится напрямую в synapse/handlers/sync.py
(модульного хука для этого нет) и читает атрибуты этого модуля через
hs.liza_chat_topology_sync_gate_module, который модуль выставляет на
HomeServer в своём __init__ — см. Task 5.
"""

import logging
from typing import Any, Optional

from synapse.module_api import ModuleApi

from ._storage import DeviceCapabilitiesStore, ForcedFullStateMarkers, HiddenRoomsLookup
from ._version_gate_client import VersionGateThresholds

logger = logging.getLogger(__name__)

# ⚠️ Здесь платформа — ключ ПОРОГА min_stories_build, а не адрес приложения.
# Приложения по ней не разводятся: номер сборки у обоих Apple-приложений
# сквозной (bump-build-number.sh не знает про LIZA_ACCOUNT, счётчик один на
# pubspec), поэтому порог у них общий. Клиент шлёт сюда ios/macos независимо
# от bundle id — см. resolvePlatform в clients/flutter/lib/widgets/matrix.dart.
#
# Сам bundle нужен только для ЗАПРОСА к version-gate, где строка iOS/macOS
# адресуется им: см. BUNDLES_BY_PLATFORM в _version_gate_client.py. Без него
# сервис ответит 404 → get_min_build вернёт None → device_passed_gate=False,
# и скрытые комнаты вырежутся из /sync у всех владельцев iOS/macOS.
KNOWN_PLATFORMS = ("ios", "macos", "android", "windows", "web")

# Платформы с порогом в version-gate. web там нет (сервис отвечает 404 «unknown
# platform»): веб-клиент скрытые чаты не видит намеренно (решение 07.11), гейт
# для него закрыт без запроса — иначе на каждый /sync веб-устройства уходил HTTP
# в version-gate с 404 (≈200/ч warning в логах HS user).
GATED_PLATFORMS = ("ios", "macos", "android", "windows")


class ChatTopologySyncGateModule:
    @staticmethod
    def parse_config(config: dict[str, Any]) -> dict[str, Any]:
        return {
            "enabled": bool(config.get("enabled", False)),
            "version_gate_base_url": config.get("version_gate_base_url"),
            "threshold_ttl_seconds": int(config.get("threshold_ttl_seconds", 300)),
        }

    def __init__(self, config: dict[str, Any], api: ModuleApi) -> None:
        self._api = api
        self.enabled = config["enabled"]

        # ModuleApi не даёт публичного доступа к db_pool/datastores напрямую
        # (нет api.get_datastores()) - реальный HomeServer достаётся через
        # приватный api._hs, единый источник для всех нижеследующих сторов.
        hs = getattr(api, "_hs", None)
        db_pool = hs.get_datastores().main.db_pool if hs is not None else None

        self.capabilities_store = DeviceCapabilitiesStore(db_pool)
        self.forced_full_state = ForcedFullStateMarkers(db_pool)

        base_url = config["version_gate_base_url"]
        if base_url:
            self.thresholds: Optional[VersionGateThresholds] = VersionGateThresholds(
                base_url=base_url,
                http_get=self._http_get_json,
                ttl_seconds=config["threshold_ttl_seconds"],
                platforms=GATED_PLATFORMS,
            )
        else:
            self.thresholds = None

        # Прокидываем инстанс модуля на HomeServer, т.к. ModuleApi не хранит
        # ссылки на загруженные модули (synapse/app/_base.py: `m = module(...)`
        # нигде не сохраняется). DeviceCapabilitiesRestServlet читает этот
        # атрибут лениво на каждый запрос (не кеширует в своём __init__),
        # потому что в тестовом харнессе (tests/unittest.py HomeserverTestCase)
        # этот код загрузки модулей не прогоняется вообще — там атрибут не
        # появится ни в момент __init__ сервлета, ни позже (см.
        # rest/client/chat_topology.py). В проде порядок другой (модули
        # грузятся раньше, чем строится ClientRestResource), но ленивое
        # чтение работает корректно в обоих случаях.
        #
        # ВАЖНО (Task 5): на самом деле tests/server.py:setup_test_homeserver
        # (используется HomeserverTestCase) ДОЕТ прогоняет hs.config.modules.loaded_modules
        # и инстанцирует модуль с тем же ModuleApi, что и в проде — там
        # api._hs доступен. Комментарий выше относится к отдельному пути
        # построения REST-ресурсов (create_resource_dict), не к module loading.
        if hs is not None:
            hs.liza_chat_topology_sync_gate_module = self
            self.hidden_rooms = HiddenRoomsLookup(
                hs.get_datastores().main, hs.get_storage_controllers().state
            )
        else:
            self.hidden_rooms = None

        if db_pool is not None:
            api.run_as_background_process(
                "chat_topology_sync_gate_schema", self.capabilities_store.ensure_schema
            )
            api.run_as_background_process(
                "chat_topology_forced_full_state_schema",
                self.forced_full_state.ensure_schema,
            )

        # HA: намеренно во ВСЕХ процессах, не через synapse_modules._ha —
        # колбэк инвалидирует per-process кэш HiddenRoomsLookup, побочных
        # эффектов вне процесса у него нет.
        api.register_third_party_rules_callbacks(
            on_new_event=self._on_new_event,
        )

        logger.info(
            "ChatTopologySyncGateModule loaded (enabled=%s, version_gate=%s)",
            self.enabled,
            base_url,
        )

    async def _on_new_event(self, event: Any, state_events: Any) -> None:
        """Инвалидация per-user кэша HiddenRoomsLookup при персисте
        com.liza.chat.topology - см. design doc секция 3 ("Список
        hidden-комнат юзера кэшируется per-user с инвалидацией на персист
        com.liza.chat.topology"). Инвалидируем ВСЕХ текущих join-участников
        комнаты (не только отправителя события) - смена hidden в комнате
        может изменить видимость для любого из них."""
        if self.hidden_rooms is None or event.type != "com.liza.chat.topology":
            return
        try:
            for (event_type, member_id), member_event in state_events.items():
                if event_type != "m.room.member":
                    continue
                if (member_event.content or {}).get("membership") != "join":
                    continue
                self.hidden_rooms.invalidate_user(member_id)
        except Exception:
            logger.exception("chat_topology_sync_gate: cache invalidation failed")

    async def _http_get_json(self, url: str) -> Optional[dict]:
        try:
            client = self._api.http_client
            return await client.get_json(url)
        except Exception:
            logger.warning("chat_topology_sync_gate: version-gate request failed", exc_info=True)
            return None

    async def device_passed_gate(self, device_id: str) -> bool:
        """True, если устройство доказало build >= порога своей платформы.
        Используется патчем sync.py (Task 5) для решения, резать ли hidden-комнаты."""
        if not self.enabled or self.thresholds is None:
            return False
        capability = await self.capabilities_store.get_capability(device_id)
        if capability is None:
            return False
        min_build = await self.thresholds.get_min_build(capability["platform"])
        if min_build is None:
            return False
        return capability["build"] >= min_build
