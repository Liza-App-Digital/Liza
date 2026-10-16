"""Pure-предикаты channel_sync: без импорта synapse, тестируются напрямую."""

CHANNEL_DISCUSSION_STATE = "com.liza.channel.discussion"
CHANNEL_PARENT_STATE = "com.liza.channel.parent"
POST_REF_KEY = "com.liza.channel.post_ref"
DISCUSSION_CHAT_TYPE = "channel_discussion"
# Ключ в content com.liza.channel.discussion, которым клиент помечает удаление
# КАНАЛА (а не выключение комментариев). Пишется РЯДОМ с room_id, не вместо
# него. См. channel_deleted_of.
CHANNEL_DELETED_KEY = "deleted"

JOIN_RULES_STATE = "m.room.join_rules"
HISTORY_VISIBILITY_STATE = "m.room.history_visibility"
TOPOLOGY_STATE = "com.liza.chat.topology"

_RELATES = "m.relates_to"


def is_root_post(event_type: str, content: dict) -> bool:
    """Корневой пост канала: m.room.message без relation (не reply/edit)."""
    if event_type != "m.room.message":
        return False
    return _RELATES not in content


def is_edit(content: dict) -> bool:
    rel = content.get(_RELATES) or {}
    return rel.get("rel_type") == "m.replace"


def edited_event_id(content: dict) -> str | None:
    rel = content.get(_RELATES) or {}
    if rel.get("rel_type") != "m.replace":
        return None
    return rel.get("event_id")


def discussion_room_of(create_content: dict, discussion_state_content: dict | None) -> str | None:
    """room_id привязанного чата из state com.liza.channel.discussion, или None.

    Маркер удаления (deleted:true) здесь НАМЕРЕННО не учитывается: маркер
    пишется вместе с room_id и обязан оставлять чат находимым. На нём держится
    кик подписчиков из чата обсуждения при удалении канала — см.
    ChannelSyncModule._on_channel_leave и channel_deleted_of.
    """
    if not discussion_state_content:
        return None
    return discussion_state_content.get("room_id")


def channel_deleted_of(discussion_state_content: dict | None) -> bool:
    """Маркер «канал удалён» в content com.liza.channel.discussion.

    В Matrix нет события «комната удалена»: удаление канала — это кик
    участников + leave + forget, сервер видит ровно те же события, что и при
    обычной отписке. Поэтому удаление помечается ЯВНО: клиент перед уходом
    пишет в привязку {"room_id": <чат>, "deleted": true}. Выводить удаление из
    простой отвязки нельзя — это и был баг, из-за которого выключение
    комментариев стирало связь постов с комментариями безвозвратно.

    room_id в маркере ОБЯЗАТЕЛЕН и держит инвариант порядка: кик каждого
    подписчика из канала обрабатывается фоново (run_as_background_process), и
    к моменту, когда фоновый процесс дочитает привязку, маркер уже может быть
    записан. Пустой content на этом месте (как было в первой версии) означал
    бы «комментариев нет» → часть подписчиков осталась бы членами чата
    обсуждения. С room_id ответ не зависит от того, что успело приземлиться
    раньше.

    Признаём только литеральный True: маркер запускает необратимое удаление
    строк, и «правдоподобное» значение (строка "true", 1) от чужого клиента
    не должно к нему приводить.
    """
    if not discussion_state_content:
        return False
    return discussion_state_content.get(CHANNEL_DELETED_KEY) is True


def should_cleanup_mappings(
    *,
    prev_room: str | None,
    new_room: str | None,
    channel_deleted: bool,
) -> bool:
    """Нужно ли удалять маппинги пост→зеркало отвязанного чата.

    Отвязка чата (выключение комментариев) маппинги СОХРАНЯЕТ: чат остаётся
    целым, и при повторном включении комментарии возвращаются — так же, как
    при повторном включении. Раньше здесь чистилось всё подряд, и старые треды
    восстановить было уже нельзя.

    Чистим в двух случаях: канал удалён либо привязка переехала на ДРУГОЙ
    чат (маппинги старого больше никому не нужны).
    """
    if not prev_room:
        return False
    if channel_deleted:
        return True
    return new_room is not None and new_room != prev_room


def build_mirror_content(post_content: dict, channel_id: str, post_event_id: str) -> dict:
    """Копия content поста + маркер обратной ссылки на оригинал."""
    mirror = dict(post_content)
    mirror[POST_REF_KEY] = {
        "channel_id": channel_id,
        "post_event_id": post_event_id,
    }
    return mirror


def join_rule_of(content: dict | None) -> str | None:
    """join_rule из content события m.room.join_rules, или None."""
    if not content:
        return None
    return content.get("join_rule")


def is_public_channel(join_rule: str | None) -> bool:
    return join_rule == "public"


def is_membership_leave(event_type: str, content: dict) -> bool:
    """Событие членства, лишающее доступа: отписка (leave) или бан (ban).

    Бан здесь равен уходу: забаненный в канале не должен оставаться в
    привязанном чате обсуждения. Копия семантики
    channel_stories._logic.is_channel_leave.
    """
    return event_type == "m.room.member" and content.get("membership") in (
        "leave",
        "ban",
    )


