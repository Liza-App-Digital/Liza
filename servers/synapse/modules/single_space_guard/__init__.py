"""Synapse module: ровно одно главное пространство (root-space) на инстанс.

- on_create_room: блокирует создание второго root-space.
- check_event_allowed: блокирует выход/бан из главного root-space.
- web endpoint GET /_synapse/client/single_space/v1/root -> {exists, room_id, company}.
- web endpoint GET /_synapse/client/single_space/v1/companies?query= -> {companies: [...]}.

Главное пространство = самый ранний (min origin_server_ts m.room.create) среди
root-space (space без входящего m.space.child). Кэшируется после первого
определения (главное неудаляемо).

Конфигурация:

    modules:
      - module: synapse_modules.single_space_guard.SingleSpaceGuardModule
        config:
          backfill_existing: false   # разовый перенос старых чатов (opt-in)
          auto_add_new: true         # авто-добавление новых чатов (дефолт)
          parent_grace_seconds: 60   # сколько ждать m.space.child у комнаты,
                                     # рождённой с m.space.parent
"""

import json
import logging
import time
from typing import Any, Optional

from twisted.web import resource, server

from synapse.api.errors import AuthError, Codes, SynapseError
from synapse.logging.context import run_in_background
from synapse.util.async_helpers import yieldable_gather_results
from synapse.module_api import ModuleApi

from ._guard import (
    apply_space_parent_marker,
    auto_add_delay_ms,
    deduplicate_companies,
    is_auto_add_candidate,
    is_dm_creation,
    is_local_room,
    is_protected_membership_change,
    is_root_space_creation,
    is_space_chunk,
    matches_query,
    root_response,
)

logger = logging.getLogger(__name__)


