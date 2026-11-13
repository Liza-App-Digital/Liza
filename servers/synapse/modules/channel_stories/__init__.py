"""Synapse-модуль: раздача историй канала по членству.

При join локального/удалённого подписчика в комнату-КАНАЛ
(com.liza.chat.type == "channel") инвайтит его в отдельную stories-комнату
этого канала (mute перед invite для локальных, как stories_membership); на
leave/ban - кикает. Stories-комнату канала заводит клиент при первой
публикации истории (Task 6, ensure_channel_stories_room на клиенте) - сервер
узнаёт об этом через _on_new_event на m.room.create (см. _on_room_create) и
пишет маппинг channel_id -> stories_room_id в ChannelStoriesStore; раздача
членства читает этот маппинг (Task 2: _storage.py).

on_new_event, а не on_create_room: on_create_room вызывается ДО фактического
создания комнаты и room_id там недоступен (см. single_space_guard/_guard.py,
docstring is_dm_creation, и channel_guard/__init__.py._on_create_room -
сигнатура (requester, config, is_requester_admin), без room_id). На
m.room.create в on_new_event room_id уже есть в event.room_id, а
event.content - это тот же creation_content, что клиент передал в createRoom.

Доступ к StateStorageController и main datastore - через приватный api._hs,
как chat_topology_sync_gate/__init__.py и stories_membership/__init__.py
(ModuleApi не даёт публичных геттеров для них).
"""

import logging
from typing import Any

from synapse_modules._ha import register_on_new_event_once
from synapse_modules.channel_stories._logic import (
    CHANNEL_STORIES_OF,
    CHAT_TYPE_KEY,
    is_channel_join,
    is_channel_leave,
)
from synapse_modules.channel_stories._storage import ChannelStoriesStore

logger = logging.getLogger(__name__)

_CHANNEL_TYPE = "channel"
_AI_LOCALPARTS = frozenset({"liza"})


