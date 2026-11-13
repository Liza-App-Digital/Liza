"""stories_membership: автоинвайт по DM-графу + чистка протухших сторисов.

При join в DM-комнату взаимно инвайтит участников в сторис-комнаты друг друга,
чтобы сторисы доставлялись родным механизмом Matrix (вкл. федерацию).
Периодически redact-ит события с истёкшим com.liza.story.expires_ts.
"""

import json
import logging
import time
from typing import Any

from twisted.internet import reactor

from synapse_modules._ha import is_effects_process, register_on_new_event_once

from ._logic import (
    LEGACY_STORIES_ROOM_NAME,
    STORIES_TAG,
    dm_pairs_from_direct,
    is_direct_membership_join,
    is_direct_membership_leave,
    is_hidden_room,
    is_local_user,
    is_reachable_server,
    server_name_of,
    stories_room_name,
    story_is_expired,
    story_notify_rule_id,
)

logger = logging.getLogger(__name__)


class StoriesMembershipModule:
    @staticmethod
    def parse_config(config: dict[str, Any]) -> dict[str, Any]:
        return {
            "cleanup_interval_minutes": int(
                config.get("cleanup_interval_minutes", 30)
            ),
            "story_ttl_hours": int(config.get("story_ttl_hours", 24)),
            # localpart-ы AI-ботов, которых не подписываем на сторисы.
            # Работает и для ботов на другом инстансе (@liza на prod-synapse).
            "ai_bot_localparts": list(
                config.get("ai_bot_localparts", ["liza"])
            ),
        }

    def __init__(self, config: dict[str, Any], api: Any) -> None:
        self._api = api
        self._cleanup_interval = config["cleanup_interval_minutes"] * 60
        self._ttl_hours = config["story_ttl_hours"]
        self._ai_bot_localparts = set(config["ai_bot_localparts"])

        # store нужен напрямую для add_push_rule (см. _mute_room_for_local_user) -
        # ModuleApi не даёт публичного метода СОЗДАНИЯ room-push-rule (только
        # set_push_rule_action для УЖЕ существующего правила). Тот же паттерн
        # доступа к store, что в chat_topology_sync_gate/__init__.py.
        hs = getattr(api, "_hs", None)
        self._store = hs.get_datastores().main if hs is not None else None

        # federation_domain_whitelist: не ходим за профилями на серверы, к
        # которым федерация запрещена (напр. погашенный инстанс, убранный из
        # конфига). None = whitelist не настроен -> достижимы все.
        self._federation_whitelist = getattr(
            getattr(getattr(hs, "config", None), "federation", None),
            "federation_domain_whitelist",
            None,
        )

        # HA: подписки/отписки выполняет один процесс инстанса (см. synapse_modules._ha).
        register_on_new_event_once(api, self._on_new_event)
        # HA: модуль грузится в каждый процесс (main и все воркеры). Чистку и
        # разовые backfill'ы гоняем в одном процессе — писателе push_rules (мьют
        # идёт через add_push_rule, вне писателя он падает), иначе N воркеров
        # делали бы одну и ту же работу N раз. См. synapse_modules._ha.
        if not is_effects_process(api):
            return
        # Периодическую чистку планируем только в боевом reactor.
        # В юнит-тестах reactor не запускается, callLater копится безвредно.
        reactor.callLater(self._cleanup_interval, self._run_cleanup_safe)
        # Разовый backfill существующих DM (до деплоя модуля хук не срабатывал).
        # run_as_background_process не блокирует __init__ и даёт корректный logcontext.
        api.run_as_background_process(
            "stories_membership_backfill", self.backfill_existing_dms
        )
        # Постфактум-мьют участников stories-комнат, созданных ДО деплоя
        # серверного dont_notify (инцидент на prod 2026-07-02, см.
        # _mute_room_for_local_user). Идемпотентно: add_push_rule - upsert по
        # (user_name, rule_id), повторный запуск на каждый рестарт безвреден.
        api.run_as_background_process(
            "stories_membership_mute_existing", self.mute_existing_stories_rooms
        )
        # Постфактум-переименование сторис-комнат, созданных ДО уникализации
        # имени (2026-07-04, все назывались просто "Stories" - неразличимо
        # в админке/логах). Идемпотентно: SQL сам не возвращает уже
        # переименованные комнаты (см. _find_stories_rooms_to_rename_txn),
        # безопасно гонять на каждый рестарт.
        api.run_as_background_process(
            "stories_membership_rename_existing", self.rename_existing_stories_rooms
        )

    async def ensure_stories_room(self, user_id: str) -> str:
        """Возвращает room_id сторис-комнаты юзера, создавая лениво.

        Идемпотентно: room_id запоминается в account_data владельца под
        тегом com.liza.stories. Создаём только для локальных юзеров.
        """
        existing = await self._api.account_data_manager.get_global(
            user_id, STORIES_TAG
        )
        if existing and existing.get("room_id"):
            return existing["room_id"]

        room_id, _ = await self._api.create_room(
            user_id,
            {
                "preset": "private_chat",
                "name": stories_room_name(user_id),
                "visibility": "private",
                "creation_content": {
                    "com.liza.stories": True,
                    "com.liza.chat.type": "stories",
                },
                # PL-гейт на com.liza.chat.topology: без этого любой
                # приглашённый в комнату участник (state_default=50 по
                # умолчанию) мог бы сам снять hidden через обычный PUT
                # state - см. design doc, секция 1 "Контроль прав на
                # изменение видимости". Финальный whole-branch review
                # (I1) отметил отсутствие этого override здесь как
                # реальную дыру: клиент (Task 10) его ставит, а
                # server-side создание комнаты - нет.
                "power_level_content_override": {
                    "events": {"com.liza.chat.topology": 100}
                },
                "initial_state": [
                    {
                        "type": "com.liza.chat.topology",
                        "state_key": "",
                        "content": {"hidden": True},
                    }
                ],
            },
        )
        await self._api.account_data_manager.put_global(
            user_id, STORIES_TAG, {"room_id": room_id}
        )
        return room_id

    async def _is_ai_user(self, user_id: str) -> bool:
        """Проверить, является ли юзер AI-ботом (не подписывается на сторисы).

        Два признака:
        1. localpart в списке известных AI-ботов (liza) - работает
           и для УДАЛЁННЫХ ботов (они живут на другом инстансе, например @liza
           на prod-synapse, и их роль через локальный account_data не прочитать).
        2. роль ai в user_roles (account_data) - для локальных юзеров с ролью ai,
           заведённых не под стандартным именем.
        """
        localpart = user_id.split(":", 1)[0].lstrip("@")
        if localpart in self._ai_bot_localparts:
            return True
        if not self._api.is_mine(user_id):
            return False
        try:
            data = await self._api.account_data_manager.get_global(
                user_id, "com.liza.user_role"
            )
        except Exception:
            return False
        return bool(data) and data.get("role") == "ai"

    async def subscribe_pair(self, user_a: str, user_b: str) -> None:
        """Взаимный инвайт: B в сторис-комнату A и A в сторис-комнату B.

        Сторис-комнату создаём только у ЛОКАЛЬНОГО владельца (нельзя создать
        комнату за удалённого юзера). Удалённого target инвайтим с
        remote_room_hosts, авто-джойн делает его клиент.
        AI-боты (роль ai) пропускаются - сторисы только для людей-контактов.
        """
        if await self._is_ai_user(user_a) or await self._is_ai_user(user_b):
            logger.debug(
                "stories_membership: subscribe_pair(%s, %s) пропущен - один из юзеров AI",
                user_a, user_b,
            )
            return
        await self._invite_into_owner_room(owner=user_a, guest=user_b)
        await self._invite_into_owner_room(owner=user_b, guest=user_a)

    async def unsubscribe_pair(self, user_a: str, user_b: str) -> None:
        """LABA-1970 AC-7: снять взаимную подписку на сторисы при удалении DM.

        Симметрично subscribe_pair: удаляет каждого из встречной сторис-комнаты
        (kick от лица владельца). Выход из аудитории = ни показа, ни пуша, без
        чистки push-rules (правило на комнату, где юзер уже не участник, не
        матчит — BulkPushRuleEvaluator оценивает push только для участников).
        """
        await self._leave_owner_room(owner=user_a, guest=user_b)
        await self._leave_owner_room(owner=user_b, guest=user_a)

    async def _leave_owner_room(self, owner: str, guest: str) -> None:
        """Убрать guest из сторис-комнаты owner (kick от лица owner-создателя).

        Комнату НЕ создаём (в отличие от _invite_into_owner_room): читаем room_id
        из account_data владельца, нет записи — подписки и не было, выходим.
        """
        if not self._api.is_mine(owner):
            return
        try:
            data = await self._api.account_data_manager.get_global(
                owner, STORIES_TAG
            )
        except Exception:
            return
        room_id = data.get("room_id") if data else None
        if not room_id:
            return
        try:
            await self._api.update_room_membership(owner, guest, room_id, "leave")
        except Exception as e:  # не участник / гонка / федерация - не критично
            logger.debug(
                "stories_membership: unsubscribe %s из %s пропущен: %s",
                guest, room_id, e,
            )

    async def backfill_existing_dms(self) -> None:
        """Разовый backfill: подписать все существующие DM-пары на сторисы.

        Вызывается при старте модуля через run_as_background_process. Идемпотентен:
        subscribe_pair ловит повторные инвайты через except. Деградирует gracefully:
        если run_db_interaction упрётся, логируем и уходим (новые DM всё равно
        обрабатываются хуком on_new_event).
        """
        try:
            pairs: list[tuple[str, str]] = await self._api.run_db_interaction(
                "stories_membership_backfill_find_dms",
                self._find_dm_pairs_txn,
                self._api.server_name,
            )
        except Exception:
            logger.exception("stories_membership: backfill не смог считать DM-пары из БД")
            return

        # Отсекаем пары с погашенными серверами: старые записи в m.direct
        # переживают отключение инстанса, и без фильтра каждый старт даёт
        # таймауты на запросах профиля (инцидент 2026-07-24, dev-стенд).
        server_name = self._api.server_name
        whitelist = self._federation_whitelist
        reachable_pairs = [
            (a, b)
            for a, b in pairs
            if is_reachable_server(a, server_name, whitelist)
            and is_reachable_server(b, server_name, whitelist)
        ]
        skipped = len(pairs) - len(reachable_pairs)
        if skipped:
            logger.info(
                "stories_membership: backfill пропустил %d пар с недостижимыми"
                " серверами (нет в federation_domain_whitelist)",
                skipped,
            )
        pairs = reachable_pairs

        federated = sum(
            1
            for a, b in pairs
            if not self._api.is_mine(a) or not self._api.is_mine(b)
        )
        logger.info(
            "stories_membership: backfill нашёл %d DM-пар для подписки"
            " (из них %d федеративных)",
            len(pairs),
            federated,
        )
        failed = 0
        for user_a, user_b in pairs:
            try:
                await self.subscribe_pair(user_a, user_b)
            except Exception:
                # sleep(0) после проглоченного исключения выполнялся на уже
                # завершённом logcontext -> "Re-starting finished log context"
                # (тот же дефект, что был в cleanup; на проде 2026-07-24 дал
                # 70 warning'ов за 15 минут после старта).
                failed += 1
                logger.exception(
                    "stories_membership: backfill subscribe_pair(%s, %s) упал",
                    user_a, user_b,
                )
                continue
            # Не блокируем reactor между УСПЕШНЫМИ инвайтами.
            await self._sleep_zero()

        if failed:
            logger.warning(
                "stories_membership: backfill — %d из %d пар не подписаны",
                failed, len(pairs),
            )

        logger.info("stories_membership: backfill завершён")

    async def mute_existing_stories_rooms(self) -> None:
        """Постфактум-мьют: room-level dont_notify для участников ЛЮБЫХ
        hidden-по-топологии комнат (is_hidden_room - не только "stories",
        любая будущая скрытая категория заведённая тем же механизмом
        com.liza.chat.topology), созданных до деплоя серверного мьюта в
        _invite_into_owner_room.

        Идемпотентно (add_push_rule - upsert, плюс явная проверка перед
        вызовом - см. _mute_room_for_local_user), безопасно гонять на каждый
        рестарт. Владельца комнаты (создателя) не мьютим - это его собственная
        лента, ему push о своих же событиях не грозит (сторис создаёт он сам).
        """
        if self._store is None:
            return
        try:
            memberships: list[tuple[str, str, str]] = await self._api.run_db_interaction(
                "stories_membership_mute_existing_find",
                self._find_stories_room_members_txn,
            )
        except Exception:
            logger.exception(
                "stories_membership: postfix-mute не смог считать участников из БД"
            )
            return

        logger.info(
            "stories_membership: postfix-mute нашёл %d (room, user) пар", len(memberships)
        )
        muted = 0
        for room_id, user_id, creator in memberships:
            if user_id == creator or not self._api.is_mine(user_id):
                continue
            await self._mute_room_for_local_user(user_id, room_id)
            # LABA-1970 backfill: дать существующим зрителям override-правило
            # пуша (enabled по умолчанию), иначе тумблер у них мёртв
            # (setPushRuleEnabled на несуществующем rule_id = M_NOT_FOUND).
            # Только создаёт правило — события не переигрывает, сторма нет;
            # пуш пойдёт лишь на следующую новую сторис.
            await self._ensure_story_notify_rule(user_id, room_id)
            muted += 1
            await self._sleep_zero()

        logger.info("stories_membership: postfix-mute завершён, обработано %d", muted)

    @staticmethod
    def _find_stories_room_members_txn(txn) -> list[tuple[str, str, str]]:
        """Собрать (room_id, member_user_id, creator_user_id) для всех
        hidden-по-топологии комнат (is_hidden_room - НЕ завязан на конкретный
        тип "stories", покрывает любую будущую скрытую категорию, заведённую
        тем же механизмом com.liza.chat.topology), по каждому join/invite
        участнику, кроме leave/ban."""
        txn.execute(
            """
            SELECT cse.room_id, ej.json
            FROM current_state_events cse
            JOIN event_json ej ON ej.event_id = cse.event_id
            WHERE cse.type = 'm.room.create' AND cse.state_key = ''
            """
        )
        create_contents: dict[str, tuple[dict, str]] = {}  # room_id -> (content, sender)
        for room_id, raw_json in txn.fetchall():
            try:
                event = json.loads(raw_json)
                content = event.get("content") or {}
            except (TypeError, ValueError):
                continue
            create_contents[room_id] = (content, event.get("sender", ""))

        if not create_contents:
            return []

        # Явный com.liza.chat.topology state для всех кандидатов разом -
        # is_hidden_room приоритизирует его над legacy-дефолтом по типу.
        placeholders = ",".join("?" * len(create_contents))
        txn.execute(
            f"""
            SELECT cse.room_id, ej.json
            FROM current_state_events cse
            JOIN event_json ej ON ej.event_id = cse.event_id
            WHERE cse.type = 'com.liza.chat.topology' AND cse.state_key = ''
            AND cse.room_id IN ({placeholders})
            """,
            tuple(create_contents.keys()),
        )
        topology_contents: dict[str, dict] = {}
        for room_id, raw_json in txn.fetchall():
            try:
                event = json.loads(raw_json)
                topology_contents[room_id] = event.get("content") or {}
            except (TypeError, ValueError):
                continue

        hidden_rooms: dict[str, str] = {}  # room_id -> creator
        for room_id, (create_content, sender) in create_contents.items():
            if is_hidden_room(create_content, topology_contents.get(room_id)):
                hidden_rooms[room_id] = sender

        if not hidden_rooms:
            return []

        result: list[tuple[str, str, str]] = []
        placeholders = ",".join("?" * len(hidden_rooms))
        txn.execute(
            f"""
            SELECT room_id, state_key FROM current_state_events
            WHERE type = 'm.room.member' AND membership IN ('join', 'invite')
            AND room_id IN ({placeholders})
            """,
            tuple(hidden_rooms.keys()),
        )
        for room_id, member_id in txn.fetchall():
            result.append((room_id, member_id, hidden_rooms[room_id]))
        return result

    async def rename_existing_stories_rooms(self) -> None:
        """Постфактум-переименование: сторис-комнаты, созданные до
        уникализации имени (2026-07-04), все назывались просто "Stories" -
        неразличимо в админке/логах. Переименовывает в
        f"{STORIES_ROOM_NAME_PREFIX}{localpart владельца}" от лица creator
        (m.room.create.sender), у которого есть права на m.room.name.

        Идемпотентно: _find_stories_rooms_to_rename_txn сам не возвращает
        уже переименованные комнаты, безопасно гонять на каждый рестарт.
        """
        try:
            rooms: list[tuple[str, str | None, str]] = (
                await self._api.run_db_interaction(
                    "stories_membership_find_rooms_to_rename",
                    self._find_stories_rooms_to_rename_txn,
                )
            )
        except Exception:
            logger.exception(
                "stories_membership: rename не смог считать комнаты из БД"
            )
            return

        logger.info(
            "stories_membership: rename нашёл %d комнат с легаси-именем",
            len(rooms),
        )
        renamed = 0
        for room_id, _current_name, creator in rooms:
            try:
                await self._api.create_and_send_event_into_room(
                    {
                        "type": "m.room.name",
                        "room_id": room_id,
                        "sender": creator,
                        "state_key": "",
                        "content": {"name": stories_room_name(creator)},
                    }
                )
                renamed += 1
            except Exception:
                # См. backfill_existing_dms: sleep(0) на завершённом
                # logcontext после проглоченного исключения.
                logger.debug(
                    "stories_membership: rename %s пропущен", room_id,
                )
                continue
            await self._sleep_zero()

        logger.info("stories_membership: rename завершён, обработано %d", renamed)

    @staticmethod
    def _find_stories_rooms_to_rename_txn(
        txn,
    ) -> list[tuple[str, str | None, str]]:
        """Собрать (room_id, current_name, creator) для сторис-комнат,
        всё ещё называющихся легаси-именем "Stories" (или не имеющих
        m.room.name state вообще). Использует тот же критерий "это
        сторис-комната", что и _find_expired_stories_txn: creation_content
        с com.liza.stories=true."""
        txn.execute(
            """
            SELECT cse.room_id, ev.sender, ej.json
            FROM current_state_events AS cse
            JOIN events AS ev ON ev.event_id = cse.event_id
            JOIN event_json AS ej ON ej.event_id = cse.event_id
            WHERE cse.type = 'm.room.create'
              AND cse.state_key = ''
            """
        )
        stories_rooms: dict[str, str] = {}  # room_id -> creator
        for room_id, sender, raw_json in txn.fetchall():
            try:
                content = json.loads(raw_json).get("content") or {}
            except (TypeError, ValueError):
                continue
            if content.get("com.liza.stories"):
                stories_rooms[room_id] = sender

        if not stories_rooms:
            return []

        placeholders = ",".join("?" * len(stories_rooms))
        txn.execute(
            f"""
            SELECT cse.room_id, ej.json
            FROM current_state_events cse
            JOIN event_json ej ON ej.event_id = cse.event_id
            WHERE cse.type = 'm.room.name' AND cse.state_key = ''
              AND cse.room_id IN ({placeholders})
            """,
            tuple(stories_rooms.keys()),
        )
        current_names: dict[str, str] = {}
        for room_id, raw_json in txn.fetchall():
            try:
                event = json.loads(raw_json)
                current_names[room_id] = (event.get("content") or {}).get("name")
            except (TypeError, ValueError):
                continue

        result: list[tuple[str, str | None, str]] = []
        for room_id, creator in stories_rooms.items():
            name = current_names.get(room_id)
            if name is None or name == LEGACY_STORIES_ROOM_NAME:
                result.append((room_id, name, creator))
        return result

    @staticmethod
    def _find_dm_pairs_txn(
        txn, server_name: str
    ) -> list[tuple[str, str]]:
        """txn-функция: собрать уникальные DM-пары из account_data.

        Читает m.direct из account_data (portable SELECT без LIKE для совместимости
        SQLite/Postgres - тот же подход что в single_space_guard._orphan_rooms_txn).

        Подписывает пару, если (1) хотя бы один участник ЛОКАЛЬНЫЙ и (2) локальный
        участник реально состоит (join) хотя бы в одной из комнат контрагента из
        m.direct. Проверка через local_current_membership, а НЕ через is_local_room:
        для кросс-федеративного DM комната лежит на одном из двух серверов, и на
        сервере-НЕ-владельце комнаты старый фильтр is_local_room выбрасывал пару
        целиком - локальный владелец не инвайтил удалённого гостя, и разные
        федерации не видели сторисы друг друга. local_current_membership содержит
        membership локальных юзеров в ЛЮБЫХ комнатах, включая федеративные.
        """
        txn.execute(
            "SELECT user_id, content FROM account_data"
            " WHERE account_data_type = 'm.direct'"
        )
        rows = txn.fetchall()

        seen: set[tuple[str, str]] = set()
        for user_id, content_raw in rows:
            try:
                mapping = json.loads(content_raw)
            except (TypeError, ValueError):
                continue
            if not isinstance(mapping, dict):
                continue
            for pair in dm_pairs_from_direct(user_id, mapping):
                # Подписывать некого, если оба участника удалённые:
                # _invite_into_owner_room для не-локального owner делает ранний
                # return, инвайтов не будет.
                local_members = [
                    u for u in pair if is_local_user(u, server_name)
                ]
                if not local_members:
                    continue
                # Комнаты контрагента из m.direct текущего владельца строки.
                other = pair[0] if pair[1] == user_id else pair[1]
                rooms = mapping.get(other, [])
                if not isinstance(rooms, list):
                    rooms = []
                rooms = [r for r in rooms if isinstance(r, str)]
                if not rooms:
                    # Осиротевшая m.direct-запись без комнат - инвайтить не по чему.
                    continue
                # Подтверждаем, что локальный участник реально join хотя бы в
                # одной из комнат. IN (?) с плейсхолдерами (не LIKE/% - psycopg2).
                placeholders_u = ",".join("?" for _ in local_members)
                placeholders_r = ",".join("?" for _ in rooms)
                txn.execute(
                    "SELECT 1 FROM local_current_membership"
                    " WHERE membership = 'join'"
                    f" AND user_id IN ({placeholders_u})"
                    f" AND room_id IN ({placeholders_r})"
                    " LIMIT 1",
                    (*local_members, *rooms),
                )
                if txn.fetchone() is not None:
                    seen.add(pair)

        return list(seen)

    async def _invite_into_owner_room(self, owner: str, guest: str) -> None:
        if not self._api.is_mine(owner):
            # Комнату владельца создаёт его собственный сервер.
            return
        room_id = await self.ensure_stories_room(owner)
        remote_hosts = (
            None if self._api.is_mine(guest) else [server_name_of(guest)]
        )
        # Тишина ДО инвайта: стандартный push (m.rule.invite_for_me) уходит
        # немедленно на сервере, а клиентский dontNotify (stories_extension.dart
        # autoJoinStoryInvites) ставится только постфактум и только если
        # приложение вообще открыто - без этого массовый backfill рассылает
        # push всем существующим DM-контактам (инцидент на prod 2026-07-02:
        # 84 комнаты, сотни push за первые минуты, пока не остановили sygnal).
        # Только для ЛОКАЛЬНЫХ guest - удалённый sever должен заглушить сам.
        if self._api.is_mine(guest):
            await self._mute_room_for_local_user(guest, room_id)
            # LABA-1970: override-правило пуша на публикацию сторис РЯДОМ с мьютом
            # (дефолт "включено"). Ставим только для локального зрителя - его
            # сервер владеет его push-rules; удалённый зритель ставит сам у себя.
            await self._ensure_story_notify_rule(guest, room_id)
        try:
            await self._api.update_room_membership(
                owner, guest, room_id, "invite",
                remote_room_hosts=remote_hosts,
            )
        except Exception as e:  # уже участник / гонка - не критично
            logger.debug(
                "stories_membership: invite %s -> %s skipped: %s",
                guest, room_id, e,
            )

    async def _mute_room_for_local_user(self, user_id: str, room_id: str) -> None:
        """Ставит room-level push rule dont_notify для user_id в room_id.

        Эквивалент клиентского Room.setPushRuleState(dontNotify) - тот же
        rule_id ("global/room/{room_id}") и формат conditions, что и в
        PushRuleRestServlet._rule_tuple_from_request_object при template=="room"
        (servers/synapse/src/synapse/rest/client/push_rule.py), чтобы клиент,
        открыв приложение позже, не создавал дублирующее правило.

        Проверяем наличие правила ПЕРЕД вызовом add_push_rule: add_push_rule
        безусловно пишет новую строку в append-only push_rules_stream при
        каждом вызове (_upsert_push_rule_txn -> _insert_push_rules_update_txn
        всегда с update_stream=True), даже если содержимое правила не
        изменилось - таблица push_rules сама честный upsert и не растёт, а
        push_rules_stream растёт на каждый рестарт модуля (backfill и
        postfix-mute идемпотентны и перепроверяют все комнаты заново). Без
        этой проверки push_rules_stream накопил бы ~400 лишних строк на
        каждый рестарт Synapse без единого реального изменения состояния.
        """
        if self._store is None:
            return
        try:
            existing = await self._store.db_pool.simple_select_one_onecol(
                table="push_rules",
                keyvalues={"user_name": user_id, "rule_id": f"global/room/{room_id}"},
                retcol="id",
                allow_none=True,
                desc="stories_membership_check_mute_rule",
            )
            if existing is not None:
                return
            await self._store.add_push_rule(
                user_id=user_id,
                rule_id=f"global/room/{room_id}",
                priority_class=3,  # PRIORITY_CLASS_MAP["room"]
                conditions=[
                    {"kind": "event_match", "key": "room_id", "pattern": room_id}
                ],
                actions=["dont_notify"],
            )
        except Exception:
            logger.exception(
                "stories_membership: не удалось замьютить %s для %s", room_id, user_id
            )

    async def _ensure_story_notify_rule(self, user_id: str, room_id: str) -> None:
        """LABA-1970: override-правило пуша на публикацию сторис для зрителя.

        conditions матчат ТОЛЬКО стори-событие в конкретной сторис-комнате:
        type == m.room.message И room_id == этой комнаты. override (класс 5)
        перекрывает room-level dont_notify (класс 3, _mute_room_for_local_user)
        именно для стори-события; служебные события (m.room.member/m.reaction/
        m.room.redaction) не матчат type=m.room.message и остаются заглушёнными
        мьютом. `.m.rule.master` — тоже override, но prepend-first → при
        включённом "Отключить все" короткое замыкание, стори-пуша нет.

        Создаётся enabled (дефолт "включено"): тумблер выключается клиентом через
        setPushRuleEnabled. Проверка существования ПЕРЕД add_push_rule — как в
        _mute_room_for_local_user: append-only push_rules_stream не должен расти
        на рестартах (backfill/postfix-mute перепроверяют все комнаты заново).
        """
        if self._store is None:
            return
        rule_id = story_notify_rule_id(room_id)
        try:
            existing = await self._store.db_pool.simple_select_one_onecol(
                table="push_rules",
                keyvalues={"user_name": user_id, "rule_id": rule_id},
                retcol="id",
                allow_none=True,
                desc="stories_membership_check_story_notify_rule",
            )
            if existing is not None:
                return
            await self._store.add_push_rule(
                user_id=user_id,
                rule_id=rule_id,
                priority_class=5,  # PRIORITY_CLASS_MAP["override"]
                conditions=[
                    {
                        "kind": "event_match",
                        "key": "type",
                        "pattern": "m.room.message",
                    },
                    {"kind": "event_match", "key": "room_id", "pattern": room_id},
                ],
                actions=["notify", {"set_tweak": "sound", "value": "default"}],
            )
        except Exception:
            logger.exception(
                "stories_membership: не удалось создать story-notify правило"
                " %s для %s",
                room_id,
                user_id,
            )

    async def _on_new_event(self, event: Any, state_events: Any) -> None:
        content = dict(getattr(event, "content", {}) or {})
        # Игнорируем membership-события в САМИХ скрытых сторис-комнатах: иначе наш
        # же kick (отписка) или авто-джойн зрителя рекурсивно триггерил бы
        # subscribe/unsubscribe в НЕ той комнате (leave в сторис-комнате с 2
        # участниками выглядит как DM-leave по фолбэку len<=2). Реагируем только
        # на membership в обычных DM.
        if self._event_room_is_hidden(state_events):
            return
        is_direct = bool(content.get("is_direct")) or self._room_is_direct(
            state_events
        )
        if is_direct_membership_join(event.type, content, is_direct):
            joined_user = event.state_key
            others = self._other_members(state_events, joined_user)
            for other in others:
                await self.subscribe_pair(joined_user, other)
            return
        # LABA-1970 AC-7: выход/удаление DM -> снять подписку на сторисы, чтобы
        # "удалённый" контакт не звенел (override-правило enabled по умолчанию).
        if is_direct_membership_leave(event.type, content, is_direct):
            left_user = event.state_key
            # ГЕЙТ: отписываем ТОЛЬКО из настоящего DM (комната в m.direct
            # покидающего), а не из ЛЮБОЙ приватной комнаты с 2 участниками.
            # Иначе ban/выход из НЕсвязанной 2-местной комнаты порвал бы
            # легитимную сторис-подписку по действующему DM той же пары
            # (fallback len<=2 не различает DM и обычную 2-местную комнату).
            room_id = getattr(event, "room_id", None)
            if not await self._room_is_registered_dm(left_user, room_id):
                return
            others = self._other_members(state_events, left_user)
            for other in others:
                await self.unsubscribe_pair(left_user, other)

    async def _room_is_registered_dm(self, user_id: str, room_id: Any) -> bool:
        """True, если room_id числится DM в m.direct пользователя user_id.

        Дискриминатор настоящего DM vs обычной 2-местной приватной комнаты (см.
        гейт отписки). Дешёвое чтение account_data, без DB-скана. Локального
        user_id проверяем; удалённый — не наш, m.direct недоступен -> False
        (его сторону обслуживает его сервер).
        """
        if not room_id or not self._api.is_mine(user_id):
            return False
        try:
            direct = await self._api.account_data_manager.get_global(
                user_id, "m.direct"
            )
        except Exception:
            return False
        if not isinstance(direct, dict):
            return False
        for rooms in direct.values():
            if isinstance(rooms, list) and room_id in rooms:
                return True
        return False

    def _event_room_is_hidden(self, state_events: Any) -> bool:
        """True, если комната события скрыта по топологии (сторис/любая hidden).

        Читает m.room.create + com.liza.chat.topology из state_events, тем же
        предикатом is_hidden_room, что и postfix-mute. Нужно, чтобы не трактовать
        membership-события внутри самих сторис-комнат как DM-подписку/отписку.
        """
        create_content: dict | None = None
        topology_content: dict | None = None
        try:
            for (t, state_key), ev in state_events.items():
                if state_key != "":
                    continue
                if t == "m.room.create":
                    create_content = ev.content or {}
                elif t == "com.liza.chat.topology":
                    topology_content = ev.content or {}
        except Exception:
            return False
        return is_hidden_room(create_content, topology_content)

    def _room_is_direct(self, state_events: Any) -> bool:
        # is_direct прилетает на самом m.room.member; этот fallback оставлен
        # на случай, когда флага нет, но в комнате ровно 2 участника.
        try:
            members = [
                k for (t, k) in state_events.keys() if t == "m.room.member"
            ]
            return len(members) <= 2
        except Exception:
            return False

    def _other_members(self, state_events: Any, exclude: str) -> list[str]:
        result = []
        try:
            for (t, state_key), ev in state_events.items():
                if t != "m.room.member" or state_key == exclude:
                    continue
                if (ev.content or {}).get("membership") == "join":
                    result.append(state_key)
        except Exception:
            pass
        return result

    def _run_cleanup_safe(self) -> None:
        try:
            self._api.run_as_background_process(
                "stories_membership_cleanup", self._cleanup_expired
            )
        except Exception:
            logger.exception("stories_membership: cleanup scheduling failed")
        finally:
            reactor.callLater(self._cleanup_interval, self._run_cleanup_safe)

    async def _cleanup_expired(self) -> None:
        # Запускает раунд чистки с текущим временем.
        await self._cleanup_round()

    async def _cleanup_round(self) -> None:
        await self._cleanup_round_with_now(int(time.time() * 1000))

    async def _cleanup_round_with_now(self, now_ms: int) -> None:
        """Найти и redact-ировать все протухшие сторис-события.

        Использует run_db_interaction для поиска через реальные таблицы Synapse:
        events, event_json, current_state_events. sender берётся из самого
        события (автор сториса), а не из фиктивного @stories-аккаунта.
        """
        try:
            expired: list[tuple[str, str, str]] = (
                await self._api.run_db_interaction(
                    "stories_membership_find_expired",
                    self._find_expired_stories_txn,
                    now_ms,
                )
            )
        except Exception:
            logger.exception("stories_membership: не удалось считать протухшие сторисы из БД")
            return

        logger.debug(
            "stories_membership: cleanup нашёл %d протухших сторисов", len(expired)
        )
        failed = 0
        for room_id, event_id, sender in expired:
            try:
                await self._api.create_and_send_event_into_room(
                    {
                        "type": "m.room.redaction",
                        "room_id": room_id,
                        "sender": sender,
                        "redacts": event_id,
                        "content": {},
                    }
                )
            except Exception:
                # Федеративная комната может быть недоступна. sleep(0) после
                # упавшего redact выполнялся на уже завершённом logcontext ->
                # "Re-starting finished log context" тысячами (инцидент
                # 2026-07-23, 3248 повторов на одном cleanup-id).
                failed += 1
                logger.debug(
                    "stories_membership: redact %s в %s упал, пропускаем",
                    event_id, room_id,
                )
                continue
            # Не блокируем reactor между УСПЕШНЫМИ redact-ами.
            await self._sleep_zero()

        if failed:
            logger.warning(
                "stories_membership: cleanup — %d из %d redact-ов не прошли",
                failed, len(expired),
            )

    @staticmethod
    def _find_expired_stories_txn(
        txn, now_ms: int
    ) -> list[tuple[str, str, str]]:
        """txn-функция: собрать протухшие сторис-события.

        Возвращает list[(room_id, event_id, sender)] для всех m.room.message
        в сторис-комнатах, у которых com.liza.story.expires_ts < now_ms.

        Алгоритм двухшаговый (portable SQLite + Postgres, без LIKE):
        1. Найти сторис-комнаты: current_state_events JOIN events JOIN event_json
           где type='m.room.create', content содержит com.liza.stories - фильтр
           на Python через json.loads (LIKE с % ломается через psycopg2).
        2. Выбрать m.room.message из найденных комнат, фильтровать expires_ts
           на Python через story_is_expired.
        """
        # Шаг 1: найти сторис-комнаты через событие m.room.create.
        txn.execute(
            """
            SELECT cse.room_id, ej.json
            FROM current_state_events AS cse
            JOIN events AS ev ON ev.event_id = cse.event_id
            JOIN event_json AS ej ON ej.event_id = cse.event_id
            WHERE cse.type = 'm.room.create'
              AND cse.state_key = ''
            """
        )
        stories_rooms: set[str] = set()
        for room_id, raw_json in txn.fetchall():
            try:
                ev = json.loads(raw_json)
                content = ev.get("content") or {}
                if content.get("com.liza.stories"):
                    stories_rooms.add(room_id)
            except (TypeError, ValueError):
                continue

        if not stories_rooms:
            return []

        # Шаг 2: выбрать m.room.message из сторис-комнат, фильтровать на Python.
        # WHERE room_id IN (...) - безопасно, room_id-ы - доверенные из БД.
        # LEFT JOIN redactions + IS NULL исключает уже отредактированные
        # события - без этого один и тот же истёкший сторис редактировался
        # заново на каждом cleanup-раунде (инцидент на prod: одно событие
        # получило 670 повторных m.room.redaction за 168 часов).
        placeholders = ",".join("?" * len(stories_rooms))
        txn.execute(
            f"""
            SELECT e.room_id, e.event_id, e.sender, ej.json
            FROM events AS e
            JOIN event_json AS ej ON ej.event_id = e.event_id
            LEFT JOIN redactions AS r ON r.redacts = e.event_id
            WHERE e.type = 'm.room.message'
              AND e.room_id IN ({placeholders})
              AND r.redacts IS NULL
            """,
            tuple(stories_rooms),
        )
        result: list[tuple[str, str, str]] = []
        for room_id, event_id, sender, raw_json in txn.fetchall():
            try:
                content = json.loads(raw_json).get("content") or {}
            except (TypeError, ValueError):
                continue
            if story_is_expired(content, now_ms):
                result.append((room_id, event_id, sender))
        return result

    async def _sleep_zero(self) -> None:
        # Отдаём управление reactor между итерациями, не блокируя его и
        # сохраняя logcontext (defer.succeed не сохранял контекст -> warning
        # "Re-starting finished log context" при backfill).
        await self._api.sleep(0)
