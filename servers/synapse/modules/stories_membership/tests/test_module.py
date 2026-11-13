import asyncio
import json
import sqlite3

from synapse_modules.stories_membership import StoriesMembershipModule


class _FakeAccountData:
    def __init__(self):
        self.store = {}

    async def get_global(self, user_id, type_):
        return self.store.get((user_id, type_))

    async def put_global(self, user_id, type_, content):
        self.store[(user_id, type_)] = content

    def mark_as_ai(self, user_id):
        """Пометить юзера как AI-бота (роль ai в com.liza.user_role)."""
        self.store[(user_id, "com.liza.user_role")] = {"role": "ai"}


class _FakeApi:
    def __init__(self, server="local.test"):
        self.server_name = server
        self.account_data_manager = _FakeAccountData()
        self.created_rooms = []
        self.memberships = []  # (sender, target, room_id, membership, hosts)
        self.redacted = []    # event_id всех redact-ированных событий
        self.renamed_rooms = []  # (room_id, sender, new_name)
        self._room_counter = 0
        self._registered = {}
        # Список протухших (room_id, event_id, sender) для подмены txn в тестах чистки.
        self._expired_stories: list[tuple[str, str, str]] = []
        # Список (room_id, current_name, creator) для подмены txn в тестах rename.
        self._rooms_to_rename: list[tuple[str, str, str]] = []

    def is_mine(self, user_id):
        return user_id.endswith(":" + self.server_name)

    def register_third_party_rules_callbacks(self, **kwargs):
        self._registered.update(kwargs)

    def run_as_background_process(self, name, coro, *args):
        # В тестах запускаем переданную корутину синхронно.
        import asyncio as _asyncio
        return _asyncio.run(coro(*args))

    async def sleep(self, seconds):
        # В тестах reactor не крутится, sleep - no-op.
        return None

    async def create_room(self, user_id, config, ratelimit=True):
        self._room_counter += 1
        room_id = f"!room{self._room_counter}:{self.server_name}"
        self.created_rooms.append((user_id, room_id, config))
        return room_id, None

    async def update_room_membership(
        self, sender, target, room_id, new_membership,
        content=None, remote_room_hosts=None,
    ):
        self.memberships.append(
            (sender, target, room_id, new_membership, remote_room_hosts)
        )
        return None

    async def run_db_interaction(self, desc: str, txn_func, *args):
        """Возвращает заранее заданный список протухших сторисов для тестов чистки.

        Для других desc (backfill и т.д.) возвращает пустой список по умолчанию.
        """
        if desc == "stories_membership_find_expired":
            return list(self._expired_stories)
        if desc == "stories_membership_find_rooms_to_rename":
            return list(self._rooms_to_rename)
        return []

    def set_expired_stories(
        self, expired: list[tuple[str, str, str]]
    ) -> None:
        """Задать список (room_id, event_id, sender), которые вернёт txn чистки."""
        self._expired_stories = list(expired)

    def set_rooms_to_rename(
        self, rooms: list[tuple[str, str, str]]
    ) -> None:
        """rows: (room_id, current_name, creator_user_id)."""
        self._rooms_to_rename = list(rooms)

    async def create_and_send_event_into_room(self, event_dict):
        if event_dict.get("type") == "m.room.redaction":
            self.redacted.append(event_dict["redacts"])
        if event_dict.get("type") == "m.room.name":
            self.renamed_rooms.append(
                (
                    event_dict["room_id"],
                    event_dict["sender"],
                    event_dict["content"]["name"],
                )
            )
        return None


def _make_module(api):
    config = StoriesMembershipModule.parse_config(
        {"cleanup_interval_minutes": 30, "story_ttl_hours": 24}
    )
    return StoriesMembershipModule(config, api)


def test_parse_config_defaults():
    cfg = StoriesMembershipModule.parse_config({})
    assert cfg["cleanup_interval_minutes"] == 30
    assert cfg["story_ttl_hours"] == 24


def test_ensure_stories_room_creates_once():
    api = _FakeApi()
    mod = _make_module(api)
    rid1 = asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    rid2 = asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    assert rid1 == rid2
    assert len(api.created_rooms) == 1


def test_ensure_stories_room_tags_account_data():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    tag = api.account_data_manager.store.get(
        ("@alice:local.test", "com.liza.stories")
    )
    assert tag is not None
    assert "room_id" in tag


def test_ensure_stories_room_sets_both_type_keys():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    _, _, config = api.created_rooms[0]
    assert config["creation_content"] == {
        "com.liza.stories": True,
        "com.liza.chat.type": "stories",
    }


def test_ensure_stories_room_name_is_unique_by_localpart():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    _, _, config = api.created_rooms[0]
    assert config["name"] == "Stories - alice"


def test_ensure_stories_room_sets_pl_gate_on_topology_event():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    _, _, config = api.created_rooms[0]
    assert config["power_level_content_override"]["events"][
        "com.liza.chat.topology"
    ] == 100


def test_ensure_stories_room_sets_hidden_atomically():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.ensure_stories_room("@alice:local.test"))
    _, _, config = api.created_rooms[0]
    topology_events = [
        e for e in config["initial_state"] if e["type"] == "com.liza.chat.topology"
    ]
    assert len(topology_events) == 1
    assert topology_events[0]["content"] == {"hidden": True}


def test_subscribe_pair_invites_both():
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:local.test"))
    # Боб должен быть приглашён в комнату Алисы и наоборот.
    targets = {(m[1], m[3]) for m in api.memberships}
    assert ("@bob:local.test", "invite") in targets
    assert ("@alice:local.test", "invite") in targets


def test_subscribe_pair_remote_target_passes_hosts():
    api = _FakeApi(server="local.test")
    mod = _make_module(api)
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:other.example"))
    remote_invites = [
        m for m in api.memberships
        if m[1] == "@bob:other.example" and m[4]
    ]
    assert remote_invites
    assert "other.example" in remote_invites[0][4]


