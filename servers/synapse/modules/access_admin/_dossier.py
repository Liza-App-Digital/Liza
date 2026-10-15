"""Сбор досье по членствам пользователя.

Одним SQL берём join-комнаты вместе с метаданными и событием power_levels,
разбор JSON — на Python: фильтровать содержимое JSON в SQL через LIKE
нельзя, "%" ломается через psycopg2.
"""

import json
import logging
from collections.abc import Mapping

from ._logic import (
    CHAT_TYPE_KEY,
    DEFAULT_BOT_LOCALPARTS,
    DEFAULT_BOTS_HOMESERVER,
    LEGACY_STORIES_KEY,
    classify_room,
    is_bot_user,
    is_hidden_room,
    is_local_room,
    level_from_power,
    power_from_content,
)

logger = logging.getLogger(__name__)

DIRECT_ACCOUNT_DATA = "m.direct"


def membership_rows_sql() -> str:
    """SQL членств пользователя.

    Источник — current_state_events по m.room.member, а НЕ
    local_current_membership: последняя содержит только локальные
    аккаунты, из-за чего досье федеративного пользователя всегда
    пустое. state_key события — это MXID участника, поэтому запрос
    одинаково работает для локальных и федеративных.
    """
    return """
    SELECT cse.room_id, rss.name, rss.avatar, rss.room_type,
           ej.json, cj.json, tj.json, tomb.event_id
    FROM current_state_events AS cse
    LEFT JOIN room_stats_state AS rss ON rss.room_id = cse.room_id
    LEFT JOIN current_state_events AS pl
           ON pl.room_id = cse.room_id
          AND pl.type = 'm.room.power_levels'
          AND pl.state_key = ''
    LEFT JOIN event_json AS ej ON ej.event_id = pl.event_id
    LEFT JOIN current_state_events AS cr
           ON cr.room_id = cse.room_id
          AND cr.type = 'm.room.create'
          AND cr.state_key = ''
    LEFT JOIN event_json AS cj ON cj.event_id = cr.event_id
    LEFT JOIN current_state_events AS tp
           ON tp.room_id = cse.room_id
          AND tp.type = 'com.liza.chat.topology'
          AND tp.state_key = ''
    LEFT JOIN event_json AS tj ON tj.event_id = tp.event_id
    LEFT JOIN current_state_events AS tomb
           ON tomb.room_id = cse.room_id
          AND tomb.type = 'm.room.tombstone'
          AND tomb.state_key = ''
    WHERE cse.type = 'm.room.member'
      AND cse.state_key = ?
      AND cse.membership = 'join'
"""

_GROUP_KEYS = {
    "space": "spaces",
    "channel": "channels",
    "chat": "chats",
    "bot": "bots",
}
_LEVEL_ORDER = {"admin": 0, "moderator": 1, "user": 2}


def _content_from_json(raw: str | None) -> dict | None:
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except (ValueError, TypeError):
        return None
    content = parsed.get("content") if isinstance(parsed, dict) else None
    return content if isinstance(content, dict) else None


def build_dossier_groups(
    rows, *, target_id: str, server_name: str, dm_room_ids, bot_dm_room_ids
) -> dict:
    groups: dict[str, list] = {
        "spaces": [],
        "channels": [],
        "chats": [],
        "bots": [],
    }

    for (
        room_id,
        name,
        avatar,
        room_type,
        power_raw,
        create_raw,
        topology_raw,
        tombstone_id,
    ) in rows:
        if not is_local_room(room_id, server_name):
            continue
        is_bot_dm = room_id in bot_dm_room_ids
        if room_id in dm_room_ids and not is_bot_dm:
            continue
        if tombstone_id is not None:
            continue

        create_content = _content_from_json(create_raw) or {}
        chat_type = create_content.get(CHAT_TYPE_KEY)
        legacy_stories = create_content.get(LEGACY_STORIES_KEY) is True
        topology_content = _content_from_json(topology_raw)

        if is_hidden_room(topology_content, chat_type, legacy_stories):
            continue

        # Легаси-ключ определяет ТИП комнаты (зеркало lizaChatType), но при
        # наличии topology-стейта вопрос скрытости уже решён выше — второй
        # раз фильтровать по легаси нельзя, иначе topology:hidden=false не
        # сможет вернуть комнату в выдачу.
        group = "bot" if is_bot_dm else classify_room(
            room_type,
            chat_type,
            legacy_stories=legacy_stories and topology_content is None,
        )
        if group is None:
            continue

        power = power_from_content(_content_from_json(power_raw), target_id)
        groups[_GROUP_KEYS[group]].append(
            {
                "room_id": room_id,
                "name": name,
                "avatar": avatar,
                "level": level_from_power(power),
            }
        )

    for entries in groups.values():
        entries.sort(
            key=lambda e: (_LEVEL_ORDER[e["level"]], e["name"] is None, e["name"] or "")
        )

    return groups


