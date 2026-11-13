"""ledger:RL-sygnal-egress-deadlines — APNs-dispatch укладывается в таймаут Envoy.

Заявка 11.11.2026: второй пуш приходил через минуты. В k8s egress молча терял
SYN, aioapns ждал connect без таймаута под локом пула, Envoy рвал запрос Synapse
на 15 с → 504 → backoff пушера. Тесты гоняют НАСТОЯЩИЙ пул aioapns и настоящий
ApnsPushkin._dispatch_notification_unlimited; подменяется только сеть.
"""

import asyncio
import inspect
import time
import unittest
from collections import OrderedDict
from functools import partial
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import opentracing
from aioapns.common import NotificationResult, PushType
from aioapns.connection import APNsBaseConnectionPool
from aioapns.exceptions import MaxAttemptsExceeded

from sygnal._sent_cache import SentCache
from sygnal.apnspushkin import ApnsPushkin, ApnsSendTimeout, ConnectDeadlineLoop
from sygnal.exceptions import (
    NotificationDispatchException,
    TemporaryNotificationDispatchException,
)
from sygnal.helper.proxy.proxy_asyncio import ProxyingEventLoopWrapper
from sygnal.notifications import Notification, NotificationContext, Pushkin

TOKEN = "dGVzdC10b2tlbi0wMTIzNDU2Nzg5"
SILENT_IP = "203.0.113.7"  # TEST-NET-3: в логах его быть не должно


class FakeConnection:
    """Минимум протокола aioapns: requests, is_busy, close→connection_lost."""

    def __init__(self, respond: bool):
        self.respond = respond
        self.requests: dict = {}
        self.closed = False
        self.is_busy = False
        self.on_close = None

    async def send_notification(self, request):
        if self.respond:
            return NotificationResult(request.notification_id, "200")
        future = asyncio.get_running_loop().create_future()
        self.requests[request.notification_id] = future
        return await future

    def close(self):
        # Как APNsBaseClientProtocol.connection_lost: всем ждущим — исключение.
        # На отменённом future set_exception бросает InvalidStateError.
        self.closed = True
        for future in self.requests.values():
            future.set_exception(ConnectionError("closed"))
        if self.on_close:
            self.on_close(self)


class FakeNetworkLoop:
    """Реальный loop, у которого create_connection — управляемая «сеть»."""

    def __init__(self, real_loop, mode: str):
        self._real = real_loop
        self.mode = mode
        self.calls: list = []

    async def create_connection(
        self, protocol_factory, host, port, ssl=False, **kwargs
    ):
        self.calls.append(kwargs)
        if self.mode == "silent":
            await asyncio.sleep(3600)
        return None, FakeConnection(respond=self.mode == "ok")

    def __getattr__(self, item):
        return getattr(self._real, item)


class FakePool(APNsBaseConnectionPool):
    """Настоящий acquire/send_notification aioapns 3.2, create_connection как
    у APNsCertConnectionPool (через self.loop)."""

    async def create_connection(self):
        _, protocol = await self.loop.create_connection(
            protocol_factory=partial(object, self.apns_topic, self.loop),
            host="api.push.apple.com",
            port=443,
            ssl=None,
        )
        protocol.on_close = self.discard_connection
        return protocol