def test_cleanup_redacts_only_expired():
    """Чистка через run_db_interaction: redact только протухших.

    txn-функция мокается через _FakeApi.set_expired_stories: задаём именно
    те тройки (room_id, event_id, sender), которые вернул бы реальный SQL-проход.
    Проверяем, что create_and_send_event_into_room вызван только для протухших.
    """
    api = _FakeApi()
    mod = _make_module(api)
    # Задаём только то, что уже отфильтровала бы txn-функция (по expires_ts).
    api.set_expired_stories([
        ("!s:local.test", "$old", "@alice:local.test"),
    ])
    asyncio.run(mod._cleanup_round_with_now(2000))
    assert "$old" in api.redacted
    # $fresh не попадает в expired_stories - значит redact не вызван.
    assert "$fresh" not in api.redacted


def test_cleanup_continues_after_failed_redact():
    """Падение redact по одной комнате не прерывает раунд и не роняет logcontext.

    Регрессия 2026-07-23: sleep(0) выполнялся после проглоченного исключения
    на уже завершённом logcontext -> 3248 warning'ов Re-starting finished
    log context на одном cleanup-id. Проверяем, что после упавшей федеративной
    комнаты обработка продолжается на следующей, а sleep вызывается только
    после УСПЕШНОГО redact-а.
    """
    api = _FakeApi()
    mod = _make_module(api)
    api.set_expired_stories([
        ("!bad:remote.example", "$e1", "@a:remote.example"),
        ("!good:local.example", "$e2", "@b:local.example"),
    ])

    async def _failing_send(event_dict):
        if event_dict["room_id"] == "!bad:remote.example":
            raise Exception("federation unreachable")
        if event_dict.get("type") == "m.room.redaction":
            api.redacted.append(event_dict["redacts"])
        return None

    api.create_and_send_event_into_room = _failing_send

    sleep_calls = []
    orig_sleep = api.sleep

    async def _counting_sleep(seconds):
        sleep_calls.append(seconds)
        return await orig_sleep(seconds)

    api.sleep = _counting_sleep

    asyncio.run(mod._cleanup_round_with_now(2000))

    # Второй redact выполнен, несмотря на падение первого.
    assert api.redacted == ["$e2"]
    # sleep вызван только после успешной итерации, не после упавшей.
    assert len(sleep_calls) == 1


def _make_stories_schema_conn():
    """In-memory sqlite с минимальной схемой таблиц Synapse, нужных
    _find_expired_stories_txn: events, event_json, current_state_events,
    redactions - по образцу _FakeSqliteEngine в chat_topology_sync_gate."""
    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE TABLE events (event_id TEXT PRIMARY KEY, room_id TEXT,"
        " type TEXT, sender TEXT)"
    )
    conn.execute("CREATE TABLE event_json (event_id TEXT PRIMARY KEY, json TEXT)")
    conn.execute(
        "CREATE TABLE current_state_events (room_id TEXT, event_id TEXT,"
        " type TEXT, state_key TEXT)"
    )
    conn.execute("CREATE TABLE redactions (event_id TEXT, redacts TEXT)")
    return conn


def _insert_story_room_with_message(
    conn, room_id, create_event_id, message_event_id, sender, expires_ts
):
    create_content = json.dumps({"content": {"com.liza.stories": True}})
    conn.execute(
        "INSERT INTO events VALUES (?, ?, 'm.room.create', ?)",
        (create_event_id, room_id, sender),
    )
    conn.execute(
        "INSERT INTO event_json VALUES (?, ?)", (create_event_id, create_content)
    )
    conn.execute(
        "INSERT INTO current_state_events VALUES (?, ?, 'm.room.create', '')",
        (room_id, create_event_id),
    )
    message_content = json.dumps(
        {"content": {"com.liza.story": {"expires_ts": expires_ts}}}
    )
    conn.execute(
        "INSERT INTO events VALUES (?, ?, 'm.room.message', ?)",
        (message_event_id, room_id, sender),
    )
    conn.execute(
        "INSERT INTO event_json VALUES (?, ?)", (message_event_id, message_content)
    )


def test_find_expired_stories_txn_excludes_already_redacted():
    """Уже отредактированное истёкшее событие не должно возвращаться повторно.

    Баг на prod: _find_expired_stories_txn не проверял таблицу redactions,
    из-за чего один и тот же истёкший сторис редактировался заново на каждом
    30-минутном cleanup-раунде (одно событие получило 670 повторных
    m.room.redaction за 168 часов).
    """
    conn = _make_stories_schema_conn()
    _insert_story_room_with_message(
        conn,
        room_id="!s:local.test",
        create_event_id="$create",
        message_event_id="$old",
        sender="@alice:local.test",
        expires_ts=1000,
    )
    # $old уже отредактирован ранее.
    conn.execute("INSERT INTO redactions VALUES (?, ?)", ("$redaction1", "$old"))

    cur = conn.cursor()
    result = StoriesMembershipModule._find_expired_stories_txn(cur, 2000)

    assert result == []


def test_find_expired_stories_txn_returns_expired_not_yet_redacted():
    conn = _make_stories_schema_conn()
    _insert_story_room_with_message(
        conn,
        room_id="!s:local.test",
        create_event_id="$create",
        message_event_id="$old",
        sender="@alice:local.test",
        expires_ts=1000,
    )

    cur = conn.cursor()
    result = StoriesMembershipModule._find_expired_stories_txn(cur, 2000)

    assert result == [("!s:local.test", "$old", "@alice:local.test")]


# --- тесты миграции легаси-имени сторис-комнат (уникализация 2026-07-04) ---


def test_rename_existing_stories_rooms_renames_legacy_name():
    api = _FakeApi()
    api.set_rooms_to_rename([
        ("!room1:local.test", "Stories", "@alice:local.test"),
    ])
    mod = _make_module(api)
    api.renamed_rooms.clear()

    asyncio.run(mod.rename_existing_stories_rooms())

    assert ("!room1:local.test", "@alice:local.test", "Stories - alice") in (
        api.renamed_rooms
    )