class DossierBuilder:
    def __init__(
        self,
        db_pool,
        account_data,
        server_name: str,
        bot_localparts=DEFAULT_BOT_LOCALPARTS,
        bots_homeserver: str = DEFAULT_BOTS_HOMESERVER,
    ) -> None:
        self._db = db_pool
        self._account_data = account_data
        self._server_name = server_name
        self._bot_localparts = bot_localparts
        self._bots_homeserver = bots_homeserver

    async def _fetch_rows(self, user_id: str) -> list:
        def _txn(txn):
            txn.execute(membership_rows_sql(), (user_id,))
            return txn.fetchall()

        return await self._db.runInteraction("access_admin_dossier", _txn)

    def _is_local(self, user_id: str) -> bool:
        """Локальный ли аккаунт.

        Проверяем суффиксом домена — тем же приёмом, что _api.py::dossier.
        Ловить ValueError из get_global нельзя: так проглотится и настоящий
        сбой БД.
        """
        return user_id.endswith(":" + self._server_name)

    async def _dm_room_ids(self, user_id: str) -> set:
        # m.direct — приватные account data пользователя, они живут на ЕГО
        # домашнем сервере. Для федеративного MXID Synapse бросает ValueError
        # (AccountDataManager._validate_user_id) → досье падало с HTTP 500.
        if not self._is_local(user_id):
            return set()
        data = await self._account_data.get_global(user_id, DIRECT_ACCOUNT_DATA)
        if not isinstance(data, Mapping):
            return set()
        rooms = set()
        for value in data.values():
            if isinstance(value, (list, tuple)):
                rooms.update(str(room) for room in value)
        return rooms

    async def _bot_dm_room_ids(self, user_id: str) -> set:
        """DM целевого пользователя, где собеседник — бот.

        m.direct хранит {mxid собеседника: [room_id]} — собеседник
        известен из ключа, дополнительных запросов не нужно.
        """
        if not self._is_local(user_id):
            return set()
        data = await self._account_data.get_global(user_id, DIRECT_ACCOUNT_DATA)
        if not isinstance(data, Mapping):
            return set()
        rooms = set()
        for peer_id, value in data.items():
            if not is_bot_user(
                str(peer_id), self._bot_localparts, self._bots_homeserver
            ):
                continue
            if isinstance(value, (list, tuple)):
                rooms.update(str(room) for room in value)
        return rooms

    async def collect(self, target_id: str) -> dict:
        rows = await self._fetch_rows(target_id)
        dm_rooms = await self._dm_room_ids(target_id)
        bot_dm_rooms = await self._bot_dm_room_ids(target_id)
        return build_dossier_groups(
            rows,
            target_id=target_id,
            server_name=self._server_name,
            dm_room_ids=dm_rooms,
            bot_dm_room_ids=bot_dm_rooms,
        )

    async def power_in_room(self, user_id: str, room_id: str) -> int:
        """PL пользователя НЕПОСРЕДСТВЕННО в указанной комнате.

        В отличие от shared_space_power_pairs (PL в пространствах,
        где состоит ЦЕЛЕВОЙ пользователь) — здесь целевого пользователя
        нет, есть конкретная space-комната из URL (space_members), и нужен
        прямой запрос PL вызывающего именно в ней.
        """

        def _txn(txn):
            txn.execute(
                """
                SELECT ej.json
                FROM current_state_events AS pl
                LEFT JOIN event_json AS ej ON ej.event_id = pl.event_id
                WHERE pl.room_id = ?
                  AND pl.type = 'm.room.power_levels'
                  AND pl.state_key = ''
                """,
                (room_id,),
            )
            return txn.fetchone()

        row = await self._db.runInteraction("access_admin_power_in_room", _txn)
        power_raw = row[0] if row else None
        return power_from_content(_content_from_json(power_raw), user_id)

    async def shared_space_power_pairs(
        self, caller_id: str, target_id: str
    ) -> list[tuple[int, int]]:
        """(PL вызывающего, PL цели) в пространствах, где состоит цель.

        Оба уровня читаются из одного content m.room.power_levels — лишнего
        запроса нет. PL цели нужен деактивации: админ (99) не вправе
        действовать над владельцем (100) и другим админом.
        """
        target_rows = await self._fetch_rows(target_id)
        target_spaces = {
            row[0]
            for row in target_rows
            if row[3] == "m.space" and is_local_room(row[0], self._server_name)
        }
        if not target_spaces:
            return []

        caller_rows = await self._fetch_rows(caller_id)
        powers = []
        for (
            room_id,
            _name,
            _avatar,
            _room_type,
            power_raw,
            _create,
            _topology,
            _tombstone,
        ) in caller_rows:
            if room_id in target_spaces:
                content = _content_from_json(power_raw)
                powers.append(
                    (
                        power_from_content(content, caller_id),
                        power_from_content(content, target_id),
                    )
                )
        return powers