class DeadlineTest(unittest.IsolatedAsyncioTestCase):
    CONNECT = 0.2
    # > CONNECT + sleep(1) пула aioapns — то же соотношение, что на проде (3+1 < 5).
    SEND = 1.5
    DELAY = 0.05

    def run(self, result=None):
        # Как в test_push_outcomes: Twisted-тесты оставляют свой loop running.
        previous_loop = asyncio._get_running_loop()
        asyncio._set_running_loop(None)
        try:
            return super().run(result)
        finally:
            asyncio._set_running_loop(previous_loop)

    def make_pushkin(self, mode: str):
        pushkin = object.__new__(ApnsPushkin)
        Pushkin.__init__(
            pushkin,
            "test.app",
            SimpleNamespace(tracer=opentracing.Tracer(), reactor=None),
            {},
        )
        pushkin.push_type = PushType.ALERT
        pushkin.sent_cache = SentCache(0, lambda: 0.0)
        pushkin.stable_apns_id = False
        pushkin.collapse_by_event = False
        pushkin.alert_clearing = False
        pushkin._unique_ids = OrderedDict()
        pushkin.CONNECT_TIMEOUT = self.CONNECT
        pushkin.SEND_TIMEOUT = self.SEND
        pushkin.RETRY_DELAY = self.DELAY
        network = FakeNetworkLoop(asyncio.get_running_loop(), mode)
        pool = FakePool(topic="test.app", max_connection_attempts=1)
        pool.loop = ConnectDeadlineLoop(network, self.CONNECT, happy_eyeballs=True)
        pushkin.apns_client = SimpleNamespace(
            pool=pool, send_notification=pool.send_notification
        )
        # Deferred.fromFuture в чистом asyncio-тесте не await-ится; обёртка над
        # Twisted — единственное, что не проверяем.
        pushkin._send_notification = pushkin._send_with_deadline  # type: ignore[method-assign]
        return pushkin, pool, network

    def notification(self):
        return Notification(
            {
                "event_id": "$event",
                "room_id": "!room:example.test",
                "counts": {"unread": 1},
                "devices": [{"app_id": "test.app", "pushkey": TOKEN}],
            }
        )

    async def dispatch(self, pushkin):
        n = self.notification()
        context = NotificationContext(
            "req", pushkin.sygnal.tracer.start_span("test"), 0
        )
        sleeps: list = []

        async def fake_sleep(delay, twisted_reactor=None):
            sleeps.append(delay)
            await asyncio.sleep(delay)

        with patch("sygnal.apnspushkin.twisted_sleep", fake_sleep):
            with self.assertLogs("sygnal", level="DEBUG") as captured:
                started = time.monotonic()
                try:
                    result = await pushkin._dispatch_notification_unlimited(
                        n, n.devices[0], context
                    )
                    error = None
                except NotificationDispatchException as exc:
                    result, error = None, exc
                elapsed = time.monotonic() - started
        return result, error, elapsed, sleeps, "\n".join(captured.output)

    async def test_connect_to_silent_address_is_bounded(self):
        """AC:RL-sygnal-egress-deadlines/1"""
        network = FakeNetworkLoop(asyncio.get_running_loop(), "silent")
        loop = ConnectDeadlineLoop(network, self.CONNECT, happy_eyeballs=True)
        started = time.monotonic()
        with self.assertRaises(asyncio.TimeoutError):
            await loop.create_connection(object, SILENT_IP, 443, ssl=None)
        self.assertLess(time.monotonic() - started, self.CONNECT + 0.15)
        # Прод-значение ≤ 3 с, иначе бюджет 2×SEND + пауза не влезет в 15 с.
        self.assertLessEqual(ApnsPushkin.CONNECT_TIMEOUT, 3.0)
        self.assertLess(ApnsPushkin.CONNECT_TIMEOUT, ApnsPushkin.SEND_TIMEOUT)

    async def test_happy_eyeballs_only_without_proxy(self):
        """AC:RL-sygnal-egress-deadlines/2"""
        network = FakeNetworkLoop(asyncio.get_running_loop(), "ok")
        await ConnectDeadlineLoop(network, 1, happy_eyeballs=True).create_connection(
            object, "h", 443
        )
        self.assertEqual(
            network.calls[-1], {"happy_eyeballs_delay": 0.25, "interleave": 1}
        )
        await ConnectDeadlineLoop(network, 1, happy_eyeballs=False).create_connection(
            object, "h", 443
        )
        self.assertEqual(network.calls[-1], {})

        # С прокси обёртка лежит поверх ProxyingEventLoopWrapper: лишние kwargs
        # дали бы TypeError на КАЖДОМ пуше.
        proxy_params = inspect.signature(
            ProxyingEventLoopWrapper.create_connection
        ).parameters
        self.assertNotIn("happy_eyeballs_delay", proxy_params)
        proxy = ProxyingEventLoopWrapper(network, "http://proxy.test:8080")
        proxy.create_connection = AsyncMock(return_value=(None, None))  # type: ignore[method-assign]
        wrapped = ConnectDeadlineLoop(proxy, 1, happy_eyeballs=False)
        await wrapped.create_connection(
            protocol_factory=object, host="h", port=443, ssl=None
        )
        self.assertEqual(
            set(proxy.create_connection.call_args.kwargs),
            {"protocol_factory", "host", "port", "ssl"},
        )
        # Остальное (call_later у протокола aioapns) — делегируется.
        self.assertEqual(wrapped.call_later, network.call_later)

    async def test_hung_connect_does_not_block_other_sends(self):
        """AC:RL-sygnal-egress-deadlines/3"""
        pushkin, pool, network = self.make_pushkin("silent")
        started = time.monotonic()
        results = await asyncio.gather(
            *[
                pool.send_notification(SimpleNamespace(notification_id=str(i)))
                for i in range(3)
            ],
            return_exceptions=True,
        )
        elapsed = time.monotonic() - started
        # Лок пула отдаётся через CONNECT_TIMEOUT, а не через ~127 с SYN-ретраев.
        self.assertTrue(all(isinstance(r, MaxAttemptsExceeded) for r in results))
        self.assertLess(elapsed, 3 * (self.CONNECT + 1) + 0.5)
        started = time.monotonic()
        with self.assertRaises(Exception):
            await pushkin._send_with_deadline(SimpleNamespace(notification_id="x"))
        self.assertLess(time.monotonic() - started, self.SEND + 0.15)

    async def test_send_without_response_is_retryable_and_drops_connection(self):
        """AC:RL-sygnal-egress-deadlines/4"""
        pushkin, pool, _ = self.make_pushkin("mute")
        loop = asyncio.get_running_loop()
        loop_errors: list = []
        loop.set_exception_handler(lambda _l, ctx: loop_errors.append(ctx))
        # Чужой запрос в полёте на соседнем (занятом) соединении пула.
        other = FakeConnection(respond=False)
        other.is_busy = True
        other_future = loop.create_future()
        other.requests["other"] = other_future
        pool.connections.append(other)

        started = time.monotonic()
        with self.assertRaises(ApnsSendTimeout):
            await pushkin._send_notification(SimpleNamespace(notification_id="notif-1"))
        self.assertLess(time.monotonic() - started, self.SEND + 0.15)
        self.assertEqual(pool.connections, [other], "зависшее соединение — вон из пула")
        self.assertFalse(other.closed)
        self.assertFalse(other_future.done())
        await asyncio.sleep(0.05)
        self.assertEqual(loop_errors, [])

    async def test_whole_dispatch_fits_envoy_budget_when_apns_hangs(self):
        """AC:RL-sygnal-egress-deadlines/5 AC:RL-sygnal-egress-deadlines/8
        AC:RL-sygnal-egress-deadlines/9"""
        for mode in ("silent", "mute"):
            with self.subTest(mode=mode):
                pushkin, _, _ = self.make_pushkin(mode)
                result, error, elapsed, sleeps, logs = await self.dispatch(pushkin)
                self.assertIsNotNone(
                    error, "исчерпание → 502 (NotificationDispatchException)"
                )
                self.assertNotIsInstance(error, TemporaryNotificationDispatchException)
                self.assertIsNone(result, "таймаут не должен стать rejected-токеном")
                budget = 2 * self.SEND + self.DELAY
                self.assertLess(elapsed, budget + 0.3)
                self.assertIn('"reason":"retry_exhausted"', logs)
                reason = "provider_timeout" if mode == "mute" else "connection_failure"
                self.assertIn(f'"reason":"{reason}"', logs)
                self.assertNotIn('"outcome":"rejected"', logs)
                self.assertNotIn("unexpected_error", logs)
                self.assertNotIn(TOKEN, logs)
                self.assertNotIn(SILENT_IP, logs)
        # Прод-бюджет < 15 с таймаута Envoy по умолчанию.
        prod = (
            ApnsPushkin.MAX_TRIES * ApnsPushkin.SEND_TIMEOUT
            + (ApnsPushkin.MAX_TRIES - 1) * ApnsPushkin.RETRY_DELAY
        )
        self.assertLess(prod, 15.0 - 3.0)

    async def test_max_attempts_exceeded_is_retried(self):
        """AC:RL-sygnal-egress-deadlines/6 AC:RL-sygnal-egress-deadlines/7"""
        pushkin, _, _ = self.make_pushkin("ok")
        pushkin._send_notification = AsyncMock(  # type: ignore[method-assign]
            side_effect=[MaxAttemptsExceeded(), NotificationResult("id", "200")]
        )
        result, error, _, sleeps, logs = await self.dispatch(pushkin)
        self.assertIsNone(error)
        self.assertEqual(result, [])
        self.assertEqual(pushkin._send_notification.call_count, 2)
        self.assertIn('"reason":"connection_failure"', logs)
        self.assertNotIn("unexpected_error", logs)
        self.assertEqual(sleeps, [self.DELAY])
        self.assertLessEqual(ApnsPushkin.RETRY_DELAY, 1.0)

        # custom_retry_delay не может растянуть паузу за бюджет.
        pushkin, _, _ = self.make_pushkin("ok")
        pushkin._dispatch_request = AsyncMock(  # type: ignore[method-assign]
            side_effect=[
                TemporaryNotificationDispatchException("x", custom_retry_delay=60),
                [],
            ]
        )
        _, error, _, sleeps, _ = await self.dispatch(pushkin)
        self.assertIsNone(error)
        self.assertEqual(sleeps, [self.DELAY])


if __name__ == "__main__":
    unittest.main()