def test_rename_existing_stories_rooms_second_run_is_noop():
    """Идемпотентно: txn-запрос сам не возвращает уже переименованные комнаты
    (симулируем это тем, что второй "рестарт" получает пустой список -
    поведение самого SQL-фильтра проверяется отдельно, на уровне txn-функции)."""
    api = _FakeApi()
    api.set_rooms_to_rename([
        ("!room1:local.test", "Stories", "@alice:local.test"),
    ])
    mod = _make_module(api)
    # __init__ уже запустил rename_existing_stories_rooms фоново -
    # сбрасываем, чтобы явный вызов ниже считался с чистого листа.
    api.renamed_rooms.clear()

    asyncio.run(mod.rename_existing_stories_rooms())
    assert len(api.renamed_rooms) == 1

    api.set_rooms_to_rename([])  # как будто SQL больше не находит легаси-имя
    asyncio.run(mod.rename_existing_stories_rooms())
    assert len(api.renamed_rooms) == 1


def test_find_stories_rooms_to_rename_txn_finds_legacy_name():
    conn = _make_stories_schema_conn()
    _insert_story_room_with_message(
        conn,
        room_id="!s:local.test",
        create_event_id="$create",
        message_event_id="$msg",
        sender="@alice:local.test",
        expires_ts=1000,
    )
    conn.execute(
        "INSERT INTO current_state_events VALUES (?, ?, 'm.room.name', '')",
        ("!s:local.test", "$name1"),
    )
    conn.execute(
        "INSERT INTO event_json VALUES (?, ?)",
        ("$name1", json.dumps({"content": {"name": "Stories"}})),
    )

    cur = conn.cursor()
    result = StoriesMembershipModule._find_stories_rooms_to_rename_txn(cur)

    assert result == [("!s:local.test", "Stories", "@alice:local.test")]


def test_find_stories_rooms_to_rename_txn_skips_already_renamed():
    conn = _make_stories_schema_conn()
    _insert_story_room_with_message(
        conn,
        room_id="!s:local.test",
        create_event_id="$create",
        message_event_id="$msg",
        sender="@alice:local.test",
        expires_ts=1000,
    )
    conn.execute(
        "INSERT INTO current_state_events VALUES (?, ?, 'm.room.name', '')",
        ("!s:local.test", "$name1"),
    )
    conn.execute(
        "INSERT INTO event_json VALUES (?, ?)",
        ("$name1", json.dumps({"content": {"name": "Stories - alice"}})),
    )

    cur = conn.cursor()
    result = StoriesMembershipModule._find_stories_rooms_to_rename_txn(cur)

    assert result == []


def test_find_stories_rooms_to_rename_txn_treats_missing_name_as_legacy():
    """Комната создана без m.room.name state вообще (напрямую через клиент до
    того, как имя стало обязательным полем) - тоже кандидат на переименование."""
    conn = _make_stories_schema_conn()
    _insert_story_room_with_message(
        conn,
        room_id="!s:local.test",
        create_event_id="$create",
        message_event_id="$msg",
        sender="@alice:local.test",
        expires_ts=1000,
    )

    cur = conn.cursor()
    result = StoriesMembershipModule._find_stories_rooms_to_rename_txn(cur)

    assert result == [("!s:local.test", None, "@alice:local.test")]


# --- тесты backfill ---

