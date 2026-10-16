"""Интеграционные тесты ChannelSyncModule (зеркалирование create).

ledger:RL-channel-discussion-restricted-join

Async-стиль: pytest-asyncio в servers/synapse/src не установлен (урок из
плана 1) — используем unittest.TestCase + asyncio.run(...), как в
channel_sync/tests/test_storage.py.

Модуль сконструирован через ChannelSyncModule.__new__ + ручную подстановку
_api/_state/_store, чтобы не собирать реальный api._hs (минуем __init__,
который трогает hs.get_storage_controllers()/get_datastores()).
"""

import asyncio
import unittest

from synapse_modules.channel_sync import ChannelSyncModule


class _FakeEvent:
    def __init__(
        self,
        event_type="m.room.message",
        content=None,
        room_id="!chan:h",
        sender="@a:h",
        event_id="$post",
        redacts=None,
        state_key=None,
        unsigned=None,
    ):
        self.type = event_type
        self.content = content or {}
        self.room_id = room_id
        self.sender = sender
        self.event_id = event_id
        self.redacts = redacts
        self.state_key = state_key
        self.unsigned = unsigned or {}


class _FakeState:
    """Фейковый StateStorageController: create/discussion/join_rules-стейт."""

    def __init__(
        self,
        chat_type="channel",
        discussion_room=None,
        room_chat_types=None,
        join_rules=None,
        room_creators=None,
        history_visibility=None,
        topology=None,
        discussion_rooms=None,
        discussion_contents=None,
    ):
        self._chat_type = chat_type
        self._discussion = discussion_room
        # room_id -> chat_type, для комнат, отличных от дефолтной (например
        # discussion-комната имеет свой com.liza.chat.type == 'channel_discussion').
        self._room_chat_types = room_chat_types or {}
        # room_id -> join_rule ("public"/"invite"); отсутствие = нет стейта.
        self._join_rules = join_rules or {}
        # room_id -> sender события m.room.create (владелец комнаты).
        self._room_creators = room_creators or {}
        # room_id -> history_visibility; отсутствие = нет стейта.
        self._history_visibility = history_visibility or {}
        # room_id -> content com.liza.chat.topology; отсутствие = нет стейта.
        self._topology = topology or {}
        # room_id канала -> room_id привязанного чата. Нужен миграции, которая
        # обходит НЕСКОЛЬКО каналов (одного self._discussion не хватает).
        self._discussion_rooms = discussion_rooms or {}
        # room_id канала -> СЫРОЙ content com.liza.channel.discussion. Нужен,
        # когда важна не только ссылка на чат, но и остальные ключи — например
        # маркер удаления {"room_id": ..., "deleted": true}.
        self._discussion_contents = discussion_contents or {}

    async def get_current_state_event(self, room_id, ev_type, state_key):
        if ev_type == "m.room.create":
            chat_type = self._room_chat_types.get(room_id, self._chat_type)
            if chat_type is None:
                return None
            return _FakeEvent(
                event_type="m.room.create",
                room_id=room_id,
                content={"com.liza.chat.type": chat_type},
                sender=self._room_creators.get(room_id, "@owner:h"),
            )
        if ev_type == "com.liza.channel.discussion":
            content = self._discussion_contents.get(room_id)
            if content is not None:
                return _FakeEvent(content=content)
            discussion = self._discussion_rooms.get(room_id, self._discussion)
            if discussion is None:
                return None
            return _FakeEvent(content={"room_id": discussion})
        if ev_type == "m.room.join_rules":
            rule = self._join_rules.get(room_id)
            if rule is None:
                return None
            # строка — только join_rule; dict — content целиком (restricted+allow)
            return _FakeEvent(
                event_type=ev_type,
                room_id=room_id,
                content=dict(rule) if isinstance(rule, dict) else {"join_rule": rule},
            )
        if ev_type == "m.room.history_visibility":
            visibility = self._history_visibility.get(room_id)
            if visibility is None:
                return None
            return _FakeEvent(
                event_type=ev_type,
                room_id=room_id,
                content={"history_visibility": visibility},
            )
        if ev_type == "com.liza.chat.topology":
            content = self._topology.get(room_id)
            if content is None:
                return None
            return _FakeEvent(event_type=ev_type, room_id=room_id, content=content)
        return None


class _FakeStore:
    """Фейковый MirrorStore в памяти."""

    def __init__(self, channel_rooms=None):
        self._m = {}
        # Список каналов, который вернёт find_channel_rooms (миграция).
        self._channel_rooms = channel_rooms or []
        self.fail_find_channel_rooms = False
        self.schema_calls = 0
        # Лог вызовов delete_by_discussion: отличает «чистку не звали вовсе»
        # от «позвали, но удалять было нечего» (проверка идемпотентности).
        self.deleted_by_discussion = []

    async def ensure_schema(self):
        self.schema_calls += 1

    async def find_channel_rooms(self):
        if self.fail_find_channel_rooms:
            raise RuntimeError("boom")
        return list(self._channel_rooms)

    async def already_mirrored(self, post_id):
        return post_id in self._m

    async def get_mirror(self, post_id):
        return self._m.get(post_id)

    async def put_mirror(self, post_id, mirror_id, disc_id):
        self._m.setdefault(post_id, (mirror_id, disc_id))

    async def delete_mirror(self, post_event_id):
        self._m.pop(post_event_id, None)

    async def delete_by_discussion(self, discussion_room_id):
        self.deleted_by_discussion.append(discussion_room_id)
        doomed = [k for k, v in self._m.items() if v[1] == discussion_room_id]
        for k in doomed:
            self._m.pop(k)
        return len(doomed)


class _FakeApi:
    def __init__(self, server_name="h"):
        self.sent = []
        # state-события (со state_key) копим отдельно от обычных сообщений:
        # ассерты зеркалирования постов смотрят только в self.sent.
        self.state_events = []
        self.registered = {}
        self.server_name = server_name
        self.pending_background = []
        # (sender, target, room_id, action, remote_room_hosts)
        self.memberships = []
        # user_id -> content глобального account data com.liza.user_role
        self.account_data = {}
        self.fail_invite = False
        self.fail_leave = False
        # Роняет отправку обычных (не-state) событий в комнату - нужно, чтобы
        # проверить, что маппинг зеркала переживает неудачную отправку.
        self.fail_send = False

    def register_third_party_rules_callbacks(self, **cb):
        self.registered.update(cb)

    def run_as_background_process(self, name, fn, *args):
        # Синхронное выполнение для детерминизма теста. Если вызвано из-под
        # уже работающего loop (например, _on_new_event сам вызван через
        # asyncio.run в тесте), запускать вложенный run_until_complete нельзя -
        # копим корутину и прогоняем в _drain_background() после возврата.
        loop = asyncio.get_event_loop()
        if loop.is_running():
            self.pending_background.append(fn(*args))
            return
        loop.run_until_complete(fn(*args))

    def is_mine(self, user_id):
        return user_id.endswith(":" + self.server_name)

    async def sleep(self, seconds):
        # Модуль отдаёт управление reactor между каналами миграции; в тесте
        # достаточно no-op.
        return None

    async def create_and_send_event_into_room(self, event_dict):
        if "state_key" in event_dict:
            self.state_events.append(event_dict)
            return _FakeEvent(event_id="$state")
        if self.fail_send:
            raise RuntimeError("boom")
        self.sent.append(event_dict)
        return _FakeEvent(event_id="$mirror")

    async def update_room_membership(
        self, sender, target, room_id, action, remote_room_hosts=None
    ):
        if self.fail_invite and action == "invite":
            raise RuntimeError("boom")
        if self.fail_leave and action == "leave":
            raise RuntimeError("boom")
        self.memberships.append((sender, target, room_id, action, remote_room_hosts))

    class _AccountDataManager:
        def __init__(self, outer):
            self._outer = outer

        async def get_global(self, user_id, key):
            return self._outer.account_data.get(user_id)

    @property
    def account_data_manager(self):
        return self._AccountDataManager(self)