class ChannelStoriesModule:
    @staticmethod
    def parse_config(config: dict[str, Any]) -> dict[str, Any]:
        return dict(config or {})

    def __init__(self, config: dict[str, Any], api: Any) -> None:
        self._api = api

        hs = getattr(api, "_hs", None)
        self._state = hs.get_storage_controllers().state if hs is not None else None
        # main datastore нужен напрямую для db_pool (ChannelStoriesStore) и
        # add_push_rule (мьют подписчика перед invite) - тот же паттерн
        # доступа, что в stories_membership/__init__.py и channel_sync/__init__.py.
        self._main_store = hs.get_datastores().main if hs is not None else None
        db_pool = self._main_store.db_pool if self._main_store is not None else None
        self._store = ChannelStoriesStore(db_pool)

        # HA: раздачу членства выполняет один процесс инстанса (см. synapse_modules._ha).
        register_on_new_event_once(api, self._on_new_event)
        api.run_as_background_process("channel_stories_schema", self._store.ensure_schema)

    async def _chat_type(self, room_id: str) -> str | None:
        create = await self._state.get_current_state_event(room_id, "m.room.create", "")
        content = getattr(create, "content", None) if create is not None else None
        return (content or {}).get(CHAT_TYPE_KEY)

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

    async def _on_new_event(self, event: Any, state_events: Any) -> None:
        content = dict(getattr(event, "content", {}) or {})
        if event.type == "m.room.create":
            self._api.run_as_background_process(
                "channel_stories_link_room", self._on_room_create, event.room_id, content
            )
            return
        is_join = is_channel_join(event.type, content)
        is_leave = is_channel_leave(event.type, content)
        if not (is_join or is_leave):
            return
        room_id = event.room_id
        if await self._chat_type(room_id) != _CHANNEL_TYPE:
            return
        member = event.state_key
        if is_join:
            self._api.run_as_background_process(
                "channel_stories_add_member", self._add_member, room_id, member
            )
        else:
            self._api.run_as_background_process(
                "channel_stories_remove_member", self._remove_member, room_id, member
            )

    async def _on_room_create(self, room_id: str, creation_content: dict[str, Any]) -> None:
        """Ловит создание stories-комнаты канала клиентом (Task 6) и пишет
        маппинг channel_id -> stories_room_id в ChannelStoriesStore.

        Без этого put_stories_room никогда не вызывается production-кодом:
        сервер не создаёт stories-комнату сам, а клиент физически не может
        писать в БД Synapse-модуля. Раздача членства (_add_member/_remove_member)
        читает именно этот маппинг - без записи она навсегда no-op.
        """
        marker = creation_content.get(CHANNEL_STORIES_OF)
        if not isinstance(marker, dict):
            return
        channel_id = marker.get("channel_id")
        if not channel_id:
            return
        await self._store.put_stories_room(channel_id, room_id)
        await self._backfill_channel_members(channel_id)

    async def _backfill_channel_members(self, channel_id: str) -> None:
        """Инвайтит в новую stories-комнату существующих join-членов канала.

        Без этого действующие подписчики канала не увидят историй, пока не
        перезайдут (join/leave/rejoin) - _add_member иначе срабатывает только
        реактивно на будущие m.room.member события. channel_id - это room_id
        самого канала (_add_member/_remove_member уже трактуют channel_id
        именно так - см. вызовы в _on_new_event).

        Чтение членов - get_users_in_room на main datastore
        (synapse/storage/databases/main/roommember.py): join-only список из
        current_state_events, тот же источник правды, что и
        local_current_membership в miniapp/stories_membership, но без ручного
        runInteraction - метод уже есть на self._main_store.
        """
        if self._main_store is None:
            return
        members = await self._main_store.get_users_in_room(channel_id)
        for member in members:
            await self._add_member(channel_id, member)

    async def _add_member(self, channel_id: str, member: str) -> None:
        if await self._is_ai(member):
            return
        stories_room = await self._store.get_stories_room(channel_id)
        if stories_room is None:
            return  # истории у канала ещё не заведены (создаст клиент, Task 6)
        owner = await self._room_creator(stories_room)
        if owner is None:
            return
        if self._api.is_mine(member):
            await self._mute_room_for_local_user(member, stories_room)
        remote_hosts = None if self._api.is_mine(member) else [member.split(":", 1)[1]]
        try:
            await self._api.update_room_membership(
                owner, member, stories_room, "invite", remote_room_hosts=remote_hosts
            )
        except Exception as e:  # уже участник / гонка - не критично
            logger.debug("channel_stories: invite %s -> %s skipped: %s", member, stories_room, e)

    async def _remove_member(self, channel_id: str, member: str) -> None:
        stories_room = await self._store.get_stories_room(channel_id)
        if stories_room is None:
            return
        owner = await self._room_creator(stories_room)
        if owner is None:
            return
        try:
            await self._api.update_room_membership(owner, member, stories_room, "leave")
        except Exception as e:
            logger.debug("channel_stories: kick %s <- %s skipped: %s", member, stories_room, e)

    async def _room_creator(self, room_id: str) -> str | None:
        create = await self._state.get_current_state_event(room_id, "m.room.create", "")
        return getattr(create, "sender", None) if create is not None else None

    async def _mute_room_for_local_user(self, user_id: str, room_id: str) -> None:
        """Ставит room-level push rule dont_notify для user_id в room_id.

        Копия паттерна stories_membership._mute_room_for_local_user: проверка
        наличия правила ПЕРЕД add_push_rule (simple_select_one_onecol по
        table='push_rules', keyvalues user_name+rule_id), иначе
        push_rules_stream растёт на каждый повторный join/рестарт без
        реального изменения состояния (см. инцидент на prod 2026-07-02).
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
                desc="channel_stories_check_mute_rule",
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
                "channel_stories: не удалось замьютить %s для %s", room_id, user_id
            )


# Решение по ensure_channel_stories_room (см. брифинг Task 3):
#
# В MVP stories-комнату канала создаёт КЛИЕНТ при первой публикации истории
# (Task 6), а не сервер. Сервер узнаёт об этом реактивно: _on_new_event ловит
# m.room.create такой комнаты (_on_room_create) и пишет маппинг
# channel_id -> stories_room_id в ChannelStoriesStore. Серверный хук здесь
# только РАЗДАЁТ членство: если ChannelStoriesStore.get_stories_room(channel_id)
# возвращает None (маппинг ещё не пришёл / истории у канала ещё не заведены),
# _add_member/_remove_member молча выходят - это ожидаемое состояние "у канала
# пока нет историй", а не ошибка.
#
# Метод ensure_channel_stories_room (АКТИВНОЕ создание stories-комнаты сервером)
# НЕ включён в этот модуль: сервер только пассивно слушает создание, но сам
# комнату не создаёт и не должен - это ответственность клиента (Task 6). Если
# в будущем появится server-side сценарий создания (например, админский
# bulk-backfill существующих каналов), метод стоит завести вместе с вызывающим
# кодом и тестом на него, а не заранее.