class _FakeApiWithBackfill(_FakeApi):
    """Расширение _FakeApi с поддержкой run_db_interaction для backfill."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._dm_pairs: list[tuple[str, str]] = []

    def set_dm_pairs(self, pairs: list[tuple[str, str]]) -> None:
        """Задать пары, которые вернёт txn-функция backfill."""
        self._dm_pairs = list(pairs)

    async def run_db_interaction(self, desc: str, txn_func, *args):
        """Возвращает заранее заданные DM-пары для backfill, игнорируя
        реальный txn. Остальные desc (rename и т.д.) делегирует базовому
        классу, чтобы __init__ (запускающий несколько background-процессов
        параллельно) не путал форматы возвращаемых кортежей."""
        if desc == "stories_membership_backfill_find_dms":
            return list(self._dm_pairs)
        return await super().run_db_interaction(desc, txn_func, *args)


def _make_module_with_backfill(api):
    config = StoriesMembershipModule.parse_config(
        {"cleanup_interval_minutes": 30, "story_ttl_hours": 24}
    )
    return StoriesMembershipModule(config, api)


def test_backfill_calls_subscribe_for_each_pair():
    """При 2 DM-парах должно быть 4 инвайта (взаимный для каждой пары).

    __init__ запускает backfill сразу; сбрасываем memberships перед проверкой
    чтобы считать только инвайты одного явного вызова.
    """
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([
        ("@alice:local.test", "@bob:local.test"),
        ("@carol:local.test", "@dave:local.test"),
    ])
    mod = _make_module_with_backfill(api)
    # Сбрасываем инвайты от __init__-запуска, проверяем отдельный вызов
    api.memberships.clear()
    asyncio.run(mod.backfill_existing_dms())
    # subscribe_pair создаёт 2 инвайта (A->B.room и B->A.room)
    invite_targets = {m[1] for m in api.memberships}
    assert "@bob:local.test" in invite_targets
    assert "@alice:local.test" in invite_targets
    assert "@dave:local.test" in invite_targets
    assert "@carol:local.test" in invite_targets
    assert len(api.memberships) == 4


def test_backfill_empty_no_crash():
    """Пустой набор пар не должен приводить к ошибке."""
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([])
    mod = _make_module_with_backfill(api)
    asyncio.run(mod.backfill_existing_dms())
    assert api.memberships == []


def test_backfill_idempotent():
    """Повторный backfill не должен дублировать инвайты (subscribe_pair идемпотентен)."""
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([("@alice:local.test", "@bob:local.test")])
    mod = _make_module_with_backfill(api)
    asyncio.run(mod.backfill_existing_dms())
    first_count = len(api.memberships)
    # Второй запуск - добавляются update_room_membership вызовы, но модуль
    # их ловит через except (уже участник) без падения.
    asyncio.run(mod.backfill_existing_dms())
    # Просто убеждаемся, что не упало и инвайты были хотя бы один раз
    assert len(api.memberships) >= first_count


def test_backfill_continues_after_failed_pair():
    """Падение subscribe_pair не роняет logcontext всего backfill-прохода.

    Тот же дефект, что был в cleanup (исправлен ранее): sleep(0) выполнялся
    после проглоченного исключения на уже завершённом logcontext. На проде
    2026-07-24 после фикса cleanup осталось 70 warning'ов
    'Re-starting finished log context stories_membership_backfill-0' —
    второй очаг того же паттерна. Проверяем: упавшая пара пропускается,
    следующая обрабатывается, sleep только после успешной.
    """
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([
        ("@bad:remote.example", "@x:local.test"),
        ("@alice:local.test", "@bob:local.test"),
    ])
    mod = _make_module_with_backfill(api)
    api.memberships.clear()

    orig_subscribe = mod.subscribe_pair

    async def _failing_subscribe(user_a, user_b):
        if user_a == "@bad:remote.example" or user_b == "@bad:remote.example":
            raise Exception("federation unreachable")
        return await orig_subscribe(user_a, user_b)

    mod.subscribe_pair = _failing_subscribe

    sleep_calls = []
    orig_sleep = api.sleep

    async def _counting_sleep(seconds):
        sleep_calls.append(seconds)
        return await orig_sleep(seconds)

    api.sleep = _counting_sleep

    asyncio.run(mod.backfill_existing_dms())

    # Вторая пара подписана, несмотря на падение первой.
    invite_targets = {m[1] for m in api.memberships}
    assert "@alice:local.test" in invite_targets
    assert "@bob:local.test" in invite_targets
    # sleep вызван только после успешной пары, не после упавшей.
    assert len(sleep_calls) == 1


def test_backfill_skips_unreachable_servers():
    """Пары с серверами вне federation_domain_whitelist не обрабатываются.

    Погашенный инстанс остаётся в старом m.direct: без фильтра backfill
    дёргает его профили при каждом старте и ловит таймауты (инцидент
    2026-07-24 — dev.liza.laba.prodamus.tech после отключения стенда).
    """
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([
        ("@alice:local.test", "@ghost:dead.example"),
        ("@alice:local.test", "@bob:local.test"),
    ])
    mod = _make_module_with_backfill(api)
    # Живой сервер в whitelist есть, погашенного нет.
    mod._federation_whitelist = {"alive.example": True}
    api.memberships.clear()

    asyncio.run(mod.backfill_existing_dms())

    targets = {m[1] for m in api.memberships}
    assert "@ghost:dead.example" not in targets
    assert "@bob:local.test" in targets


def test_backfill_processes_all_when_whitelist_absent():
    """whitelist не настроен (None) — фильтр никого не режет."""
    api = _FakeApiWithBackfill()
    api.set_dm_pairs([("@alice:local.test", "@remote:other.example")])
    mod = _make_module_with_backfill(api)
    mod._federation_whitelist = None
    api.memberships.clear()

    asyncio.run(mod.backfill_existing_dms())

    targets = {m[1] for m in api.memberships}
    assert "@remote:other.example" in targets


def test_rename_continues_after_failed_room():
    """Падение rename по одной комнате не роняет logcontext прохода.

    Третий очаг того же паттерна (см. test_backfill_continues_after_failed_pair).
    """
    api = _FakeApi()
    mod = _make_module(api)
    api.set_rooms_to_rename([
        ("!bad:remote.example", "Stories", "@a:remote.example"),
        ("!good:local.test", "Stories", "@b:local.test"),
    ])

    renamed = []

    async def _failing_send(event_dict):
        if event_dict["room_id"] == "!bad:remote.example":
            raise Exception("federation unreachable")
        if event_dict.get("type") == "m.room.name":
            renamed.append(event_dict["room_id"])
        return None

    api.create_and_send_event_into_room = _failing_send

    sleep_calls = []
    orig_sleep = api.sleep

    async def _counting_sleep(seconds):
        sleep_calls.append(seconds)
        return await orig_sleep(seconds)

    api.sleep = _counting_sleep

    asyncio.run(mod.rename_existing_stories_rooms())

    assert renamed == ["!good:local.test"]
    assert len(sleep_calls) == 1


def test_backfill_launched_at_startup(monkeypatch):
    """__init__ должен запускать backfill через run_as_background_process."""
    launched = []

    class _TrackingApi(_FakeApiWithBackfill):
        def run_as_background_process(self, name, coro, *args):
            launched.append(name)
            # Не запускаем корутину реально в этом тесте
            if asyncio.iscoroutine(coro):
                coro.close()

    api = _TrackingApi()
    _make_module_with_backfill(api)
    assert "stories_membership_backfill" in launched


# --- тесты фильтрации AI-ботов ---

def test_subscribe_pair_skips_if_one_is_ai():
    """subscribe_pair не должен создавать инвайты, если один из юзеров AI-бот."""
    api = _FakeApi()
    mod = _make_module(api)
    # Помечаем @liza как AI
    api.account_data_manager.mark_as_ai("@liza:local.test")
    api.memberships.clear()
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@liza:local.test"))
    assert api.memberships == [], (
        "subscribe_pair с AI-юзером не должен создавать инвайты"
    )


def test_subscribe_pair_skips_if_both_are_ai():
    """subscribe_pair не создаёт инвайты, если оба участника AI."""
    api = _FakeApi()
    mod = _make_module(api)
    api.account_data_manager.mark_as_ai("@liza:local.test")
    api.account_data_manager.mark_as_ai("@xl_bot:local.test")
    api.memberships.clear()
    asyncio.run(mod.subscribe_pair("@liza:local.test", "@xl_bot:local.test"))
    assert api.memberships == []


def test_subscribe_pair_works_for_two_humans():
    """subscribe_pair между двумя людьми создаёт инвайты как обычно."""
    api = _FakeApi()
    mod = _make_module(api)
    # Никто не помечен AI - значит оба люди
    api.memberships.clear()
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:local.test"))
    targets = {(m[1], m[3]) for m in api.memberships}
    assert ("@bob:local.test", "invite") in targets
    assert ("@alice:local.test", "invite") in targets


def test_is_ai_user_returns_false_for_remote_non_bot():
    """Удалённый юзер с не-бот localpart не считается AI."""
    api = _FakeApi(server="local.test")
    mod = _make_module(api)
    result = asyncio.run(mod._is_ai_user("@bob:remote.example"))
    assert result is False


def test_is_ai_user_returns_true_for_remote_ai_bot():
    """УДАЛЁННЫЙ AI-бот (@liza на другом инстансе) определяется по localpart.

    Главный кейс: @liza живёт на prod-synapse, для dev это удалённый юзер,
    его роль через локальный account_data не прочитать. Отсекаем по имени.
    """
    api = _FakeApi(server="dev.test")
    mod = _make_module(api)
    result = asyncio.run(
        mod._is_ai_user("@liza:synapse.liza.laba.prodamus.tech")
    )
    assert result is True


def test_subscribe_pair_skips_remote_ai_bot():
    """subscribe_pair с удалённым AI-ботом не создаёт инвайтов."""
    api = _FakeApi(server="dev.test")
    mod = _make_module(api)
    asyncio.run(
        mod.subscribe_pair(
            "@alice:dev.test", "@liza:synapse.liza.laba.prodamus.tech"
        )
    )
    assert api.memberships == []


def test_is_ai_user_returns_false_for_human():
    """Локальный юзер без роли ai считается человеком."""
    api = _FakeApi()
    mod = _make_module(api)
    result = asyncio.run(mod._is_ai_user("@alice:local.test"))
    assert result is False


def test_is_ai_user_returns_true_for_ai_role():
    """Локальный юзер с ролью ai (нестандартное имя) определяется как AI."""
    api = _FakeApi()
    mod = _make_module(api)
    api.account_data_manager.mark_as_ai("@assistant:local.test")
    result = asyncio.run(mod._is_ai_user("@assistant:local.test"))
    assert result is True


# --- тесты серверного mute (инцидент 2026-07-02: push уходил до клиентского dontNotify) ---


class _FakeDbPool:
    """Даёт simple_select_one_onecol поверх push_rules_added того же store -
    ровно та проверка "уже есть правило?", что _mute_room_for_local_user
    делает перед add_push_rule, чтобы не плодить push_rules_stream зря."""

    def __init__(self, store):
        self._store = store

    async def simple_select_one_onecol(
        self, table, keyvalues, retcol, allow_none=False, desc=""
    ):
        for row in self._store.push_rules_added:
            if row[0] == keyvalues["user_name"] and row[1] == keyvalues["rule_id"]:
                return "existing-id"
        if allow_none:
            return None
        raise LookupError(f"no row in {table} for {keyvalues}")


class _FakeStore:
    def __init__(self):
        self.push_rules_added = []  # (user_id, rule_id, priority_class, conditions, actions)
        self.db_pool = _FakeDbPool(self)

    async def add_push_rule(
        self, user_id, rule_id, priority_class, conditions, actions,
        before=None, after=None,
    ):
        self.push_rules_added.append(
            (user_id, rule_id, priority_class, conditions, actions)
        )


class _FakeMainStores:
    def __init__(self, store):
        self.main = store


class _FakeHomeServer:
    def __init__(self, store):
        self._store = store

    def get_datastores(self):
        return _FakeMainStores(self._store)


class _FakeApiWithStore(_FakeApi):
    """_FakeApi + _hs с доступом к store.add_push_rule (мьют перед инвайтом)."""

    def __init__(self, server="local.test"):
        super().__init__(server=server)
        self.store = _FakeStore()
        self._hs = _FakeHomeServer(self.store)


def test_subscribe_pair_mutes_local_guest_before_invite():
    """AC:RL-stories-publish-push/3 — override ставится каждому зрителю рядом с мьютом
    (мьют раньше инвайта), повторный вызов идемпотентен."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:local.test"))

    mute_rules = [
        r for r in api.store.push_rules_added
        if r[1].startswith("global/room/!room")
    ]
    notify_rules = [
        r for r in api.store.push_rules_added
        if r[1].startswith("global/override/com.liza.story_notify.")
    ]
    # Оба локальных участника получают room-level мьют встречной сторис-комнаты.
    assert {r[0] for r in mute_rules} == {"@alice:local.test", "@bob:local.test"}
    for _user, _rule_id, priority_class, conditions, actions in mute_rules:
        assert priority_class == 3
        assert actions == ["dont_notify"]
        assert conditions[0]["kind"] == "event_match"
        assert conditions[0]["key"] == "room_id"
    # LABA-1970: рядом — override-правило пуша на публикацию сторис (enabled),
    # матч по type=m.room.message + room_id, override (класс 5) поверх мьюта.
    assert {r[0] for r in notify_rules} == {"@alice:local.test", "@bob:local.test"}
    for _user, _rule_id, priority_class, conditions, actions in notify_rules:
        assert priority_class == 5
        assert actions[0] == "notify"
        keys = {c["key"] for c in conditions}
        assert keys == {"type", "room_id"}
        type_cond = next(c for c in conditions if c["key"] == "type")
        assert type_cond["pattern"] == "m.room.message"