class SingleSpaceGuardModule:
    def __init__(self, config: dict[str, Any], api: ModuleApi) -> None:
        self._api = api

        # Конфиг-флаги авто-добавления чатов в компанию.
        # backfill_existing (дефолт False): разовый перенос СТАРЫХ чатов - opt-in.
        # auto_add_new (дефолт True): хук на НОВЫЕ чаты - поведение по умолчанию.
        self._backfill_existing = bool(config.get("backfill_existing", False))
        self._auto_add_new = bool(config.get("auto_add_new", True))
        self._parent_grace_ms = int(
            float(config.get("parent_grace_seconds", 60)) * 1000
        )

        # None = ещё не определено / нет root-space; str = кэш главного навсегда.
        self._main_root_space_id: Optional[str] = None

        # Реентрантность backfill: get_main_root_space_id (откуда триггерится
        # backfill) зовётся на каждый запрос к эндпоинтам, параллельные запросы
        # могут запустить _maybe_backfill дважды. Флаг ставится ДО первого await,
        # поэтому в однопоточном reactor второй проход не стартует (иначе оба
        # слали бы дублирующие m.space.child: purge-lock в
        # create_and_send_nonmember_event read-only, писателей не сериализует).
        self._backfill_started = False

        # Sender'ы, создающие DM прямо сейчас (config.is_direct в on_create_room).
        # Снимается первым m.room.create этого sender в _check_event_allowed,
        # чтобы НЕ добавлять DM в компанию (m.direct/is_direct в state ещё нет
        # на момент create). createRoom per-requester сериализован, поэтому
        # пометка снимается своей комнатой.
        self._pending_dm_senders: set[str] = set()

        # TTL-кэш федеративного списка компаний (без учёта query).
        # Список (room-dict-ов) + момент заполнения (monotonic). 0.0 = пуст.
        self._fed_cache: list[dict] = []
        self._fed_cache_at: float = 0.0
        self._FED_CACHE_TTL = 45.0  # сек

        api.register_third_party_rules_callbacks(
            on_create_room=self._on_create_room,
            check_event_allowed=self._check_event_allowed,
        )
        api.register_web_resource(
            "/_synapse/client/single_space/v1/root",
            _RootSpaceResource(api, self),
        )
        api.register_web_resource(
            "/_synapse/client/single_space/v1/companies",
            _CompaniesResource(api, self),
        )
        logger.info("SingleSpaceGuardModule loaded")

    @property
    def is_company(self) -> bool:
        """Инстанс-компания: класс задаёт ``auto_add_new`` (LABA-2539)."""
        return self._auto_add_new

    async def get_main_root_space_id(self) -> Optional[str]:
        """Вернуть room_id главного пространства или None. Кэширует не-None."""
        if self._main_root_space_id is not None:
            return self._main_root_space_id
        room_id = await self._api.run_db_interaction(
            "single_space_guard_find_main",
            self._find_main_root_space_txn,
        )
        if room_id is not None:
            self._main_root_space_id = room_id
            # run_as_background_process (не голый run_in_background) даёт корректный
            # logcontext. Триггерим только отсюда — при первом обращении к
            # эндпоинту, когда HomeServer уже полностью инициализирован. Запуск из
            # __init__ слал бы m.space.child до готовности HS: события персистились,
            # но current-state-кэш не инвалидировался, и дети не появлялись в
            # /hierarchy до рестарта.
            self._api.run_as_background_process(
                "single_space_guard_ensure_public",
                self._ensure_public_directory,
                room_id,
            )
            self._api.run_as_background_process(
                "single_space_guard_backfill",
                self._maybe_backfill,
            )
        return room_id

    @staticmethod
    def _find_main_root_space_txn(txn) -> Optional[str]:
        # root-space: room_type='m.space' и room_id НЕ встречается как state_key
        # в current_state_events с type='m.space.child'. Главный = самый ранний
        # по origin_server_ts события m.room.create.
        txn.execute(
            """
            SELECT rss.room_id
            FROM room_stats_state AS rss
            JOIN current_state_events AS cse_create
              ON cse_create.room_id = rss.room_id
             AND cse_create.type = 'm.room.create'
             AND cse_create.state_key = ''
            JOIN events AS ev
              ON ev.event_id = cse_create.event_id
            WHERE rss.room_type = 'm.space'
              AND NOT EXISTS (
                SELECT 1 FROM current_state_events AS child
                WHERE child.type = 'm.space.child'
                  AND child.state_key = rss.room_id
              )
            ORDER BY ev.origin_server_ts ASC
            LIMIT 1
            """
        )
        row = txn.fetchone()
        return row[0] if row else None

    async def _ensure_public_directory(self, room_id: str) -> None:
        """Синхронизировать публикацию главного пространства в directory.

        Публикуем в directory ТОЛЬКО если комната создана публичной (is_public).
        Приватную компанию (visibility=private, join_rules=invite) не публикуем:
        иначе она попала бы в федеративный поиск вопреки выбору владельца.

        Использует store напрямую, минуя DirectoryHandler, который требует
        Requester с правами модератора. Это допустимо для системного действия
        модуля над собственным root-space.
        """
        try:
            room = await self._api._store.get_room(room_id)
            # get_room -> (is_public, has_auth_chain_index) | None
            if room is None or not room[0]:
                return
            await self._api._store.set_room_is_public(room_id, True)
            logger.info(
                "single_space_guard: main root-space %s published to directory",
                room_id,
            )
        except Exception as e:  # noqa: BLE001
            logger.warning(
                "single_space_guard: ensure_public_directory failed for %s: %s",
                room_id,
                e,
            )

    async def _own_company_entry(self) -> Optional[dict]:
        """Метаданные своего главного пространства для выдачи companies.

        Приватную компанию (is_public=False) в поиск не отдаём: иначе на своём
        homeserver она была бы видна в разделе "Компании" вопреки выбору
        владельца (на чужих серверах её и так скрывает directory, см.
        _ensure_public_directory).
        """
        room_id = await self.get_main_root_space_id()
        if room_id is None:
            return None
        room = await self._api._store.get_room(room_id)
        # get_room -> (is_public, has_auth_chain_index) | None
        if room is None or not room[0]:
            return None
        stats = await self._api.run_db_interaction(
            "single_space_guard_room_stats",
            self._room_stats_txn,
            room_id,
        )
        server_name = self._api.server_name
        return {
            "room_id": room_id,
            "name": stats.get("name"),
            "topic": stats.get("topic"),
            "avatar_url": stats.get("avatar"),
            "num_joined_members": stats.get("joined_members", 0),
            "homeserver": server_name,
            "via": [server_name],
            "is_main_space": True,
        }

    @staticmethod
    def _room_stats_txn(txn, room_id: str) -> dict:
        txn.execute(
            """
            SELECT rss.name, rss.topic, rss.avatar, rsc.joined_members
            FROM room_stats_state AS rss
            LEFT JOIN room_stats_current AS rsc USING (room_id)
            WHERE rss.room_id = ?
            """,
            (room_id,),
        )
        row = txn.fetchone()
        if not row:
            return {}
        return {
            "name": row[0],
            "topic": row[1],
            "avatar": row[2],
            "joined_members": row[3] or 0,
        }

    async def _main_space_creator(self, main_id: str) -> Optional[str]:
        """user_id создателя главного пространства (sender m.room.create)."""
        return await self._api.run_db_interaction(
            "single_space_guard_main_creator",
            self._room_creator_txn,
            main_id,
        )

    @staticmethod
    def _room_creator_txn(txn, room_id: str) -> Optional[str]:
        txn.execute(
            """
            SELECT ev.sender
            FROM current_state_events AS cse
            JOIN events AS ev ON ev.event_id = cse.event_id
            WHERE cse.room_id = ? AND cse.type = 'm.room.create'
              AND cse.state_key = ''
            LIMIT 1
            """,
            (room_id,),
        )
        row = txn.fetchone()
        return row[0] if row else None

    async def _add_room_to_main_space(
        self, room_id: str, main_id: str, sender: str
    ) -> None:
        """Отправить m.space.child(main_id -> room_id) от имени sender. Идемпотентно."""
        try:
            await self._api.create_and_send_event_into_room(
                {
                    "type": "m.space.child",
                    "room_id": main_id,
                    "sender": sender,
                    "state_key": room_id,
                    "content": {"via": [self._api.server_name]},
                }
            )
            logger.info(
                "single_space_guard: auto-added room %s to main space %s",
                room_id,
                main_id,
            )
        except Exception as e:  # noqa: BLE001 — best-effort, не валим создание чата
            logger.warning(
                "single_space_guard: failed to auto-add %s to %s: %s",
                room_id,
                main_id,
                e,
            )

    async def _add_room_if_still_unparented(
        self, room_id: str, main_id: str, sender: str
    ) -> None:
        """Запасной путь для комнаты с m.space.parent: вложить в компанию, если
        ни одно пространство так и не записало на неё m.space.child."""
        has_child = await self._api.run_db_interaction(
            "single_space_guard_has_incoming_child",
            self._has_incoming_child_txn,
            room_id,
        )
        if has_child:
            return
        await self._add_room_to_main_space(room_id, main_id, sender)

    @staticmethod
    def _has_incoming_child_txn(txn, room_id: str) -> bool:
        txn.execute(
            """
            SELECT 1 FROM current_state_events
            WHERE type = 'm.space.child' AND state_key = ?
            LIMIT 1
            """,
            (room_id,),
        )
        return txn.fetchone() is not None

    @staticmethod
    def _create_meta_txn(txn) -> None:
        txn.execute(
            """
            CREATE TABLE IF NOT EXISTS single_space_guard_meta (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """
        )

    async def _maybe_backfill(self) -> None:
        if not self._backfill_existing:
            # Перенос старых чатов отключён конфигом: ничего не читаем/не пишем.
            return
        # Реентрантный guard: check-and-set до первого await атомарен в
        # single-threaded reactor: исключает параллельный второй проход.
        if self._backfill_started:
            return
        self._backfill_started = True
        main_id = await self.get_main_root_space_id()
        if main_id is None:
            # Компании ещё нет: разрешаем повторный проход при следующем старте.
            self._backfill_started = False
            return
        # Схему создаём лениво здесь (а не в __init__), уже в готовом контексте.
        await self._api.run_db_interaction(
            "single_space_guard_create_meta",
            self._create_meta_txn,
        )
        done = await self._api.run_db_interaction(
            "single_space_guard_backfill_flag",
            self._get_meta_txn,
            "backfill_done",
        )
        if done == "1":
            return
        creator = await self._main_space_creator(main_id)
        if creator is None:
            return
        room_ids = await self._api.run_db_interaction(
            "single_space_guard_orphan_rooms",
            self._orphan_rooms_txn,
            main_id,
            self._api.server_name,
        )
        logger.info(
            "single_space_guard: backfill %d orphan rooms into %s",
            len(room_ids),
            main_id,
        )
        for room_id in room_ids:
            await self._add_room_to_main_space(room_id, main_id, creator)
        await self._api.run_db_interaction(
            "single_space_guard_set_backfill_flag",
            self._set_meta_txn,
            "backfill_done",
            "1",
        )

    @staticmethod
    def _get_meta_txn(txn, key: str) -> Optional[str]:
        txn.execute(
            "SELECT value FROM single_space_guard_meta WHERE key = ?", (key,)
        )
        row = txn.fetchone()
        return row[0] if row else None

    @staticmethod
    def _set_meta_txn(txn, key: str, value: str) -> None:
        # ON CONFLICT работает и в SQLite, и в Postgres (синтаксис общий).
        txn.execute(
            """
            INSERT INTO single_space_guard_meta (key, value) VALUES (?, ?)
            ON CONFLICT (key) DO UPDATE SET value = excluded.value
            """,
            (key, value),
        )

    @staticmethod
    def _orphan_rooms_txn(txn, main_id: str, server_name: str) -> list[str]:
        """Локальные не-DM чаты вне любого пространства (кандидаты на перенос).

        Берём комнаты с живыми локальными участниками (local_users_in_room > 0),
        кроме m.space, не сам main и без входящего m.space.child (не вложены ни в
        одно пространство). Фильтр local_users отсекает покинутые/remote/пустые
        комнаты (room_stats_state хранит вообще все известные комнаты). Исключаем
        настоящие DM по account_data m.direct (не по эвристике числа участников/
        имени, которая ложно отсекала маленькие группы).

        Берём только локальные комнаты (room_id оканчивается на :server_name) -
        зарождённые на этом homeserver; remote-комнаты с локальными участниками
        исключаются (1 homeserver = 1 компания). Локальность фильтруем на Python
        через is_local_room: литеральный "%" в SQL LIKE ломается на Postgres,
        т.к. Synapse конвертит "?" в "%s" и psycopg2 трактует "%" как формат.
        """
        # Собираем room_id всех DM из m.direct: content = {other_user: [room_id]}.
        # Парсим JSON на Python (portable для SQLite и Postgres).
        txn.execute(
            "SELECT content FROM account_data WHERE account_data_type = 'm.direct'"
        )
        dm_room_ids: set[str] = set()
        for (content,) in txn.fetchall():
            try:
                mapping = json.loads(content)
            except (TypeError, ValueError):
                continue
            for rooms in mapping.values():
                if isinstance(rooms, list):
                    dm_room_ids.update(r for r in rooms if isinstance(r, str))

        txn.execute(
            """
            SELECT rss.room_id
            FROM room_stats_state AS rss
            JOIN room_stats_current AS rsc USING (room_id)
            WHERE (rss.room_type IS NULL OR rss.room_type <> 'm.space')
              AND rss.room_id <> ?
              AND rsc.local_users_in_room > 0
              AND NOT EXISTS (
                SELECT 1 FROM current_state_events AS child
                WHERE child.type = 'm.space.child'
                  AND child.state_key = rss.room_id
              )
            """,
            (main_id,),
        )
        return [
            room_id
            for (room_id,) in txn.fetchall()
            if room_id not in dm_room_ids and is_local_room(room_id, server_name)
        ]

    def _federation_whitelist(self) -> list[str]:
        """Домены из federation_domain_whitelist. Пусто если whitelist не задан.

        federation_domain_whitelist: None означает "все домены разрешены" —
        в этом режиме для companies мы не обходим весь интернет, возвращаем [].
        Только явно перечисленные домены обходятся для companies-directory.
        """
        # _hs.config — internal API; публичного пути к конфигу через ModuleApi нет.
        wl = self._api._hs.config.federation.federation_domain_whitelist
        if not wl:
            # None = whitelist отключён (все домены разрешены) или пустой dict
            return []
        return list(wl.keys())

    async def _all_federated_companies(self) -> list[dict]:
        """Все главные пространства whitelisted-федераций. TTL-кэш, параллельно.

        query НЕ применяется здесь — фильтрация в get_companies. Best-effort:
        ошибки по каждому домену гасим.
        """
        now = time.monotonic()
        if self._fed_cache_at and (now - self._fed_cache_at) < self._FED_CACHE_TTL:
            return self._fed_cache

        # get_room_list_handler() — internal API через _hs; публичного нет в ModuleApi.
        room_list_handler = self._api._hs.get_room_list_handler()
        domains = self._federation_whitelist()

        async def fetch_domain(domain: str) -> list[dict]:
            try:
                resp = await room_list_handler.get_remote_public_room_list(
                    server_name=domain,
                    limit=50,
                )
            except Exception as e:  # noqa: BLE001 — best-effort по каждой федерации
                logger.warning(
                    "single_space_guard: federation companies from %s failed: %s",
                    domain,
                    e,
                )
                return []
            out: list[dict] = []
            for chunk in resp.get("chunk", []):
                if not is_space_chunk(chunk):
                    continue
                out.append(
                    {
                        "room_id": chunk.get("room_id"),
                        "name": chunk.get("name"),
                        "topic": chunk.get("topic"),
                        "avatar_url": chunk.get("avatar_url"),
                        "num_joined_members": chunk.get("num_joined_members", 0),
                        "homeserver": domain,
                        "via": [domain],
                        "is_main_space": True,
                    }
                )
            return out

        results: list[dict] = []
        if domains:
            # yieldable_gather_results — Twisted-native параллель (defer.gatherResults
            # под капотом), надёжнее asyncio.gather в reactor Synapse.
            per_domain = await yieldable_gather_results(fetch_domain, domains)
            for lst in per_domain:
                results.extend(lst)

        self._fed_cache = results
        self._fed_cache_at = time.monotonic()
        return results

    async def get_companies(self, query: Optional[str]) -> list[dict]:
        """Список компаний: своя + федеративные (из кэша), фильтр по query, дедуп."""
        companies: list[dict] = []
        own = await self._own_company_entry()
        if own is not None and matches_query(own.get("name"), query):
            companies.append(own)
        for c in await self._all_federated_companies():
            if matches_query(c.get("name"), query):
                companies.append(c)
        return deduplicate_companies(companies)

    async def _on_create_room(
        self, requester, config: dict, is_requester_admin: bool
    ) -> None:
        if is_dm_creation(config):
            self._pending_dm_senders.add(requester.user.to_string())
        apply_space_parent_marker(config)
        if not is_root_space_creation(config):
            return
        existing = await self.get_main_root_space_id()
        if existing is not None:
            logger.warning(
                "single_space_guard: blocked second root-space creation "
                "(existing main=%s, requester=%s)",
                existing,
                requester.user.to_string(),
            )
            raise SynapseError(
                403,
                "Главное пространство уже существует на этом сервере.",
                Codes.FORBIDDEN,
            )

    async def _check_event_allowed(
        self, event, state_events
    ) -> tuple[bool, Optional[dict]]:
        membership = (
            event.content.get("membership")
            if event.type == "m.room.member"
            else None
        )
        main_id = await self.get_main_root_space_id()
        if is_protected_membership_change(
            event_type=event.type,
            membership=membership,
            room_id=event.room_id,
            main_root_space_id=main_id,
        ):
            logger.warning(
                "single_space_guard: blocked %s of main root-space %s",
                membership,
                event.room_id,
            )
            return (False, None)

        if event.type == "m.room.create":
            # DM помечен в on_create_room (config.is_direct): снимаем пометку
            # ВСЕГДА (одноразово, независимо от main_id/флагов), иначе при создании
            # DM до появления главного пространства пометка зависла бы и следующая
            # обычная комната этого sender ошибочно считалась бы DM. На create
            # m.direct/is_direct в state ещё нет.
            is_direct = event.sender in self._pending_dm_senders
            self._pending_dm_senders.discard(event.sender)
            if self._auto_add_new and main_id is not None:
                candidate = is_auto_add_candidate(
                    room_type=event.content.get("type"),
                    is_direct=is_direct,
                    has_space_parent=False,
                    is_local=self._api.is_mine(event.sender),
                )
                if candidate and event.room_id != main_id:
                    creator = await self._main_space_creator(main_id)
                    if creator is not None:
                        delay_ms = auto_add_delay_ms(
                            event.content, self._parent_grace_ms
                        )
                        if delay_ms:
                            # Родилась с m.space.parent: связь пишет клиент
                            # со стороны родителя. Компания — только запасной
                            # путь, если он так и не записал m.space.child.
                            self._api.delayed_background_call(
                                delay_ms,
                                self._add_room_if_still_unparented,
                                event.room_id,
                                main_id,
                                creator,
                                desc="single_space_guard_add_unparented",
                            )
                        else:
                            self._api.run_as_background_process(
                                "single_space_guard_add_room",
                                self._add_room_to_main_space,
                                event.room_id,
                                main_id,
                                creator,
                            )
        return (True, None)


