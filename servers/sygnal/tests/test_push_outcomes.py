"""ledger:RL-push-provider-outcomes — реальные dispatcher/response ветви."""

import asyncio
import base64
import hashlib
import json
import logging
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import aioapns
import opentracing
from aioapns.common import NotificationResult, PushType
from twisted.web.http_headers import Headers

from sygnal.apnspushkin import ApnsPushkin
from sygnal.exceptions import (
    NotificationDispatchException,
    TemporaryNotificationDispatchException,
)
from sygnal.gcmpushkin import APIVersion, GcmPushkin
from sygnal.notifications import Notification, NotificationContext, Pushkin

TOKEN = base64.b64encode(b"PRIVATE_PROVIDER_TOKEN_POISON_0123456789").decode()
EVENT = "$PRIVATE_EVENT_POISON"
ROOM = "!PRIVATE_ROOM_POISON:example.test"
BODY = "PRIVATE_RESPONSE_BODY_POISON"


class ProviderOutcomeTest(unittest.IsolatedAsyncioTestCase):
    def run(self, result=None):
        # Старые Twisted tests оставляют виртуальный loop как running. На время
        # нашего asyncio runner изолируем его и возвращаем соседним тестам.
        previous_loop = asyncio._get_running_loop()
        asyncio._set_running_loop(None)
        try:
            return super().run(result)
        finally:
            asyncio._set_running_loop(previous_loop)

    def notification(self, *, clearing=False, keys=None):
        return Notification(
            {
                "event_id": None if clearing else EVENT,
                "room_id": None if clearing else ROOM,
                "counts": {"unread": 2},
                "devices": [
                    {
                        "app_id": "test.app",
                        "pushkey": key,
                        "data": {
                            "default_payload": {
                                "liza_clear_v": 1,
                                "aps": {"sound": "ding"},
                            },
                        },
                    }
                    for key in (keys or [TOKEN])
                ],
            }
        )

    def pushkin(self, cls, version=None):
        pushkin = object.__new__(cls)
        tracer = opentracing.Tracer()
        Pushkin.__init__(
            pushkin, "test.app", SimpleNamespace(tracer=tracer, reactor=None), {}
        )
        if cls is ApnsPushkin:
            pushkin.push_type = PushType.ALERT
        else:
            pushkin.api_version = version
            pushkin.base_request_body = {}
            pushkin._get_auth_header = AsyncMock(return_value="private auth")
        return pushkin

    async def dispatch(self, pushkin, n):
        context = NotificationContext(
            "test-request", pushkin.sygnal.tracer.start_span("test"), 0
        )
        with self.assertLogs("sygnal", level="DEBUG") as captured:
            try:
                result = await pushkin._dispatch_notification_unlimited(
                    n, n.devices[0], context
                )
            except NotificationDispatchException:
                # Как внешний HTTP-handler: traceback тоже не должен раскрывать ответ.
                logging.getLogger("sygnal.test").exception("Dispatch failed")
                result = None
        text = "\n".join(captured.output)
        for secret in (TOKEN, base64.b64decode(TOKEN).hex(), EVENT, ROOM, BODY):
            self.assertNotIn(secret, text)
        outcomes = [
            json.loads(record.getMessage().split("PUSH_OUTCOME ", 1)[1])
            for record in captured.records
            if "PUSH_OUTCOME " in record.getMessage()
        ]
        self.assertTrue(outcomes)
        for outcome in outcomes:
            self.assertEqual(
                set(outcome),
                {
                    "provider",
                    "app_id",
                    "pushkey_hash",
                    "event_hash",
                    "attempt",
                    "outcome",
                    "status",
                    "reason",
                    "clearing",
                    "hash_version",
                },
            )
            self.assertEqual(outcome["hash_version"], "sha256-128")
            self.assertEqual(outcome["app_id"], "test.app")
        return result, outcomes

    async def test_apns_accept_reject_error_and_original_fingerprint(self):
        """AC:RL-push-provider-outcomes/1 AC:RL-push-provider-outcomes/5"""
        for code, reason, expected in [
            (200, None, "accepted"),
            (400, "BadDeviceToken", "rejected"),
            (400, "DeviceTokenNotForTopic", "rejected"),
            (400, "TopicDisallowed", "rejected"),
            (410, "Unregistered", "rejected"),
            (403, BODY + TOKEN, "error"),
            (BODY + TOKEN, None, "error"),
        ]:
            with self.subTest(code=code, expected=expected):
                pushkin = self.pushkin(ApnsPushkin)
                pushkin._send_notification = AsyncMock(
                    return_value=NotificationResult("id", str(code), reason)
                )
                result, outcomes = await self.dispatch(pushkin, self.notification())
                self.assertEqual(
                    [x["outcome"] for x in outcomes], ["attempt", expected]
                )
                self.assertEqual(
                    outcomes[-1]["status"], code if isinstance(code, int) else None
                )
                self.assertEqual(outcomes[-1]["attempt"], 0)
                self.assertEqual(
                    outcomes[-1]["pushkey_hash"],
                    hashlib.sha256(TOKEN.encode()).hexdigest()[:32],
                )
                self.assertEqual(
                    outcomes[-1]["event_hash"],
                    hashlib.sha256(EVENT.encode()).hexdigest()[:32],
                )
                self.assertEqual(
                    result,
                    (
                        [TOKEN]
                        if expected == "rejected"
                        else [] if expected == "accepted" else None
                    ),
                )
                request = pushkin._send_notification.call_args.args[0]
                self.assertEqual(request.device_token, base64.b64decode(TOKEN).hex())
                self.assertEqual(request.message["event_id"], EVENT)

    async def test_apns_retry_connection_server_error_and_clearing(self):
        """AC:RL-push-provider-outcomes/2 AC:RL-push-provider-outcomes/5"""
        for failure in [
            NotificationResult("id", "503", BODY + TOKEN),
            aioapns.ConnectionError(BODY + TOKEN),
        ]:
            pushkin = self.pushkin(ApnsPushkin)
            pushkin._send_notification = AsyncMock(
                side_effect=[failure, NotificationResult("id", "200")]
            )
            with patch(
                "sygnal.apnspushkin.twisted_sleep", new_callable=AsyncMock
            ) as sleep:
                result, outcomes = await self.dispatch(
                    pushkin, self.notification(clearing=True)
                )
            self.assertEqual(result, [])
            self.assertEqual(
                [x["outcome"] for x in outcomes],
                ["attempt", "retryable", "attempt", "accepted"],
            )
            self.assertEqual([x["attempt"] for x in outcomes], [0, 0, 1, 1])
            self.assertTrue(
                all(x["clearing"] and x["event_hash"] is None for x in outcomes)
            )
            self.assertEqual(sleep.call_args.args[0], 10)
            request = pushkin._send_notification.call_args.args[0]
            self.assertEqual(request.push_type, PushType.BACKGROUND)
            self.assertEqual(request.message["aps"], {"content-available": 1})

    async def test_fcm_legacy_and_v1_statuses(self):
        """AC:RL-push-provider-outcomes/3 AC:RL-push-provider-outcomes/5"""
        for version in (APIVersion.Legacy, APIVersion.V1):
            for code, expected in [
                (200, "accepted"),
                (404, "rejected"),
                (400, "error"),
                (401, "error"),
                (403, "error"),
            ]:
                with self.subTest(version=version, code=code):
                    pushkin = self.pushkin(GcmPushkin, version)
                    payload = {
                        "results": [{"message_id": "id"}],
                        "private": BODY + TOKEN,
                    }
                    pushkin._perform_http_request = AsyncMock(
                        return_value=(SimpleNamespace(code=code), json.dumps(payload))
                    )
                    result, outcomes = await self.dispatch(pushkin, self.notification())
                    self.assertEqual(
                        [x["outcome"] for x in outcomes], ["attempt", expected]
                    )
                    self.assertEqual(
                        result,
                        (
                            [TOKEN]
                            if expected == "rejected"
                            else [] if expected == "accepted" else None
                        ),
                    )
                    self.assertEqual(outcomes[-1]["status"], code)
                    self.assertEqual(
                        outcomes[-1]["pushkey_hash"],
                        hashlib.sha256(TOKEN.encode()).hexdigest()[:32],
                    )
                    body = pushkin._perform_http_request.call_args.args[0]
                    data = body if version is APIVersion.Legacy else body["message"]
                    self.assertEqual(data["data"]["event_id"], EVENT)

    async def test_fcm_retry_server_quota_connection(self):
        """AC:RL-push-provider-outcomes/4 AC:RL-push-provider-outcomes/5"""
        cases = [
            (APIVersion.Legacy, 503),
            (APIVersion.V1, 503),
            (APIVersion.V1, 429),
            (APIVersion.Legacy, None),
            (APIVersion.V1, None),
        ]
        for version, code in cases:
            with self.subTest(version=version, code=code):
                pushkin = self.pushkin(GcmPushkin, version)
                first = (
                    (
                        SimpleNamespace(
                            code=code, headers=Headers({b"retry-after": [b"7"]})
                        ),
                        BODY + TOKEN,
                    )
                    if code
                    else TemporaryNotificationDispatchException(BODY + TOKEN)
                )
                pushkin._perform_http_request = AsyncMock(
                    side_effect=[
                        first,
                        (
                            SimpleNamespace(code=200),
                            '{"results":[{"message_id":"id"}]}',
                        ),
                    ]
                )
                with patch(
                    "sygnal.gcmpushkin.twisted_sleep", new_callable=AsyncMock
                ) as sleep:
                    result, outcomes = await self.dispatch(pushkin, self.notification())
                self.assertEqual(result, [])
                self.assertEqual(
                    [x["outcome"] for x in outcomes],
                    ["attempt", "retryable", "attempt", "accepted"],
                )
                self.assertEqual([x["attempt"] for x in outcomes], [0, 0, 1, 1])
                self.assertEqual(sleep.call_args.args[0], 7 if code else 10)

    async def test_legacy_per_device_outcomes_and_malformed_response(self):
        """AC:RL-push-provider-outcomes/3 AC:RL-push-provider-outcomes/4 AC:RL-push-provider-outcomes/5"""
        pushkin = self.pushkin(GcmPushkin, APIVersion.Legacy)
        keys = [TOKEN, "second-key", "third-key", "fourth-key"]
        payload = {
            "results": [
                {"message_id": "id"},
                {"error": "NotRegistered"},
                {"error": "MessageTooBig"},
                {"error": BODY + TOKEN},
            ]
        }
        pushkin._perform_http_request = AsyncMock(
            side_effect=[
                (SimpleNamespace(code=200), json.dumps(payload)),
                (SimpleNamespace(code=200), '{"results":[{"message_id":"id"}]}'),
            ]
        )
        result, outcomes = await self.dispatch(pushkin, self.notification(keys=keys))
        self.assertEqual(result, ["second-key"])
        terminal = [x["outcome"] for x in outcomes if x["outcome"] != "attempt"]
        self.assertEqual(
            terminal, ["accepted", "rejected", "error", "retryable", "accepted"]
        )
        self.assertEqual(pushkin._perform_http_request.call_count, 2)
        for payload in [
            BODY + TOKEN,
            json.dumps({"private": BODY + TOKEN}),
            '{"results":[]}',
            '{"results":[{}]}',
            '{"results":["missing-result"]}',
        ]:
            pushkin._perform_http_request = AsyncMock(
                return_value=(SimpleNamespace(code=200), payload)
            )
            _, outcomes = await self.dispatch(pushkin, self.notification())
            self.assertEqual(outcomes[-1]["outcome"], "error")
            self.assertNotIn("accepted", [x["outcome"] for x in outcomes])

    async def test_retry_exhaustion_keeps_return_contract(self):
        """AC:RL-push-provider-outcomes/2 AC:RL-push-provider-outcomes/4"""
        for cls in (ApnsPushkin, GcmPushkin):
            pushkin = self.pushkin(cls, APIVersion.V1)
            if cls is ApnsPushkin:
                pushkin._send_notification = AsyncMock(
                    return_value=NotificationResult("id", "503", BODY)
                )
                target = "sygnal.apnspushkin.twisted_sleep"
            else:
                pushkin._perform_http_request = AsyncMock(
                    return_value=(SimpleNamespace(code=503, headers=Headers()), BODY)
                )
                target = "sygnal.gcmpushkin.twisted_sleep"
            with patch(target, new_callable=AsyncMock):
                result, outcomes = await self.dispatch(pushkin, self.notification())
            self.assertEqual(result, None if cls is ApnsPushkin else [])
            self.assertEqual(outcomes[-1]["reason"], "retry_exhausted")
            self.assertEqual(
                [x["attempt"] for x in outcomes if x["outcome"] == "attempt"], [0, 1, 2]
            )


if __name__ == "__main__":
    unittest.main()
