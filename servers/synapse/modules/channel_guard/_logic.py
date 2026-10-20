"""Pure-предикаты channel_guard: без импорта synapse, тестируются напрямую."""

CHAT_TYPE_KEY = "com.liza.chat.type"
CHANNEL_TYPE = "channel"
# Стандартный m.room.create ключ типа комнаты. Именно он доезжает до
# room_stats_state.room_type и попадает в ответ /publicRooms.
ROOM_TYPE_KEY = "type"
LIZA_CHANNEL_ROOM_TYPE = "com.liza.channel"


def is_channel_creation(config: dict) -> bool:
    """True, если create-room config создаёт канал (com.liza.chat.type=channel)."""
    creation_content = config.get("creation_content") or {}
    return creation_content.get(CHAT_TYPE_KEY) == CHANNEL_TYPE


def mark_channel_room_type(config: dict) -> bool:
    """Проставить каналу стандартный room_type, чтобы он был отличим в каталоге.

    publicRooms отдаёт room_type из room_stats_state, куда Synapse пишет
    m.room.create -> type. Наш com.liza.chat.type туда не попадает, поэтому
    публичный канал неотличим от публичного чата на клиенте.

    Мутируем config["creation_content"]: handlers/room.py читает его ПОСЛЕ
    вызова on_create_room (см. creation_content = config.get(...) там же),
    и Synapse штатно допускает правку конфига из third-party rules.

    Возвращает True, если пометка проставлена (для лога/тестов).
    """
    if not is_channel_creation(config):
        return False
    creation_content = config.setdefault("creation_content", {})
    if creation_content.get(ROOM_TYPE_KEY):
        return False  # тип уже задан явно — не перетираем
    creation_content[ROOM_TYPE_KEY] = LIZA_CHANNEL_ROOM_TYPE
    return True
