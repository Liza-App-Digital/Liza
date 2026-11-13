"""block_guard: чистая логика реальной блокировки пользователя (LABA-2545).

Namespace-пакет: __init__.py импортирует synapse, поэтому решения вынесены сюда —
их тесты не требуют установленного Synapse (unittest, как knock_notify/channel_sync).

Дизайн — docs/superpowers/specs/2026-09-04-block-user-enforcement-design.md.
"""

from collections.abc import Mapping, Sequence
from typing import Any, Iterable

# ⚠️ ModuleApi.account_data_manager.get_global() отдаёт содержимое через
# synapse.util.frozenutils.freeze: словари становятся `immutabledict` (НЕ подкласс
# dict), а списки — кортежами. Проверки `isinstance(x, dict)` / `isinstance(x, list)`
# на таком содержимом молча дают False → предикат «не заблокирован» → fail-open, и
# энфорс не срабатывает вообще. Поймано живым прогоном на инстансе hello
# (юнит-тесты на простых dict были зелёными). Поэтому ниже — Mapping/Sequence.


def _is_mapping(value: Any) -> bool:
    return isinstance(value, Mapping)


def _is_sequence(value: Any) -> bool:
    """Список room_id: list ИЛИ tuple (после freeze), но не строка."""
    return isinstance(value, Sequence) and not isinstance(value, (str, bytes))


MEMBER_EVENT_TYPE = "m.room.member"
CREATE_EVENT_TYPE = "m.room.create"

# Типы, которые вообще могут быть заблокированы. Всё остальное (power_levels,
# topic, com.liza.chat.hidden_members, knock, redaction) отсекается ПЕРВОЙ же
# проверкой — до любого обращения к БД. Без этого фильтра под удар попадали бы
# knock-заявки (RL-knock-push-to-inviters) и скрытие участников
# (RL-participant-hidden-from-list).
BLOCKABLE_MESSAGE_TYPES = frozenset(
    {"m.room.message", "m.room.encrypted", "m.reaction"}
)

ROOM_TYPE_SPACE = "m.space"
ROOM_TYPE_CHANNEL = "com.liza.channel"

CHAT_TYPE_KEY = "com.liza.chat.type"
CHAT_TYPE_STORIES = "stories"
CHAT_TYPE_DISCUSSION = "channel_discussion"
LEGACY_STORIES_KEY = "com.liza.stories"
TOPOLOGY_STATE_TYPE = "com.liza.chat.topology"

IGNORED_USER_LIST = "m.ignored_user_list"
DIRECT_ACCOUNT_DATA = "m.direct"
USER_ROLE_ACCOUNT_DATA = "com.liza.user_role"

# Отказ отдаём СВОИМ errcode, а не M_FORBIDDEN. Причины (обе проверены):
# 1. SDK matrix-4.1.0 (room.dart:1274-1288) перебрасывает исключение наружу
#    ИМЕННО на M_FORBIDDEN, а текстовые отправки в чате зовутся без catch
#    (chat.dart:490,1301,1305) → был бы шторм unhandled-исключений в мониторинге;
# 2. клиент затирает M_FORBIDDEN на generic «Нет прав»
#    (localized_exception_extension.dart:54-58), а неизвестный errcode уходит в
#    ветку default: и показывает наш текст ДОСЛОВНО — то есть понятный отказ
#    работает и на уже установленных сборках, без релиза.
BLOCKED_ERRCODE = "RU.PRODAMUS.LIZA_BLOCKED"
BLOCKED_MESSAGE = "Пользователь ограничил круг общения: вы не можете писать ему."

DEFAULT_SERVICE_LOCALPARTS = (
    "liza",
    "bot_father",
    "botfather",
    "support",
    "bo_food",
)


def is_blockable_event_type(event_type: Any, content: dict | None) -> bool:
    """Первый (и самый дешёвый) фильтр: может ли событие в принципе блокироваться.

    True для сообщений/реакций и для ЛИЧНОГО приглашения (m.room.member с
    membership=invite и is_direct). knock, leave, ban, join и любые прочие
    state-события — False, до БД дело не доходит.
    """
    if event_type in BLOCKABLE_MESSAGE_TYPES:
        return True
    if event_type != MEMBER_EVENT_TYPE:
        return False
    c = content or {}
    return c.get("membership") == "invite" and c.get("is_direct") is True