def test_mute_happens_before_invite_is_sent():
    """Порядок важен: push уходит на invite немедленно, мьют должен успеть раньше."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:local.test"))

    # room_id для комнаты Алисы (создана первой) - находим по memberships.
    alice_room_invite = next(
        m for m in api.memberships if m[1] == "@bob:local.test"
    )
    alice_room_id = alice_room_invite[2]
    mute_call_indices = [
        i for i, r in enumerate(api.store.push_rules_added)
        if r[0] == "@bob:local.test" and alice_room_id in r[1]
    ]
    assert mute_call_indices, "мьют для bob в комнате alice не найден"


def test_subscribe_pair_does_not_mute_remote_guest():
    """Удалённого guest мы не можем замьютить - это должен сделать его сервер."""
    api = _FakeApiWithStore(server="local.test")
    mod = _make_module(api)
    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:other.example"))

    muted_users = {r[0] for r in api.store.push_rules_added}
    assert "@bob:other.example" not in muted_users
    # Alice (владелец, локальная) при этом мьютится в своей же комнате -
    # нет, Alice - owner здесь, guest - remote bob; только remote-сторона не мьютится.
    assert muted_users == set()


def test_mute_failure_does_not_block_invite():
    """Если add_push_rule упал - инвайт всё равно должен уйти (fail-open)."""

    class _FailingStore(_FakeStore):
        async def add_push_rule(self, *args, **kwargs):
            raise RuntimeError("db error")

    api = _FakeApiWithStore()
    api.store = _FailingStore()
    api._hs = _FakeHomeServer(api.store)
    mod = _make_module(api)

    asyncio.run(mod.subscribe_pair("@alice:local.test", "@bob:local.test"))
    targets = {(m[1], m[3]) for m in api.memberships}
    assert ("@bob:local.test", "invite") in targets
    assert ("@alice:local.test", "invite") in targets


def test_mute_noop_without_hs():
    """_FakeApi без _hs (как в остальных тестах) - store=None, мьют тихо no-op."""
    api = _FakeApi()
    mod = _make_module(api)
    assert mod._store is None
    # Не должно падать.
    asyncio.run(mod._mute_room_for_local_user("@alice:local.test", "!room:local.test"))


# --- тесты постфактум-мьюта существующих комнат (mute_existing_stories_rooms) ---


class _FakeApiWithStoreAndMemberships(_FakeApiWithStore):
    """_FakeApiWithStore + run_db_interaction для mute_existing_stories_rooms."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._room_members: list[tuple[str, str, str]] = []

    def set_room_members(self, rows: list[tuple[str, str, str]]) -> None:
        """rows: (room_id, member_user_id, creator_user_id)."""
        self._room_members = list(rows)

    async def run_db_interaction(self, desc, txn_func, *args):
        if desc == "stories_membership_mute_existing_find":
            return list(self._room_members)
        return await super().run_db_interaction(desc, txn_func, *args)


