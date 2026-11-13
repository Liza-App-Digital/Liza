# -*- coding: utf-8 -*-
# Copyright 2025 New Vector Ltd.
# Copyright 2019 The Matrix.org Foundation C.I.C.
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE files in the repository root for full details.
#
# Originally licensed under the Apache License, Version 2.0:
# <http://www.apache.org/licenses/LICENSE-2.0>.
import json
import tempfile
from typing import TYPE_CHECKING, Any, AnyStr, Dict, List, Tuple
from unittest.mock import MagicMock

from twisted.internet.defer import Deferred, ensureDeferred

from sygnal.exceptions import (
    NotificationQuotaDispatchException,
    TemporaryNotificationDispatchException,
)
from sygnal.gcmpushkin import APIVersion, GcmPushkin

from tests import testutils
from tests.testutils import DummyResponse

if TYPE_CHECKING:
    from sygnal.sygnal import Sygnal

DEVICE_EXAMPLE = {"app_id": "com.example.gcm", "pushkey": "spqr", "pushkey_ts": 42}
DEVICE_EXAMPLE2 = {"app_id": "com.example.gcm", "pushkey": "spqr2", "pushkey_ts": 42}
DEVICE_EXAMPLE_APIV1 = {
    "app_id": "com.example.gcm.apiv1",
    "pushkey": "spqr",
    "pushkey_ts": 42,
}
DEVICE_EXAMPLE2_APIV1 = {
    "app_id": "com.example.gcm.apiv1",
    "pushkey": "spqr2",
    "pushkey_ts": 42,
}
DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD = {
    "app_id": "com.example.gcm",
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
DEVICE_EXAMPLE_APIV1_WITH_DEFAULT_PAYLOAD = {
    "app_id": "com.example.gcm.apiv1",
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
    "app_id": "com.example.gcm",
    "pushkey": "badpayload",
    "pushkey_ts": 42,
    "data": {
        "default_payload": None,
    },
}

DEVICE_EXAMPLE_IOS = {
    "app_id": "com.example.gcm.ios",
    "pushkey": "spqr",
    "pushkey_ts": 42,
}


class TestCredentials:
    def __init__(self) -> None:
        self.valid = False

    @property
    def token(self) -> str:
        if self.valid:
            return "myaccesstoken"
        else:
            raise Exception()

    async def refresh(self, request: Any) -> None:
        self.valid = True


class TestGcmPushkin(GcmPushkin):
    """
    A GCM pushkin with the ability to make HTTP requests removed and instead
    can be preloaded with virtual requests.
    """

    def __init__(self, name: str, sygnal: "Sygnal", config: Dict[str, Any]):
        super().__init__(name, sygnal, config)
        self.preloaded_response = DummyResponse(0)
        self.preloaded_response_payload: Dict[str, Any] = {}
        self.last_request_body: Dict[str, Any] = {}
        self.last_request_headers: Dict[AnyStr, List[AnyStr]] = {}  # type: ignore[valid-type]
        self.num_requests = 0
        if self.api_version is APIVersion.V1:
            self.credentials = TestCredentials()  # type: ignore[assignment]

    def preload_with_response(
        self, code: int, response_payload: Dict[str, Any]
    ) -> None:
        """
        Preloads a fake GCM response.
        """
        self.preloaded_response = DummyResponse(code)
        self.preloaded_response_payload = response_payload

    async def _perform_http_request(  # type: ignore[override]
        self, body: Dict[str, Any], headers: Dict[AnyStr, List[AnyStr]]
    ) -> Tuple[DummyResponse, str]:
        self.last_request_body = body
        self.last_request_headers = headers
        self.num_requests += 1
        return self.preloaded_response, json.dumps(self.preloaded_response_payload)

    async def _refresh_credentials(self) -> None:
        assert self.credentials is not None
        if not self.credentials.valid:
            await self.credentials.refresh(self.google_auth_request)


FAKE_SERVICE_ACCOUNT_FILE = b"""
{
  "type": "service_account",
  "project_id": "project_id",
  "private_key_id": "private_key_id",
  "private_key": "-----BEGIN PRIVATE KEY-----\\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC0PwE6TeTHjD5R\\nY2nOw1rsTgQZ38LCR2CLtx36n+LUkgej/9b+fwC88oKIqJKjUwn43JEOhf4rbA/a\\nqo4jVoLgv754G5+7Glfarr3/rqg+AVT75x6J5DRvhIYpDXwMIUqLAAbfk3TTFNJn\\n2ctrkBF2ZP9p3mzZ3NRjU63Wbf3LBpRqs8jdFEQu8JAecG8VKV1mboJIXG3hwqFN\\nJmcpC/+sWaxB5iMgSqy0w/rGFs6ZbZF6D10XYvf40lEEk9jQIovT+QD4+6GTlroT\\nbOk8uIwxFQcwMFpXj4MktqVNSNyiuuttptIvBWcMWHlaabXrR89vqUFe1g1Jx4GL\\nCF89RrcLAgMBAAECggEAPUYZ3b8zId78JGDeTEq+8wwGeuFFbRQkrvpeN5/41Xib\\nHlZPuQ5lqtXqKBjeWKVXA4G/0icc45gFv7kxPrQfI9YrItuJLmrjKNU0g+HVEdcU\\nE9pa2Fd6t9peXUBXRixfEee9bm3LTiKK8IDqlTNRrGTjKxNQ/7MBhI6izv1vRH/x\\n8i0o1xxNdqstHZ9wBFKYO9w8UQjtfzckkBNDLkaJ/WN0BoRubmUiV1+KwAyyBr6O\\nRnnZ9Tvy8VraSNSdJhX36ai36y18/sT6PWOp99zHYuDyz89KIz1la/fT9eSoR0Jy\\nYePmTEi+9pWhvtpAkqJkRxe5IDz71JVsQ07KoVfzaQKBgQDzKKUd/0ujhv/B9MQf\\nHcwSeWu/XnQ4hlcwz8dTWQjBV8gv9l4yBj9Pra62rg/tQ7b5XKMt6lv/tWs1IpdA\\neMsySY4972VPrmggKXgCnyKckDUYydNtHAIj9buo6AV8rONaneYnGv5wpSsf3q2c\\nOZrkamRgbBkI+B2mZ2obH1oVlQKBgQC9w9HkrDMvZ5L/ilZmpsvoHNFlQwmDgNlN\\n0ej5QGID5rljRM3CcLNHdyQiKqvLA9MCpPEXb2vVJPdmquD12A7a9s0OwxB/dtOD\\nykofcTY0ZHEM1HEyYJGmdK4FvZuNU4o2/D268dePjtj1Xw3c5fs0bcDiGQMtjWlz\\n5hjBzMsyHwKBgGjrIsPcwlBfEcAo0u7yNnnKNnmuUcuJ+9kt7j3Cbwqty80WKvK+\\ny1agBIECfhDMZQkXtbk8JFIjf4y/zi+db1/VaTDEORy2jmtCOWw4KgEQIDj/7OBp\\nc2r8vupUovl2x+rzsrkw5pTIT+FCffqoyHLCjWkle2/pTzHb8Waekoo5AoGAbELk\\nYy5uwTO45Hr60fOEzzZpq/iz28dNshz4agL2KD2gNGcTcEO1tCbfgXKQsfDLmG2b\\ncgBKJ77AOl1wnDEYQIme8TYOGnojL8Pfx9Jh10AaUvR8Y/49+hYFFhdXQCiR6M69\\nNQM2NJuNYWdKVGUMjJu0+AjHDFzp9YonQ6Ffp4cCgYEAmVALALCjU9GjJymgJ0lx\\nD9LccVHMwf9NmR/sMg0XNePRbCEcMDHKdtVJ1zPGS5txuxY3sRb/tDpv7TfuitrU\\nAw0/2ooMzunaoF/HXo+C/+t+pfuqPqLK4sCCyezUlMfCcaPdwXN2FmbgsaFHfe7I\\n7sGEnS/d8wEgydMiptJEf9s=\\n-----END PRIVATE KEY-----\\n",
  "client_email": "firebase-adminsdk@project_id.iam.gserviceaccount.com",
  "client_id": "client_id",
  "auth_uri": "https://accounts.google.com/o/oauth2/auth",
  "token_uri": "https://oauth2.googleapis.com/token",
  "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
  "client_x509_cert_url": "https://www.googleapis.com/robot/v1/metadata/x509/firebase-adminsdk%40project_id.iam.gserviceaccount.com",
  "universe_domain": "googleapis.com"
}
"""


class GcmTestCase(testutils.TestCase):
    maxDiff = None

    def config_setup(self, config: Dict[str, Any]) -> None:
        config["apps"]["com.example.gcm"] = {
            "type": "tests.test_gcm.TestGcmPushkin",
            "api_key": "kii",
            "api_version": "legacy",
        }
        config["apps"]["com.example.gcm.ios"] = {
            "type": "tests.test_gcm.TestGcmPushkin",
            "api_key": "kii",
            "fcm_options": {"content_available": True, "mutable_content": True},
        }
        self.service_account_file = tempfile.NamedTemporaryFile()
        self.service_account_file.write(FAKE_SERVICE_ACCOUNT_FILE)
        self.service_account_file.flush()
        config["apps"]["com.example.gcm.apiv1"] = {
            "type": "tests.test_gcm.TestGcmPushkin",
            "api_version": "v1",
            "project_id": "example_project",
            "service_account_file": self.service_account_file.name,
            "fcm_options": {
                "apns": {
                    "payload": {
                        "aps": {
                            "content-available": 1,
                            "mutable-content": 1,
                            "alert": "",
                        },
                    },
                },
            },
        }

        config["apps"]["com.example.gcm.apiv1.normal"] = {
            **config["apps"]["com.example.gcm.apiv1"],
            "counts_priority_normal": True,
            "sent_timestamp": True,
        }

    def tearDown(self) -> None:
        self.service_account_file.close()

    def get_test_pushkin(self, name: str) -> TestGcmPushkin:
        pushkin = self.sygnal.pushkins[name]
        assert isinstance(pushkin, TestGcmPushkin)
        return pushkin

    def test_expected(self) -> None:
        """
        Tests the expected case: a good response from GCM leads to a good
        response from Sygnal.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200, {"results": [{"message_id": "msg42", "registration_id": "spqr"}]}
        )

        # type safety: using ignore here due to mypy not handling monkeypatching,
        # see https://github.com/python/mypy/issues/2427
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501

        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        self.assertEqual(1, method.call_count)
        notification_req = method.call_args.args

        self.assertEqual(
            {
                "data": {
                    "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                    "type": "m.room.message",
                    "sender": "@exampleuser:matrix.org",
                    "room_name": "Mission Control",
                    "room_alias": "#exampleroom:matrix.org",
                    "sender_display_name": "Major Tom",
                    "content": {
                        "msgtype": "m.text",
                        "body": "I'm floating in a most peculiar way.",
                        "other": 1,
                    },
                    "room_id": "!slw48wfj34rtnrf:example.com",
                    "prio": "high",
                    "unread": 2,
                    "missed_calls": 1,
                },
                "priority": "high",
                "to": "spqr",
            },
            notification_req[2],
        )

        self.assertEqual(resp, {"rejected": []})

    def test_expected_api_v1(self) -> None:
        """
        Tests the expected case: a good response from GCM leads to a good
        response from Sygnal.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")

        # type safety: using ignore here due to mypy not handling monkeypatching,
        # see https://github.com/python/mypy/issues/2427
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501

        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(1, method.call_count)
        notification_req = method.call_args.args

        self.assertEqual(
            {
                "message": {
                    "data": {
                        "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                        "type": "m.room.message",
                        "sender": "@exampleuser:matrix.org",
                        "room_name": "Mission Control",
                        "room_alias": "#exampleroom:matrix.org",
                        "sender_display_name": "Major Tom",
                        "content_msgtype": "m.text",
                        "content_body": "I'm floating in a most peculiar way.",
                        "room_id": "!slw48wfj34rtnrf:example.com",
                        "prio": "high",
                        "unread": "2",
                        "missed_calls": "1",
                    },
                    "android": {
                        "priority": "high",
                        "notification": {
                            "title": "Mission Control",
                            "body": "I'm floating in a most peculiar way.",
                            "channel_id": "liza_push",
                            "sound": "default",
                            "notification_priority": "PRIORITY_HIGH",
                            "default_vibrate_timings": True,
                            "tag": "!slw48wfj34rtnrf:example.com",
                        },
                    },
                    "apns": {
                        "payload": {
                            "aps": {
                                "content-available": 1,
                                "mutable-content": 1,
                                "alert": "",
                            },
                        },
                    },
                    "token": "spqr",
                }
            },
            notification_req[2],
        )

        self.assertEqual(resp, {"rejected": []})
        assert notification_req[3] is not None
        self.assertEqual(
            notification_req[3].get("Authorization"), ["Bearer myaccesstoken"]
        )

    def test_low_prio_still_high_priority_fcm_api_v1(self) -> None:
        """
        Liza-specific: даже когда Synapse прислал prio=low (обычное сообщение в
        незашифрованном групповом чате), FCM-сообщение должно уходить с
        android.priority=high — иначе Android в Doze/фоне дропает data-пуш и
        уведомление не показывается. См. gcmpushkin: форс high.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        notif = self._make_dummy_notification([DEVICE_EXAMPLE_APIV1])
        notif["notification"]["prio"] = "low"
        resp = self._request(notif)

        self.assertEqual(1, method.call_count)
        message = method.call_args.args[2]["message"]
        # data.prio отражает исходный low (_build_data: low→"normal"), но
        # транспортный android.priority всё равно форсится в high.
        self.assertEqual(message["data"]["prio"], "normal")
        self.assertEqual(message["android"]["priority"], "high")
        self.assertEqual(resp, {"rejected": []})

    def test_android_notification_e2ee_fallback_api_v1(self) -> None:
        """
        LABA-1891: android.notification.body НИКОГДА не несёт секретный текст.
        Для зашифрованного события расшифрованного content.body нет → показываем
        обобщённое «Новое сообщение», title берём из room_name. Для
        незашифрованного — реальный текст. Баннер рисует система (Play Services)
        без пробуждения isolate — доходит в Doze/App-Standby.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        # Зашифрованное событие: content без плейн-body (m.room.encrypted).
        notif = self._make_dummy_notification([DEVICE_EXAMPLE_APIV1])
        notif["notification"]["type"] = "m.room.encrypted"
        notif["notification"]["content"] = {
            "algorithm": "m.megolm.v1.aes-sha2",
            "ciphertext": "AwgAEnABC...secret...",
        }
        self._request(notif)

        notification = method.call_args.args[2]["message"]["android"]["notification"]
        self.assertEqual(notification["body"], "Новое сообщение")
        self.assertEqual(notification["title"], "Mission Control")
        self.assertEqual(notification["channel_id"], "liza_push")
        self.assertEqual(notification["notification_priority"], "PRIORITY_HIGH")
        self.assertEqual(notification["tag"], "!slw48wfj34rtnrf:example.com")

        # Незашифрованное событие: реальный текст в баннере.
        method.reset_mock()
        self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))
        notification = method.call_args.args[2]["message"]["android"]["notification"]
        self.assertEqual(notification["body"], "I'm floating in a most peculiar way.")

    def test_no_android_notification_for_counts_only_api_v1(self) -> None:
        """
        LABA-1891: counts-only пуш (обновление бейджа после прочтения на другом
        устройстве — без event_id) НЕ должен нести android.notification, иначе
        система нарисует ложный баннер «Новое сообщение» на уже прочитанное.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501
        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        resp = self._request(
            self._make_dummy_notification_badge_only([DEVICE_EXAMPLE_APIV1])
        )

        self.assertEqual(1, method.call_count)
        android = method.call_args.args[2]["message"]["android"]
        self.assertNotIn("notification", android)
        self.assertEqual(android["priority"], "high")
        self.assertEqual(resp, {"rejected": []})

    def test_expected_with_default_payload(self) -> None:
        """
        Tests the expected case: a good response from GCM leads to a good
        response from Sygnal.
        """
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200, {"results": [{"message_id": "msg42", "registration_id": "spqr"}]}
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_WITH_DEFAULT_PAYLOAD])
        )

        self.assertEqual(resp, {"rejected": []})
        self.assertEqual(gcm.num_requests, 1)

    def test_expected_api_v1_with_default_payload(self) -> None:
        """
        Tests the expected case: a good response from GCM leads to a good
        response from Sygnal.
        """
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(
            200, {"results": [{"message_id": "msg42", "registration_id": "spqr"}]}
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_APIV1_WITH_DEFAULT_PAYLOAD])
        )

        self.assertEqual(resp, {"rejected": []})
        self.assertEqual(gcm.num_requests, 1)

    def test_misformed_default_payload_rejected(self) -> None:
        """
        Tests that a non-dict default_payload is rejected.
        """
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200, {"results": [{"message_id": "msg42", "registration_id": "badpayload"}]}
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_WITH_BAD_DEFAULT_PAYLOAD])
        )

        self.assertEqual(resp, {"rejected": ["badpayload"]})
        self.assertEqual(gcm.num_requests, 0)

    def test_rejected(self) -> None:
        """
        Tests the rejected case: a pushkey rejected to GCM leads to Sygnal
        informing the homeserver of the rejection.
        """
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200, {"results": [{"registration_id": "spqr", "error": "NotRegistered"}]}
        )

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE]))

        self.assertEqual(resp, {"rejected": ["spqr"]})
        self.assertEqual(gcm.num_requests, 1)

    def test_batching(self) -> None:
        """
        Tests that multiple GCM devices have their notification delivered to GCM
        together, instead of being delivered separately.
        """
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200,
            {
                "results": [
                    {"registration_id": "spqr", "message_id": "msg42"},
                    {"registration_id": "spqr2", "message_id": "msg42"},
                ]
            },
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE, DEVICE_EXAMPLE2])
        )

        self.assertEqual(resp, {"rejected": []})
        assert gcm.last_request_body is not None
        self.assertEqual(gcm.last_request_body["registration_ids"], ["spqr", "spqr2"])
        self.assertEqual(gcm.num_requests, 1)

    def test_batching_api_v1(self) -> None:
        """
        Tests that multiple GCM devices have their notification delivered to GCM
        separately, instead of being delivered together.
        """
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(
            200,
            {
                "results": [
                    {"registration_id": "spqr", "message_id": "msg42"},
                    {"registration_id": "spqr2", "message_id": "msg42"},
                ]
            },
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE_APIV1, DEVICE_EXAMPLE2_APIV1])
        )

        self.assertEqual(resp, {"rejected": []})
        assert gcm.last_request_body is not None
        self.assertEqual(gcm.last_request_body["message"]["token"], "spqr2")
        self.assertEqual(gcm.num_requests, 2)

    def test_batching_individual_failure(self) -> None:
        """
        Tests that multiple GCM devices have their notification delivered to GCM
        together, instead of being delivered separately,
        and that if only one device ID is rejected, then only that device is
        reported to the homeserver as rejected.
        """
        gcm = self.get_test_pushkin("com.example.gcm")
        gcm.preload_with_response(
            200,
            {
                "results": [
                    {"registration_id": "spqr", "message_id": "msg42"},
                    {"registration_id": "spqr2", "error": "NotRegistered"},
                ]
            },
        )

        resp = self._request(
            self._make_dummy_notification([DEVICE_EXAMPLE, DEVICE_EXAMPLE2])
        )

        self.assertEqual(resp, {"rejected": ["spqr2"]})
        assert gcm.last_request_body is not None
        self.assertEqual(gcm.last_request_body["registration_ids"], ["spqr", "spqr2"])
        self.assertEqual(gcm.num_requests, 1)

    def test_api_v1_retry(self) -> None:
        """
        Tests that a Firebase response of 502 results in Sygnal retrying.
        Also checks the notification message to ensure it is sane after retrying
        multiple times.
        """
        self.gcm_pushkin_snotif = MagicMock()

        gcm = self.get_test_pushkin("com.example.gcm.apiv1")

        # type safety: using ignore here due to mypy not handling monkeypatching,
        # see https://github.com/python/mypy/issues/2427
        gcm._request_dispatch = self.gcm_pushkin_snotif  # type: ignore[assignment] # noqa: E501

        async def side_effect(*_args: Any, **_kwargs: Any) -> None:
            raise TemporaryNotificationDispatchException(
                "GCM server error, hopefully temporary.", custom_retry_delay=None
            )

        method = self.gcm_pushkin_snotif
        method.side_effect = side_effect

        _resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        # Р4 спеки 2026-11-12: две попытки, бюджет FCM ≤ 9 с.
        self.assertEqual(2, method.call_count)
        notification_req = method.call_args.args

        self.assertEqual(
            {
                "message": {
                    "data": {
                        "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                        "type": "m.room.message",
                        "sender": "@exampleuser:matrix.org",
                        "room_name": "Mission Control",
                        "room_alias": "#exampleroom:matrix.org",
                        "sender_display_name": "Major Tom",
                        "content_msgtype": "m.text",
                        "content_body": "I'm floating in a most peculiar way.",
                        "room_id": "!slw48wfj34rtnrf:example.com",
                        "prio": "high",
                        "unread": "2",
                        "missed_calls": "1",
                    },
                    "android": {
                        "priority": "high",
                        "notification": {
                            "title": "Mission Control",
                            "body": "I'm floating in a most peculiar way.",
                            "channel_id": "liza_push",
                            "sound": "default",
                            "notification_priority": "PRIORITY_HIGH",
                            "default_vibrate_timings": True,
                            "tag": "!slw48wfj34rtnrf:example.com",
                        },
                    },
                    "apns": {
                        "payload": {
                            "aps": {
                                "content-available": 1,
                                "mutable-content": 1,
                                "alert": "",
                            },
                        },
                    },
                    "token": "spqr",
                }
            },
            notification_req[2],
        )

    def test_fcm_options(self) -> None:
        """
        Tests that the config option `fcm_options` allows setting a base layer
        of options to pass to FCM, for example ones that would be needed for iOS.
        """
        gcm = self.get_test_pushkin("com.example.gcm.ios")
        gcm.preload_with_response(
            200, {"results": [{"registration_id": "spqr_new", "message_id": "msg42"}]}
        )

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_IOS]))

        self.assertEqual(resp, {"rejected": []})
        assert gcm.last_request_body is not None
        self.assertEqual(gcm.last_request_body["mutable_content"], True)
        self.assertEqual(gcm.last_request_body["content_available"], True)

    def test_api_v1_large_fields(self) -> None:
        """
        Tests the gcm pushkin truncates unusually large fields. Includes large
        fields both at the top level of `data`, and nested within `content`.
        """
        self.apns_pushkin_snotif = MagicMock()
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(
            200, {"results": [{"message_id": "msg42", "registration_id": "spqr"}]}
        )

        # type safety: using ignore here due to mypy not handling monkeypatching,
        # see https://github.com/python/mypy/issues/2427
        gcm._request_dispatch = self.apns_pushkin_snotif  # type: ignore[assignment] # noqa: E501

        method = self.apns_pushkin_snotif
        method.side_effect = testutils.make_async_magic_mock(([], []))

        resp = self._request(
            self._make_dummy_notification_large_fields([DEVICE_EXAMPLE_APIV1])
        )

        self.assertEqual(1, method.call_count)
        notification_req = method.call_args.args

        # The values for `room_name` & `content_other` should be truncated from the original.
        expected = {
            "message": {
                "data": {
                    "event_id": "$qTOWWTEL48yPm3uT-gdNhFcoHxfKbZuqRVnnWWSkGBs",
                    "type": "m.room.message",
                    "sender": "@exampleuser:matrix.org",
                    "room_name": "xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooox…",
                    "room_alias": "#exampleroom:matrix.org",
                    "sender_display_name": "Major Tom",
                    "content_msgtype": "m.text",
                    "content_body": "I'm floating in a most peculiar way.",
                    "content_other": "xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxoooooooooo\
xxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxxooooooooooxxxxxxxxxx\
ooooooooooxxxxxxxxxx🦉oooooo£xxxxxxxx☻oo🦉…",
                    "room_id": "!slw48wfj34rtnrf:example.com",
                    "prio": "high",
                    "unread": "2",
                    "missed_calls": "1",
                },
                "android": {
                    "priority": "high",
                    "notification": {
                        # title == усечённый room_name (тот же truncate_str);
                        # подставляем из data ниже, чтобы не дублировать
                        # огромный литерал в ожидании.
                        "body": "I'm floating in a most peculiar way.",
                        "channel_id": "liza_push",
                        "sound": "default",
                        "notification_priority": "PRIORITY_HIGH",
                        "default_vibrate_timings": True,
                        "tag": "!slw48wfj34rtnrf:example.com",
                    },
                },
                "apns": {
                    "payload": {
                        "aps": {
                            "content-available": 1,
                            "mutable-content": 1,
                            "alert": "",
                        },
                    },
                },
                "token": "spqr",
            }
        }
        expected["message"]["android"]["notification"]["title"] = expected["message"][
            "data"
        ]["room_name"]
        self.assertEqual(expected, notification_req[2])

        self.assertEqual(resp, {"rejected": []})
        assert notification_req[3] is not None
        self.assertEqual(
            notification_req[3].get("Authorization"), ["Bearer myaccesstoken"]
        )


DEVICE_APIV1_LIZA = {
    "app_id": "com.example.gcm.apiv1",
    "pushkey": "spqr",
    "pushkey_ts": 42,
    "data": {"default_payload": {"client_name": "acc1"}},
}
DEVICE_APIV1_NORMAL = {
    "app_id": "com.example.gcm.apiv1.normal",
    "pushkey": "spqr",
    "pushkey_ts": 42,
}


class GcmBudgetTestCase(testutils.TestCase):
    """ledger:RL-sygnal-egress-deadlines — бюджет FCM ≤ 9 с (Р4 спеки 2026-11-12)."""

    config_setup = GcmTestCase.config_setup
    tearDown = GcmTestCase.tearDown
    get_test_pushkin = GcmTestCase.get_test_pushkin


    def _fail_with(self, exc: Exception) -> Tuple[MagicMock, List[float]]:
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        calls: List[float] = []

        async def side_effect(*_args: Any, **_kwargs: Any) -> None:
            calls.append(self.reactor.seconds())
            raise exc

        method = MagicMock(side_effect=side_effect)
        gcm._request_dispatch = method  # type: ignore[assignment]
        return method, calls

    def test_two_tries_short_pause_then_503(self) -> None:
        """AC:RL-sygnal-egress-deadlines/11 — FCM: 2 попытки, пауза 0,5 с, итог 503 быстрее 9 с."""
        method, calls = self._fail_with(
            TemporaryNotificationDispatchException("temp", custom_retry_delay=None)
        )
        start = self.reactor.seconds()

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(2, method.call_count)
        self.assertEqual(503, resp)
        # Тестовый reactor идёт шагом 1 с: пауза 0,5 с видна как ≤ 1 с.
        self.assertLessEqual(calls[1] - calls[0], 1.0)
        self.assertLess(self.reactor.seconds() - start, 9)

    def test_retry_after_longer_than_budget_fails_at_once(self) -> None:
        """AC:RL-sygnal-egress-deadlines/12 — Retry-After 30 с → одна попытка, 503."""
        method, _ = self._fail_with(
            TemporaryNotificationDispatchException("temp", custom_retry_delay=30)
        )
        start = self.reactor.seconds()

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(1, method.call_count)
        self.assertEqual(503, resp)
        self.assertLess(self.reactor.seconds() - start, 2)

    def test_retry_after_within_budget_is_honoured(self) -> None:
        """AC:RL-sygnal-egress-deadlines/13 — Retry-After 2 с умещается в бюджет и соблюдается."""
        method, calls = self._fail_with(
            TemporaryNotificationDispatchException("temp", custom_retry_delay=2)
        )

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(2, method.call_count)
        self.assertEqual(503, resp)
        self.assertGreaterEqual(calls[1] - calls[0], 2)

    def test_quota_exceeded_fails_at_once(self) -> None:
        """AC:RL-sygnal-egress-deadlines/12 — квота (пауза 60 с) → одна попытка, 503."""
        method, _ = self._fail_with(
            NotificationQuotaDispatchException("quota", custom_retry_delay=None)
        )

        resp = self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(1, method.call_count)
        self.assertEqual(503, resp)

    def test_request_is_cut_after_four_seconds(self) -> None:
        """AC:RL-sygnal-egress-deadlines/14 — запрос к FCM обрывается через 4 с, слот семафора возвращается."""
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        hung: "Deferred[Any]" = Deferred()
        gcm.http_agent = MagicMock()
        gcm.http_agent.request.return_value = hung

        d = ensureDeferred(GcmPushkin._perform_http_request(gcm, {}, {}))
        failures: List[Any] = []
        d.addErrback(failures.append)

        self.reactor.advance(3.9)
        self.assertEqual([], failures)
        self.reactor.advance(0.2)
        self.assertEqual(1, len(failures))
        self.assertIsInstance(
            failures[0].value, TemporaryNotificationDispatchException
        )
        self.assertEqual(gcm.max_connections, gcm.connection_semaphore.tokens)


class GcmPriorityTestCase(testutils.TestCase):
    """ledger:RL-fcm-counts-priority-normal — Р1/Ф0.5, AC-8."""

    config_setup = GcmTestCase.config_setup
    tearDown = GcmTestCase.tearDown
    get_test_pushkin = GcmTestCase.get_test_pushkin


    def _capture(self, app_id: str) -> MagicMock:
        method = MagicMock(side_effect=testutils.make_async_magic_mock(([], [])))
        self.get_test_pushkin(app_id)._request_dispatch = method  # type: ignore
        return method

    def test_counts_only_normal_under_flag(self) -> None:
        """AC:RL-fcm-counts-priority-normal/1"""
        method = self._capture("com.example.gcm.apiv1.normal")
        self._request(self._make_dummy_notification_badge_only([DEVICE_APIV1_NORMAL]))
        android = method.call_args.args[2]["message"]["android"]
        self.assertEqual("normal", android["priority"])

    def test_visible_push_stays_high_under_flag(self) -> None:
        """AC:RL-fcm-counts-priority-normal/2"""
        method = self._capture("com.example.gcm.apiv1.normal")
        self._request(self._make_dummy_notification([DEVICE_APIV1_NORMAL]))
        android = method.call_args.args[2]["message"]["android"]
        self.assertEqual("high", android["priority"])

    def test_counts_only_high_without_flag(self) -> None:
        """AC:RL-fcm-counts-priority-normal/3 — флаг выключен, всё как было."""
        method = self._capture("com.example.gcm.apiv1")
        self._request(self._make_dummy_notification_badge_only([DEVICE_EXAMPLE_APIV1]))
        android = method.call_args.args[2]["message"]["android"]
        self.assertEqual("high", android["priority"])


    def test_sent_timestamp_in_event_push_under_flag(self) -> None:
        """AC:RL-push-test-sender-and-acks/8 — liza_sent_ms строкой (FCM v1 data —
        только строки) у пуша с событием; у счётчика и без флага — нет.
        ledger:RL-push-test-sender-and-acks"""
        self.reactor.advance(1_700_000_000)
        method = self._capture("com.example.gcm.apiv1.normal")
        self._request(self._make_dummy_notification([DEVICE_APIV1_NORMAL]))
        data = method.call_args.args[2]["message"]["data"]
        self.assertEqual(str(int(self.reactor.seconds() * 1000)), data["liza_sent_ms"])
        self._request(self._make_dummy_notification_badge_only([DEVICE_APIV1_NORMAL]))
        self.assertNotIn("liza_sent_ms", method.call_args.args[2]["message"]["data"])
        off = self._capture("com.example.gcm.apiv1")
        self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))
        self.assertNotIn("liza_sent_ms", off.call_args.args[2]["message"]["data"])


class GcmSentCacheTestCase(testutils.TestCase):
    """ledger:RL-push-sent-dedupe — повтор Synapse после 504 не шлём второй раз."""

    config_setup = GcmTestCase.config_setup
    tearDown = GcmTestCase.tearDown
    get_test_pushkin = GcmTestCase.get_test_pushkin


    def test_repeat_of_accepted_event_is_not_sent(self) -> None:
        """AC:RL-push-sent-dedupe/1 — повтор того же события в 10 минут не уходит второй раз."""
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(200, {"name": "projects/x/messages/1"})

        first = self._request(self._make_dummy_notification([DEVICE_APIV1_LIZA]))
        second = self._request(self._make_dummy_notification([DEVICE_APIV1_LIZA]))

        self.assertEqual({"rejected": []}, first)
        self.assertEqual({"rejected": []}, second)
        self.assertEqual(1, gcm.num_requests)

    def test_without_client_name_every_request_is_sent(self) -> None:
        """AC:RL-push-sent-dedupe/2 — без client_name ключа нет, каждый запрос уходит."""
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(200, {"name": "projects/x/messages/1"})

        self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))
        self._request(self._make_dummy_notification([DEVICE_EXAMPLE_APIV1]))

        self.assertEqual(2, gcm.num_requests)

    def test_counts_only_is_never_deduplicated(self) -> None:
        """AC:RL-push-sent-dedupe/3 — пуш «только счётчик» не запоминается."""
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(200, {"name": "projects/x/messages/1"})

        notif = self._make_dummy_notification_badge_only([DEVICE_APIV1_LIZA])
        self._request(notif)
        self._request(notif)

        self.assertEqual(2, gcm.num_requests)

    def test_cache_expires_after_ten_minutes(self) -> None:
        """AC:RL-push-sent-dedupe/4 — через 10 минут память о событии истекает."""
        gcm = self.get_test_pushkin("com.example.gcm.apiv1")
        gcm.preload_with_response(200, {"name": "projects/x/messages/1"})

        self._request(self._make_dummy_notification([DEVICE_APIV1_LIZA]))
        self.reactor.advance(601)
        self._request(self._make_dummy_notification([DEVICE_APIV1_LIZA]))

        self.assertEqual(2, gcm.num_requests)