def discussion_settings_for(channel_join_rule: str | None, channel_id: str) -> dict:
    """Настройки привязанного чата под приватность канала.

    Открытый канал: чат public + world_readable — комментарии видны без
    членства (peek), войти можно самому при первой отправке.

    Закрытый: restricted с allow по членству в КАНАЛЕ + shared — механика
    Telegram (Надежда 15.10: «возьми механику у тг»): доступ к обсуждению
    даёт сама подписка, без приглашений. Подписчик входит тихим join при
    первом комментарии, как в открытом канале. Раньше здесь был invite, и
    подписчики, вступившие до включения комментариев (или до смены
    открытый → закрытый), получали отказ до ближайшего рестарта Synapse.

    allow указывает на канал, который можно покинуть, а не на корень
    компании с вечным членством (LABA-2539 — другой механизм).

    Любое НЕизвестное правило (knock/restricted/None) трактуем как закрытый
    канал: ошибка в сторону приватности не раскрывает чужие комментарии.
    """
    if is_public_channel(channel_join_rule):
        return {"join_rule": "public", "history_visibility": "world_readable"}
    return {
        "join_rule": "restricted",
        "allow": [{"type": "m.room_membership", "room_id": channel_id}],
        "history_visibility": "shared",
    }


def join_rules_content(settings: dict) -> dict:
    """content события m.room.join_rules из discussion_settings_for.

    restricted без allow означает «войти не может никто», поэтому allow
    обязан ехать в КАЖДОЙ записи правила, а не только при создании.
    """
    content = {"join_rule": settings["join_rule"]}
    if "allow" in settings:
        content["allow"] = settings["allow"]
    return content


def plan_discussion_migration(snapshot: dict) -> dict:
    """Что надо изменить в привязанном чате канала, чтобы он соответствовал
    целевой модели (см. docs/superpowers/specs/2026-07-24-channels-fixes-design.md
    и 2026-10-15-nadya-answers-discussion-place-search-owner-leave-design.md).

    Чистая функция: снимок состояния собирает вызывающий (модуль читает его из
    Synapse), решение принимается здесь и тестируется без Synapse.

    Ключи снимка: channel_id, channel_join_rule, discussion_join_rules
    (content m.room.join_rules чата), discussion_history_visibility,
    discussion_hidden.

    Возвращает {"set_join_rules", "set_history_visibility", "set_hidden"};
    уже правильное — None/False, поэтому повторный прогон не порождает
    записей (идемпотентность считается ЗДЕСЬ, а не в вызывающем).

    Инвайтов больше нет: закрытый канал пускает в чат по членству (allow).
    Уже висящие инвайты не отзываем — они по-прежнему принимаются.
    """
    wanted = discussion_settings_for(
        snapshot.get("channel_join_rule"), snapshot.get("channel_id") or ""
    )
    wanted_rules = join_rules_content(wanted)
    current = snapshot.get("discussion_join_rules") or {}
    current_rules = {k: current[k] for k in ("join_rule", "allow") if k in current}
    if current_rules.get("join_rule") != "restricted":
        current_rules.pop("allow", None)

    set_join_rules = wanted_rules if current_rules != wanted_rules else None
    set_history = (
        wanted["history_visibility"]
        if snapshot.get("discussion_history_visibility")
        != wanted["history_visibility"]
        else None
    )

    # Чаты, созданные до этой ветки, топологию не несут вовсе: без неё
    # isHiddenChat=False, и обсуждение вылезает отдельной строкой в списке
    # чатов. hidden:true — «скрыто у всех по умолчанию»; персональное
    # раскрытие живёт в room account data и этой простановкой не затрагивается.
    set_hidden = snapshot.get("discussion_hidden") is not True

    return {
        "set_join_rules": set_join_rules,
        "set_history_visibility": set_history,
        "set_hidden": set_hidden,
    }


def plan_is_noop(plan: dict) -> bool:
    """True, если по плану делать нечего — канал уже мигрирован."""
    return (
        plan["set_join_rules"] is None
        and plan["set_history_visibility"] is None
        and not plan["set_hidden"]
    )


# Порог прав исполнителя: state_default/kick пресета private_chat.
ACTOR_MIN_LEVEL = 50


def pick_discussion_actor(
    creator: str | None,
    joined_local: list[str],
    power_levels: dict | None,
) -> str | None:
    """От чьего имени модуль пишет в чат обсуждения.

    Раньше — всегда создатель чата. Но уход создателя из КАНАЛА кикает его и
    из чата (_on_channel_leave), и после этого инвайты, миграция, кик
    отписавшихся и зеркала постов молча падали: отправителя нет в комнате.
    Передача владения при выходе (Надежда 15.10) делает такой уход частым.

    Создатель — если он локальный участник чата. Иначе локальный участник с
    наибольшим PL не ниже [ACTOR_MIN_LEVEL] (state/kick по умолчанию), при
    равенстве — первый по mxid. Свои есть, но прав ни у кого нет — None:
    запись от рядового упала бы 403 молча. Своих в чате не видно — создатель,
    как раньше: запись упадёт и залогируется, хуже прежнего не станет.
    """
    joined = sorted(set(joined_local))
    if not joined or creator in joined:
        return creator
    content = power_levels or {}
    users = content.get("users") or {}
    default = content.get("users_default", 0)

    def level(user_id: str) -> int:
        value = users.get(user_id, default)
        return value if isinstance(value, int) else 0

    best = min(joined, key=lambda u: (-level(u), u))
    return best if level(best) >= ACTOR_MIN_LEVEL else None
