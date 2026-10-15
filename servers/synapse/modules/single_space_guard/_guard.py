"""Pure predicates for single_space_guard. No synapse imports - testable standalone."""

SPACE_TYPE = "m.space"
SPACE_PARENT_EVENT = "m.space.parent"
SPACE_PARENT_MARKER = "io.liza.has_space_parent"
MEMBER_EVENT = "m.room.member"
PROTECTED_MEMBERSHIPS = ("leave", "ban")


def is_root_space_creation(config: dict) -> bool:
    """True если createRoom-конфиг создаёт пространство 1-го уровня (root-space).

    root-space = space без указания родителя в initial_state.
    """
    creation_content = config.get("creation_content") or {}
    if creation_content.get("type") != SPACE_TYPE:
        return False
    initial_state = config.get("initial_state") or []
    has_parent = any(
        ev.get("type") == SPACE_PARENT_EVENT for ev in initial_state
    )
    return not has_parent


def has_initial_space_parent(config: dict) -> bool:
    """True если createRoom-конфиг объявляет родителя в initial_state."""
    initial_state = config.get("initial_state") or []
    return any(
        isinstance(ev, dict)
        and ev.get("type") == SPACE_PARENT_EVENT
        and bool(ev.get("state_key"))
        for ev in initial_state
    )


def apply_space_parent_marker(config: dict) -> None:
    """Пометить в creation_content, что комната рождается с родителем.

    Автодобавление в компанию решается на m.room.create, а initial_state
    применяется позже — без маркера группа, созданная в подпространстве,
    уходила ещё и в главное пространство (второй входящий m.space.child).
    Маркер едет в content самого m.room.create, то есть привязан к комнате, а
    не к sender: параллельные createRoom не путаются, упавший createRoom не
    оставляет висящей пометки. Ставит его только сервер — присланный клиентом
    без настоящего m.space.parent снимается.

    Маркер не отменяет автодобавление, а ОТКЛАДЫВАЕТ его (auto_add_delay_ms):
    parent в initial_state сервер не проверяет, а клиент пишет m.space.child
    отдельным запросом и может не успеть (упал, сеть). Если к сроку входящего
    m.space.child нет — комната вкладывается в компанию как обычно.
    """
    creation_content = config.get("creation_content")
    if has_initial_space_parent(config):
        if not isinstance(creation_content, dict):
            creation_content = {}
            config["creation_content"] = creation_content
        creation_content[SPACE_PARENT_MARKER] = True
    elif isinstance(creation_content, dict):
        creation_content.pop(SPACE_PARENT_MARKER, None)


def auto_add_delay_ms(create_content: dict, grace_ms: int) -> int:
    """Через сколько мс вкладывать новую комнату в компанию: 0 — сразу."""
    if create_content.get(SPACE_PARENT_MARKER) is True:
        return grace_ms
    return 0


def is_dm_creation(config: dict) -> bool:
    """True если createRoom-конфиг создаёт direct-чат (DM).

    Клиент шлёт is_direct=True при создании DM (startDirectChat). Признак
    доступен в on_create_room ДО создания комнаты; m.direct/is_direct в
    state-событиях появляются позже.
    """
    return bool(config.get("is_direct"))


def is_protected_membership_change(
    *,
    event_type: str,
    membership,
    room_id: str,
    main_root_space_id,
) -> bool:
    """True если событие - выход/бан из главного пространства (надо запретить)."""
    if main_root_space_id is None:
        return False
    if event_type != MEMBER_EVENT:
        return False
    if membership not in PROTECTED_MEMBERSHIPS:
        return False
    return room_id == main_root_space_id


def is_space_chunk(chunk: dict) -> bool:
    """True если элемент publicRooms-выдачи — пространство (m.space)."""
    return chunk.get("room_type") == SPACE_TYPE


def is_auto_add_candidate(
    *,
    room_type: str | None,
    is_direct: bool,
    has_space_parent: bool,
    is_local: bool,
) -> bool:
    """True если комнату надо авто-добавить в компанию.

    Кандидат: локальная (на этом homeserver) группа — не space, не DM, и ещё
    не вложена ни в одно пространство (нет m.space.parent / не child).
    """
    if not is_local:
        return False
    if room_type == SPACE_TYPE:
        return False
    if is_direct:
        return False
    if has_space_parent:
        return False
    return True


def is_local_room(room_id: str, server_name: str) -> bool:
    """True если комната зарождена на этом homeserver.

    room_id имеет вид !localpart:origin_server, где origin_server - homeserver,
    на котором комната создана (неизменен). Ведущий ":" в суффиксе отсекает
    ложные совпадения по поддомену.
    """
    return bool(room_id) and room_id.endswith(":" + server_name)


# Все unicode-варианты дефиса/тире, которые надо считать одним символом:
# -(U+002D) ‑(U+2011) –(U+2013) —(U+2014) −(U+2212).
_DASHES = "-‑–—−"
_DASH_TABLE = {ord(d): "-" for d in _DASHES}


def _normalize(text: str) -> str:
    """casefold + унификация тире + схлопывание пробелов. Для сравнения имён."""
    text = text.translate(_DASH_TABLE)
    text = " ".join(text.split())
    return text.casefold()


def matches_query(name: str | None, query: str | None) -> bool:
    """True если имя компании содержит query.

    Сравнение регистро- и тире-независимое (casefold + унификация дефисов),
    пробелы схлопываются. Пустой/None query совпадает со всеми. None name
    совпадает только с пустым query.
    """
    if not query:
        return True
    if not name:
        return False
    return _normalize(query) in _normalize(name)


def deduplicate_companies(companies: list[dict]) -> list[dict]:
    """Дедупликация списка компаний по room_id, порядок сохраняется."""
    seen: set[str] = set()
    result: list[dict] = []
    for c in companies:
        rid = c.get("room_id")
        if rid is None or rid in seen:
            continue
        seen.add(rid)
        result.append(c)
    return result


def root_response(room_id: str | None, company: bool) -> dict:
    """Тело ответа GET /single_space/v1/root.

    ``company`` — класс инстанса (= ``auto_add_new``): компания, где все чаты
    живут в одном главном пространстве, или общий инстанс (users.liza.ru, bots,
    стенд). Клиент по нему включает гейт приглашений «кнопка у всех, без права —
    плашка» (задача 13, спека 2026-10-14-search-sections-and-company-invite-
    admin-only). Старый сервер поля не отдаёт — клиент читает это как false.
    """
    return {"exists": room_id is not None, "room_id": room_id, "company": bool(company)}
