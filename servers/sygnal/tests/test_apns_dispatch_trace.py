"""Сквозная непрозрачная метка попыток реального APNs dispatcher.

ledger:RL-push-dispatch-trace
"""

import asyncio
import copy
import json
import unittest
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from uuid import UUID

from aioapns.common import NotificationResult

from sygnal.apnspushkin import ApnsPushkin, ApnsSendTimeout
from sygnal.notifications import NotificationContext

from tests import test_push_outcomes as helpers


class DispatchTraceTest(unittest.IsolatedAsyncioTestCase):
    def run(self, result=None):
        old = asyncio._get_running_loop()
        asyncio._set_running_loop(None)
        try:
            return super().run(result)
        finally:
            asyncio._set_running_loop(old)

    async def dispatch(self, pushkin, notification):
        context = NotificationContext(
            "test-trace", pushkin.sygnal.tracer.start_span("test"), 0
        )
        with patch("sygnal.apnspushkin.twisted_sleep", new_callable=AsyncMock):
            with self.assertLogs("sygnal", level="INFO") as logs:
                result = await pushkin._dispatch_notification_unlimited(
                    notification, notification.devices[0], context
                )
        rows = [
            json.loads(row.getMessage().split("PUSH_DISPATCH_TRACE ", 1)[1])
            for row in logs.records
            if "PUSH_DISPATCH_TRACE " in row.getMessage()
        ]
        text = "\n".join(logs.output)
        for secret in (helpers.TOKEN, helpers.EVENT, helpers.ROOM, helpers.BODY):
            self.assertNotIn(secret, text)
        return result, rows

    # AC:RL-push-dispatch-trace/1
    async def test_retries_keep_dispatch_id_and_distinct_attempts(self):
        helper = helpers.ProviderOutcomeTest()
        pushkin = helper.pushkin(ApnsPushkin)
        pushkin._send_notification = AsyncMock(
            side_effect=[
                NotificationResult("id", "503"),
                NotificationResult("id", "200"),
            ]
        )
        result, rows = await self.dispatch(pushkin, helper.notification())
        self.assertEqual(result, [])
        requests = [call.args[0] for call in pushkin._send_notification.call_args_list]
        self.assertEqual(
            [row["phase"] for row in rows],
            ["prepared", "provider_response", "prepared", "provider_response"],
        )
        self.assertEqual([row["status"] for row in rows], [None, 503, None, 200])
        trace = requests[0].message["liza_dispatch_id"]
        self.assertEqual(str(UUID(trace)), trace)
        self.assertEqual(requests[1].message["liza_dispatch_id"], trace)
        self.assertEqual([r.message["liza_dispatch_attempt"] for r in requests], [0, 1])
        self.assertEqual([row["dispatch_id"] for row in rows], [trace] * 4)
        self.assertEqual([row["attempt"] for row in rows], [0, 0, 1, 1])
        self.assertTrue(all(row["attempt_scope"] == "sygnal_dispatch" for row in rows))
        self.assertTrue(all(row["payload_trace"] == "attached" for row in rows))
        # Другой dispatch того же Matrix-события — новая метка, отдельно от apns-id.
        pushkin._send_notification = AsyncMock(
            return_value=NotificationResult("id", "200")
        )
        await self.dispatch(pushkin, helper.notification())
        self.assertNotEqual(
            pushkin._send_notification.call_args.args[0].message["liza_dispatch_id"],
            trace,
        )

    # AC:RL-push-dispatch-trace/2
    async def test_full_payload_is_unchanged_when_diagnostics_do_not_fit(self):
        helper = helpers.ProviderOutcomeTest()
        pushkin = helper.pushkin(ApnsPushkin)
        original = {"aps": {"alert": "Ж🙂" * 660}, "event_id": helpers.EVENT}
        # Ставим предел ровно по исходному payload: диагностике нельзя резать текст.
        from sygnal import apnstruncate

        pushkin.MAX_JSON_BODY_SIZE = len(apnstruncate.json_encode(original))
        saved = copy.deepcopy(original)
        pushkin._get_payload_event_id_only = lambda *args: copy.deepcopy(original)
        pushkin._send_notification = AsyncMock(
            return_value=NotificationResult("id", "200")
        )
        _, rows = await self.dispatch(pushkin, helper.notification())
        request = pushkin._send_notification.call_args.args[0]
        self.assertEqual(request.message, saved)
        self.assertEqual(rows[0]["payload_trace"], "omitted_size_limit")
        self.assertLessEqual(
            len(apnstruncate.json_encode(request.message)), pushkin.MAX_JSON_BODY_SIZE
        )

    # AC:RL-push-dispatch-trace/3
    async def test_clearing_has_no_incident_trace_payload(self):
        helper = helpers.ProviderOutcomeTest()
        pushkin = helper.pushkin(ApnsPushkin)
        pushkin._send_notification = AsyncMock(
            return_value=NotificationResult("id", "200")
        )
        _, rows = await self.dispatch(pushkin, helper.notification(clearing=True))
        self.assertEqual(rows, [])
        self.assertNotIn(
            "liza_dispatch_id", pushkin._send_notification.call_args.args[0].message
        )

    # AC:RL-push-dispatch-trace/1
    async def test_timeout_is_correlated_and_stable_apns_id_is_separate(self):
        helper = helpers.ProviderOutcomeTest()
        pushkin = helper.pushkin(ApnsPushkin)
        pushkin.stable_apns_id = True
        pushkin.apns_client = SimpleNamespace(pool=SimpleNamespace(connections=[]))
        n = helper.notification()
        n.devices[0].data["default_payload"]["client_name"] = "Liza test"
        pushkin._send_notification = AsyncMock(
            side_effect=[ApnsSendTimeout(), NotificationResult("id", "200")]
        )
        _, rows = await self.dispatch(pushkin, n)
        self.assertEqual(
            [row["phase"] for row in rows],
            ["prepared", "timeout", "prepared", "provider_response"],
        )
        requests = [call.args[0] for call in pushkin._send_notification.call_args_list]
        first = requests[0]
        self.assertEqual(first.notification_id, requests[1].notification_id)
        pushkin._send_notification = AsyncMock(
            return_value=NotificationResult("id", "200")
        )
        await self.dispatch(pushkin, n)
        next_request = pushkin._send_notification.call_args.args[0]
        self.assertEqual(first.notification_id, next_request.notification_id)
        self.assertNotEqual(
            first.message["liza_dispatch_id"], next_request.message["liza_dispatch_id"]
        )

    # AC:RL-push-dispatch-trace/3
    async def test_counts_only_without_clearing_capability_has_no_trace(self):
        helper = helpers.ProviderOutcomeTest()
        pushkin = helper.pushkin(ApnsPushkin)
        n = helper.notification(clearing=True)
        n.devices[0].data["default_payload"] = {"aps": {"badge": 2}}
        pushkin._send_notification = AsyncMock(
            return_value=NotificationResult("id", "200")
        )
        _, rows = await self.dispatch(pushkin, n)
        self.assertEqual(rows, [])
        self.assertNotIn(
            "liza_dispatch_id", pushkin._send_notification.call_args.args[0].message
        )