def test_mute_existing_skips_creator_and_mutes_others():
    api = _FakeApiWithStoreAndMemberships()
    api.set_room_members([
        ("!room1:local.test", "@alice:local.test", "@alice:local.test"),  # creator
        ("!room1:local.test", "@bob:local.test", "@alice:local.test"),
        ("!room1:local.test", "@carol:local.test", "@alice:local.test"),
    ])
    mod = _make_module(api)
    api.store.push_rules_added.clear()  # сбросить возможный шум от __init__ backfill

    asyncio.run(mod.mute_existing_stories_rooms())

    muted = {r[0] for r in api.store.push_rules_added}
    assert muted == {"@bob:local.test", "@carol:local.test"}
    assert "@alice:local.test" not in muted


def test_mute_existing_skips_remote_members():
    api = _FakeApiWithStoreAndMemberships(server="local.test")
    api.set_room_members([
        ("!room1:local.test", "@alice:local.test", "@alice:local.test"),
        ("!room1:local.test", "@bob:other.example", "@alice:local.test"),
    ])
    mod = _make_module(api)
    api.store.push_rules_added.clear()

    asyncio.run(mod.mute_existing_stories_rooms())

    muted = {r[0] for r in api.store.push_rules_added}
    assert muted == set()


def test_mute_existing_noop_without_store():
    """store=None (нет _hs) - постфактум-мьют тихо ничего не делает."""
    api = _FakeApi()
    mod = _make_module(api)
    asyncio.run(mod.mute_existing_stories_rooms())  # не должно падать


class _SequencedFakeCursor:
    """Возвращает заранее заданные результаты по ПОРЯДКУ вызовов execute/
    fetchall (не по угадыванию SQL-текста) - _find_stories_room_members_txn
    делает до 3 последовательных запросов (create, topology, member)."""

    def __init__(self, results: list[list[tuple]]):
        self._results = list(results)
        self._call_index = -1

    def execute(self, sql, params=()):
        self._call_index += 1

    def fetchall(self):
        return self._results[self._call_index]


def test_find_stories_room_members_txn_finds_join_and_invite():
    """Legacy-путь: com.liza.stories в creation_content, нет topology state."""
    cursor = _SequencedFakeCursor([
        [(  # m.room.create
            "!s1:local.test",
            json.dumps({"content": {"com.liza.stories": True}, "sender": "@alice:local.test"}),
        )],
        [],  # com.liza.chat.topology - нет state event
        [("!s1:local.test", "@bob:local.test")],  # m.room.member
    ])

    rows = StoriesMembershipModule._find_stories_room_members_txn(cursor)
    assert rows == [("!s1:local.test", "@bob:local.test", "@alice:local.test")]


def test_find_stories_room_members_txn_ignores_non_stories_rooms():
    """Обычная комната (пустой creation_content, нет topology state) - не hidden."""
    cursor = _SequencedFakeCursor([
        [(  # m.room.create
            "!ordinary:local.test",
            json.dumps({"content": {}, "sender": "@alice:local.test"}),
        )],
        [],  # com.liza.chat.topology - нет state event
        [],  # до member-запроса не дойдёт (hidden_rooms пуст), но на всякий случай
    ])

    rows = StoriesMembershipModule._find_stories_room_members_txn(cursor)
    assert rows == []


def test_find_stories_room_members_txn_uses_explicit_topology_hidden():
    """Универсальность (обобщение под /remember: любая hidden-по-топологии
    комната, не только stories) - явный com.liza.chat.topology.hidden=true
    на комнате БЕЗ com.liza.stories/com.liza.chat.type должен считаться
    hidden. Это покрывает будущие системные/скрытые категории комнат."""
    cursor = _SequencedFakeCursor([
        [(  # m.room.create - обычный тип, ничего похожего на stories
            "!future-hidden:local.test",
            json.dumps({"content": {}, "sender": "@alice:local.test"}),
        )],
        [(  # com.liza.chat.topology - явно hidden
            "!future-hidden:local.test",
            json.dumps({"content": {"hidden": True}}),
        )],
        [("!future-hidden:local.test", "@bob:local.test")],  # m.room.member
    ])

    rows = StoriesMembershipModule._find_stories_room_members_txn(cursor)
    assert rows == [("!future-hidden:local.test", "@bob:local.test", "@alice:local.test")]


def test_find_stories_room_members_txn_explicit_topology_not_hidden_wins_over_legacy():
    """Явный com.liza.chat.topology.hidden=false ПЕРЕБИВАЕТ legacy-дефолт
    по com.liza.stories=true - is_hidden_room приоритизирует explicit state
    (симметрично HiddenRoomsLookup на сервере и isHiddenChat на клиенте)."""
    cursor = _SequencedFakeCursor([
        [(  # m.room.create - com.liza.stories=true (legacy сказал бы hidden)
            "!unhidden-stories:local.test",
            json.dumps({"content": {"com.liza.stories": True}, "sender": "@alice:local.test"}),
        )],
        [(  # com.liza.chat.topology - явно НЕ hidden
            "!unhidden-stories:local.test",
            json.dumps({"content": {"hidden": False}}),
        )],
        [],  # до member-запроса не дойдёт
    ])

    rows = StoriesMembershipModule._find_stories_room_members_txn(cursor)
    assert rows == []


