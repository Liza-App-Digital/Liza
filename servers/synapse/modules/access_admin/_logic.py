"""Чистая логика управления доступами.

Namespace-пакет: __init__.py у access_admin импортирует synapse, поэтому
логика вынесена сюда — так её тесты не требуют установленного Synapse.
"""

ROOM_TYPE_SPACE = "m.space"
ROOM_TYPE_CHANNEL = "com.liza.channel"

CHAT_TYPE_KEY = "com.liza.chat.type"
CHAT_TYPE_STORIES = "stories"
CHAT_TYPE_DISCUSSION = "channel_discussion"

LEGACY_STORIES_KEY = "com.liza.stories"
TOPOLOGY_STATE_TYPE = "com.liza.chat.topology"

LEVEL_ADMIN = "admin"
LEVEL_MODERATOR = "moderator"
LEVEL_USER = "user"

# Роли в комнате (механика ВК, спека 2026-10-14-room-owner-role-design):
# владелец 100, администратор 99, модератор 50. «Админ» — от 99 и выше,
# зеркало adminPowerLevel клиента (lib/utils/chat_topology.dart). Порог 100
# отрезал бы новых админов компании от досье и деактивации.
OWNER_POWER_LEVEL = 100
ADMIN_POWER_LEVEL = 99
MODERATOR_POWER_LEVEL = 50

DEFAULT_BOT_LOCALPARTS = frozenset(
    {"liza", "gpt", "deepseek", "bot_father", "botfather"}
)
DEFAULT_BOTS_HOMESERVER = "bots.liza.ru"


def level_from_power(power: int) -> str:
    if power >= ADMIN_POWER_LEVEL:
        return LEVEL_ADMIN
    if power >= MODERATOR_POWER_LEVEL:
        return LEVEL_MODERATOR
    return LEVEL_USER


def power_from_content(content: dict | None, user_id: str) -> int:
    """Power level пользователя из content события m.room.power_levels."""
    if not isinstance(content, dict):
        return 0
    users = content.get("users")
    if isinstance(users, dict) and user_id in users:
        value = users[user_id]
        return value if isinstance(value, int) else 0
    default = content.get("users_default", 0)
    return default if isinstance(default, int) else 0


def classify_room(
    room_type: str | None,
    chat_type: str | None,
    *,
    legacy_stories: bool = False,
) -> str | None:
    """Группа комнаты для досье, либо None если комнату не показываем.

    Служебные комнаты (сторисы, обсуждения каналов) отсеиваются по
    com.liza.chat.type из creation_content: они попадают в выдачу как
    обычные комнаты с room_type = NULL. legacy_stories — старый ключ
    com.liza.stories=true у комнат, созданных stories_membership до
    перехода на новый ключ; клиент и chat_topology_sync_gate его
    проверяют, поэтому проверяем и здесь.
    """
    if chat_type in (CHAT_TYPE_STORIES, CHAT_TYPE_DISCUSSION):
        return None
    if room_type == ROOM_TYPE_SPACE:
        return "space"
    if room_type == ROOM_TYPE_CHANNEL:
        return "channel"
    # Легаси-ключ проверяем ПОСЛЕ room_type: сторисы — всегда комнаты с
    # room_type = NULL, а space/канал с этим ключом означал бы потерю
    # пространства из досье.
    if legacy_stories:
        return None
    # Неизвестный room_type не теряем: тихое исчезновение комнаты из досье
    # хуже лишней строки — админ не узнает, что членство существует.
    return "chat"


def is_bot_user(
    user_id: str, bot_localparts: frozenset, bots_homeserver: str
) -> bool:
    """Бот определяется по аккаунту: домен ботового инстанса либо
    известный localpart. Признака бот-комнаты в Matrix нет."""
    if not user_id.startswith("@") or ":" not in user_id:
        return False
    localpart, _, domain = user_id[1:].partition(":")
    if domain == bots_homeserver:
        return True
    return localpart in bot_localparts


def is_local_room(room_id: str, server_name: str) -> bool:
    """Комнаты чужих серверов больше не отсекаются.

    Досье описывает всё, что известно НАШЕМУ серверу: комната с чужим
    доменом в room_id, где состоит пользователь, — такое же валидное
    членство. Функция сохранена, чтобы не менять сигнатуры вызовов.
    """
    return True


def is_hidden_room(
    topology_content: dict | None,
    chat_type: str | None,
    legacy_stories: bool,
) -> bool:
    """Зеркало isHiddenChat из clients/flutter/lib/utils/chat_topology.dart.

    Ярус com.liza.chat.revealed намеренно НЕ учитывается: это персональная
    настройка смотрящего, а досье описывает членства другого пользователя.
    Так же поступает chat_topology_sync_gate.
    """
    if topology_content is not None:
        return topology_content.get("hidden") is True
    return legacy_stories or chat_type == CHAT_TYPE_STORIES
