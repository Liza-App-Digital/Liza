"""knock_notify: чистая логика выбора получателей пуша о заявке (knock).

Тестируется без реального Synapse (unittest + asyncio, как channel_sync).
"""

from typing import Any, Callable, Iterable

MEMBER_EVENT_TYPE = "m.room.member"
POWER_LEVELS_TYPE = "m.room.power_levels"
ROOM_NAME_TYPE = "m.room.name"

# Нижняя граница порога «может рассматривать заявки» = модератор (PL 50).
# Совпадает с клиентским moderatorPowerLevel (chat_topology.dart). Через один
# invite-порог гейтить НЕЛЬЗЯ: у старой компании (space) invite:0 → пуш о
# заявке утёк бы ВСЕМ участникам (находка flutter-critic). Итоговый порог —
# review_threshold() = max(50, invite).
MODERATOR_POWER_LEVEL = 50


def is_knock_membership(event_type: Any, content: dict | None) -> bool:
    """True для m.room.member с membership=knock (заявка на вступление)."""
    return (
        event_type == MEMBER_EVENT_TYPE
        and (content or {}).get("membership") == "knock"
    )


def user_power_level(user_id: str, power_levels_content: dict | None) -> int:
    """PL пользователя из m.room.power_levels: users[user] или users_default."""
    pl = power_levels_content or {}
    users = pl.get("users")
    if isinstance(users, dict) and user_id in users:
        try:
            return int(users[user_id])
        except (TypeError, ValueError):
            pass
    try:
        return int(pl.get("users_default", 0))
    except (TypeError, ValueError):
        return 0


def review_threshold(power_levels_content: dict | None) -> int:
    """Порог ревьюера заявки: max(модератор, invite).

    При «приглашают только админы» (invite:99, задача 13) модератор заявку
    одобрить не может — значит, и пуш о ней ему не нужен. Та же формула в
    клиенте: knockReviewThreshold (lib/utils/knock_requests.dart).
    """
    raw = (power_levels_content or {}).get("invite", 0)
    try:
        invite = int(raw)
    except (TypeError, ValueError):
        invite = 0
    return max(MODERATOR_POWER_LEVEL, invite)


def knock_reviewers(
    members: Iterable[tuple[str, str]],
    power_levels_content: dict | None,
    knocker: str | None,
    is_local: Callable[[str], bool],
    min_level: int | None = None,
) -> list[str]:
    """Локальные joined-участники с PL>=min_level, кроме самого стучащегося.

    min_level по умолчанию — review_threshold(power_levels_content).

    members: iterable из (user_id, membership).
    is_local: callable(user_id)->bool — обслуживаем только своих; каждый инстанс
        достучится до СВОИХ локальных ревьюеров, дублей между инстансами нет.
    Сам knocker исключён: о своём действии пуш не шлём.
    """
    if min_level is None:
        min_level = review_threshold(power_levels_content)
    result: set[str] = set()
    for user_id, membership in members:
        if membership != "join":
            continue
        if knocker is not None and user_id == knocker:
            continue
        if not is_local(user_id):
            continue
        if user_power_level(user_id, power_levels_content) >= min_level:
            result.add(user_id)
    return sorted(result)


def build_push_content(
    event: Any,
    sender_display_name: str | None = None,
    room_name: str | None = None,
) -> dict:
    """notification-payload для send_http_push_notification.

    Текст «постучался» клиент рендерит по event_id (calcLocalizedBodyFallback →
    hasKnocked). Кладём event_id/room_id/type/sender/membership + читаемые имена,
    prio=high (membership не звенит по дефолту — поднимаем, чтобы iOS NSE/Android
    доставили). `counts` НАМЕРЕННО не трогаем: доставка идёт мимо
    event_push_actions, notification_count/бейдж не инфлируется.
    """
    content: dict = {
        "event_id": getattr(event, "event_id", None),
        "room_id": getattr(event, "room_id", None),
        "type": MEMBER_EVENT_TYPE,
        "sender": getattr(event, "sender", None),
        "membership": "knock",
        "prio": "high",
    }
    if sender_display_name:
        content["sender_display_name"] = sender_display_name
    if room_name:
        content["room_name"] = room_name
    return content