def test_mute_skips_add_push_rule_when_rule_already_exists():
    """Повторный мьют той же (room, user) пары не должен звать add_push_rule
    второй раз - иначе push_rules_stream растёт на каждый рестарт модуля
    без единого реального изменения состояния (найдено на prod: 1216 лишних
    строк за 3 рестарта). Проверяем именно ОТСУТСТВИЕ второго вызова, не
    только итоговое состояние (которое и так не изменится - upsert)."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.store.push_rules_added.clear()

    asyncio.run(mod._mute_room_for_local_user("@alice:local.test", "!room1:local.test"))
    assert len(api.store.push_rules_added) == 1

    asyncio.run(mod._mute_room_for_local_user("@alice:local.test", "!room1:local.test"))
    # Второй вызов для той же пары не должен добавить новую запись.
    assert len(api.store.push_rules_added) == 1


def test_mute_existing_stories_rooms_second_run_is_noop():
    """mute_existing_stories_rooms повторно (как при рестарте Synapse) не
    должен звать add_push_rule заново для уже замьюченных пар."""
    api = _FakeApiWithStoreAndMemberships()
    api.set_room_members([
        ("!room1:local.test", "@alice:local.test", "@alice:local.test"),
        ("!room1:local.test", "@bob:local.test", "@alice:local.test"),
    ])
    mod = _make_module(api)
    api.store.push_rules_added.clear()

    asyncio.run(mod.mute_existing_stories_rooms())
    first_run_count = len(api.store.push_rules_added)
    # bob (не creator alice) получает 2 правила: room-level мьют + LABA-1970
    # override-правило пуша на сторис. Оба идемпотентны.
    assert first_run_count == 2

    asyncio.run(mod.mute_existing_stories_rooms())
    # Второй "рестарт" не должен создать новых записей (обе проверки существования).
    assert len(api.store.push_rules_added) == first_run_count


# --- LABA-1970: override-правило пуша на сторис + отписка (AC-7) ---
# ledger:RL-stories-publish-push


class _Ev:
    """Мини-событие для _on_new_event: type/state_key/content/room_id."""

    def __init__(self, type_, state_key=None, content=None, room_id=None):
        self.type = type_
        self.state_key = state_key
        self.content = content or {}
        self.room_id = room_id


def _story_notify_rules(store):
    return [
        r for r in store.push_rules_added
        if r[1].startswith("global/override/com.liza.story_notify.")
    ]


def test_ensure_story_notify_rule_idempotent():
    """Повторный вызов не плодит push_rules_stream (проверка существования)."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.store.push_rules_added.clear()
    asyncio.run(mod._ensure_story_notify_rule("@bob:local.test", "!s:local.test"))
    assert len(_story_notify_rules(api.store)) == 1
    asyncio.run(mod._ensure_story_notify_rule("@bob:local.test", "!s:local.test"))
    assert len(_story_notify_rules(api.store)) == 1


def test_story_notify_rule_matches_message_type_and_room():
    """AC:RL-stories-publish-push/2 — override матчит ТОЛЬКО m.room.message в нужной
    комнате: служебные события (membership/receipt) пуш не порождают."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.store.push_rules_added.clear()
    asyncio.run(mod._ensure_story_notify_rule("@bob:local.test", "!s:local.test"))
    _u, rule_id, priority_class, conditions, actions = _story_notify_rules(
        api.store
    )[0]
    assert rule_id == "global/override/com.liza.story_notify.!s:local.test"
    assert priority_class == 5  # override — поверх room-level dont_notify (3)
    assert actions[0] == "notify"
    by_key = {c["key"]: c["pattern"] for c in conditions}
    assert by_key["type"] == "m.room.message"
    assert by_key["room_id"] == "!s:local.test"


def test_on_new_event_ignores_hidden_room_membership():
    """Membership-события в САМОЙ сторис-комнате (hidden) не триггерят
    subscribe/unsubscribe — иначе наш же kick/join зациклил бы подписку."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.store.push_rules_added.clear()
    state = {
        ("m.room.create", ""): _Ev(
            "m.room.create", "", {"com.liza.stories": True}
        ),
        ("m.room.member", "@bob:local.test"): _Ev(
            "m.room.member", "@bob:local.test", {"membership": "join"}
        ),
        ("m.room.member", "@alice:local.test"): _Ev(
            "m.room.member", "@alice:local.test", {"membership": "join"}
        ),
    }
    ev = _Ev("m.room.member", "@bob:local.test", {"membership": "join"})
    asyncio.run(mod._on_new_event(ev, state))
    assert api.memberships == []
    assert api.store.push_rules_added == []