def is_service_localpart(user_id: str, service_localparts: Iterable[str]) -> bool:
    """Служебный аккаунт по localpart (работает и для УДАЛЁННЫХ ботов).

    Роль `ai` читается отдельно через account_data — здесь только та половина,
    которую можно решить без БД. Зеркало stories_membership._is_ai_user.
    """
    localpart = (user_id or "").split(":", 1)[0].lstrip("@")
    return localpart in set(service_localparts)


def is_exempt_room(
    room_type: str | None,
    chat_type: str | None,
    topology_content: dict | None,
    *,
    legacy_stories: bool = False,
) -> bool:
    """Комнаты, которых энфорс не касается ВООБЩЕ.

    Пространства и каналы — блокировка личная, общие площадки не трогаем.
    Сторис/скрытые — иначе тихо разваливается сторис-граф: stories_membership
    раздаёт членство инвайтом и глотает исключения в logger.debug, регрессия
    была бы бесшумной (обвинение прокурора №9).
    """
    if room_type in (ROOM_TYPE_SPACE, ROOM_TYPE_CHANNEL):
        return True
    if chat_type in (CHAT_TYPE_STORIES, CHAT_TYPE_DISCUSSION):
        return True
    if legacy_stories:
        return True
    if _is_mapping(topology_content) and topology_content.get("hidden") is True:
        return True
    return False


def joined_and_invited(members: Iterable[tuple[str, str]]) -> list[str]:
    """Участники комнаты в состоянии join/invite — состав «личного чата»."""
    return [
        user_id
        for user_id, membership in members
        if membership in ("join", "invite")
    ]


def dm_counterpart(members: Iterable[tuple[str, str]], sender: str) -> str | None:
    """Единственный собеседник в паре, либо None если комната не парная.

    Ровно 2 участника — НЕОБХОДИМОЕ условие личного чата, но не достаточное
    (схлопнувшаяся группа, комната заявки саппорта, сторис-комната тоже парные).
    Достаточность даёт m.direct — см. room_is_direct_for.
    """
    participants = joined_and_invited(members)
    if len(participants) != 2 or sender not in participants:
        return None
    for user_id in participants:
        if user_id != sender:
            return user_id
    return None


def room_is_direct_for(direct_content: Any, room_id: str) -> bool:
    """Числится ли room_id личным чатом в m.direct пользователя.

    m.direct = {mxid собеседника: [room_id, ...]}. Зеркало
    stories_membership._room_is_registered_dm — единственный протокольно
    корректный дискриминатор «настоящий DM vs просто парная комната».
    """
    if not _is_mapping(direct_content) or not room_id:
        return False
    for rooms in direct_content.values():
        if _is_sequence(rooms) and room_id in rooms:
            return True
    return False


def ignores(ignored_user_list_content: Any, user_id: str) -> bool:
    """Держит ли владелец списка данного пользователя в m.ignored_user_list."""
    if not _is_mapping(ignored_user_list_content):
        return False
    ignored = ignored_user_list_content.get("ignored_users")
    return _is_mapping(ignored) and user_id in ignored


def blocked_invitees(
    config: dict | None,
    ignore_lookup: dict[str, bool],
) -> list[str]:
    """Кого из приглашаемых при создании ЛИЧНОГО чата нельзя приглашать.

    config — тело /createRoom. Путь апгрейда комнаты (handlers/room.py:700)
    передаёт урезанный dict БЕЗ ключа invite → список пуст, fast-path allow.
    ignore_lookup: {invitee -> он игнорирует создателя}.
    """
    cfg = config or {}
    if not _is_mapping(cfg) or not cfg.get("is_direct"):
        return []
    invites = cfg.get("invite")
    if not _is_sequence(invites):
        return []
    return [u for u in invites if isinstance(u, str) and ignore_lookup.get(u)]


def should_notify_invite(sender: str, invited_ignored_users: Iterable[str]) -> bool:
    """R1: слать ли пуш о приглашении.

    Зеркало однострочной правки в
    servers/synapse/src/synapse/push/bulk_push_rule_evaluator.py. Живёт здесь,
    потому что ledger-check.sh сканирует servers/synapse/modules/*/tests и НЕ
    видит servers/synapse/src/tests — без этой функции страж AC-5/AC-6 был бы
    невидим реестру.

    Смысл правки: sync уже отбрасывает инвайты от игнорируемых
    (handlers/sync.py:2680-2682), а push спрашивал ДРУГОЙ источник —
    get_invite_config_for_user (MSC4155/4380), который при выключенном
    msc4155_enabled всегда отвечает «всё разрешено». Отсюда пуш-«призрак»:
    уведомление приходит, а чата в списке нет.
    """
    return sender not in set(invited_ignored_users)
