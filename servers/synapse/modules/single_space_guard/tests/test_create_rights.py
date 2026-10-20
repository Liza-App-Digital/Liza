"""Порог «кто создаёт чаты / каналы в компании» (задача 12, Надежда 18.10).

ledger:RL-company-create-rights

Чистый предикат — по общим кейсам create_rights_cases.json (их же читает
dart-тест клиента). Проводка модуля — на фейковом ModuleApi. Пакет модуля
импортирует synapse/twisted, поэтому прогон — в venv с matrix-synapse
(см. servers/synapse/modules/README.md → «Тесты»).
"""

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from .. import SingleSpaceGuardModule
from .. import _guard as guard

_cases = json.loads((Path(__file__).parent / "create_rights_cases.json").read_text())["cases"]

MAIN = "!main:hs"
BOSS = "@boss:hs"


class FakeApi:
    server_name = "hs"

    def __init__(self, power_levels):
        self.power_levels = power_levels
        self.has_child = False
        self.create = None
        self.sent = []
        self.background = []
        self.delayed = []

    def register_third_party_rules_callbacks(self, **kw):
        pass

    def register_web_resource(self, *a):
        pass

    def is_mine(self, user_id):
        return user_id.endswith(":hs")

    async def run_db_interaction(self, desc, fn, *args):
        if desc == "single_space_guard_main_creator":
            return BOSS
        if desc == "single_space_guard_has_incoming_child":
            return self.has_child
        raise AssertionError(desc)

    async def get_room_state(self, room_id, event_filter=None):
        assert room_id == MAIN
        if self.power_levels is None:
            return {}
        state = {("m.room.power_levels", ""): SimpleNamespace(content=self.power_levels)}
        if self.create is not None:
            state[("m.room.create", "")] = self.create
        return state

    async def create_and_send_event_into_room(self, event_dict):
        self.sent.append(event_dict)

    def run_as_background_process(self, desc, fn, *args):
        self.background.append((fn, args))

    def delayed_background_call(self, ms, fn, *args, desc=None):
        self.delayed.append((ms, fn, args))


def _module(power_levels):
    api = FakeApi(power_levels)
    module = SingleSpaceGuardModule({"auto_add_new": True}, api)
    module._main_root_space_id = MAIN
    return module, api


def _create_event(sender, content=None, room_id="!new:hs"):
    return SimpleNamespace(
        type="m.room.create", room_id=room_id, sender=sender, content=content or {}
    )


def _run_create(module, api, event):
    asyncio.run(module._check_event_allowed(event, {}))
    for fn, args in api.background:
        asyncio.run(fn(*args))
    return [e for e in api.sent if e["type"] == "m.space.child"]


CHANNEL = {"com.liza.chat.type": "channel", "type": "com.liza.channel"}


class TestMayCreateInCompany:
    @pytest.mark.parametrize("case", _cases, ids=[c["name"] for c in _cases])
    def test_shared_cases(self, case):
        assert (
            guard.may_create_in_company(
                case["power_levels"], case["user"], case["kind"], case.get("creators", [])
            )
            is case["allowed"]
        )

    def test_none_content_is_denied(self):
        assert guard.may_create_in_company(None, "@u:hs", "chat") is False

    def test_bool_level_is_not_a_level(self):
        pl = {"users": {"@u:hs": True}, "events": {guard.CREATE_CHAT_KEY: 1}}
        assert guard.may_create_in_company(pl, "@u:hs", "chat") is False


class TestCreationKind:
    def test_plain_group_is_chat(self):
        assert guard.creation_kind({}) == "chat"

    def test_client_channel_marker(self):
        assert guard.creation_kind({"com.liza.chat.type": "channel"}) == "channel"

    def test_channel_guard_room_type(self):
        assert guard.creation_kind({"type": "com.liza.channel"}) == "channel"

    def test_stories_is_chat(self):
        assert guard.creation_kind({"com.liza.chat.type": "stories"}) == "chat"


