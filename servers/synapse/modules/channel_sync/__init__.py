"""Synapse-модуль: зеркалирование корневых постов канала в привязанный чат
обсуждения (комментарии к каналам).

На каждый корневой пост (m.room.message без m.relates_to) в комнате с
com.liza.chat.type == "channel" и настроенным com.liza.channel.discussion
создаёт копию контента в привязанном чате-обсуждении с маркером
com.liza.channel.post_ref (Task 1: _logic.py) и пишет маппинг пост<->зеркало
в БД (Task 2: _storage.py MirrorStore), чтобы не задублировать зеркало.

Доступ к StateStorageController и db_pool — через приватный api._hs, как
chat_topology_sync_gate/__init__.py:40-41 и stories_membership/__init__.py:55-56
(ModuleApi не даёт публичных геттеров для них).
"""

import logging
from typing import Any

from synapse_modules.channel_sync._logic import (
    CHANNEL_DISCUSSION_STATE,
    DISCUSSION_CHAT_TYPE,
    HISTORY_VISIBILITY_STATE,
    JOIN_RULES_STATE,
    TOPOLOGY_STATE,
    build_mirror_content,
    channel_deleted_of,
    discussion_room_of,
    discussion_settings_for,
    edited_event_id,
    is_edit,
    is_membership_leave,
    is_public_channel,
    is_root_post,
    join_rule_of,
    join_rules_content,
    pick_discussion_actor,
    plan_discussion_migration,
    plan_is_noop,
    should_cleanup_mappings,
)
from synapse_modules.channel_sync._storage import MirrorStore

logger = logging.getLogger(__name__)

_CHAT_TYPE_KEY = "com.liza.chat.type"
_CHANNEL_TYPE = "channel"
_AI_LOCALPARTS = frozenset({"liza", "gpt", "deepseek"})