class _FakeDbPool:
    """Даёт simple_select_one_onecol поверх push_rules_added того же store -
    паттерн из stories_membership/tests/test_module.py."""

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


class _FakeMainStore:
    """Фейковый main datastore: add_push_rule + db_pool.simple_select_one_onecol."""

    def __init__(self, events=None, joined=None, invited=None):
        self.push_rules_added = []  # (user_id, rule_id, priority_class, conditions, actions)
        self.db_pool = _FakeDbPool(self)
        # event_id -> _FakeEvent, для get_event(get_prev_content=True):
        # так модуль достаёт прошлое значение com.liza.channel.discussion.
        self._events = events or {}
        self.fail_get_event = False
        # room_id -> участники: join и invite отдельно, как в реальном store
        # (get_users_in_room join-only, get_invited_users_in_room — invite).
        self._joined = joined or {}
        self._invited = invited or {}

    async def get_users_in_room(self, room_id):
        return list(self._joined.get(room_id, []))

    async def get_invited_users_in_room(self, room_id):
        return list(self._invited.get(room_id, []))

    async def get_event(
        self, event_id, get_prev_content=False, allow_none=False, **kwargs
    ):
        if self.fail_get_event:
            raise RuntimeError("boom")
        ev = self._events.get(event_id)
        if ev is None and not allow_none:
            raise LookupError(event_id)
        return ev

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


def _make_module(
    chat_type="channel", discussion_room="!disc:h", main_store=None,
    room_chat_types=None, api=None, join_rules=None, room_creators=None,
    history_visibility=None, topology=None, discussion_rooms=None,
    channel_rooms=None, discussion_contents=None,
):
    m = ChannelSyncModule.__new__(ChannelSyncModule)  # минуем __init__ (он трогает _hs)
    api = api or _FakeApi()
    if main_store is not None:
        api._hs = _FakeHomeServer(main_store)
    m._api = api
    m._state = _FakeState(
        chat_type, discussion_room, room_chat_types, join_rules, room_creators,
        history_visibility, topology, discussion_rooms,
        discussion_contents=discussion_contents,
    )
    m._store = _FakeStore(channel_rooms)
    m._main_store = main_store
    return m


def _member_event(room_id, state_key, membership="join", sender=None):
    return _FakeEvent(
        event_type="m.room.member",
        content={"membership": membership},
        room_id=room_id,
        sender=sender or state_key,
        event_id="$member",
        state_key=state_key,
    )


def _get_mirror(m, post_id="$post"):
    return asyncio.run(m._store.get_mirror(post_id))


def _run_on_new_event(m, event, state_events):
    """Прогоняет _on_new_event и синхронно дожидается всех фоновых корутин,
    накопленных в api.pending_background (см. _FakeApi.run_as_background_process)."""
    asyncio.run(m._on_new_event(event, state_events))
    pending = m._api.pending_background
    m._api.pending_background = []
    for coro in pending:
        asyncio.run(coro)


class MirrorCreateTest(unittest.TestCase):
    def test_root_post_in_channel_is_mirrored(self):
        m = _make_module()
        content = {"body": "post", "msgtype": "m.text"}
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))

        self.assertEqual(len(m._api.sent), 1)
        sent = m._api.sent[0]
        self.assertEqual(sent["room_id"], "!disc:h")
        self.assertEqual(sent["sender"], "@a:h")
        self.assertEqual(
            sent["content"]["com.liza.channel.post_ref"]["post_event_id"], "$post"
        )
        self.assertEqual(_get_mirror(m), ("$mirror", "!disc:h"))

    def test_author_not_in_discussion_is_joined_and_mirror_retried(self):
        """Автор поста не член привязанного чата — вводим его и шлём зеркало.

        Прод-инцидент 2026-08-12 (nadezhda.liza.ru): зеркала не создавались
        НИ ДЛЯ ОДНОГО поста канала, таблица channel_post_mirror пустая.
        Synapse отвечал 403 «User … not in room …» на отправку зеркала от
        имени автора, ошибка глохла в except — пост навсегда оставался без
        комментариев, клиент показывал «не удалось открыть обсуждение».
        """
        m = _make_module()
        content = {"body": "post", "msgtype": "m.text"}

        original_send = m._api.create_and_send_event_into_room
        calls = {"n": 0}

        async def fail_until_joined(event_dict):
            if "state_key" not in event_dict:
                calls["n"] += 1
                joined = any(
                    target == "@a:h" and action == "join"
                    for _sender, target, _room, action, _hosts in m._api.memberships
                )
                if not joined:
                    raise RuntimeError("403: User @a:h not in room !disc:h")
            return await original_send(event_dict)

        m._api.create_and_send_event_into_room = fail_until_joined
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))

        self.assertEqual(calls["n"], 2, "должна быть повторная отправка после join")
        self.assertIn(
            ("@a:h", "@a:h", "!disc:h", "join", ["h"]),
            m._api.memberships,
            "автор обязан быть введён в чат обсуждений",
        )
        self.assertEqual(len(m._api.sent), 1)
        self.assertEqual(m._api.sent[0]["sender"], "@a:h")
        self.assertEqual(_get_mirror(m), ("$mirror", "!disc:h"))

    def test_join_failure_leaves_post_retriable(self):
        """Ввести автора не удалось — маппинг НЕ пишем, попытка повторяема.

        already_mirrored — вечная блокировка: записанный маппинг навсегда
        закрывает посту дорогу к зеркалу. Поэтому при неудаче маппинга быть не
        должно, и следующая публикация (или рестарт) обязана пробовать снова.
        """
        m = _make_module()
        content = {"body": "post"}
        m._api.fail_send = True
        m._api.fail_invite = True

        async def fail_join(sender, target, room_id, action, remote_room_hosts=None):
            raise RuntimeError("boom")

        m._api.update_room_membership = fail_join
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))

        self.assertEqual(m._api.sent, [])
        self.assertIsNone(_get_mirror(m))

        # Автор вошёл в чат сам (или отработал ретрай) — зеркало обязано уйти.
        m._api.fail_send = False
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))
        self.assertEqual(len(m._api.sent), 1)
        self.assertEqual(_get_mirror(m), ("$mirror", "!disc:h"))

    def test_idempotent_no_double_mirror(self):
        m = _make_module()
        content = {"body": "post"}
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))
        self.assertEqual(len(m._api.sent), 1)  # второй раз не отправил

    def test_non_channel_post_ignored(self):
        m = _make_module(chat_type="dm")
        content = {"body": "post"}
        event = _FakeEvent(content=content)
        # _on_new_event сам фильтрует по chat_type (в отличие от _mirror_post)
        asyncio.run(m._on_new_event(event, {}))
        self.assertEqual(m._api.sent, [])

    def test_no_discussion_not_mirrored(self):
        m = _make_module(discussion_room=None)
        content = {"body": "post"}
        asyncio.run(m._mirror_post(_FakeEvent(content=content), content))
        self.assertEqual(m._api.sent, [])

    def test_non_channel_edit_ignored(self):
        # edit в НЕ-канале не должен доходить до _mirror_edit (фильтр по chat_type
        # в _on_new_event, симметрично посту) — иначе лишний get_mirror на каждый
        # edit во всех комнатах инстанса.
        m = _make_module(chat_type="dm")
        edit_content = {
            "body": "* edited",
            "m.new_content": {"body": "edited"},
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$post"},
        }
        event = _FakeEvent(content=edit_content, event_id="$edit")
        asyncio.run(m._on_new_event(event, {}))
        self.assertEqual(m._api.sent, [])

    def test_non_channel_redact_ignored(self):
        m = _make_module(chat_type="dm")
        event = _FakeEvent(
            event_type="m.room.redaction", content={}, event_id="$red", redacts="$post"
        )
        asyncio.run(m._on_new_event(event, {}))
        self.assertEqual(m._api.sent, [])


