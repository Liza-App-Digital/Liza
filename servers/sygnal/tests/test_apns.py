# -*- coding: utf-8 -*-
# Copyright 2025 New Vector Ltd.
# Copyright 2019 The Matrix.org Foundation C.I.C.
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE files in the repository root for full details.
#
# Originally licensed under the Apache License, Version 2.0:
# <http://www.apache.org/licenses/LICENSE-2.0>.
from typing import Any, Dict
from unittest.mock import MagicMock, patch

from aioapns.common import NotificationResult, PushType

from sygnal import apnstruncate
from sygnal.apnspushkin import ApnsPushkin

from tests import testutils

PUSHKIN_ID = "com.example.apns"
PUSHKIN_ID_WITH_PUSH_TYPE = "com.example.apns.push_type"

TEST_CERTFILE_PATH = "/path/to/my/certfile.pem"

DEVICE_EXAMPLE = {"app_id": "com.example.apns", "pushkey": "spqr", "pushkey_ts": 42}
DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD = {
    "app_id": "com.example.apns",
    "pushkey": "spqr",
    "pushkey_ts": 42,
    "data": {
        "default_payload": {
            "aps": {
                "mutable-content": 1,
                "alert": {"loc-key": "SINGLE_UNREAD", "loc-args": []},
            }
        }
    },
}

DEVICE_EXAMPLE_WITH_BAD_DEFAULT_PAYLOAD = {
    "app_id": "com.example.apns",
    "pushkey": "badpayload",
    "pushkey_ts": 42,
    "data": {"default_payload": None},
}

DEVICE_EXAMPLE_FOR_PUSH_TYPE_PUSHKIN = {
    "app_id": "com.example.apns.push_type",
    "pushkey": "spqr",
    "pushkey_ts": 42,
}

# Зеркалит боевой default_payload клиента (background_push.dart): mutable-content
# для NSE + звук, но БЕЗ aps.alert. На таком payload баннер рисует NSE, а prio=10
# всё равно легален по критерию Apple (есть aps.sound). Нужен для RL-apns-alert-
# priority AC-3: event_id_only-пуш с этим default_payload → priority == 10.
DEVICE_EXAMPLE_WITH_SOUND_DEFAULT_PAYLOAD = {
    "app_id": "com.example.apns",
    "pushkey": "spqr",
    "pushkey_ts": 42,
    "data": {
        "default_payload": {
            "aps": {
                "mutable-content": 1,
                "sound": "liza_ding.aiff",
            }
        }
    },
}