class _RootSpaceResource(resource.Resource):
    """GET /_synapse/client/single_space/v1/root -> {exists, room_id, company}."""

    isLeaf = True

    def __init__(self, api: ModuleApi, module: SingleSpaceGuardModule) -> None:
        super().__init__()
        self._api = api
        self._module = module

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        await self._api.get_user_by_req(request)  # требует валидный токен
        room_id = await self._module.get_main_root_space_id()
        self._json(request, root_response(room_id, self._module.is_company))

    def _json(self, request: server.Request, data: dict, status: int = 200) -> None:
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        request.write(json.dumps(data).encode())
        request.finish()

    def _on_errback(self, failure, request: server.Request) -> None:
        if request.finished:
            return
        ex = failure.value
        if isinstance(ex, AuthError):
            self._json(request, {"error": "unauthorized"}, 401)
        elif isinstance(ex, SynapseError):
            self._json(request, {"error": ex.errcode}, ex.code)
        else:
            logger.error("single_space_guard endpoint error: %s", failure)
            self._json(request, {"error": "internal_error"}, 500)


class _CompaniesResource(resource.Resource):
    """GET /_synapse/client/single_space/v1/companies?query= -> {companies: [...]}."""

    isLeaf = True

    def __init__(self, api: ModuleApi, module: SingleSpaceGuardModule) -> None:
        super().__init__()
        self._api = api
        self._module = module

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        await self._api.get_user_by_req(request)  # требует валидный токен
        raw = request.args.get(b"query", [b""])[0]
        query = raw.decode("utf-8", "ignore").strip() or None
        companies = await self._module.get_companies(query)
        self._json(request, {"companies": companies})

    def _json(self, request: server.Request, data: dict, status: int = 200) -> None:
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        request.write(json.dumps(data).encode())
        request.finish()

    def _on_errback(self, failure, request: server.Request) -> None:
        if request.finished:
            return
        ex = failure.value
        if isinstance(ex, AuthError):
            self._json(request, {"error": "unauthorized"}, 401)
        elif isinstance(ex, SynapseError):
            self._json(request, {"error": ex.errcode}, ex.code)
        else:
            logger.error("single_space_guard companies endpoint error: %s", failure)
            self._json(request, {"error": "internal_error"}, 500)