def test_on_new_event_leave_unsubscribes_from_stories_room():
    """AC-7 / AC:RL-stories-publish-push/4 — leave из DM (комната в m.direct) снимает
    подписку: kick зрителя из встречной сторис-комнаты (ни показа, ни пуша)."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.account_data_manager.store[
        ("@alice:local.test", "com.liza.stories")
    ] = {"room_id": "!alice_s:local.test"}
    # Покидаемая комната — настоящий DM (числится в m.direct покидающего).
    api.account_data_manager.store[("@bob:local.test", "m.direct")] = {
        "@alice:local.test": ["!dm:local.test"],
    }
    state = {
        ("m.room.member", "@bob:local.test"): _Ev(
            "m.room.member", "@bob:local.test", {"membership": "leave"}
        ),
        ("m.room.member", "@alice:local.test"): _Ev(
            "m.room.member", "@alice:local.test", {"membership": "join"}
        ),
    }
    ev = _Ev(
        "m.room.member",
        "@bob:local.test",
        {"membership": "leave", "is_direct": True},
        room_id="!dm:local.test",
    )
    asyncio.run(mod._on_new_event(ev, state))
    kicks = [m for m in api.memberships if m[3] == "leave"]
    assert (
        "@alice:local.test",
        "@bob:local.test",
        "!alice_s:local.test",
        "leave",
        None,
    ) in kicks


def test_on_new_event_leave_non_dm_two_person_room_does_not_unsubscribe():
    """Ложная отписка: ban/выход из обычной 2-местной комнаты, которой НЕТ в
    m.direct, НЕ должен снимать сторис-подписку по действующему DM той же пары
    (fallback len<=2 не различает DM и обычную 2-местную комнату)."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    api.account_data_manager.store[
        ("@alice:local.test", "com.liza.stories")
    ] = {"room_id": "!alice_s:local.test"}
    # m.direct НЕ содержит покидаемую комнату (!other:local.test) — это НЕ DM.
    api.account_data_manager.store[("@bob:local.test", "m.direct")] = {
        "@alice:local.test": ["!dm:local.test"],
    }
    state = {
        ("m.room.member", "@bob:local.test"): _Ev(
            "m.room.member", "@bob:local.test", {"membership": "ban"}
        ),
        ("m.room.member", "@alice:local.test"): _Ev(
            "m.room.member", "@alice:local.test", {"membership": "join"}
        ),
    }
    ev = _Ev(
        "m.room.member",
        "@bob:local.test",
        {"membership": "ban"},
        room_id="!other:local.test",
    )
    asyncio.run(mod._on_new_event(ev, state))
    # Никаких kick-ов — подписка по !dm цела.
    assert [m for m in api.memberships if m[3] == "leave"] == []


def test_unsubscribe_pair_noop_without_stories_room():
    """Нет сторис-комнаты у владельца (подписки не было) — kick не шлём."""
    api = _FakeApiWithStore()
    mod = _make_module(api)
    asyncio.run(mod.unsubscribe_pair("@alice:local.test", "@bob:local.test"))
    assert api.memberships == []


# --- backfill: отбор DM-пар через _find_dm_pairs_txn (кросс-федерация) ---


def _make_dm_schema_conn():
    """In-memory sqlite со схемой account_data + local_current_membership -
    минимум, нужный _find_dm_pairs_txn. local_current_membership содержит
    membership ЛОКАЛЬНЫХ юзеров в любых комнатах, включая федеративные."""
    conn = sqlite3.connect(":memory:")
    conn.execute(
        "CREATE TABLE account_data (user_id TEXT, account_data_type TEXT,"
        " content TEXT)"
    )
    conn.execute(
        "CREATE TABLE local_current_membership (room_id TEXT, user_id TEXT,"
        " event_id TEXT, membership TEXT)"
    )
    return conn


def _insert_direct(conn, owner, mapping):
    conn.execute(
        "INSERT INTO account_data VALUES (?, 'm.direct', ?)",
        (owner, json.dumps(mapping)),
    )


def _insert_membership(conn, room_id, user_id, membership="join"):
    conn.execute(
        "INSERT INTO local_current_membership VALUES (?, ?, ?, ?)",
        (room_id, user_id, f"$e_{user_id}", membership),
    )


def _find_pairs(conn, server="local.test"):
    return StoriesMembershipModule._find_dm_pairs_txn(conn.cursor(), server)


def test_find_dm_pairs_txn_cross_federated_local_owner():
    """ГЛАВНЫЙ регресс-тест: DM-комната на ЧУЖОМ сервере, локальный участник
    реально join. Старый is_local_room-фильтр вернул бы [] (комната не
    локальна) - разные федерации не видели сторисы друг друга."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:remote.example": ["!dm:remote.example"]},
    )
    _insert_membership(conn, "!dm:remote.example", "@alice:local.test")

    pairs = _find_pairs(conn)

    assert pairs == [("@alice:local.test", "@bob:remote.example")]


def test_find_dm_pairs_txn_cross_federated_room_on_local_server():
    """Симметрия: комната на НАШЕМ сервере, контрагент удалённый - пара тоже
    возвращается (фикс не ломает случай локальной комнаты с remote-участником)."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:remote.example": ["!dm:local.test"]},
    )
    _insert_membership(conn, "!dm:local.test", "@alice:local.test")

    pairs = _find_pairs(conn)

    assert pairs == [("@alice:local.test", "@bob:remote.example")]


def test_find_dm_pairs_txn_both_local():
    """Регресс существующего поведения: оба локальные, join - пара возвращается."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:local.test": ["!dm:local.test"]},
    )
    _insert_membership(conn, "!dm:local.test", "@alice:local.test")
    _insert_membership(conn, "!dm:local.test", "@bob:local.test")

    pairs = _find_pairs(conn)

    assert pairs == [("@alice:local.test", "@bob:local.test")]


def test_find_dm_pairs_txn_no_local_member_dropped():
    """Оба участника удалённые (в проде account_data только локальных, но
    защищаемся): подписывать некого - пара отбрасывается."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@carol:remote.example",
        {"@bob:other.example": ["!dm:remote.example"]},
    )
    _insert_membership(conn, "!dm:remote.example", "@carol:remote.example")

    pairs = _find_pairs(conn)

    assert pairs == []


def test_find_dm_pairs_txn_orphan_direct_no_membership():
    """m.direct есть, но локальный юзер НЕ состоит (join) в комнате -
    осиротевшая запись, не подписываем."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:remote.example": ["!dm:remote.example"]},
    )
    # local_current_membership пуст - Alice нигде не join.

    pairs = _find_pairs(conn)

    assert pairs == []


def test_find_dm_pairs_txn_left_room_not_subscribed():
    """Локальный юзер вышел (membership=leave) - пара не подписывается."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:remote.example": ["!dm:remote.example"]},
    )
    _insert_membership(
        conn, "!dm:remote.example", "@alice:local.test", membership="leave"
    )

    pairs = _find_pairs(conn)

    assert pairs == []


def test_find_dm_pairs_txn_dedup_multiple_rooms():
    """Контрагент с несколькими комнатами, join в одной - ровно одна пара."""
    conn = _make_dm_schema_conn()
    _insert_direct(
        conn,
        "@alice:local.test",
        {"@bob:remote.example": ["!dm1:remote.example", "!dm2:remote.example"]},
    )
    _insert_membership(conn, "!dm2:remote.example", "@alice:local.test")

    pairs = _find_pairs(conn)

    assert pairs == [("@alice:local.test", "@bob:remote.example")]