class TestAutoAddRespectsRights:
    # AC:RL-company-create-rights/1
    def test_regular_user_group_not_added(self):
        module, api = _module({"users": {BOSS: 100}})
        assert _run_create(module, api, _create_event("@u:hs")) == []

    # AC:RL-company-create-rights/1
    def test_regular_user_channel_not_added(self):
        module, api = _module({"users": {BOSS: 100}})
        assert _run_create(module, api, _create_event("@u:hs", CHANNEL)) == []

    # AC:RL-company-create-rights/2
    def test_moderator_group_added_from_main_creator(self):
        module, api = _module({"users": {BOSS: 100, "@m:hs": 50}})
        sent = _run_create(module, api, _create_event("@m:hs"))
        assert len(sent) == 1
        assert sent[0]["room_id"] == MAIN
        assert sent[0]["state_key"] == "!new:hs"
        assert sent[0]["sender"] == BOSS

    # AC:RL-company-create-rights/2
    def test_open_threshold_lets_regular_in(self):
        module, api = _module({"events": {guard.CREATE_CHAT_KEY: 0}})
        assert len(_run_create(module, api, _create_event("@u:hs"))) == 1

    # AC:RL-company-create-rights/2
    def test_high_threshold_blocks_moderator(self):
        module, api = _module({"users": {"@m:hs": 50}, "events": {guard.CREATE_CHAT_KEY: 99}})
        assert _run_create(module, api, _create_event("@m:hs")) == []

    # AC:RL-company-create-rights/3
    def test_thresholds_are_independent(self):
        pl = {"events": {guard.CREATE_CHAT_KEY: 0}}
        module, api = _module(pl)
        assert len(_run_create(module, api, _create_event("@u:hs"))) == 1
        module, api = _module(pl)
        assert _run_create(module, api, _create_event("@u:hs", CHANNEL)) == []

    def test_unreadable_power_levels_fail_closed(self):
        module, api = _module(None)
        assert _run_create(module, api, _create_event(BOSS)) == []

    def _v12_create(self, msc4289=True, additional=None):
        content = {"room_version": "12"}
        if additional is not None:
            content["additional_creators"] = additional
        return SimpleNamespace(
            sender=BOSS,
            content=content,
            room_version=SimpleNamespace(msc4289_creator_power_enabled=msc4289),
        )

    def test_v12_creator_outside_users_is_added(self):
        # В v12 создатель главного не пишется в users, но уровень у него
        # бесконечный — его группы вкладываются.
        module, api = _module({"users": {}})
        api.create = self._v12_create()
        assert len(_run_create(module, api, _create_event(BOSS))) == 1

    def test_v12_additional_creator_is_added(self):
        module, api = _module({"users": {}})
        api.create = self._v12_create(additional=["@co:hs"])
        assert len(_run_create(module, api, _create_event("@co:hs"))) == 1

    def test_v10_creator_outside_users_is_not_special(self):
        module, api = _module({"users": {}})
        api.create = self._v12_create(msc4289=False)
        assert _run_create(module, api, _create_event(BOSS)) == []

    def test_check_event_allowed_never_rejects_create(self):
        module, api = _module({"users": {BOSS: 100}})
        allowed, _ = asyncio.run(module._check_event_allowed(_create_event("@u:hs"), {}))
        assert allowed is True


class TestDeferredPathUsesRoomSender:
    def _deferred(self, power_levels, sender):
        module, api = _module(power_levels)
        content = {guard.SPACE_PARENT_MARKER: True}
        asyncio.run(module._check_event_allowed(_create_event(sender, content), {}))
        assert api.background == []
        assert len(api.delayed) == 1
        return module, api

    # AC:RL-company-create-rights/4
    def test_deferred_checks_room_sender_not_main_creator(self):
        # Создатель главного (BOSS, 100) прав имеет — но решает право того,
        # кто создал комнату.
        module, api = self._deferred({"users": {BOSS: 100}}, "@u:hs")
        _, fn, args = api.delayed[0]
        assert args[2] == BOSS and args[3] == "@u:hs"
        asyncio.run(fn(*args))
        assert api.sent == []

    # AC:RL-company-create-rights/4
    def test_deferred_adds_when_sender_has_right(self):
        module, api = self._deferred({"users": {BOSS: 100, "@m:hs": 50}}, "@m:hs")
        _, fn, args = api.delayed[0]
        asyncio.run(fn(*args))
        assert len(api.sent) == 1

    # AC:RL-company-create-rights/4
    def test_deferred_rechecks_threshold_changed_during_grace(self):
        module, api = self._deferred({"users": {"@m:hs": 50}}, "@m:hs")
        api.power_levels = {"users": {"@m:hs": 50}, "events": {guard.CREATE_CHAT_KEY: 99}}
        _, fn, args = api.delayed[0]
        asyncio.run(fn(*args))
        assert api.sent == []

    def test_deferred_skips_when_parent_wrote_child(self):
        module, api = self._deferred({"users": {"@m:hs": 50}}, "@m:hs")
        api.has_child = True
        _, fn, args = api.delayed[0]
        asyncio.run(fn(*args))
        assert api.sent == []