class MirrorEditTest(unittest.TestCase):
    def test_edit_of_mirrored_post_sends_replace_to_mirror(self):
        m = _make_module()
        asyncio.run(m._store.put_mirror("$post", "$mirror", "!disc:h"))
        edit_content = {
            "body": "* edited",
            "msgtype": "m.text",
            "m.new_content": {"body": "edited", "msgtype": "m.text"},
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$post"},
        }
        edit_event = _FakeEvent(
            content=edit_content, event_id="$edit", sender="@a:h"
        )
        asyncio.run(m._mirror_edit(edit_event, edit_content, "$post"))

        self.assertEqual(len(m._api.sent), 1)
        sent = m._api.sent[0]
        self.assertEqual(sent["type"], "m.room.message")
        self.assertEqual(sent["room_id"], "!disc:h")
        self.assertEqual(sent["sender"], "@a:h")
        self.assertEqual(sent["content"]["body"], "edited")
        self.assertEqual(
            sent["content"]["m.relates_to"],
            {"rel_type": "m.replace", "event_id": "$mirror"},
        )

    def test_edit_of_unmirrored_post_ignored(self):
        m = _make_module()
        edit_content = {
            "body": "* edited",
            "m.new_content": {"body": "edited"},
            "m.relates_to": {"rel_type": "m.replace", "event_id": "$post"},
        }
        edit_event = _FakeEvent(content=edit_content, event_id="$edit")
        asyncio.run(m._mirror_edit(edit_event, edit_content, "$post"))
        self.assertEqual(m._api.sent, [])


class MirrorRedactTest(unittest.TestCase):
    def test_redact_of_mirrored_post_redacts_mirror(self):
        m = _make_module()
        asyncio.run(m._store.put_mirror("$post", "$mirror", "!disc:h"))
        redaction_event = _FakeEvent(
            event_type="m.room.redaction",
            event_id="$redaction",
            sender="@a:h",
            redacts="$post",
        )
        asyncio.run(m._mirror_redact(redaction_event, "$post"))

        self.assertEqual(len(m._api.sent), 1)
        sent = m._api.sent[0]
        self.assertEqual(sent["type"], "m.room.redaction")
        self.assertEqual(sent["room_id"], "!disc:h")
        self.assertEqual(sent["sender"], "@a:h")
        self.assertEqual(sent["redacts"], "$mirror")

    def test_redact_of_unmirrored_post_ignored(self):
        m = _make_module()
        redaction_event = _FakeEvent(
            event_type="m.room.redaction",
            event_id="$redaction",
            redacts="$post",
        )
        asyncio.run(m._mirror_redact(redaction_event, "$post"))
        self.assertEqual(m._api.sent, [])

    def test_successful_redact_deletes_mapping(self):
        """После успешной отправки redaction маппинг чистится: пост удалён,
        связь больше не нужна, иначе таблица растёт неограниченно."""
        m = _make_module()
        asyncio.run(m._store.put_mirror("$post", "$mirror", "!disc:h"))
        redaction_event = _FakeEvent(
            event_type="m.room.redaction",
            event_id="$redaction",
            sender="@a:h",
            redacts="$post",
        )
        asyncio.run(m._mirror_redact(redaction_event, "$post"))

        self.assertEqual(len(m._api.sent), 1)
        self.assertIsNone(_get_mirror(m))

    def test_failed_redact_keeps_mapping(self):
        """Отправка redaction упала — маппинг ОБЯЗАН остаться.

        Порядок в _mirror_redact критичен: delete_mirror только ПОСЛЕ успешной
        отправки. Удали маппинг раньше — при сбое связь «пост → зеркало»
        теряется навсегда, зеркало сиротеет в чате и повтор его не найдёт.
        """
        api = _FakeApi()
        api.fail_send = True
        m = _make_module(api=api)
        asyncio.run(m._store.put_mirror("$post", "$mirror", "!disc:h"))
        redaction_event = _FakeEvent(
            event_type="m.room.redaction",
            event_id="$redaction",
            sender="@a:h",
            redacts="$post",
        )
        asyncio.run(m._mirror_redact(redaction_event, "$post"))  # не должно бросить

        self.assertEqual(api.sent, [])
        self.assertEqual(_get_mirror(m), ("$mirror", "!disc:h"))


# --- тесты push-mute для подписчиков привязанного чата обсуждения (Task 8) ---


