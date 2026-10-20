import asyncio
import unittest

import pytest

from synapse_modules.channel_guard._logic import (
    LIZA_CHANNEL_ROOM_TYPE,
    is_channel_creation,
)


def _run(coro):
    return asyncio.run(coro)


def test_is_channel_creation_true():
    assert is_channel_creation(
        {"creation_content": {"com.liza.chat.type": "channel"}}
    )


def test_is_channel_creation_false_for_space():
    assert not is_channel_creation({"creation_content": {"type": "m.space"}})


def test_is_channel_creation_false_when_no_creation_content():
    assert not is_channel_creation({})


class _FakeApi:
    """Fake ModuleApi: конструктор модуля вызывает register_third_party_rules_callbacks,
    поэтому fake обязан его иметь (иначе __init__ упадёт)."""

    def __init__(self):
        self.registered = {}

    def register_third_party_rules_callbacks(self, **callbacks):
        self.registered.update(callbacks)


class _FakeUser:
    def __init__(self, user_id):
        self._id = user_id

    def to_string(self):
        return self._id


class _FakeRequester:
    def __init__(self, user_id):
        self.user = _FakeUser(user_id)


def _channel_config():
    return {"creation_content": {"com.liza.chat.type": "channel"}}


# ledger:RL-create-menu-order-agent-entry AC:RL-create-menu-order-agent-entry/10
# Канал создаёт любая роль: модуль не читает роль и не бросает 403, а только
# помечает room_type для каталога.
@pytest.mark.parametrize("role", ["user", "developer", "ai", "moderator", "admin"])
@pytest.mark.parametrize("is_requester_admin", [False, True])
def test_any_role_creates_channel_with_room_type(role, is_requester_admin):
    from synapse_modules.channel_guard import ChannelGuardModule

    module = ChannelGuardModule({}, _FakeApi())
    config = _channel_config()
    _run(
        module._on_create_room(
            _FakeRequester(f"@{role}:h"), config, is_requester_admin
        )
    )
    assert config["creation_content"]["type"] == LIZA_CHANNEL_ROOM_TYPE


def test_module_registers_on_create_room():
    from synapse_modules.channel_guard import ChannelGuardModule

    api = _FakeApi()
    ChannelGuardModule({}, api)
    assert "on_create_room" in api.registered


def test_non_channel_create_is_untouched():
    from synapse_modules.channel_guard import ChannelGuardModule

    module = ChannelGuardModule({}, _FakeApi())
    config = {"creation_content": {}}
    _run(module._on_create_room(_FakeRequester("@u:h"), config, False))
    assert config == {"creation_content": {}}


def test_mark_channel_room_type_sets_type():
    from synapse_modules.channel_guard._logic import (
        LIZA_CHANNEL_ROOM_TYPE,
        mark_channel_room_type,
    )

    config = {"creation_content": {"com.liza.chat.type": "channel"}}
    assert mark_channel_room_type(config) is True
    assert config["creation_content"]["type"] == LIZA_CHANNEL_ROOM_TYPE


def test_mark_channel_room_type_ignores_non_channel():
    from synapse_modules.channel_guard._logic import mark_channel_room_type

    config = {"creation_content": {"com.liza.chat.type": "stories"}}
    assert mark_channel_room_type(config) is False
    assert "type" not in config["creation_content"]


def test_mark_channel_room_type_ignores_channel_discussion():
    """channel_discussion — отдельный тип, каналом в каталоге он не является."""
    from synapse_modules.channel_guard._logic import mark_channel_room_type

    config = {"creation_content": {"com.liza.chat.type": "channel_discussion"}}
    assert mark_channel_room_type(config) is False
    assert "type" not in config["creation_content"]


def test_mark_channel_room_type_does_not_overwrite_explicit_type():
    from synapse_modules.channel_guard._logic import mark_channel_room_type

    config = {
        "creation_content": {
            "com.liza.chat.type": "channel",
            "type": "m.space",
        }
    }
    assert mark_channel_room_type(config) is False
    assert config["creation_content"]["type"] == "m.space"


if __name__ == "__main__":
    unittest.main()
