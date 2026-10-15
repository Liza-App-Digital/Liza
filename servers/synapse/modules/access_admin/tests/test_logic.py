"""Тесты чистой логики access_admin.

Модуль _logic.py намеренно не импортирует synapse — эти тесты гоняются
обычным unittest без контейнера.
"""

import unittest

from synapse_modules.access_admin._logic import (
    LEVEL_ADMIN,
    LEVEL_MODERATOR,
    LEVEL_USER,
    classify_room,
    is_bot_user,
    is_local_room,
    level_from_power,
    power_from_content,
)

BOT_LOCALPARTS = frozenset({"liza", "gpt", "deepseek", "bot_father", "botfather"})


class LevelFromPowerTestCase(unittest.TestCase):
    def test_admin_at_100(self):
        self.assertEqual(level_from_power(100), LEVEL_ADMIN)

    def test_admin_at_99_owner_model(self):
        # ledger:RL-room-owner-transfer — админ 99 (владелец 100) = admin.
        self.assertEqual(level_from_power(99), LEVEL_ADMIN)
        self.assertEqual(level_from_power(98), LEVEL_MODERATOR)

    def test_admin_above_100(self):
        self.assertEqual(level_from_power(150), LEVEL_ADMIN)

    def test_moderator_at_50(self):
        self.assertEqual(level_from_power(50), LEVEL_MODERATOR)

    def test_user_below_50(self):
        self.assertEqual(level_from_power(49), LEVEL_USER)

    def test_user_at_zero(self):
        self.assertEqual(level_from_power(0), LEVEL_USER)


class PowerFromContentTestCase(unittest.TestCase):
    def test_explicit_user_power(self):
        content = {"users": {"@a:srv": 100}, "users_default": 0}
        self.assertEqual(power_from_content(content, "@a:srv"), 100)

    def test_falls_back_to_users_default(self):
        content = {"users": {"@b:srv": 50}, "users_default": 25}
        self.assertEqual(power_from_content(content, "@a:srv"), 25)

    def test_users_default_missing_is_zero(self):
        content = {"users": {}}
        self.assertEqual(power_from_content(content, "@a:srv"), 0)

    def test_no_power_levels_event_is_zero(self):
        self.assertEqual(power_from_content(None, "@a:srv"), 0)

    def test_non_int_power_is_zero(self):
        content = {"users": {"@a:srv": "сто"}}
        self.assertEqual(power_from_content(content, "@a:srv"), 0)


class ClassifyRoomTestCase(unittest.TestCase):
    def test_space(self):
        self.assertEqual(classify_room("m.space", None), "space")

    def test_channel(self):
        self.assertEqual(classify_room("com.liza.channel", None), "channel")

    def test_plain_chat(self):
        self.assertEqual(classify_room(None, None), "chat")

    def test_stories_excluded(self):
        self.assertIsNone(classify_room(None, "stories"))

    def test_channel_discussion_excluded(self):
        self.assertIsNone(classify_room(None, "channel_discussion"))


class LegacyStoriesTestCase(unittest.TestCase):
    def test_legacy_stories_flag_excluded(self):
        self.assertIsNone(classify_room(None, None, legacy_stories=True))

    def test_legacy_flag_false_is_chat(self):
        self.assertEqual(classify_room(None, None, legacy_stories=False), "chat")

    def test_new_key_still_wins(self):
        self.assertIsNone(classify_room(None, "stories", legacy_stories=False))

    def test_legacy_flag_does_not_swallow_space_or_channel(self):
        # Легаси-ключ не должен прятать пространство/канал: сторисы —
        # всегда room_type = NULL, а потеря space из досье критична.
        self.assertEqual(
            classify_room("m.space", None, legacy_stories=True), "space"
        )
        self.assertEqual(
            classify_room("com.liza.channel", None, legacy_stories=True),
            "channel",
        )


class UnknownRoomTypeTestCase(unittest.TestCase):
    def test_unknown_room_type_falls_back_to_chat(self):
        self.assertEqual(classify_room("m.unknown", None), "chat")

    def test_space_and_channel_unaffected(self):
        self.assertEqual(classify_room("m.space", None), "space")
        self.assertEqual(classify_room("com.liza.channel", None), "channel")


class IsLocalRoomTestCase(unittest.TestCase):
    """Комнаты чужих серверов больше не отсекаются (Task 4, спека §5.2 п.3):
    досье показывает всё, что известно нашему серверу, независимо от
    домена в room_id.
    """

    def test_local(self):
        self.assertTrue(is_local_room("!abc:liza.example", "liza.example"))

    def test_federated_no_longer_excluded(self):
        self.assertTrue(is_local_room("!abc:other.example", "liza.example"))

    def test_suffix_lookalike_no_longer_excluded(self):
        self.assertTrue(is_local_room("!abc:notliza.example", "liza.example"))


class BotUserTestCase(unittest.TestCase):
    def test_bots_homeserver_is_bot(self):
        self.assertTrue(
            is_bot_user("@anything:bots.liza.ru", BOT_LOCALPARTS, "bots.liza.ru")
        )

    def test_known_localpart_is_bot(self):
        self.assertTrue(
            is_bot_user("@liza:liza.example", BOT_LOCALPARTS, "bots.liza.ru")
        )

    def test_regular_user_is_not_bot(self):
        self.assertFalse(
            is_bot_user("@ivan:liza.example", BOT_LOCALPARTS, "bots.liza.ru")
        )

    def test_malformed_mxid_is_not_bot(self):
        self.assertFalse(is_bot_user("garbage", BOT_LOCALPARTS, "bots.liza.ru"))


if __name__ == "__main__":
    unittest.main()