class MuteDiscussionMemberTest(unittest.TestCase):
    def test_join_into_discussion_room_mutes_local_user(self):
        """join в комнату com.liza.chat.type == 'channel_discussion' ставит
        dont_notify push-rule локальному юзеру на эту комнату."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!disc:h": "channel_discussion"},
            main_store=main_store,
        )
        event = _member_event(room_id="!disc:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(main_store.push_rules_added), 1)
        user_id, rule_id, priority_class, conditions, actions = (
            main_store.push_rules_added[0]
        )
        self.assertEqual(user_id, "@sub:h")
        self.assertEqual(rule_id, "global/room/!disc:h")
        self.assertEqual(priority_class, 3)
        self.assertEqual(actions, ["dont_notify"])
        self.assertEqual(
            conditions, [{"kind": "event_match", "key": "room_id", "pattern": "!disc:h"}]
        )

    def test_repeated_join_does_not_duplicate_rule(self):
        """Повторный join (например, leave+join) не должен звать add_push_rule
        второй раз - симметрично stories_membership: simple_select_one_onecol
        должен найти уже существующее правило и пропустить add."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!disc:h": "channel_discussion"},
            main_store=main_store,
        )
        event = _member_event(room_id="!disc:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})
        _run_on_new_event(m, event, {})

        self.assertEqual(len(main_store.push_rules_added), 1)

    def test_join_into_channel_room_not_muted(self):
        """Сам КАНАЛ мьютить нельзя - подписчик должен получать push на посты.

        С Task 2 join в канал ставит мьют на ПРИВЯЗАННЫЙ ЧАТ (!disc:h), поэтому
        проверяем не «правил нет вообще», а что среди них нет правила на комнату
        самого канала.
        """
        main_store = _FakeMainStore()
        m = _make_module(chat_type="channel", main_store=main_store)
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        muted_rooms = [rule_id for _, rule_id, *_ in main_store.push_rules_added]
        self.assertNotIn("global/room/!chan:h", muted_rooms)

    def test_remote_user_join_not_muted(self):
        """Удалённого юзера мьютить нельзя - push_rules это его домашний сервер."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!disc:h": "channel_discussion"},
            main_store=main_store,
        )
        event = _member_event(room_id="!disc:h", state_key="@sub:other.example")
        _run_on_new_event(m, event, {})

        self.assertEqual(main_store.push_rules_added, [])

    def test_non_join_membership_not_muted(self):
        """invite/leave не должны триггерить мьют - только join."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!disc:h": "channel_discussion"},
            main_store=main_store,
        )
        event = _member_event(room_id="!disc:h", state_key="@sub:h", membership="invite")
        _run_on_new_event(m, event, {})

        self.assertEqual(main_store.push_rules_added, [])

    def test_mute_noop_without_main_store(self):
        """Без _hs (main_store=None) - мьют тихо no-op, не должен падать."""
        m = _make_module(room_chat_types={"!disc:h": "channel_discussion"})
        self.assertIsNone(m._main_store)
        event = _member_event(room_id="!disc:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})  # не должно падать


# --- тесты авто-инвайта подписчика канала в привязанный чат (Task 2) ---


class ChannelVisibilityMigrationTest(unittest.TestCase):
    """Открытый канал читается без вступления (world_readable)."""

    def test_public_channel_opened_for_reading(self):
        m = _make_module(
            join_rules={"!chan:h": "public"},
            room_creators={"!chan:h": "@owner:h"},
            history_visibility={"!chan:h": "shared"},
        )
        changed = asyncio.run(m._migrate_channel_visibility("!chan:h"))

        self.assertTrue(changed)
        self.assertEqual(len(m._api.state_events), 1)
        sent = m._api.state_events[0]
        self.assertEqual(sent["type"], "m.room.history_visibility")
        self.assertEqual(sent["room_id"], "!chan:h")
        self.assertEqual(sent["sender"], "@owner:h")
        self.assertEqual(sent["content"]["history_visibility"], "world_readable")

    def test_private_channel_visibility_untouched(self):
        """Закрытый канал НЕ открываем: его контент не публичен."""
        m = _make_module(
            join_rules={"!chan:h": "invite"},
            room_creators={"!chan:h": "@owner:h"},
            history_visibility={"!chan:h": "shared"},
        )
        changed = asyncio.run(m._migrate_channel_visibility("!chan:h"))

        self.assertFalse(changed)
        self.assertEqual(m._api.state_events, [])

    def test_startup_migration_opens_public_channel(self):
        """Шаг подключён к общему проходу миграции, а не висит в стороне."""
        main_store = _FakeMainStore(joined={"!chan:h": ["@a:h"], "!disc:h": []})
        m = _make_module(
            main_store=main_store,
            channel_rooms=["!chan:h"],
            room_chat_types={"!chan:h": "channel"},
            join_rules={"!chan:h": "public"},
            room_creators={"!chan:h": "@owner:h"},
            history_visibility={"!chan:h": "shared"},
            discussion_room=None,  # у канала нет чата обсуждений
        )
        asyncio.run(m._migrate_channel_discussions())

        written = [
            ev
            for ev in m._api.state_events
            if ev["type"] == "m.room.history_visibility"
            and ev["room_id"] == "!chan:h"
        ]
        self.assertEqual(len(written), 1, "лента канала без чата тоже открывается")
        self.assertEqual(written[0]["content"]["history_visibility"], "world_readable")

    def test_already_world_readable_is_noop(self):
        """Повторный прогон миграции ничего не пишет (идемпотентность)."""
        m = _make_module(
            join_rules={"!chan:h": "public"},
            room_creators={"!chan:h": "@owner:h"},
            history_visibility={"!chan:h": "world_readable"},
        )
        changed = asyncio.run(m._migrate_channel_visibility("!chan:h"))

        self.assertFalse(changed)
        self.assertEqual(m._api.state_events, [])


RESTRICTED_DISC = {
    "join_rule": "restricted",
    "allow": [{"type": "m.room_membership", "room_id": "!chan:h"}],
}


class ChannelJoinAutoInviteTest(unittest.TestCase):
    """join в КАНАЛ → мьют привязанного чата + инвайт, только если чат
    фактически invite (создан старым клиентом, ещё не мигрирован)."""

    def test_restricted_discussion_join_does_not_invite(self):
        """AC:RL-channel-discussion-restricted-join/3 — закрытый канал с чатом
        restricted: подписчик входит сам, инвайта нет, мьют ставится."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite", "!disc:h": RESTRICTED_DISC},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])
        self.assertEqual(len(main_store.push_rules_added), 1)

    def test_private_channel_join_invites_subscriber_into_discussion(self):
        """AC:RL-channel-discussion-restricted-join/3 — старый invite-чат по-прежнему инвайтит."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite", "!disc:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        sender, target, room_id, action, remote_hosts = m._api.memberships[0]
        self.assertEqual(sender, "@owner:h")
        self.assertEqual(target, "@sub:h")
        self.assertEqual(room_id, "!disc:h")
        self.assertEqual(action, "invite")
        self.assertIsNone(remote_hosts)

    def test_public_channel_join_does_not_invite(self):
        """Открытый канал: чат public, подписчик войдёт сам при отправке."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "public"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])

    def test_channel_join_mutes_discussion_for_local_subscriber(self):
        """Мьют ставится независимо от приватности: пуш идёт на посты канала."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "public"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(main_store.push_rules_added), 1)
        user_id, rule_id, priority_class, conditions, actions = (
            main_store.push_rules_added[0]
        )
        self.assertEqual(user_id, "@sub:h")
        self.assertEqual(rule_id, "global/room/!disc:h")
        self.assertEqual(actions, ["dont_notify"])

    def test_federated_subscriber_gets_remote_room_hosts_and_no_mute(self):
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite", "!disc:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:other.example")
        _run_on_new_event(m, event, {})

        self.assertEqual(main_store.push_rules_added, [])  # удалённого не мьютим
        self.assertEqual(len(m._api.memberships), 1)
        _, target, _, _, remote_hosts = m._api.memberships[0]
        self.assertEqual(target, "@sub:other.example")
        self.assertEqual(remote_hosts, ["other.example"])

    def test_ai_user_is_skipped(self):
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@liza:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])
        self.assertEqual(main_store.push_rules_added, [])

    def test_ai_by_account_data_role_is_skipped(self):
        """AI помечен ролью в account data, а не именем — тоже пропускаем."""
        main_store = _FakeMainStore()
        api = _FakeApi()
        api.account_data["@helper:h"] = {"role": "ai"}
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
            api=api,
        )
        event = _member_event(room_id="!chan:h", state_key="@helper:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(api.memberships, [])
        self.assertEqual(main_store.push_rules_added, [])

    def test_channel_without_discussion_does_nothing(self):
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel"},
            discussion_room=None,
            join_rules={"!chan:h": "invite"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])
        self.assertEqual(main_store.push_rules_added, [])

    def test_invite_failure_does_not_raise(self):
        """Гонка/уже участник — инвайт падает, обработка события не валится."""
        main_store = _FakeMainStore()
        api = _FakeApi()
        api.fail_invite = True
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
            api=api,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})  # не должно бросить

        self.assertEqual(api.memberships, [])

    def test_repeated_channel_join_does_not_duplicate_mute(self):
        """Повторный join в канал не должен плодить push-rule."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h")
        _run_on_new_event(m, event, {})
        _run_on_new_event(m, event, {})

        self.assertEqual(len(main_store.push_rules_added), 1)


# --- тесты кика из привязанного чата при отписке от канала (Fix И1) ---


class ChannelLeaveKickTest(unittest.TestCase):
    """leave/ban из КАНАЛА → кик из привязанного чата обсуждения.

    Симметрия к ChannelJoinAutoInviteTest: без неё отписавшийся от закрытого
    канала остаётся членом чата и продолжает читать/писать комментарии.
    """

    def _module(self, main_store, api=None, join_rule="invite", discussion_room="!disc:h"):
        return _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": join_rule},
            room_creators={"!disc:h": "@owner:h"},
            discussion_room=discussion_room,
            main_store=main_store,
            api=api,
        )

    def test_leave_from_channel_kicks_from_discussion(self):
        main_store = _FakeMainStore()
        m = self._module(main_store)
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        sender, target, room_id, action, remote_hosts = m._api.memberships[0]
        self.assertEqual(sender, "@owner:h")
        self.assertEqual(target, "@sub:h")
        self.assertEqual(room_id, "!disc:h")
        self.assertEqual(action, "leave")
        self.assertIsNone(remote_hosts)

    def test_ban_from_channel_kicks_from_discussion(self):
        main_store = _FakeMainStore()
        m = self._module(main_store)
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="ban")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        _, target, room_id, action, _ = m._api.memberships[0]
        self.assertEqual(target, "@sub:h")
        self.assertEqual(room_id, "!disc:h")
        self.assertEqual(action, "leave")

    def test_leave_from_public_channel_also_kicks(self):
        """Открытый канал: чат public и кик двери не запирает, но убирает
        комнату из синка ушедшего — делаем единообразно, без ветвления."""
        main_store = _FakeMainStore()
        m = self._module(main_store, join_rule="public")
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        self.assertEqual(m._api.memberships[0][3], "leave")

    def test_leave_from_channel_without_discussion_does_nothing(self):
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel"},
            discussion_room=None,
            join_rules={"!chan:h": "invite"},
            main_store=main_store,
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])

    def test_kick_failure_does_not_raise(self):
        """Уже не участник / гонка — кик падает, обработка события не валится."""
        main_store = _FakeMainStore()
        api = _FakeApi()
        api.fail_leave = True
        m = self._module(main_store, api=api)
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})  # не должно бросить

        self.assertEqual(api.memberships, [])

    def test_kick_works_after_deletion_marker_landed(self):
        """Маркер удаления канала НЕ должен ломать кик из чата обсуждения.

        Инвариант порядка (Task 12, fix round 1). Клиент при удалении канала
        кикает подписчиков, затем пишет маркер удаления. Но каждый кик сервер
        обрабатывает ЧЕРЕЗ run_as_background_process, то есть асинхронно:
        клиент дожидается только HTTP-ответов на kick, а не завершения
        фоновых процессов. Поэтому последние из них читают привязку уже
        ПОСЛЕ того, как маркер приземлился.

        Раньше маркер был голым {"deleted": true} — для такого content
        _discussion_room возвращает None, обработчик считал «комментарии
        выключены» и молча выходил, оставляя подписчика членом чата
        обсуждения (утечка доступа, тем вероятнее чем больше канал). Теперь
        маркер несёт room_id, и ответ не зависит от порядка приземления —
        инвариант структурный, а не временной.
        """
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
            discussion_contents={"!chan:h": {"room_id": "!disc:h", "deleted": True}},
        )
        event = _member_event(room_id="!chan:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        _, target, room_id, action, _ = m._api.memberships[0]
        self.assertEqual(target, "@sub:h")
        self.assertEqual(room_id, "!disc:h")
        self.assertEqual(action, "leave")

    def test_leave_from_discussion_room_itself_does_not_kick(self):
        """Выход из самого чата-обсуждения не должен рекурсивно кикать."""
        main_store = _FakeMainStore()
        m = self._module(main_store)
        event = _member_event(room_id="!disc:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])

    def test_leave_from_non_channel_room_does_not_kick(self):
        main_store = _FakeMainStore()
        m = _make_module(chat_type="dm", main_store=main_store)
        event = _member_event(room_id="!dm:h", state_key="@sub:h", membership="leave")
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])

    def test_federated_subscriber_leave_kicks_without_remote_hosts(self):
        """Кик работает и без remote_room_hosts (асимметрия с инвайтом
        осознанная — образец channel_stories._remove_member)."""
        main_store = _FakeMainStore()
        m = self._module(main_store)
        event = _member_event(
            room_id="!chan:h", state_key="@sub:other.example", membership="leave"
        )
        _run_on_new_event(m, event, {})

        self.assertEqual(len(m._api.memberships), 1)
        _, target, _, action, remote_hosts = m._api.memberships[0]
        self.assertEqual(target, "@sub:other.example")
        self.assertEqual(action, "leave")
        self.assertIsNone(remote_hosts)


# --- тесты синхронизации приватности привязанного чата с каналом (Task 3) ---


def _join_rules_event(room_id="!chan:h", join_rule="public"):
    return _FakeEvent(
        event_type="m.room.join_rules",
        room_id=room_id,
        content={"join_rule": join_rule},
        event_id="$rules",
        state_key="",
    )


class DiscussionPrivacySyncTest(unittest.TestCase):
    """Смена join_rules канала переписывает настройки привязанного чата."""

    def test_channel_becomes_public_opens_discussion(self):
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
        )
        _run_on_new_event(m, _join_rules_event(join_rule="public"), {})

        by_type = {e["type"]: e for e in m._api.state_events}
        self.assertEqual(
            by_type["m.room.join_rules"]["content"], {"join_rule": "public"}
        )
        self.assertEqual(by_type["m.room.join_rules"]["room_id"], "!disc:h")
        self.assertEqual(by_type["m.room.join_rules"]["sender"], "@owner:h")
        self.assertEqual(by_type["m.room.join_rules"]["state_key"], "")
        self.assertEqual(
            by_type["m.room.history_visibility"]["content"],
            {"history_visibility": "world_readable"},
        )
        self.assertEqual(by_type["m.room.history_visibility"]["room_id"], "!disc:h")

    def test_channel_becomes_private_closes_discussion(self):
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
        )
        _run_on_new_event(m, _join_rules_event(join_rule="invite"), {})

        by_type = {e["type"]: e for e in m._api.state_events}
        # AC:RL-channel-discussion-restricted-join/1 — restricted с allow в
        # КАЖДОЙ записи: restricted без allow не пустил бы никого.
        self.assertEqual(by_type["m.room.join_rules"]["content"], RESTRICTED_DISC)
        self.assertEqual(
            by_type["m.room.history_visibility"]["content"],
            {"history_visibility": "shared"},
        )

    def test_unknown_join_rule_closes_discussion(self):
        """knock/restricted трактуем как закрытый канал (fail-safe приватности)."""
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
        )
        _run_on_new_event(m, _join_rules_event(join_rule="knock"), {})

        by_type = {e["type"]: e for e in m._api.state_events}
        self.assertEqual(by_type["m.room.join_rules"]["content"], RESTRICTED_DISC)
        self.assertEqual(
            by_type["m.room.history_visibility"]["content"],
            {"history_visibility": "shared"},
        )

    def test_join_rules_in_non_channel_room_ignored(self):
        m = _make_module(room_chat_types={"!group:h": None})
        _run_on_new_event(m, _join_rules_event(room_id="!group:h"), {})

        self.assertEqual(m._api.state_events, [])

    def test_join_rules_in_discussion_room_ignored(self):
        """Правка самого чата-обсуждения не должна запускать рекурсию."""
        m = _make_module(
            room_chat_types={"!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
        )
        _run_on_new_event(m, _join_rules_event(room_id="!disc:h"), {})

        self.assertEqual(m._api.state_events, [])

    def test_channel_without_discussion_ignored(self):
        m = _make_module(
            room_chat_types={"!chan:h": "channel"},
            discussion_room=None,
        )
        _run_on_new_event(m, _join_rules_event(), {})

        self.assertEqual(m._api.state_events, [])

    def test_join_rules_without_rule_ignored(self):
        """Битый content без join_rule — нечего синхронизировать."""
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
        )
        event = _FakeEvent(
            event_type="m.room.join_rules",
            room_id="!chan:h",
            content={},
            state_key="",
        )
        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.state_events, [])

    def test_join_rules_does_not_touch_membership_or_mirror(self):
        """Ветка join_rules не должна задевать инвайты/кики и зеркалирование."""
        main_store = _FakeMainStore()
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
            main_store=main_store,
        )
        _run_on_new_event(m, _join_rules_event(), {})

        self.assertEqual(m._api.memberships, [])
        self.assertEqual(m._api.sent, [])
        self.assertEqual(main_store.push_rules_added, [])

    def test_failure_of_first_state_does_not_block_second(self):
        """Падение записи join_rules не должно отменять history_visibility."""
        api = _FakeApi()
        original = api.create_and_send_event_into_room

        async def failing(event_dict):
            if event_dict["type"] == "m.room.join_rules":
                raise RuntimeError("boom")
            return await original(event_dict)

        api.create_and_send_event_into_room = failing
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            room_creators={"!disc:h": "@owner:h"},
            api=api,
        )
        _run_on_new_event(m, _join_rules_event(), {})  # не должно бросить

        types = [e["type"] for e in api.state_events]
        self.assertEqual(types, ["m.room.history_visibility"])


def _unlink_event(
    room_id="!chan:h", prev_discussion="!disc:h", new_content=None, event_id="$unlink"
):
    """Снятие привязки com.liza.channel.discussion (пустой content).

    prev_content отдаётся не в самом событии, а через main_store.get_event(
    get_prev_content=True) — так же, как это делает Synapse: on_new_event
    получает событие БЕЗ prev_content (get_event там вызывается с
    get_prev_content=False).
    """
    return _FakeEvent(
        event_type="com.liza.channel.discussion",
        room_id=room_id,
        content=new_content if new_content is not None else {},
        event_id=event_id,
        state_key="",
    ), _FakeEvent(
        event_type="com.liza.channel.discussion",
        room_id=room_id,
        content=new_content if new_content is not None else {},
        event_id=event_id,
        state_key="",
        unsigned=(
            {"prev_content": {"room_id": prev_discussion}}
            if prev_discussion is not None
            else {}
        ),
    )


class DiscussionUnlinkCleanupTest(unittest.TestCase):
    """Изменение com.liza.channel.discussion и судьба маппингов пост→зеркало.

    Событие одно, сценария три, и различаются они ЯВНО (Task 12):
    - выключение комментариев (пустой content) — чат обсуждения цел, маппинги
      СОХРАНЯЕМ, чтобы повторное включение вернуло старые треды (так работает
      отвязка обсуждения);
    - удаление канала — клиент помечает его ключом deleted:true, только тогда
      чистим. Своего события «комната удалена» в Matrix нет (удаление — это
      кик+leave+forget), вывести его из отвязки нельзя;
    - переезд привязки на другой чат — старый осиротел, чистим.
    """

    def _module(self, prev_discussion="!disc:h", new_content=None, **kwargs):
        event, stored = _unlink_event(
            prev_discussion=prev_discussion, new_content=new_content
        )
        main_store = _FakeMainStore(events={stored.event_id: stored})
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            main_store=main_store,
            **kwargs,
        )
        return m, event, main_store

    def _seed(self, m):
        asyncio.run(m._store.put_mirror("$p1", "$m1", "!disc:h"))
        asyncio.run(m._store.put_mirror("$p2", "$m2", "!disc:h"))
        # Чужой чат: его маппинги трогать нельзя.
        asyncio.run(m._store.put_mirror("$other", "$mo", "!other:h"))

    def test_unlink_keeps_mappings_of_that_discussion(self):
        """Выключение комментариев маппинги НЕ трогает.

        Регрессия Task 12: раньше отвязка стирала связь пост→зеркало, и
        повторное включение комментариев старые треды уже не возвращало —
        каждый пост начинал обсуждение с нуля. Чат при этом всё это время
        оставался целым, то есть терялась ровно и только связь.
        """
        m, event, _ = self._module()
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))
        self.assertEqual(_get_mirror(m, "$p2"), ("$m2", "!disc:h"))

    def test_channel_deleted_marker_cleans_mappings(self):
        """Удаление канала: клиент помечает deleted:true — маппинги чистим."""
        m, event, _ = self._module(new_content={"deleted": True})
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertIsNone(_get_mirror(m, "$p1"))
        self.assertIsNone(_get_mirror(m, "$p2"))

    def test_channel_deleted_marker_with_room_id_cleans_mappings(self):
        """Маркер в том виде, в каком его пишет клиент: room_id + deleted.

        room_id в маркере нужен киковому обработчику (см.
        ChannelLeaveKickTest.test_kick_works_after_deletion_marker_landed) и
        делает prev_room == new_room. Чистка обязана срабатывать всё равно:
        маркер удаления сильнее правила «перезапись тем же чатом — не чистим».
        """
        m, event, _ = self._module(
            new_content={"room_id": "!disc:h", "deleted": True}
        )
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertIsNone(_get_mirror(m, "$p1"))
        self.assertIsNone(_get_mirror(m, "$p2"))
        self.assertEqual(_get_mirror(m, "$other"), ("$mo", "!other:h"))

    def test_cleanup_is_idempotent_on_repeated_event(self):
        """Повторная обработка ТОГО ЖЕ события ничего не ломает.

        Докстринг _cleanup_unlinked_discussion обещает идемпотентность:
        Synapse может переиграть событие (рестарт, повтор колбэка), и второй
        прогон обязан удалить 0 строк, а не упасть и не задеть чужие чаты.
        """
        m, event, _ = self._module(
            new_content={"room_id": "!disc:h", "deleted": True}
        )
        self._seed(m)

        _run_on_new_event(m, event, {})
        deleted_first = list(m._store.deleted_by_discussion)
        _run_on_new_event(m, event, {})  # тот же event_id второй раз

        self.assertEqual(deleted_first, ["!disc:h"])
        self.assertEqual(m._store.deleted_by_discussion, ["!disc:h", "!disc:h"])
        self.assertIsNone(_get_mirror(m, "$p1"))
        self.assertEqual(_get_mirror(m, "$other"), ("$mo", "!other:h"))

    def test_channel_deleted_marker_keeps_other_discussions(self):
        """Даже удаление канала чистит только ЕГО чат."""
        m, event, _ = self._module(new_content={"deleted": True})
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$other"), ("$mo", "!other:h"))

    def test_relink_after_unlink_still_finds_mirrors(self):
        """Выключил комментарии → включил обратно тот же чат: треды на месте.

        Сквозной сценарий пользователя из запроса «как в Телеге»: две
        последовательные записи привязки не должны в сумме ничего стереть.
        """
        m, unlink_event, main_store = self._module()
        self._seed(m)
        _run_on_new_event(m, unlink_event, {})

        # Повторная привязка ТОГО ЖЕ чата: prev_content пуст (комментарии
        # были выключены), новый content указывает на прежнюю комнату.
        relink, relink_stored = _unlink_event(
            prev_discussion=None,
            new_content={"room_id": "!disc:h"},
            event_id="$relink",
        )
        main_store._events[relink_stored.event_id] = relink_stored
        _run_on_new_event(m, relink, {})

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))
        self.assertEqual(_get_mirror(m, "$p2"), ("$m2", "!disc:h"))

    def test_unlink_keeps_mappings_of_other_discussions(self):
        m, event, _ = self._module()
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$other"), ("$mo", "!other:h"))

    def test_relink_to_another_room_cleans_old_mappings(self):
        """Перепривязка (не пустой content) — старый чат тоже осиротел."""
        m, event, _ = self._module(new_content={"room_id": "!new:h"})
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertIsNone(_get_mirror(m, "$p1"))

    def test_same_room_rewrite_keeps_mappings(self):
        """Идемпотентная перезапись тем же room_id — чистить нечего."""
        m, event, _ = self._module(new_content={"room_id": "!disc:h"})
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))

    def test_first_link_without_prev_content_is_noop(self):
        """Включение комментариев впервые: prev_content нет — удалять нечего."""
        m, event, _ = self._module(
            prev_discussion=None, new_content={"room_id": "!disc:h"}
        )
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))

    def test_unlink_in_non_channel_room_ignored(self):
        event, stored = _unlink_event(room_id="!group:h")
        main_store = _FakeMainStore(events={stored.event_id: stored})
        m = _make_module(room_chat_types={"!group:h": None}, main_store=main_store)
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))

    def test_get_event_failure_does_not_raise(self):
        """Недоступный prev_content — пропускаем уборку, но не роняем sync."""
        m, event, main_store = self._module()
        main_store.fail_get_event = True
        self._seed(m)

        _run_on_new_event(m, event, {})  # не должно бросить

        self.assertEqual(_get_mirror(m, "$p1"), ("$m1", "!disc:h"))

    def test_unlink_does_not_touch_membership_or_mirror(self):
        m, event, main_store = self._module()
        self._seed(m)

        _run_on_new_event(m, event, {})

        self.assertEqual(m._api.memberships, [])
        self.assertEqual(m._api.sent, [])
        self.assertEqual(m._api.state_events, [])
        self.assertEqual(main_store.push_rules_added, [])


class MigrationTest(unittest.TestCase):
    """Разовая миграция привязанных чатов при старте Synapse.

    Замена скрипта deploy/scripts/migrate-channel-discussions.py: тот ходил
    клиентским API от @synapse_admin и получал 403 на чужих комнатах, здесь
    state пишется от имени СОЗДАТЕЛЯ чата.
    """

    def _module(
        self,
        channel_join_rule="invite",
        discussion_join_rule="invite",
        discussion_history_visibility="shared",
        discussion_hidden=None,
        channel_members=("@a:h", "@b:h"),
        discussion_joined=(),
        discussion_invited=(),
        channel_rooms=("!chan:h",),
        discussion_rooms=None,
        room_creators=None,
        channel_history_visibility="world_readable",
    ):
        main_store = _FakeMainStore(
            joined={
                "!chan:h": list(channel_members),
                "!disc:h": list(discussion_joined),
            },
            invited={"!disc:h": list(discussion_invited)},
        )
        return _make_module(
            main_store=main_store,
            channel_rooms=list(channel_rooms),
            discussion_rooms=discussion_rooms,
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={
                "!chan:h": channel_join_rule,
                "!disc:h": discussion_join_rule,
            },
            # Канал по умолчанию уже world_readable: эти тесты про миграцию
            # ЧАТА обсуждений, и отдельный шаг открытия ленты канала не должен
            # подмешивать сюда свою запись m.room.history_visibility.
            history_visibility={
                "!disc:h": discussion_history_visibility,
                "!chan:h": channel_history_visibility,
            },
            topology=(
                {"!disc:h": {"hidden": discussion_hidden}}
                if discussion_hidden is not None
                else None
            ),
            room_creators=room_creators or {"!disc:h": "@owner:h", "!chan:h": "@owner:h"},
        )

    def _state_written(self, m):
        """type -> content записанных state-событий."""
        return {ev["type"]: ev["content"] for ev in m._api.state_events}

    def test_public_channel_opens_discussion_and_hides_it(self):
        m = self._module(channel_join_rule="public")

        asyncio.run(m._migrate_channel_discussions())

        written = self._state_written(m)
        self.assertEqual(written["m.room.join_rules"], {"join_rule": "public"})
        self.assertEqual(
            written["m.room.history_visibility"],
            {"history_visibility": "world_readable"},
        )
        self.assertEqual(written["com.liza.chat.topology"], {"hidden": True})
        # Все записи идут от имени создателя ЧАТА (а не канала и не админа).
        for ev in m._api.state_events:
            self.assertEqual(ev["sender"], "@owner:h")
            self.assertEqual(ev["room_id"], "!disc:h")

    def test_public_channel_does_not_invite(self):
        """У открытого канала чат public — подписчик войдёт сам."""
        m = self._module(channel_join_rule="public")

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.memberships, [])

    def test_private_channel_migrates_invite_chat_to_restricted_without_invites(self):
        """AC:RL-channel-discussion-restricted-join/2 — старый invite-чат закрытого
        канала становится restricted по членству в канале; подписчиков больше не
        зовут (войдут сами), уже приглашённых не трогаем."""
        m = self._module(
            channel_join_rule="invite",
            channel_members=("@a:h", "@b:h", "@c:h"),
            discussion_joined=("@owner:h", "@a:h"),
            discussion_invited=("@b:h",),
        )

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(self._state_written(m)["m.room.join_rules"], RESTRICTED_DISC)
        self.assertEqual(m._api.memberships, [])

    def test_creator_left_chat_actor_is_local_member(self):
        """AC:RL-channel-discussion-restricted-join/5 — создатель чата ушёл
        (кик при выходе из канала): миграция пишет от своего участника чата."""
        m = self._with_levels(
            self._module(
                channel_join_rule="invite",
                discussion_joined=("@mod:h", "@a:h", "@far:other"),
            ),
            {"@mod:h": 50, "@far:other": 100},
        )

        asyncio.run(m._migrate_channel_discussions())

        self.assertTrue(m._api.state_events)
        for ev in m._api.state_events:
            self.assertEqual(ev["sender"], "@mod:h")

    def test_creator_left_no_local_member_with_rights_writes_nothing(self):
        """AC:RL-channel-discussion-restricted-join/5 — свои есть, но все
        рядовые: запись от них упала бы 403 молча — не пишем вовсе."""
        m = self._with_levels(
            self._module(channel_join_rule="invite", discussion_joined=("@a:h",)),
            {"@far:other": 100},
        )

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])

    @staticmethod
    def _with_levels(m, users):
        original = m._state.get_current_state_event

        async def _state(room_id, ev_type, state_key):
            if room_id == "!disc:h" and ev_type == "m.room.power_levels":
                return _FakeEvent(event_type=ev_type, content={"users": users})
            return await original(room_id, ev_type, state_key)

        m._state.get_current_state_event = _state
        return m

    def test_private_channel_keeps_chat_private(self):
        m = self._module(
            channel_join_rule="invite",
            discussion_join_rule="public",  # осталось от ошибочной настройки
            discussion_history_visibility="world_readable",
        )

        asyncio.run(m._migrate_channel_discussions())

        written = self._state_written(m)
        self.assertEqual(written["m.room.join_rules"], RESTRICTED_DISC)
        self.assertEqual(
            written["m.room.history_visibility"], {"history_visibility": "shared"}
        )

    def test_already_migrated_channel_is_untouched(self):
        """Повторный прогон (каждый рестарт Synapse) ничего не пишет.

        Это и есть причина, по которой миграции не нужен флаг в конфиге:
        идемпотентность считается по фактическому состоянию комнаты. Ловит
        снятие гейта plan_is_noop — без него Synapse на КАЖДОМ рестарте
        переписывал бы join_rules/history_visibility/topology во всех чатах
        обсуждений прода.
        """
        m = self._module(
            channel_join_rule="public",
            discussion_join_rule="public",
            discussion_history_visibility="world_readable",
            discussion_hidden=True,
        )

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])
        self.assertEqual(m._api.memberships, [])
        # False = «канал не менялся»: по этому флагу считается «изменено N» в
        # итоговом логе, ради которого и стоит гейт plan_is_noop.
        self.assertFalse(asyncio.run(m._migrate_one_channel("!chan:h")))

    def test_migrated_channel_reports_change(self):
        """Обратная сторона: канал, который реально мигрировали, даёт True."""
        m = self._module(channel_join_rule="public")

        self.assertTrue(asyncio.run(m._migrate_one_channel("!chan:h")))

    def test_second_run_after_migration_writes_nothing(self):
        """Идемпотентность сквозь фактическую запись: прогоняем миграцию,
        применяем её результат к состоянию комнаты и прогоняем ещё раз."""
        m = self._module(channel_join_rule="public")

        asyncio.run(m._migrate_channel_discussions())
        self.assertTrue(m._api.state_events)

        # Применяем записанное к фейковому состоянию — как это сделал бы
        # реальный Synapse.
        for ev in m._api.state_events:
            if ev["type"] == "m.room.join_rules":
                m._state._join_rules["!disc:h"] = ev["content"]
            elif ev["type"] == "m.room.history_visibility":
                m._state._history_visibility["!disc:h"] = ev["content"][
                    "history_visibility"
                ]
            elif ev["type"] == "com.liza.chat.topology":
                m._state._topology["!disc:h"] = ev["content"]
        m._api.state_events = []

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])

    def test_explicit_hidden_false_is_rewritten(self):
        """hidden=false — не «уже мигрировано»: чат светился бы в списке."""
        m = self._module(
            channel_join_rule="public",
            discussion_join_rule="public",
            discussion_history_visibility="world_readable",
            discussion_hidden=False,
        )

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(
            self._state_written(m)["com.liza.chat.topology"], {"hidden": True}
        )

    def test_channel_without_discussion_is_skipped(self):
        """Комментарии у канала выключены — трогать нечего."""
        m = self._module(discussion_rooms={"!chan:h": None})

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])
        self.assertEqual(m._api.memberships, [])

    def test_failed_channel_does_not_stop_the_rest(self):
        """Исключение на одной комнате не срывает проход по остальным.

        Ловит снятие try вокруг _migrate_one_channel: без него первый же
        сбойный канал оборвал бы миграцию всего инстанса.
        """
        m = self._module(
            channel_join_rule="public",
            channel_rooms=("!broken:h", "!chan:h"),
            discussion_rooms={"!broken:h": "!nocreator:h", "!chan:h": "!disc:h"},
        )
        original_state = m._state.get_current_state_event

        async def _boom(room_id, ev_type, state_key):
            if room_id == "!broken:h":
                raise RuntimeError("boom")
            return await original_state(room_id, ev_type, state_key)

        m._state.get_current_state_event = _boom

        asyncio.run(m._migrate_channel_discussions())

        self.assertTrue(m._api.state_events)
        for ev in m._api.state_events:
            self.assertEqual(ev["room_id"], "!disc:h")

    def test_channel_without_chat_creator_is_skipped(self):
        """У привязанного чата нет m.room.create — писать не от кого."""
        m = self._module(
            channel_join_rule="public",
            room_creators={"!chan:h": "@owner:h"},
        )
        m._state._room_chat_types["!disc:h"] = None  # нет m.room.create

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])
        self.assertEqual(m._api.memberships, [])

    def test_state_write_failure_does_not_stop_the_rest(self):
        """Отказ ОДНОЙ записи state не отменяет остальные записи.

        Без try вокруг каждой записи чат завис бы в полусостоянии (например,
        public без world_readable).
        """
        m = self._module(
            channel_join_rule="invite",
            channel_members=("@a:h",),
            discussion_join_rule="public",  # чинится записью join_rules
        )

        original = m._api.create_and_send_event_into_room

        async def _boom(event_dict):
            if event_dict.get("type") == "m.room.join_rules":
                raise RuntimeError("boom")
            return await original(event_dict)

        m._api.create_and_send_event_into_room = _boom

        asyncio.run(m._migrate_channel_discussions())

        written = self._state_written(m)
        self.assertNotIn("m.room.join_rules", written)  # эта упала
        self.assertIn("com.liza.chat.topology", written)  # эта прошла
        self.assertEqual(m._api.memberships, [])

    def test_lookup_failure_is_swallowed(self):
        """Упавший поиск каналов не роняет старт Synapse."""
        m = self._module()
        m._store.fail_find_channel_rooms = True

        asyncio.run(m._migrate_channel_discussions())  # не должно бросить

        self.assertEqual(m._api.state_events, [])

    def test_no_main_store_is_noop(self):
        m = _make_module(channel_rooms=["!chan:h"])  # main_store=None

        asyncio.run(m._migrate_channel_discussions())

        self.assertEqual(m._api.state_events, [])

    def test_startup_runs_schema_before_migration(self):
        """Схема БД создаётся до миграции — порядок в одном фоновом процессе."""
        m = self._module(channel_join_rule="public")
        order = []
        original_schema = m._store.ensure_schema
        original_migrate = m._migrate_channel_discussions

        async def _schema():
            order.append("schema")
            await original_schema()

        async def _migrate():
            order.append("migrate")
            await original_migrate()

        m._store.ensure_schema = _schema
        m._migrate_channel_discussions = _migrate

        asyncio.run(m._on_startup())

        self.assertEqual(order, ["schema", "migrate"])
        self.assertEqual(m._store.schema_calls, 1)

    def test_schema_failure_does_not_block_migration(self):
        """Отказ создания схемы не отменяет миграцию: она в channel_post_mirror
        не пишет и от таблицы не зависит."""
        m = self._module(channel_join_rule="public")

        async def _boom():
            raise RuntimeError("boom")

        m._store.ensure_schema = _boom

        asyncio.run(m._on_startup())  # не должно бросить

        self.assertTrue(m._api.state_events)


if __name__ == "__main__":
    unittest.main()


class BindingMigratesDiscussionTest(unittest.TestCase):
    """AC:RL-channel-discussion-restricted-join/4 — привязка чата к каналу сразу
    приводит его к модели: старые клиенты (≤3779) создают чат закрытого канала
    как invite, и без реакции на привязку подписчики не вошли бы до рестарта."""

    def _module(self, content):
        event, stored = _unlink_event(prev_discussion=None, new_content=content)
        main_store = _FakeMainStore(events={stored.event_id: stored})
        m = _make_module(
            room_chat_types={"!chan:h": "channel", "!disc:h": "channel_discussion"},
            join_rules={"!chan:h": "invite", "!disc:h": "invite"},
            room_creators={"!disc:h": "@owner:h", "!chan:h": "@owner:h"},
            history_visibility={"!disc:h": "shared", "!chan:h": "shared"},
            main_store=main_store,
        )
        return m, event

    def test_привязка_invite_чата_делает_его_restricted(self):
        m, event = self._module({"room_id": "!disc:h"})

        _run_on_new_event(m, event, {})

        written = {ev["type"]: ev for ev in m._api.state_events}
        self.assertEqual(written["m.room.join_rules"]["content"], RESTRICTED_DISC)
        self.assertEqual(written["m.room.join_rules"]["room_id"], "!disc:h")

    def test_маркер_удаления_и_отвязка_не_мигрируют(self):
        for content in ({"room_id": "!disc:h", "deleted": True}, {}):
            m, event = self._module(content)

            _run_on_new_event(m, event, {})

            self.assertEqual(m._api.state_events, [], content)