class ChannelSyncModule:
    @staticmethod
    def parse_config(config: dict[str, Any]) -> dict[str, Any]:
        return dict(config or {})

    def __init__(self, config: dict[str, Any], api: Any) -> None:
        self._api = api

        hs = getattr(api, "_hs", None)
        self._state = hs.get_storage_controllers().state if hs is not None else None
        # main datastore нужен напрямую для add_push_rule (мьют подписчиков
        # привязанного чата обсуждения) - ModuleApi не даёт публичного метода
        # СОЗДАНИЯ room-push-rule. Тот же паттерн доступа, что в
        # stories_membership/__init__.py:51-56 (_mute_room_for_local_user).
        self._main_store = hs.get_datastores().main if hs is not None else None
        db_pool = self._main_store.db_pool if self._main_store is not None else None
        self._store = MirrorStore(db_pool)

        api.register_third_party_rules_callbacks(
            on_new_event=self._on_new_event,
        )
        api.run_as_background_process("channel_sync_startup", self._on_startup)

    async def _on_startup(self) -> None:
        """Фоновая работа при старте: схема БД, затем миграция каналов.

        Последовательно в одном процессе, чтобы порядок был гарантирован.
        Схема в своём try: её отказ не должен отменять миграцию — та в
        channel_post_mirror не пишет и от таблицы не зависит.
        """
        try:
            await self._store.ensure_schema()
        except Exception:
            logger.exception("channel_sync: не удалось создать схему")
        await self._migrate_channel_discussions()

    async def _channel_type(self, room_id: str) -> str | None:
        create = await self._state.get_current_state_event(room_id, "m.room.create", "")
        content = getattr(create, "content", None) if create is not None else None
        return (content or {}).get(_CHAT_TYPE_KEY)

    async def _discussion_room(self, room_id: str) -> str | None:
        ev = await self._state.get_current_state_event(
            room_id, CHANNEL_DISCUSSION_STATE, ""
        )
        content = getattr(ev, "content", None) if ev is not None else None
        return discussion_room_of({}, content)

    async def _channel_join_rule(self, room_id: str) -> str | None:
        ev = await self._state.get_current_state_event(room_id, JOIN_RULES_STATE, "")
        content = getattr(ev, "content", None) if ev is not None else None
        return join_rule_of(content)

    async def _room_creator(self, room_id: str) -> str | None:
        create = await self._state.get_current_state_event(room_id, "m.room.create", "")
        return getattr(create, "sender", None) if create is not None else None

    async def _discussion_actor(self, discussion_id: str) -> str | None:
        """Локальный участник чата, от чьего имени пишет модуль
        (см. pick_discussion_actor): создатель, а после его ухода — свой
        участник с наибольшим PL."""
        creator = await self._room_creator(discussion_id)
        if self._main_store is None:
            return creator
        try:
            joined = await self._main_store.get_users_in_room(discussion_id)
        except Exception:
            logger.exception("channel_sync: участники %s не прочитаны", discussion_id)
            return creator
        local = [u for u in joined if self._api.is_mine(u)]
        pl = await self._state.get_current_state_event(
            discussion_id, "m.room.power_levels", ""
        )
        actor = pick_discussion_actor(
            creator, local, getattr(pl, "content", None) if pl is not None else None
        )
        if actor is None:
            logger.warning(
                "channel_sync: в чате %s нет своего участника с правами — "
                "запись с этого сервера пропущена",
                discussion_id,
            )
        elif actor != creator:
            logger.info(
                "channel_sync: создателя %s нет в чате %s, пишем от %s",
                creator,
                discussion_id,
                actor,
            )
        return actor

    async def _is_ai(self, user_id: str) -> bool:
        localpart = user_id.split(":", 1)[0].lstrip("@")
        if localpart in _AI_LOCALPARTS:
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

    async def _on_channel_join(self, channel_id: str, member: str) -> None:
        """Подписчик зашёл в канал — открываем ему комментарии.

        Порядок как в channel_stories._add_member: AI-фильтр → привязанный
        чат → мьют (только локальным) → owner → инвайт. Инвайт нужен только
        чату с правилом invite: public и restricted (закрытый канал с
        2026-10-15) подписчик проходит сам тихим join на клиенте.
        """
        if await self._is_ai(member):
            return
        discussion_id = await self._discussion_room(channel_id)
        if discussion_id is None:
            return  # комментарии у канала выключены
        if self._api.is_mine(member):
            await self._mute_for_subscriber(member, discussion_id)
        # Ветвимся по ФАКТИЧЕСКОМУ правилу чата, а не по приватности канала:
        # restricted пускает подписчика сам, а invite-чат (создан старым
        # клиентом, ещё не мигрирован) по-прежнему требует приглашения.
        if await self._channel_join_rule(discussion_id) != "invite":
            return
        owner = await self._discussion_actor(discussion_id)
        if owner is None:
            return
        remote_hosts = None if self._api.is_mine(member) else [member.split(":", 1)[1]]
        try:
            await self._api.update_room_membership(
                owner, member, discussion_id, "invite", remote_room_hosts=remote_hosts
            )
        except Exception as e:  # уже участник / гонка — не критично
            logger.debug(
                "channel_sync: invite %s -> %s skipped: %s", member, discussion_id, e
            )

    async def _sync_discussion_privacy(self, channel_id: str, join_rule: str) -> None:
        """Приводит привязанный чат к приватности канала.

        Без этого чат навсегда остаётся приватным (клиент создаёт его с
        preset privateChat), и подписчики ОТКРЫТОГО канала не видят
        комментариев, а переключение тумблера публичный/закрытый у канала
        ничего не меняет.

        Пишем от имени создателя чата — у него заведомо есть PL на state.
        Каждое state-событие в своём try: отказ по одному (например, гонка с
        параллельной правкой) не должен отменять второе, иначе чат зависнет
        в полусостоянии public без world_readable.
        """
        discussion_id = await self._discussion_room(channel_id)
        if discussion_id is None:
            return  # комментарии у канала выключены
        owner = await self._discussion_actor(discussion_id)
        if owner is None:
            return
        settings = discussion_settings_for(join_rule, channel_id)
        for event_type, content in (
            (JOIN_RULES_STATE, join_rules_content(settings)),
            (
                HISTORY_VISIBILITY_STATE,
                {"history_visibility": settings["history_visibility"]},
            ),
        ):
            try:
                await self._api.create_and_send_event_into_room(
                    {
                        "type": event_type,
                        "room_id": discussion_id,
                        "sender": owner,
                        "state_key": "",
                        "content": content,
                    }
                )
            except Exception:
                logger.exception(
                    "channel_sync: не удалось выставить %s в %s",
                    event_type,
                    discussion_id,
                )

    async def _discussion_hidden(self, room_id: str) -> bool | None:
        """content.hidden из com.liza.chat.topology привязанного чата.

        None — state-события нет вовсе (чат создан до топологии); отличать от
        явного False важно: в план миграции идёт всё, что не True.
        """
        ev = await self._state.get_current_state_event(room_id, TOPOLOGY_STATE, "")
        content = getattr(ev, "content", None) if ev is not None else None
        if content is None:
            return None
        return content.get("hidden")

    async def _history_visibility(self, room_id: str) -> str | None:
        ev = await self._state.get_current_state_event(
            room_id, HISTORY_VISIBILITY_STATE, ""
        )
        content = getattr(ev, "content", None) if ev is not None else None
        return (content or {}).get("history_visibility")

    async def _channel_snapshot(self, channel_id: str, discussion_id: str) -> dict:
        """Снимок состояния канала и его чата для plan_discussion_migration."""
        rules = await self._state.get_current_state_event(
            discussion_id, JOIN_RULES_STATE, ""
        )
        return {
            "channel_id": channel_id,
            "channel_join_rule": await self._channel_join_rule(channel_id),
            "discussion_join_rules": dict(getattr(rules, "content", None) or {})
            if rules is not None
            else {},
            "discussion_history_visibility": await self._history_visibility(
                discussion_id
            ),
            "discussion_hidden": await self._discussion_hidden(discussion_id),
        }

    async def _migrate_channel_visibility(self, channel_id: str) -> bool:
        """Открывает ленту ОТКРЫТОГО канала для чтения без вступления.

        Возвращает True, если видимость реально переписана.

        Клиент создавал канал пресетом publicChat, который даёт
        history_visibility=shared: неучастнику Synapse отвечает 403 «room
        previews are disabled», поэтому чтобы просто показать ленту клиенту
        приходилось делать joinRoom — и канал попадал в список чатов, хотя
        пользователь на него не подписывался.

        Трогаем ТОЛЬКО открытые каналы: у закрытого контент не публичен, и
        world_readable раскрыл бы его любому. Шаг отдельный от
        _migrate_one_channel: тот выходит рано, когда у канала нет чата
        обсуждений, а видимость чинить надо всем открытым каналам.
        """
        join_rule = await self._channel_join_rule(channel_id)
        if not is_public_channel(join_rule):
            return False
        if await self._history_visibility(channel_id) == "world_readable":
            return False  # уже открыт — идемпотентность повторного прогона
        owner = await self._room_creator(channel_id)
        if owner is None:
            logger.warning(
                "channel_sync: видимость %s не изменена — у канала нет создателя",
                channel_id,
            )
            return False
        try:
            await self._api.create_and_send_event_into_room(
                {
                    "type": HISTORY_VISIBILITY_STATE,
                    "room_id": channel_id,
                    "sender": owner,
                    "state_key": "",
                    "content": {"history_visibility": "world_readable"},
                }
            )
        except Exception:
            logger.exception(
                "channel_sync: не удалось открыть ленту канала %s", channel_id
            )
            return False
        logger.info(
            "channel_sync: лента канала %s открыта для чтения без вступления",
            channel_id,
        )
        return True

    async def _migrate_one_channel(self, channel_id: str) -> bool:
        """Приводит привязанный чат ОДНОГО канала к целевой модели.

        Возвращает True, если что-то реально записано (для счётчика в логе).

        До этой миграции клиент создавал чат как privateChat (join_rule
        invite) независимо от приватности канала и инвайтил только админов
        PL>=100 — подписчики открытых каналов не видели комментариев вовсе.
        Реактивные колбэки (_sync_discussion_privacy, _on_channel_join) чинят
        это только для БУДУЩИХ событий, существующие каналы надо обойти явно.

        С 2026-10-15 закрытый канал получает restricted по членству в канале
        вместо инвайтов (см. discussion_settings_for), миграция никого не зовёт.

        Пишем от имени исполнителя (создатель ЧАТА, а если его нет в чате —
        свой участник с наибольшим PL): у @synapse_admin нет прав на state
        чужих комнат (клиентский API отдаёт 403, а admin API писать state не
        умеет вовсе) — ровно поэтому миграция и живёт в модуле.
        """
        discussion_id = await self._discussion_room(channel_id)
        if discussion_id is None:
            return False  # комментарии у канала выключены
        owner = await self._discussion_actor(discussion_id)
        if owner is None:
            logger.warning(
                "channel_sync: миграция %s пропущена — у чата %s нет создателя",
                channel_id,
                discussion_id,
            )
            return False

        snapshot = await self._channel_snapshot(channel_id, discussion_id)
        plan = plan_discussion_migration(snapshot)
        if plan_is_noop(plan):
            return False

        logger.info(
            "channel_sync: миграция канала %s -> чат %s: join_rules=%s "
            "history_visibility=%s hidden=%s",
            channel_id,
            discussion_id,
            plan["set_join_rules"],
            plan["set_history_visibility"],
            plan["set_hidden"],
        )

        state_writes = []
        if plan["set_join_rules"]:
            state_writes.append((JOIN_RULES_STATE, plan["set_join_rules"]))
        if plan["set_history_visibility"]:
            state_writes.append(
                (
                    HISTORY_VISIBILITY_STATE,
                    {"history_visibility": plan["set_history_visibility"]},
                )
            )
        if plan["set_hidden"]:
            state_writes.append((TOPOLOGY_STATE, {"hidden": True}))

        # Каждая запись в своём try: отказ по одной комнате/событию (гонка,
        # недостаток PL) не должен обрывать остальные и весь проход.
        for event_type, content in state_writes:
            try:
                await self._api.create_and_send_event_into_room(
                    {
                        "type": event_type,
                        "room_id": discussion_id,
                        "sender": owner,
                        "state_key": "",
                        "content": content,
                    }
                )
            except Exception:
                logger.exception(
                    "channel_sync: миграция не смогла выставить %s в %s",
                    event_type,
                    discussion_id,
                )

        return True

    async def _migrate_channel_discussions(self) -> None:
        """Разовый проход по всем каналам инстанса при старте Synapse.

        Флага в конфиге намеренно НЕТ: план каждой комнаты пересчитывается по
        фактическому состоянию (plan_discussion_migration), уже правильное в
        план не попадает, поэтому повторный прогон на следующем рестарте —
        это только чтение. Флаг пришлось бы руками выставлять и потом снимать
        на четырёх инстансах, а забытый включённым флаг всё равно не защищает
        (защищает идемпотентность).

        Ошибка по одному каналу логируется и не срывает остальные: код бежит
        по ЖИВЫМ комнатам прода.
        """
        if self._main_store is None:
            return
        try:
            channels = await self._store.find_channel_rooms()
        except Exception:
            logger.exception("channel_sync: миграция не смогла найти каналы")
            return

        migrated = 0
        for channel_id in channels:
            try:
                changed = await self._migrate_channel_visibility(channel_id)
                if await self._migrate_one_channel(channel_id) or changed:
                    migrated += 1
                # Отдаём управление reactor между каналами: проход идёт по
                # всем комнатам инстанса и не должен занимать поток целиком.
                # sleep(0) ТОЛЬКО в успешной ветке: после проглоченного
                # исключения logcontext уже завершён, и sleep на нём даёт
                # «Re-starting finished log context» и обрывает проход (на
                # проде 2026-07-24 дал 27 warning'ов и миграция не дошла до
                # конца). Тот же дефект чинили в stories_membership.
                await self._api.sleep(0)
            except Exception:
                logger.exception("channel_sync: миграция канала %s упала", channel_id)
        logger.info(
            "channel_sync: миграция завершена, каналов %s, изменено %s",
            len(channels),
            migrated,
        )

    async def _on_channel_leave(self, channel_id: str, member: str) -> None:
        """Подписчик ушёл из канала (leave/ban) — закрываем ему комментарии.

        Обратная операция к _on_channel_join: без неё отписавшийся от
        ЗАКРЫТОГО канала остаётся членом привязанного чата и продолжает
        читать и писать комментарии — утечка доступа.

        Кик делаем и для открытого канала: там чат public и дверь он не
        запирает, но убирает комнату из списка/синка ушедшего и отражает
        намерение «я отписался». Ветвление по приватности не окупается.

        Асимметрия с _on_channel_join (нет AI-фильтра и remote_room_hosts)
        осознанная и повторяет channel_stories._remove_member: кик работает
        и без них, а лишние проверки только оставляют дыры.

        Работает и при УДАЛЕНИИ канала, где кики идут пачкой: каждый из них
        диспатчится через run_as_background_process, поэтому часть процессов
        читает привязку уже ПОСЛЕ того, как клиент записал маркер удаления.
        Маркер несёт room_id (см. channel_deleted_of), значит
        _discussion_room отдаёт чат в любом порядке и подписчики не остаются
        членами чата обсуждения. Не «оптимизируй» маркер до голого
        {"deleted": true} — это ровно та дыра.
        """
        discussion_id = await self._discussion_room(channel_id)
        if discussion_id is None:
            return  # комментарии у канала выключены
        owner = await self._discussion_actor(discussion_id)
        if owner is None:
            return
        try:
            await self._api.update_room_membership(
                owner, member, discussion_id, "leave"
            )
        except Exception as e:  # уже не участник / гонка — не критично
            logger.debug(
                "channel_sync: kick %s <- %s skipped: %s", member, discussion_id, e
            )

    async def _cleanup_unlinked_discussion(
        self, event_id: str, new_room: str | None, channel_deleted: bool
    ) -> None:
        """Чистит маппинги пост→зеркало осиротевшего чата обсуждения.

        Чистка НЕ происходит при обычной отвязке (выключении комментариев):
        чат обсуждения остаётся целым — история и участники на месте — и при
        повторном включении комментариев старые треды обязаны вернуться, как
        это сохраняет ожидаемое поведение. Решает predicate should_cleanup_mappings:
        удаляем только при удалении канала (явный маркер, см.
        channel_deleted_of) либо при переезде привязки на ДРУГОЙ чат.

        Прошлое значение com.liza.channel.discussion берём через
        get_event(get_prev_content=True): в on_new_event Synapse отдаёт событие
        БЕЗ prev_content (там get_prev_content=False), а state_events — это
        состояние ПОСЛЕ события, старого room_id в нём уже нет. Разворачивает
        его сам Synapse по unsigned["replaces_state"], который проставляется
        любому state-событию, заменившему предыдущее.

        Ошибку глотаем: недобранный prev_content стоит осиротевших строк в
        channel_post_mirror, но не сорванной обработки события.

        Идемпотентно: повторный прогон на том же событии либо ничего не
        удаляет (отвязка/перезапись тем же чатом), либо повторяет DELETE по
        уже пустому набору строк.
        """
        if self._main_store is None:
            return
        try:
            stored = await self._main_store.get_event(
                event_id, get_prev_content=True, allow_none=True
            )
        except Exception:
            logger.exception("channel_sync: не удалось получить prev_content %s", event_id)
            return
        unsigned = getattr(stored, "unsigned", None) or {}
        prev_room = (unsigned.get("prev_content") or {}).get("room_id")
        if not should_cleanup_mappings(
            prev_room=prev_room, new_room=new_room, channel_deleted=channel_deleted
        ):
            return
        deleted = await self._store.delete_by_discussion(prev_room)
        logger.info(
            "channel_sync: чат %s осиротел (удаление канала=%s), удалено маппингов: %s",
            prev_room,
            channel_deleted,
            deleted,
        )

    async def _on_new_event(self, event: Any, state_events: Any) -> None:
        content = dict(getattr(event, "content", {}) or {})
        if is_membership_leave(event.type, content):
            user_id = event.state_key
            if user_id and await self._channel_type(event.room_id) == _CHANNEL_TYPE:
                self._api.run_as_background_process(
                    "channel_sync_channel_leave",
                    self._on_channel_leave, event.room_id, user_id,
                )
            return
        if event.type == "m.room.member" and content.get("membership") == "join":
            room_chat_type = await self._channel_type(event.room_id)
            user_id = event.state_key
            if room_chat_type == DISCUSSION_CHAT_TYPE:
                if user_id and self._api.is_mine(user_id):
                    self._api.run_as_background_process(
                        "channel_sync_mute_subscriber",
                        self._mute_for_subscriber, user_id, event.room_id,
                    )
            elif room_chat_type == _CHANNEL_TYPE and user_id:
                # join в КАНАЛ: раздаём доступ к комментариям. Для закрытого
                # канала — инвайт в привязанный чат (сам он туда не войдёт),
                # для открытого чат public и вход произойдёт при первой
                # отправке комментария. Мьют — в обоих случаях.
                self._api.run_as_background_process(
                    "channel_sync_channel_join",
                    self._on_channel_join, event.room_id, user_id,
                )
            return
        if event.type == CHANNEL_DISCUSSION_STATE:
            # Привязка чата снята, переписана на другую комнату или помечена
            # удалением канала. Осиротели маппинги пост→зеркало НЕ в каждом из
            # этих случаев: простое выключение комментариев чат не разрушает и
            # маппинги обязано сохранить — решает
            # _cleanup_unlinked_discussion через should_cleanup_mappings.
            # Отдельного сигнала «канал удалён» в Matrix нет (удаление — это
            # кик+leave+forget), поэтому клиент помечает удаление явно ключом
            # deleted в content этого же события — РЯДОМ с room_id, чтобы
            # параллельные фоновые кики (_on_channel_leave) продолжали
            # находить чат обсуждения независимо от порядка приземления.
            if await self._channel_type(event.room_id) != _CHANNEL_TYPE:
                return
            self._api.run_as_background_process(
                "channel_sync_unlink_cleanup",
                self._cleanup_unlinked_discussion,
                event.event_id,
                discussion_room_of({}, content),
                channel_deleted_of(content),
            )
            # Привязка нового (или повторно включённого) чата: приводим его к
            # модели сразу, а не на следующем рестарте. Старые клиенты (≤3779)
            # создают чат закрытого канала как invite — без этого подписчики
            # такого чата не вошли бы до рестарта Synapse.
            if discussion_room_of({}, content) and not channel_deleted_of(content):
                self._api.run_as_background_process(
                    "channel_sync_bind_migrate",
                    self._migrate_one_channel,
                    event.room_id,
                )
            return
        if event.type == JOIN_RULES_STATE:
            if await self._channel_type(event.room_id) != _CHANNEL_TYPE:
                return
            join_rule = join_rule_of(content)
            if join_rule:
                self._api.run_as_background_process(
                    "channel_sync_privacy",
                    self._sync_discussion_privacy, event.room_id, join_rule,
                )
            return
        if is_root_post(event.type, content):
            if await self._channel_type(event.room_id) != _CHANNEL_TYPE:
                return
            self._api.run_as_background_process(
                "channel_sync_mirror_post", self._mirror_post, event, content
            )
            return
        # edit/redact — только в каналах, чтобы не дёргать get_mirror на каждый
        # edit/redact во ВСЕХ комнатах инстанса (симметрично ветке is_root_post).
        is_edit_event = event.type == "m.room.message" and is_edit(content)
        is_redact_event = event.type == "m.room.redaction"
        if not (is_edit_event or is_redact_event):
            return
        if await self._channel_type(event.room_id) != _CHANNEL_TYPE:
            return
        # edit поста
        if is_edit_event:
            target = edited_event_id(content)
            if target:
                self._api.run_as_background_process(
                    "channel_sync_mirror_edit", self._mirror_edit, event, content, target
                )
            return
        # redaction поста
        if is_redact_event:
            redacts = getattr(event, "redacts", None)
            if redacts:
                self._api.run_as_background_process(
                    "channel_sync_mirror_redact", self._mirror_redact, event, redacts
                )
            return

    async def _mute_for_subscriber(self, user_id: str, room_id: str) -> None:
        """Ставит room-level push rule dont_notify для подписчика в
        привязанном чате обсуждения (channel_discussion), чтобы он получал
        push на ПОСТЫ канала, но не на комментарии в чате обсуждения.

        Паттерн 1-в-1 с stories_membership._mute_room_for_local_user:
        проверяем наличие правила ПЕРЕД add_push_rule (simple_select_one_onecol
        по table='push_rules', keyvalues user_name+rule_id), иначе
        push_rules_stream растёт на каждый рестарт/повторный join.
        """
        if self._main_store is None:
            return
        rule_id = f"global/room/{room_id}"
        try:
            existing = await self._main_store.db_pool.simple_select_one_onecol(
                table="push_rules",
                keyvalues={"user_name": user_id, "rule_id": rule_id},
                retcol="id",
                allow_none=True,
                desc="channel_sync_check_mute_rule",
            )
            if existing is not None:
                return
            await self._main_store.add_push_rule(
                user_id=user_id,
                rule_id=rule_id,
                priority_class=3,  # PRIORITY_CLASS_MAP["room"]
                conditions=[
                    {"kind": "event_match", "key": "room_id", "pattern": room_id}
                ],
                actions=["dont_notify"],
            )
        except Exception:
            logger.exception(
                "channel_sync: не удалось замьютить %s для %s", room_id, user_id
            )

    async def _ensure_author_in_discussion(
        self, author: str, discussion_id: str
    ) -> bool:
        """Вводит автора поста в привязанный чат, чтобы зеркало прошло auth.

        Зеркало отправляется ОТ ИМЕНИ автора (иначе комментарии висели бы под
        чужим ником), а Synapse требует членства отправителя в комнате. Автор
        канала в чат обсуждений может не входить вовсе: чат создаётся отдельной
        комнатой, инвайты рассылаются только админам при создании, а посты
        старше привязки писались, когда чата ещё не существовало.

        Инвайт+join шлём от владельца чата — у него заведомо есть права. Для
        public-чата хватило бы одного join, но закрытый требует инвайта, а
        повторный инвайт уже приглашённому просто отдаёт ошибку, которую мы
        глотаем.
        """
        owner = await self._discussion_actor(discussion_id)
        if owner is None:
            return False
        remote_hosts = [author.split(":", 1)[1]] if ":" in author else None
        try:
            await self._api.update_room_membership(
                owner, author, discussion_id, "invite", remote_room_hosts=remote_hosts
            )
        except Exception as e:  # уже приглашён / уже в комнате — не критично
            logger.debug(
                "channel_sync: invite автора %s -> %s пропущен: %s",
                author,
                discussion_id,
                e,
            )
        try:
            await self._api.update_room_membership(
                author, author, discussion_id, "join", remote_room_hosts=remote_hosts
            )
            return True
        except Exception:
            logger.exception(
                "channel_sync: не удалось ввести автора %s в чат %s",
                author,
                discussion_id,
            )
            return False

    async def _send_mirror(
        self, sender: str, discussion_id: str, mirror_content: dict
    ) -> Any:
        return await self._api.create_and_send_event_into_room(
            {
                "type": "m.room.message",
                "room_id": discussion_id,
                "sender": sender,
                "content": mirror_content,
            }
        )

    async def _mirror_post(self, event: Any, content: dict) -> None:
        post_id = event.event_id
        if await self._store.already_mirrored(post_id):
            return
        discussion_id = await self._discussion_room(event.room_id)
        if discussion_id is None:
            return  # комментарии выключены (нет com.liza.channel.discussion)

        mirror_content = build_mirror_content(content, event.room_id, post_id)
        try:
            mirror = await self._send_mirror(
                event.sender, discussion_id, mirror_content
            )
        except Exception as first_error:
            # Самая частая причина — автор не член привязанного чата (403).
            # Молча пропускать нельзя: без зеркала пост навсегда остаётся без
            # комментариев, а пользователь видит «не удалось открыть
            # обсуждение». Вводим автора в чат и пробуем ещё раз.
            logger.info(
                "channel_sync: зеркало поста %s не ушло (%s), ввожу автора %s в %s",
                post_id,
                first_error,
                event.sender,
                discussion_id,
            )
            if not await self._ensure_author_in_discussion(
                event.sender, discussion_id
            ):
                logger.exception(
                    "channel_sync: mirror send failed for post %s in %s",
                    post_id,
                    event.room_id,
                )
                return
            try:
                mirror = await self._send_mirror(
                    event.sender, discussion_id, mirror_content
                )
            except Exception:
                logger.exception(
                    "channel_sync: mirror send failed after join for post %s in %s",
                    post_id,
                    event.room_id,
                )
                return

        await self._store.put_mirror(post_id, mirror.event_id, discussion_id)

    async def _mirror_edit(self, event: Any, content: dict, target_post_id: str) -> None:
        mapping = await self._store.get_mirror(target_post_id)
        if mapping is None:
            return
        mirror_event_id, discussion_id = mapping
        new_content = dict(content.get("m.new_content") or {})
        new_content["m.relates_to"] = {
            "rel_type": "m.replace",
            "event_id": mirror_event_id,
        }
        try:
            await self._api.create_and_send_event_into_room({
                "type": "m.room.message",
                "room_id": discussion_id,
                "sender": event.sender,
                "content": new_content,
            })
        except Exception:
            logger.exception("channel_sync: mirror edit failed for %s", target_post_id)

    async def _mirror_redact(self, event: Any, redacted_post_id: str) -> None:
        mapping = await self._store.get_mirror(redacted_post_id)
        if mapping is None:
            return
        mirror_event_id, discussion_id = mapping
        try:
            await self._api.create_and_send_event_into_room({
                "type": "m.room.redaction",
                "room_id": discussion_id,
                "sender": event.sender,
                "redacts": mirror_event_id,
                "content": {},
            })
        except Exception:
            logger.exception("channel_sync: mirror redact failed for %s", redacted_post_id)
            return
        # Пост удалён — маппинг больше не нужен. Чистим, чтобы таблица не росла
        # неограниченно (до этой правки DELETE не было вовсе).
        await self._store.delete_mirror(redacted_post_id)