class ApnsTestCase(testutils.TestCase):
    def setUp(self) -> None:
        self.apns_mock_class = patch("sygnal.apnspushkin.APNs").start()
        self.apns_mock = MagicMock()
        self.apns_mock_class.return_value = self.apns_mock

        # pretend our certificate exists
        patch("os.path.exists", lambda x: x == TEST_CERTFILE_PATH).start()
        # Since no certificate exists, don't try to read it.
        patch("sygnal.apnspushkin.ApnsPushkin._report_certificate_expiration").start()
        self.addCleanup(patch.stopall)

        super().setUp()

        self.apns_pushkin_snotif = MagicMock()
        test_pushkin = self.get_test_pushkin(PUSHKIN_ID)
        test_pushkin_push_type = self.get_test_pushkin(PUSHKIN_ID_WITH_PUSH_TYPE)
        # type safety: using ignore here due to mypy not handling monkeypatching,
        # see https://github.com/python/mypy/issues/2427
        test_pushkin._send_notification = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501
        test_pushkin_push_type._send_notification = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501

    def get_test_pushkin(self, name: str) -> ApnsPushkin:
        test_pushkin = self.sygnal.pushkins[name]
        assert isinstance(test_pushkin, ApnsPushkin)
        return test_pushkin

    def config_setup(self, config: Dict[str, Any]) -> None:
        super().config_setup(config)
        config["apps"][PUSHKIN_ID] = {"type": "apns", "certfile": TEST_CERTFILE_PATH}
        config["apps"][PUSHKIN_ID_WITH_PUSH_TYPE] = {
            "type": "apns",
            "certfile": TEST_CERTFILE_PATH,
            "push_type": "alert",
        }

    def test_payload_truncation(self) -> None:
        """
        Tests that APNS message bodies will be truncated to fit the limits of
        APNS.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        test_pushkin = self.get_test_pushkin(PUSHKIN_ID)
        test_pushkin.MAX_JSON_BODY_SIZE = 240

        # Act
        self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args
        payload = notification_req.message

        self.assertLessEqual(len(apnstruncate.json_encode(payload)), 240)

    def test_payload_truncation_test_validity(self) -> None:
        """
        This tests that L{test_payload_truncation_success} is a valid test
        by showing that not limiting the truncation size would result in a
        longer message.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        test_pushkin = self.get_test_pushkin(PUSHKIN_ID)
        test_pushkin.MAX_JSON_BODY_SIZE = 4096

        # Act
        self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args
        payload = notification_req.message

        self.assertGreater(len(apnstruncate.json_encode(payload)), 200)

    def test_expected(self) -> None:
        """AC:RL-apns-alert-priority/7 — приоритетный фикс НЕ меняет payload:
        ассерт сверяет ВЕСЬ notification_req.message целиком, поэтому любая
        подмена содержимого (а не только заголовков) красит тест.

        Tests the expected case: a good response from APNS means we pass on
        a good response to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )

        # Act
        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args

        self.assertEqual(
            {
                "room_id": "!slw48wfj34rtnrf:example.com",
                "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                "aps": {
                    "alert": {
                        "loc-key": "MSG_FROM_USER_IN_ROOM_WITH_CONTENT",
                        "loc-args": [
                            "Major Tom",
                            "Mission Control",
                            "I'm floating in a most peculiar way.",
                        ],
                    },
                    "badge": 3,
                },
                "content": {
                    "msgtype": "m.text",
                    "body": "I'm floating in a most peculiar way.",
                },
                "counts": '{"unread": 2, "missed_calls": 1}',
                "room_name": "Mission Control",
                "sender": "@exampleuser:matrix.org",
                "sender_display_name": "Major Tom",
                "type": "m.room.message",
            },
            notification_req.message,
        )

        self.assertEqual({"rejected": []}, resp)

    def test_expected_event_id_only_with_default_payload(self) -> None:
        """
        Tests the expected fallback case: a good response from APNS means we pass on
        a good response to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )

        # Act
        resp = self._request(
            self._make_dummy_notification_event_id_only(
                [DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD]
            )
        )

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args

        self.assertEqual(
            {
                "room_id": "!slw48wfj34rtnrf:example.com",
                "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                "unread_count": 2,
                "aps": {
                    "alert": {"loc-key": "SINGLE_UNREAD", "loc-args": []},
                    "mutable-content": 1,
                },
            },
            notification_req.message,
        )

        self.assertEqual({"rejected": []}, resp)

    def test_expected_badge_only_with_default_payload(self) -> None:
        """
        Tests the expected fallback case: a good response from APNS means we pass on
        a good response to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )

        # Act
        resp = self._request(
            self._make_dummy_notification_badge_only(
                [DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD]
            )
        )

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args

        self.assertEqual(
            {"aps": {"badge": 2}, "counts": '{"unread": 2}'},
            notification_req.message,
        )

        self.assertEqual({"rejected": []}, resp)

    def test_expected_full_with_default_payload(self) -> None:
        """
        Tests the expected fallback case: a good response from APNS means we pass on
        a good response to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )

        # Act
        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD])
        )

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args

        self.assertEqual(
            {
                "room_id": "!slw48wfj34rtnrf:example.com",
                "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                "aps": {
                    "alert": {
                        "loc-key": "MSG_FROM_USER_IN_ROOM_WITH_CONTENT",
                        "loc-args": [
                            "Major Tom",
                            "Mission Control",
                            "I'm floating in a most peculiar way.",
                        ],
                    },
                    "badge": 3,
                    "mutable-content": 1,
                },
                "content": {
                    "msgtype": "m.text",
                    "body": "I'm floating in a most peculiar way.",
                },
                "counts": '{"unread": 2, "missed_calls": 1}',
                "room_name": "Mission Control",
                "sender": "@exampleuser:matrix.org",
                "sender_display_name": "Major Tom",
                "type": "m.room.message",
            },
            notification_req.message,
        )

        self.assertEqual({"rejected": []}, resp)

    def test_misconfigured_payload_is_rejected(self) -> None:
        """Test that a malformed default_payload causes pushkey to be rejected"""

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_WITH_BAD_DEFAULT_PAYLOAD])
        )

        self.assertEqual({"rejected": ["badpayload"]}, resp)

    def test_rejection(self) -> None:
        """
        Tests the rejection case: a rejection response from APNS leads to us
        passing on a rejection to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "410", description="Unregistered")
        )

        # Act
        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertEqual(1, method.call_count)
        self.assertEqual({"rejected": ["spqr"]}, resp)

    def test_no_retry_on_4xx(self) -> None:
        """
        Test that we don't retry when we get a 4xx error but do not mark as
        rejected.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "429", description="TooManyRequests")
        )

        # Act
        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertEqual(1, method.call_count)
        self.assertEqual(502, resp)

    def test_retry_on_5xx(self) -> None:
        """
        Test that we DO retry when we get a 5xx error and do not mark as
        rejected.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "503", description="ServiceUnavailable")
        )

        # Act
        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        # Assert
        self.assertGreater(method.call_count, 1)
        self.assertEqual(502, resp)

    def test_expected_with_push_type(self) -> None:
        """
        Tests the expected case: a good response from APNS means we pass on
        a good response to the homeserver.
        """
        # Arrange
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )

        # Act
        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_FOR_PUSH_TYPE_PUSHKIN])
        )

        # Assert
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args

        self.assertEqual(
            {
                "room_id": "!slw48wfj34rtnrf:example.com",
                "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                "aps": {
                    "alert": {
                        "loc-key": "MSG_FROM_USER_IN_ROOM_WITH_CONTENT",
                        "loc-args": [
                            "Major Tom",
                            "Mission Control",
                            "I'm floating in a most peculiar way.",
                        ],
                    },
                    "badge": 3,
                },
                "content": {
                    "msgtype": "m.text",
                    "body": "I'm floating in a most peculiar way.",
                },
                "counts": '{"unread": 2, "missed_calls": 1}',
                "room_name": "Mission Control",
                "sender": "@exampleuser:matrix.org",
                "sender_display_name": "Major Tom",
                "type": "m.room.message",
            },
            notification_req.message,
        )

        self.assertEqual(PushType.ALERT, notification_req.push_type)

        # AC:RL-apns-alert-priority/8 — приоритет и push_type сосуществуют: даже
        # для pushkin с push_type=alert обычное сообщение уходит priority == 10.
        self.assertEqual(10, notification_req.priority)

        self.assertEqual({"rejected": []}, resp)

    # ------------------------------------------------------------------
    # RL-apns-alert-priority — приоритет доставки APNs по содержимому payload.
    #
    # Synapse шлёт prio="low" для всех обычных (не-highlight/не-encrypted)
    # сообщений (httppusher.py:472-480). Раньше apnspushkin понижал такие пуши до
    # APNs prio=5, а Apple низкоприоритетные пуши коалесцирует/придерживает
    # минутами → баннер приходил через ~10 мин, уже после прочтения. Фикс: prio=10
    # для видимых alert-пушей (aps несёт alert/sound/badge), prio=5 только для
    # истинно тихих. Матрица обязательно с prio:"low" — dummy по умолчанию "high"
    # (testutils.py) замаскировал бы регресс. Ассерт на РЕАЛЬНОМ NotificationRequest.
    # ------------------------------------------------------------------

    def _priority_of(self, notification: Dict[str, Any]) -> int:
        """Диспатчит notification и возвращает NotificationRequest.priority."""
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        self._request(notification)
        self.assertEqual(1, method.call_count)
        ((notification_req,), _kwargs) = method.call_args
        return notification_req.priority

    def test_priority_text_message_low_prio_is_high(self) -> None:
        """ledger:RL-apns-alert-priority
        AC:RL-apns-alert-priority/1 — обычное текстовое сообщение (aps.alert),
        Synapse прислал prio="low" → APNs priority == 10 (немедленная доставка)."""
        notif = self._make_dummy_notification([DEVICE_EXAMPLE])
        notif["notification"]["prio"] = "low"
        self.assertEqual(10, self._priority_of(notif))

    def test_priority_media_message_low_prio_is_high(self) -> None:
        """AC:RL-apns-alert-priority/2 — медиа-пуш (m.image → aps.alert),
        prio="low" → priority == 10."""
        notif = self._make_dummy_notification([DEVICE_EXAMPLE])
        notif["notification"]["prio"] = "low"
        notif["notification"]["content"] = {"msgtype": "m.image", "body": "photo.jpg"}
        self.assertEqual(10, self._priority_of(notif))

    def test_priority_event_id_only_with_sound_is_high(self) -> None:
        """AC:RL-apns-alert-priority/3 — event_id_only-пуш (mention/e2ee, баннер
        рисует NSE, aps.alert НЕТ) с боевым default_payload (aps.sound),
        prio="low" → priority == 10 (aps.sound делает prio=10 легальным у Apple)."""
        notif = self._make_dummy_notification_event_id_only(
            [DEVICE_EXAMPLE_WITH_SOUND_DEFAULT_PAYLOAD]
        )
        notif["notification"]["prio"] = "low"
        self.assertEqual(10, self._priority_of(notif))

    def test_priority_story_low_prio_is_high(self) -> None:
        """AC:RL-apns-alert-priority/4 — story-пуш (com.liza.story → aps.alert),
        prio="low" → priority == 10."""
        notif = self._make_dummy_notification([DEVICE_EXAMPLE])
        notif["notification"]["prio"] = "low"
        notif["notification"]["room_name"] = "Stories - ivan"
        notif["notification"]["content"] = {"com.liza.story": {"expires_ts": 1}}
        self.assertEqual(10, self._priority_of(notif))

    def test_priority_silent_payload_without_aps_content_is_low(self) -> None:
        """AC:RL-apns-alert-priority/5 (red-proof, обратен AC-1) — event_id_only-пуш
        БЕЗ default_payload (пустой aps, нет alert/sound/badge) → priority == 5.
        Так тихий фон не будит экран; если фикс форсит 10 всем подряд — падает."""
        notif = self._make_dummy_notification_event_id_only([DEVICE_EXAMPLE])
        notif["notification"]["prio"] = "low"
        self.assertEqual(5, self._priority_of(notif))

    def test_priority_counts_only_without_badge_is_not_dispatched(self) -> None:
        """AC:RL-apns-alert-priority/6 — counts-only пуш без loc_key и без badge
        (пустой counts) → _get_payload_full == None → диспатча нет вовсе
        (регресс-якорь: приоритет к нему не применяется)."""
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        notif = {
            "notification": {
                "id": "",
                "type": None,
                "sender": "",
                "counts": {},
                "devices": [DEVICE_EXAMPLE],
            }
        }
        self._request(notif)
        self.assertEqual(0, method.call_count)

    # ------------------------------------------------------------------
    # RL-push-clearing-silent — counts-only (своя квитанция) → тихий
    # background-пуш «почисти шторку», только клиентам с liza_clear_v.
    # howItWoks/pushes.md §21.
    # ------------------------------------------------------------------

    def _clearing_device(self, **extra: Any) -> Dict[str, Any]:
        default_payload: Dict[str, Any] = {
            "client_name": "Liza ios",
            "platform": "ios",
            "liza_clear_v": 1,
            "aps": {"mutable-content": 1, "sound": "liza_ding.aiff"},
        }
        default_payload.update(extra)
        return {
            "app_id": "com.example.apns",
            "pushkey": "spqr",
            "pushkey_ts": 42,
            "data": {"default_payload": default_payload},
        }

    def _dispatch_clearing(self, device: Dict[str, Any], unread: int = 0) -> Any:
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        notif = self._make_dummy_notification_badge_only([device])
        notif["notification"]["counts"] = {"unread": unread}
        resp = self._request(notif)
        self.assertEqual({"rejected": []}, resp)
        return method

    def test_clearing_push_is_silent_background(self) -> None:
        """ledger:RL-push-clearing-silent
        AC:RL-push-clearing-silent/1 — counts-only + liza_clear_v → ровно одна
        отправка: push_type=background, priority 5, aps только content-available
        (без alert/sound/badge/mutable-content из default_payload), TTL задан."""
        method = self._dispatch_clearing(self._clearing_device())
        self.assertEqual(1, method.call_count)
        ((req,), _kwargs) = method.call_args
        self.assertEqual(PushType.BACKGROUND, req.push_type)
        self.assertEqual(5, req.priority)
        self.assertEqual({"content-available": 1}, req.message["aps"])
        self.assertEqual(ApnsPushkin.CLEARING_PUSH_TTL_SECONDS, req.time_to_live)

    def test_clearing_push_payload_carries_counts_and_client_name(self) -> None:
        """AC:RL-push-clearing-silent/2 — payload: counts.unread (форма, которую
        читает PushNotification.fromJson), client_name/platform из default_payload
        (маршрут мультиаккаунта), маркер liza_clear."""
        method = self._dispatch_clearing(self._clearing_device(), unread=3)
        ((req,), _kwargs) = method.call_args
        self.assertEqual({"unread": 3}, req.message["counts"])
        self.assertEqual("Liza ios", req.message["client_name"])
        self.assertEqual("ios", req.message["platform"])
        self.assertEqual(1, req.message["liza_clear"])

    def test_clearing_push_on_push_type_pushkin_is_still_background(self) -> None:
        """AC:RL-push-clearing-silent/1 — push_type per-request: даже pushkin с
        push_type=alert в конфиге шлёт clearing как background."""
        device = self._clearing_device()
        device["app_id"] = PUSHKIN_ID_WITH_PUSH_TYPE
        method = self._dispatch_clearing(device)
        ((req,), _kwargs) = method.call_args
        self.assertEqual(PushType.BACKGROUND, req.push_type)

    def test_clearing_push_not_sent_without_capability(self) -> None:
        """AC:RL-push-clearing-silent/3 — клиент без liza_clear_v (старая сборка,
        старый бандл) → 0 отправок, как раньше (RL-apns-alert-priority AC-6).
        send_badge_counts:false — как в боевом sygnal.yaml."""
        self.get_test_pushkin(PUSHKIN_ID).cfg["send_badge_counts"] = False
        method = self._dispatch_clearing(DEVICE_EXAMPLE_WITH_SOUND_DEFAULT_PAYLOAD)
        self.assertEqual(0, method.call_count)

    def test_clearing_push_kill_switch(self) -> None:
        """AC:RL-push-clearing-silent/3 — аварийный выключатель clearing_push:false
        → 0 отправок даже при liza_clear_v."""
        pushkin = self.get_test_pushkin(PUSHKIN_ID)
        pushkin.cfg["clearing_push"] = False
        pushkin.cfg["send_badge_counts"] = False
        method = self._dispatch_clearing(self._clearing_device())
        self.assertEqual(0, method.call_count)

    def test_event_push_unchanged_for_clearing_capable_device(self) -> None:
        """AC:RL-push-clearing-silent/4 — пуш С событием клиенту с liza_clear_v
        остаётся видимым: push_type pushkin'а, priority 10, aps.sound на месте."""
        for push_type_pushkin in (False, True):
            self.apns_pushkin_snotif.reset_mock()
            device = self._clearing_device()
            if push_type_pushkin:
                device["app_id"] = PUSHKIN_ID_WITH_PUSH_TYPE
            notif = self._make_dummy_notification_event_id_only([device])
            notif["notification"]["prio"] = "low"
            self.assertEqual(10, self._priority_of(notif))
            ((req,), _kwargs) = self.apns_pushkin_snotif.call_args
            self.assertEqual(
                PushType.ALERT if push_type_pushkin else None, req.push_type
            )
            self.assertEqual("liza_ding.aiff", req.message["aps"]["sound"])
            self.assertNotIn("liza_clear", req.message)

    # ------------------------------------------------------------------
    # RL-macos-push-no-nse-wakeup — macOS-pusher'у APNs уходит без
    # aps.mutable-content: расширение уведомлений Лизы на Маке не стартует,
    # usernoted убивает его за «sluggish startup» и через 120 с ПОВТОРНО
    # показывает баннер (жалоба Саши 19.10, howItWoks/pushes/pushes.md §24).
    # iOS (там NSE рабочий) и неопознанные Apple-устройства не трогаем.
    # ------------------------------------------------------------------

    def _apple_device(self, **default_payload: Any) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "aps": {"mutable-content": 1, "sound": "liza_ding.aiff"},
        }
        payload.update(default_payload)
        return {
            "app_id": "com.example.apns",
            "pushkey": "spqr",
            "pushkey_ts": 42,
            "data": {"data_message": "ios", "default_payload": payload},
        }

    def _sent_request(self, notification: Dict[str, Any]) -> Any:
        method = self.apns_pushkin_snotif
        method.reset_mock()
        method.side_effect = testutils.make_async_magic_mock(
            NotificationResult("notID", "200")
        )
        self._request(notification)
        self.assertEqual(1, method.call_count)
        ((req,), _kwargs) = method.call_args
        return req

    def _all_payload_shapes(self, device: Dict[str, Any]) -> Dict[str, Any]:
        story = self._make_dummy_notification([device])
        story["notification"]["room_name"] = "Stories - ivan"
        story["notification"]["content"] = {"com.liza.story": {"expires_ts": 1}}
        return {
            "full": self._make_dummy_notification([device]),
            "event_id_only": self._make_dummy_notification_event_id_only([device]),
            "story": story,
            "too_large_fallback": self._make_dummy_notification_large_fields([device]),
        }

    def test_macos_push_has_no_mutable_content_in_any_payload_shape(self) -> None:
        """ledger:RL-macos-push-no-nse-wakeup
        AC:RL-macos-push-no-nse-wakeup/1 — platform=macos: во всех формах payload
        (full, event_id_only, story, фолбэк слишком длинного) нет
        aps.mutable-content, звук остаётся.
        AC:RL-macos-push-no-nse-wakeup/3 — приоритет таких пушей 10."""
        device = self._apple_device(platform="macos", client_name="Liza macos")
        for shape, notif in self._all_payload_shapes(device).items():
            notif["notification"]["prio"] = "low"
            req = self._sent_request(notif)
            self.assertNotIn("mutable-content", req.message["aps"], shape)
            self.assertEqual("liza_ding.aiff", req.message["aps"]["sound"], shape)
            self.assertEqual(10, req.priority, shape)
        full = self._sent_request(self._make_dummy_notification([device]))
        self.assertIn("alert", full.message["aps"])
        # default_payload pusher'а не мутирован — следующий пуш строится заново.
        self.assertEqual(1, device["data"]["default_payload"]["aps"]["mutable-content"])

    def test_macos_by_client_name_without_platform_field(self) -> None:
        """AC:RL-macos-push-no-nse-wakeup/1 — Мак без поля platform, но с
        client_name «Liza macos» — тоже без mutable-content."""
        device = self._apple_device(client_name="Liza macos")
        req = self._sent_request(self._make_dummy_notification([device]))
        self.assertNotIn("mutable-content", req.message["aps"])

    def test_ios_and_unknown_apple_keep_mutable_content(self) -> None:
        """AC:RL-macos-push-no-nse-wakeup/2 — iOS (явный platform и по
        client_name) и неопознанное Apple-устройство сохраняют mutable-content=1
        во всех формах payload: на iOS NSE рисует аватар и считает бейдж."""
        for device in (
            self._apple_device(platform="ios", client_name="Liza ios"),
            self._apple_device(client_name="Liza ios"),
            self._apple_device(client_name="Liza-1729000000000"),
        ):
            for shape, notif in self._all_payload_shapes(device).items():
                req = self._sent_request(notif)
                self.assertEqual(1, req.message["aps"]["mutable-content"], shape)
