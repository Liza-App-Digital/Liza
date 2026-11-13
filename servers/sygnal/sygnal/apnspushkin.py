# -*- coding: utf-8 -*-
# Copyright 2025 New Vector Ltd.
# Copyright 2019, 2020 The Matrix.org Foundation C.I.C.
# Copyright 2017 Vector Creations Ltd.
# Copyright 2014 OpenMarket Ltd.
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE files in the repository root for full details.
#
# Originally licensed under the Apache License, Version 2.0:
# <http://www.apache.org/licenses/LICENSE-2.0>.
import asyncio
import base64
import copy
import hashlib
import json
import logging
import os
from collections import OrderedDict
from datetime import timezone
from typing import TYPE_CHECKING, Any, Dict, List, Optional
from uuid import NAMESPACE_URL, uuid4, uuid5

import aioapns
from aioapns import APNs, NotificationRequest
from aioapns.common import NotificationResult, PushType
from aioapns.exceptions import MaxAttemptsExceeded
from cryptography.hazmat.backends import default_backend
from cryptography.x509 import load_pem_x509_certificate
from opentracing import Span, logs, tags
from prometheus_client import Counter, Gauge, Histogram
from twisted.internet.defer import Deferred

from sygnal import apnstruncate
from sygnal._clean_body import (
    STORY_PUBLISHED_BODY,
    clean_message_body,
    has_voice_marker,
    is_media_msgtype,
    is_story,
    media_caption,
)
from sygnal._news_audience import device_platform
from sygnal._push_outcomes import SENT_MS_KEY, PushOutcome, emit_apns_id
from sygnal._sent_cache import SENT_CACHE_TTL_SECONDS, SentCache, client_name_of
from sygnal.exceptions import (
    NotificationDispatchException,
    PushkinSetupException,
    TemporaryNotificationDispatchException,
)
from sygnal.helper.proxy.proxy_asyncio import ProxyingEventLoopWrapper
from sygnal.notifications import (
    ConcurrencyLimitedPushkin,
    Device,
    Notification,
    NotificationContext,
)
from sygnal.utils import NotificationLoggerAdapter, twisted_sleep

if TYPE_CHECKING:
    from sygnal.sygnal import Sygnal


logger = logging.getLogger(__name__)

# apns-id = UUIDv5(pushkey|client_name|event_id): один на все повторы одного
# события у одного аккаунта на одном токене. Apple по нему схлопывает дубль,
# а мы находим пуш в своих логах и в Push Notifications Console.
# Пространство имён менять нельзя — сломается сверка со старыми логами.
STABLE_APNS_NAMESPACE = uuid5(NAMESPACE_URL, "https://liza.ru/push/apns-id")

ALERT_CLEARING_FALLBACK_BODY = "Новые сообщения прочитаны"

UNIQUE_IDS_MAX_ENTRIES = 10_000


def stable_apns_id(pushkey: str, client_name: str, event_id: str) -> str:
    return str(uuid5(STABLE_APNS_NAMESPACE, f"{pushkey}|{client_name}|{event_id}"))


def collapse_id_for_event(client_name: str, event_id: str) -> str:
    """apns-collapse-id ≤ 64 байт; event_id Matrix бывает длиннее, поэтому
    хэш. Клиент macOS считает ту же строку для id локального баннера —
    формулу менять только вместе с ним."""
    digest = hashlib.sha256(f"{client_name}|{event_id}".encode()).digest()
    return base64.urlsafe_b64encode(digest).decode().rstrip("=")

SEND_TIME_HISTOGRAM = Histogram(
    "sygnal_apns_request_time", "Time taken to send HTTP request to APNS"
)

ACTIVE_REQUESTS_GAUGE = Gauge(
    "sygnal_active_apns_requests", "Number of APNS requests in flight"
)

RESPONSE_STATUS_CODES_COUNTER = Counter(
    "sygnal_apns_status_codes",
    "Number of HTTP response status codes received from APNS",
    labelnames=["pushkin", "code"],
)

CERTIFICATE_EXPIRATION_GAUGE = Gauge(
    "sygnal_client_cert_expiry",
    "The expiry date of the client certificate in seconds since the epoch",
    labelnames=["pushkin"],
)


def _without_mutable_content(payload: Dict[str, Any]) -> Dict[str, Any]:
    """Копия payload без aps.mutable-content. aps у payload бывает тем же
    объектом, что и default_payload pusher'а, — его не мутируем."""
    aps = payload.get("aps")
    if not isinstance(aps, dict) or "mutable-content" not in aps:
        return payload
    return {
        **payload,
        "aps": {k: v for k, v in aps.items() if k != "mutable-content"},
    }


class ApnsSendTimeout(Exception):
    pass


class ConnectDeadlineLoop:
    """Обёртка loop пула aioapns: ограничивает create_connection по времени.

    aioapns зовёт loop.create_connection без таймаута и под asyncio.Lock пула.
    В k8s egress иногда молча теряет SYN (Errno 110 через ~127 с), и один такой
    коннект держит лок, пока Envoy не рвёт запрос Synapse на 15 с → 504 →
    backoff пушера (заявка 11.11, howItWoks/pushes/history.md).

    happy_eyeballs: при немом первом адресе через 0,25 с параллельно пробуется
    следующий. Только без прокси: ProxyingEventLoopWrapper таких kwargs не
    принимает, а коннектится он к самому прокси.
    """

    def __init__(self, wrapped_loop: Any, timeout: float, happy_eyeballs: bool):
        self._wrapped_loop = wrapped_loop
        self._timeout = timeout
        self._happy_eyeballs = happy_eyeballs

    async def create_connection(self, *args: Any, **kwargs: Any) -> Any:
        if self._happy_eyeballs:
            kwargs.setdefault("happy_eyeballs_delay", 0.25)
            kwargs.setdefault("interleave", 1)
        return await asyncio.wait_for(
            self._wrapped_loop.create_connection(*args, **kwargs), self._timeout
        )

    def __getattr__(self, item: str) -> Any:
        return getattr(self._wrapped_loop, item)


class ApnsPushkin(ConcurrencyLimitedPushkin):
    """
    Relays notifications to the Apple Push Notification Service.
    """

    # Errors for which the token should be rejected and not reused
    # See https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns  # noqa: E501
    # for the full list of possible errors.
    TOKEN_ERRORS = {
        # A client has uploaded an invalid token.
        (400, "BadDeviceToken"),
        # `DeviceTokenNotForTopic` may be due to a token for a different app or an
        # incorrect topic in the Sygnal configuration. In the event of a
        # misconfiguration, clients will need to reupload their tokens to their
        # homeserver.
        (400, "DeviceTokenNotForTopic"),
        (400, "TopicDisallowed"),
        # The token is no longer valid, probably because the app has been uninstalled.
        (410, "Unregistered"),
    }

    # Весь dispatch обязан уложиться в таймаут Envoy перед Sygnal (15 с по
    # умолчанию в k8s): иначе Synapse получает 504, ставит пушер в backoff и
    # задерживает СЛЕДУЮЩИЕ пуши этого устройства на минуты. Бюджет:
    # SEND_TIMEOUT + RETRY_DELAY + SEND_TIMEOUT = 10,5 с. Внутри попытки пул
    # aioapns делает до двух проходов (connect ≤ CONNECT_TIMEOUT, при неудаче
    # sleep(1)); всё это обрезается SEND_TIMEOUT.
    MAX_TRIES = 2
    RETRY_DELAY = 0.5
    CONNECT_TIMEOUT = 3.0
    SEND_TIMEOUT = 5.0

    MAX_FIELD_LENGTH = 1024
    MAX_JSON_BODY_SIZE = 4096

    UNDERSTOOD_CONFIG_FIELDS = {
        "type",
        "platform",
        "certfile",
        "team_id",
        "key_id",
        "keyfile",
        "topic",
        "push_type",
        "convert_device_token_to_hex",
        "send_badge_counts",
        "clearing_push",
        "stable_apns_id",
        "collapse_by_event",
        "alert_clearing",
        "success_cache_ttl",
        "sent_timestamp",
    } | ConcurrencyLimitedPushkin.UNDERSTOOD_CONFIG_FIELDS

    # Clearing-пуш живёт в очереди APNs недолго: через час чистить шторку уже
    # поздно — это сделает сам клиент на resume.
    CLEARING_PUSH_TTL_SECONDS = 3600
    # Флаги по умолчанию — на классе: тесты собирают pushkin без __init__.
    sent_timestamp = False

    APNS_PUSH_TYPES = {
        "alert": PushType.ALERT,
        "background": PushType.BACKGROUND,
        "voip": PushType.VOIP,
        "complication": PushType.COMPLICATION,
        "fileprovider": PushType.FILEPROVIDER,
        "mdm": PushType.MDM,
    }

    def __init__(self, name: str, sygnal: "Sygnal", config: Dict[str, Any]) -> None:
        super().__init__(name, sygnal, config)

        nonunderstood = set(self.cfg.keys()).difference(self.UNDERSTOOD_CONFIG_FIELDS)
        if len(nonunderstood) > 0:
            logger.warning(
                "The following configuration fields are not understood: %s",
                nonunderstood,
            )

        platform = self.get_config("platform", str)
        if not platform or platform == "production" or platform == "prod":
            self.use_sandbox = False
        elif platform == "sandbox":
            self.use_sandbox = True
        else:
            raise PushkinSetupException(f"Invalid platform: {platform}")

        certfile = self.get_config("certfile", str)
        keyfile = self.get_config("keyfile", str)
        if not certfile and not keyfile:
            raise PushkinSetupException(
                "You must provide a path to an APNs certificate, or an APNs token."
            )

        if certfile:
            if not os.path.exists(certfile):
                raise PushkinSetupException(
                    f"The APNs certificate '{certfile}' does not exist."
                )
        elif keyfile:
            # keyfile
            if not os.path.exists(keyfile):
                raise PushkinSetupException(
                    f"The APNs key file '{keyfile}' does not exist."
                )
            if not self.get_config("key_id", str):
                raise PushkinSetupException("You must supply key_id.")
            if not self.get_config("team_id", str):
                raise PushkinSetupException("You must supply team_id.")
            if not self.get_config("topic", str):
                raise PushkinSetupException("You must supply topic.")

        # use the Sygnal global proxy configuration
        proxy_url_str = sygnal.config.get("proxy")

        loop = asyncio.get_running_loop()
        if proxy_url_str:
            # this overrides the create_connection method to use a HTTP proxy
            loop = ProxyingEventLoopWrapper(loop, proxy_url_str)  # type: ignore

        if certfile is not None:
            # max_connection_attempts is actually the maximum number of
            # additional connection attempts, so =0 means try once only
            # (we will retry at a higher level so not worth doing more here)
            apns_client = APNs(
                client_cert=certfile,
                use_sandbox=self.use_sandbox,
                max_connection_attempts=0,
            )

            self._report_certificate_expiration(certfile)

            self.apns_client = apns_client
        else:
            # max_connection_attempts is actually the maximum number of
            # additional connection attempts, so =0 means try once only
            # (we will retry at a higher level so not worth doing more here)
            self.apns_client = APNs(
                key=self.get_config("keyfile", str),
                key_id=self.get_config("key_id", str),
                team_id=self.get_config("team_id", str),
                topic=self.get_config("topic", str),
                use_sandbox=self.use_sandbox,
                max_connection_attempts=0,
            )

        push_type = self.get_config("push_type", str)
        if not push_type:
            self.push_type = None
        else:
            if push_type not in self.APNS_PUSH_TYPES.keys():
                raise PushkinSetupException(f"Invalid value for push_type: {push_type}")

            self.push_type = self.APNS_PUSH_TYPES[push_type]

        self.stable_apns_id = self.get_config("stable_apns_id", bool, False)
        self.collapse_by_event = self.get_config("collapse_by_event", bool, False)
        self.alert_clearing = self.get_config("alert_clearing", bool, False)
        self.sent_timestamp = self.get_config("sent_timestamp", bool, False)
        self.sent_cache = SentCache(
            self.get_config("success_cache_ttl", int, SENT_CACHE_TTL_SECONDS),
            sygnal.reactor.seconds,
        )
        self._unique_ids: "OrderedDict[str, str]" = OrderedDict()
        self._install_unique_id_capture()

        # without this, aioapns will retry every second forever.
        # Две попытки пула: протухшее idle-соединение (ConnectionClosed) лечится
        # внутри той же попытки Sygnal. Время всё равно режет SEND_TIMEOUT.
        self.apns_client.pool.max_connection_attempts = 2

        # without this, aioapns will not use the proxy if one is configured.
        self.apns_client.pool.loop = ConnectDeadlineLoop(  # type: ignore[assignment]
            loop, self.CONNECT_TIMEOUT, happy_eyeballs=not proxy_url_str
        )

    def _install_unique_id_capture(self) -> None:
        """apns-unique-id приходит заголовком ответа, а aioapns отдаёт наружу
        только status/description. Подменяем класс протокола пула наследником,
        который запоминает пару apns-id → apns-unique-id. Apple присылает
        unique-id только в development-окружении, в production ключом сверки
        остаётся сам apns-id."""
        base = getattr(self.apns_client.pool, "protocol_class", None)
        if not isinstance(base, type):
            return
        pushkin = self

        class UniqueIdCapturingProtocol(base):  # type: ignore[valid-type,misc]
            def on_response_received(self, headers: Dict[bytes, bytes]) -> None:
                apns_id = headers.get(b"apns-id")
                unique_id = headers.get(b"apns-unique-id")
                if apns_id and unique_id:
                    pushkin._remember_unique_id(
                        apns_id.decode("utf8"), unique_id.decode("utf8")
                    )
                super().on_response_received(headers)

        self.apns_client.pool.protocol_class = UniqueIdCapturingProtocol

    def _remember_unique_id(self, apns_id: str, unique_id: str) -> None:
        self._unique_ids[apns_id.lower()] = unique_id
        while len(self._unique_ids) > UNIQUE_IDS_MAX_ENTRIES:
            self._unique_ids.popitem(last=False)

    def _apns_id_in_flight(self, notif_id: str) -> bool:
        return any(
            notif_id in connection.requests
            for connection in list(self.apns_client.pool.connections)
        )

    def _stable_notification_id(
        self, n: Notification, device: Device
    ) -> Optional[str]:
        client_name = client_name_of(device)
        if not (self.stable_apns_id and n.event_id and client_name):
            return None
        notif_id = stable_apns_id(device.pushkey, client_name, n.event_id)
        # Тот же id ещё ждёт ответа на другом запросе (Synapse прислал повтор,
        # пока висит первая попытка) — aioapns сопоставит ответ не тому future.
        if self._apns_id_in_flight(notif_id):
            return None
        return notif_id

    def _report_certificate_expiration(self, certfile: str) -> None:
        """Export the epoch time that the certificate expires as a metric."""
        with open(certfile, "rb") as f:
            cert_bytes = f.read()

        cert = load_pem_x509_certificate(cert_bytes, default_backend())
        # Report the expiration time as seconds since the epoch (in UTC time).
        CERTIFICATE_EXPIRATION_GAUGE.labels(pushkin=self.name).set(
            cert.not_valid_after.replace(tzinfo=timezone.utc).timestamp()
        )

    async def _dispatch_request(
        self,
        log: NotificationLoggerAdapter,
        span: Span,
        device: Device,
        shaved_payload: Dict[str, Any],
        prio: int,
        notif_id: str,
        push_type: Optional[PushType] = None,
        time_to_live: Optional[int] = None,
        event_id: Optional[str] = None,
        attempt: int = 0,
        collapse_key: Optional[str] = None,
        clearing: bool = False,
        stable: bool = False,
    ) -> List[str]:
        """
        Actually attempts to dispatch the notification once.

        push_type — на запрос, а не на pushkin: clearing-пуш уходит background,
        обычные — с типом из конфига. None → тип pushkin'а.
        """
        span.set_tag("apns_id", notif_id)
        outcome = PushOutcome(
            log,
            "apns",
            self.name,
            device.pushkey,
            event_id,
            attempt,
            clearing,
        )
        outcome.emit("attempt", "dispatch")

        # Some client libraries will provide the push token in hex format already. Avoid
        # attempting to convert from base 64 to hex.
        try:
            if self.get_config("convert_device_token_to_hex", bool, True):
                device_token = base64.b64decode(device.pushkey).hex()
            else:
                device_token = device.pushkey
        except Exception:
            outcome.emit("error", "invalid_request")
            raise NotificationDispatchException("Invalid APNs token encoding") from None

        request = NotificationRequest(
            device_token=device_token,
            message=shaved_payload,
            priority=prio,
            notification_id=notif_id,
            time_to_live=time_to_live,
            push_type=push_type or self.push_type,
            collapse_key=collapse_key,
        )

        try:
            with ACTIVE_REQUESTS_GAUGE.track_inprogress():
                with SEND_TIME_HISTOGRAM.time():
                    response = await self._send_notification(request)
        except (aioapns.ConnectionError, MaxAttemptsExceeded):
            # MaxAttemptsExceeded — пул исчерпал попытки connect/ConnectionClosed;
            # это не наследник ConnectionError, раньше уходил в unexpected_error
            # без повтора.
            outcome.emit("retryable", "connection_failure")
            raise TemporaryNotificationDispatchException(
                "aioapns Connection Failure"
            ) from None
        except ApnsSendTimeout:
            outcome.emit("retryable", "provider_timeout")
            raise TemporaryNotificationDispatchException(
                "APNs request timed out"
            ) from None
        except Exception:
            outcome.emit("error", "unexpected_error")
            raise NotificationDispatchException("APNs request failed") from None

        try:
            code = int(response.status)
        except (TypeError, ValueError):
            outcome.emit("error", "invalid_response")
            raise NotificationDispatchException("Invalid APNs status") from None

        span.set_tag(tags.HTTP_STATUS_CODE, code)

        RESPONSE_STATUS_CODES_COUNTER.labels(pushkin=self.name, code=code).inc()

        emit_apns_id(
            log,
            device.pushkey,
            event_id,
            notif_id,
            self._unique_ids.pop(notif_id.lower(), None),
            stable,
            code,
        )

        if response.is_successful:
            outcome.emit("accepted", "accepted", code)
            return []
        else:
            if (code, response.description) in self.TOKEN_ERRORS:
                reason = "unregistered" if code == 410 else "bad_token"
                span.set_tag("apns_reason", reason)
                outcome.emit(
                    "rejected",
                    reason,
                    code,
                )
                return [device.pushkey]
            else:
                if 500 <= code < 600:
                    outcome.emit("retryable", "provider_unavailable", code)
                    raise TemporaryNotificationDispatchException(
                        f"APNs server error {code}"
                    )
                else:
                    outcome.emit("error", "provider_error", code)
                    raise NotificationDispatchException(f"APNs request rejected {code}")

    async def _dispatch_notification_unlimited(
        self, n: Notification, device: Device, context: NotificationContext
    ) -> List[str]:
        log = NotificationLoggerAdapter(logger, {"request_id": context.request_id})

        # The pushkey is kind of secret because you can use it to send push
        # to someone.
        # span_tags = {"pushkey": device.pushkey}
        span_tags: Dict[str, int] = {}

        with self.sygnal.tracer.start_span(
            "apns_dispatch", tags=span_tags, child_of=context.opentracing_span
        ) as span_parent:
            # Before we build the payload, check that the default_payload is not
            # malformed and reject the pushkey if it is

            default_payload = {}

            if device.data:
                default_payload = device.data.get("default_payload", {})
                if not isinstance(default_payload, dict):
                    log.warning(
                        "Rejecting pushkey due to misconfigured default_payload, "
                        "please ensure that default_payload is a dict."
                    )
                    return [device.pushkey]

            send_badge_counts = self.get_config("send_badge_counts", bool, True)

            push_type: Optional[PushType] = None
            time_to_live: Optional[int] = None
            clearing = self._is_clearing_push(n, default_payload)
            if clearing and self._wants_alert_clearing(device, default_payload):
                payload: Optional[Dict[str, Any]] = self._get_payload_alert_clearing(
                    n, default_payload
                )
                push_type = PushType.ALERT
                time_to_live = self.CLEARING_PUSH_TTL_SECONDS
            elif clearing:
                payload = self._get_payload_clearing(n, default_payload)
                push_type = PushType.BACKGROUND
                time_to_live = self.CLEARING_PUSH_TTL_SECONDS
            elif n.event_id and not n.type:
                payload = self._get_payload_event_id_only(
                    n,
                    default_payload,
                    send_badge_counts,
                )
            else:
                payload = self._get_payload_full(n, device, log, send_badge_counts)

            if payload is None:
                # Nothing to do
                span_parent.log_kv({logs.EVENT: "apns_no_payload"})
                return []

            # M6: момент отправки — до truncate, чтобы поле уложилось в 4 KiB.
            # Только пуш с событием: у снятия и счётчика подтверждений нет.
            if self.sent_timestamp and n.event_id and not clearing:
                payload = {
                    **payload,
                    SENT_MS_KEY: int(self.sygnal.reactor.seconds() * 1000),
                }

            try:
                shaved_payload = apnstruncate.truncate(
                    payload, max_length=self.MAX_JSON_BODY_SIZE
                )
            except apnstruncate.BodyTooLongException:
                # Top-level поля (room_name, content и т.п.) apnstruncate не режет —
                # для патологических событий (длинные edits, кастомные msgtype) даже
                # после truncate payload не влезает в 4 KiB. Падаем на минимальный
                # event_id-only payload — клиент дотянет содержимое через /sync.
                log.warning(
                    "APNs payload too large after truncate, falling back to "
                    "event_id-only",
                )
                shaved_payload = self._get_payload_event_id_only(
                    n, default_payload, send_badge_counts
                )

            # Расширение уведомлений Лизы на macOS не стартует ни на одном Маке:
            # usernoted убивает его за «sluggish startup», а через 120 с ПОВТОРНО
            # показывает тот же баннер — уже по прочитанному (жалобы «пуш на Маке
            # через 2 минуты»). mutable-content кладёт в default_payload сам
            # клиент, и для Мака тоже; без него usernoted расширение не будит и
            # показывает оригинал сразу. howItWoks/pushes/pushes.md §24.
            if shaved_payload and device_platform(device) == "macos":
                shaved_payload = _without_mutable_content(shaved_payload)

            # Приоритет доставки APNs считаем по СОДЕРЖИМОМУ итогового payload,
            # а НЕ по n.prio. Synapse шлёт prio="low" для всех обычных (не-highlight,
            # не-encrypted) сообщений (httppusher.py:472-480) — раньше это давало
            # APNs prio=5, а Apple низкоприоритетные пуши коалесцирует/придерживает
            # минутами (жалоба: баннер приходит через ~10 мин, уже после прочтения).
            # FCM это уже лечит безусловным форсом high (gcmpushkin.py) — Android
            # иммунен, iOS/macOS нет. Форсим prio=10 (немедленная доставка) для
            # видимых alert-пушей. Apple требует для prio=10 наличие в aps хотя бы
            # одного из alert/sound/badge (иначе 400 MissingPayload / downgrade);
            # наши пуши всегда несут aps.sound из default_payload клиента. Истинно
            # тихий payload (badge-clearing без alert/sound/badge) оставляем на 5.
            aps = shaved_payload.get("aps", {}) if shaved_payload else {}
            if aps.get("alert") or aps.get("sound") or aps.get("badge"):
                prio = 10
            else:
                prio = 5

            sent_key = self.sent_cache.key(n, device)
            if sent_key is not None and self.sent_cache.seen(sent_key):
                PushOutcome(
                    log, "apns", self.name, device.pushkey, n.event_id, 0, clearing
                ).emit("skipped", "deduplicated")
                return []

            # Один id на все попытки: повтор после таймаута, который Apple на
            # самом деле приняла, схлопнется у Apple, а не прозвенит второй раз.
            stable_id = self._stable_notification_id(n, device)
            client_name = client_name_of(device)
            collapse_key = (
                collapse_id_for_event(client_name, n.event_id)
                if self.collapse_by_event and n.event_id and client_name
                else None
            )

            for retry_number in range(self.MAX_TRIES):
                try:
                    span_tags = {"retry_num": retry_number}

                    with self.sygnal.tracer.start_span(
                        "apns_dispatch_try", tags=span_tags, child_of=span_parent
                    ) as span:
                        assert shaved_payload is not None

                        notif_id = stable_id or str(uuid4())

                        failed = await self._dispatch_request(
                            log,
                            span,
                            device,
                            shaved_payload,
                            prio,
                            notif_id,
                            push_type=push_type,
                            time_to_live=time_to_live,
                            event_id=n.event_id,
                            attempt=retry_number,
                            collapse_key=collapse_key,
                            clearing=clearing,
                            stable=stable_id is not None,
                        )
                        if not failed and sent_key is not None:
                            self.sent_cache.remember(sent_key)
                        return failed
                except TemporaryNotificationDispatchException as exc:
                    # Пауза фиксированная и короткая: длинная (раньше 10/20 с)
                    # переживала таймаут Envoy → 504 → backoff пушера Synapse.
                    retry_delay = self.RETRY_DELAY
                    if exc.custom_retry_delay is not None:
                        retry_delay = min(exc.custom_retry_delay, self.RETRY_DELAY)

                    log.warning(
                        "Temporary failure, will retry in %.1f seconds",
                        retry_delay,
                    )

                    span_parent.log_kv(
                        {"event": "temporary_fail", "retrying_in": retry_delay}
                    )
                    if retry_number < self.MAX_TRIES - 1:
                        await twisted_sleep(
                            retry_delay, twisted_reactor=self.sygnal.reactor
                        )

            PushOutcome(
                log,
                "apns",
                self.name,
                device.pushkey,
                n.event_id,
                self.MAX_TRIES - 1,
                clearing,
            ).emit("error", "retry_exhausted")
            raise NotificationDispatchException("Retried too many times.")

    def _is_clearing_push(
        self, n: Notification, default_payload: Dict[str, Any]
    ) -> bool:
        """Counts-only пуш (Synapse шлёт его на СВОЮ квитанцию) превращаем в
        тихий background-пуш «почисти шторку» — только для клиентов, объявивших
        поддержку (`liza_clear_v` в default_payload, сборки ≥3768). Старые сборки
        и чужие бандлы получают прежнее «ничего», иначе проснутся зря.
        См. howItWoks/pushes.md §21."""
        if n.event_id or n.type:
            return False
        if not self.get_config("clearing_push", bool, True):
            return False
        return default_payload.get("liza_clear_v") in (1, 2)

    def _wants_alert_clearing(
        self, device: Device, default_payload: Dict[str, Any]
    ) -> bool:
        """Видимое снятие (Р3 спеки 2026-11-12): только сборки с filtering
        entitlement объявляют liza_clear_v=2 — их NSE гасит этот alert и
        чистит шторку. Без entitlement система показала бы «Новые сообщения
        прочитаны» баннером. На macOS расширение не стартует (§24) — только
        тихий путь."""
        return (
            self.alert_clearing
            and default_payload.get("liza_clear_v") == 2
            and device_platform(device) != "macos"
        )

    def _get_payload_alert_clearing(
        self, n: Notification, default_payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            k: v for k, v in default_payload.items() if k != "aps"
        }
        aps: Dict[str, Any] = {
            "alert": {"body": ALERT_CLEARING_FALLBACK_BODY},
            "mutable-content": 1,
        }
        if n.counts.unread is not None:
            aps["badge"] = n.counts.unread
            payload["counts"] = {"unread": n.counts.unread}
        payload["aps"] = aps
        payload["liza_clear"] = 2
        return payload

    def _get_payload_clearing(
        self, n: Notification, default_payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        """aps из default_payload НЕ подмешиваем: там sound/mutable-content, а
        с ними пуш станет видимым, получит prio 10 и Apple отвергнет его как
        background. aps.badge не ставим — бейджем владеет клиент."""
        payload: Dict[str, Any] = {
            k: v for k, v in default_payload.items() if k != "aps"
        }
        payload["aps"] = {"content-available": 1}
        payload["liza_clear"] = 1
        if n.counts.unread is not None:
            payload["counts"] = {"unread": n.counts.unread}
        return payload

    def _get_payload_event_id_only(
        self,
        n: Notification,
        default_payload: Dict[str, Any],
        send_badge_counts: bool,
    ) -> Dict[str, Any]:
        """
        Constructs a payload for a notification where we know only the event ID.
        Args:
            n: The notification to construct a payload for.
            device: Device information to which the constructed payload
            will be sent.
            send_badge_counts: if `True`, the `unread_count` and `missed_calls` fields will be included.

        Returns:
            The APNs payload as a nested dicts.
        """
        payload = {}

        payload.update(default_payload)

        if n.room_id:
            payload["room_id"] = n.room_id
        if n.event_id:
            payload["event_id"] = n.event_id

        if send_badge_counts:
            if n.counts.unread is not None:
                payload["unread_count"] = n.counts.unread
            if n.counts.missed_calls is not None:
                payload["missed_calls"] = n.counts.missed_calls

        return payload

    def _get_payload_story(
        self,
        n: Notification,
        device: Device,
        from_display: str,
        send_badge_counts: bool,
    ) -> Dict[str, Any]:
        """LABA-1970: payload пуша на публикацию сторис для iOS/macOS.

        Литеральный aps.alert {title: имя автора, body: «опубликовал историю»}
        показывается системой, если NSE/AppDelegate не перерисует. Плюс
        top-level поля (sender, type, story=True), чтобы обновлённый NSE/
        AppDelegate распознал стори-пуш и построил текст сам.
        """
        payload: Dict[str, Any] = {}
        if device.data:
            payload = copy.deepcopy(device.data.get("default_payload", {}))
        payload.setdefault("aps", {})
        payload["aps"]["alert"] = {
            "title": from_display,
            "body": STORY_PUBLISHED_BODY,
        }

        if send_badge_counts and n.counts:
            badge = None
            if n.counts.unread is not None:
                badge = n.counts.unread
            if n.counts.missed_calls is not None:
                badge = (badge or 0) + n.counts.missed_calls
            if badge is not None:
                payload["aps"]["badge"] = badge

        if n.room_id:
            payload["room_id"] = n.room_id
        if n.event_id:
            payload["event_id"] = n.event_id
        if n.sender:
            payload["sender"] = n.sender[0 : self.MAX_FIELD_LENGTH]
        if n.sender_display_name:
            payload["sender_display_name"] = n.sender_display_name[
                0 : self.MAX_FIELD_LENGTH
            ]
        if n.type:
            payload["type"] = n.type
        # Маркер для нативного NSE/AppDelegate: это стори-пуш, текст —
        # «{sender} опубликовал историю». content_preview НЕ кладём намеренно:
        # у сторис body == имя файла, а тип фиксирован (story) — текст строится
        # из маркера, не из content; литеральный aps.alert выше — фолбэк до
        # обновления нативного слоя.
        payload["story"] = True
        return payload

    def _get_payload_full(
        self,
        n: Notification,
        device: Device,
        log: NotificationLoggerAdapter,
        send_badge_counts: bool,
    ) -> Optional[Dict[str, Any]]:
        """
        Constructs a payload for a notification.
        Args:
            n: The notification to construct a payload for.
            device: Device information to which the constructed payload
            will be sent.
            log: A logger.

        Returns:
            The APNs payload as nested dicts.
        """
        if not n.sender and not n.sender_display_name:
            from_display = " "
        elif n.sender_display_name is not None:
            from_display = n.sender_display_name
        elif n.sender is not None:
            from_display = n.sender
        from_display = from_display[0 : self.MAX_FIELD_LENGTH]

        # LABA-1970: публикация сторис. Литеральный aps.alert (имя автора +
        # «опубликовал историю») как фолбэк + top-level маркер story, чтобы
        # нативный NSE/AppDelegate (Ярус C, новая сборка) отрисовал финальный
        # текст. Отдельная ветка: у сторис type=m.room.message и room_name
        # "Stories - ivan" — штатный loc-key путь дал бы неверный заголовок.
        if is_story(n.content):
            return self._get_payload_story(n, device, from_display, send_badge_counts)

        loc_key = None
        loc_args = None
        if n.type == "m.room.message" or n.type == "m.room.encrypted":
            room_display = None
            if n.room_name:
                room_display = n.room_name[0 : self.MAX_FIELD_LENGTH]
            elif n.room_alias:
                room_display = n.room_alias[0 : self.MAX_FIELD_LENGTH]

            content_display = None
            action_display = None
            is_image = False
            if n.content and "msgtype" in n.content and "body" in n.content:
                if "body" in n.content:
                    body_text = clean_message_body(n.content["body"])
                    if n.content["msgtype"] == "m.text":
                        content_display = body_text
                    elif n.content["msgtype"] == "m.emote":
                        action_display = body_text
                    else:
                        # fallback: 'body' should always be user-visible text
                        # in an m.room.message.
                        # LABA-2238: у медиа body — это имя файла. Здесь оно
                        # попадает в aps.alert.loc-args СОЗНАТЕЛЬНО: этот loc-key
                        # путь — fallback, если NSE/AppDelegate не отработает. На
                        # штатном пути NSE строит текст из `content_preview` ниже
                        # (для медиа без подписи имя файла туда НЕ кладётся).
                        content_display = body_text
                if n.content["msgtype"] == "m.image":
                    is_image = True

            if room_display:
                if is_image:
                    loc_key = "IMAGE_FROM_USER_IN_ROOM"
                    loc_args = [from_display, content_display, room_display]
                elif content_display:
                    loc_key = "MSG_FROM_USER_IN_ROOM_WITH_CONTENT"
                    loc_args = [from_display, room_display, content_display]
                elif action_display:
                    loc_key = "ACTION_FROM_USER_IN_ROOM"
                    loc_args = [room_display, from_display, action_display]
                else:
                    loc_key = "MSG_FROM_USER_IN_ROOM"
                    loc_args = [from_display, room_display]
            else:
                if is_image:
                    loc_key = "IMAGE_FROM_USER"
                    loc_args = [from_display, content_display]
                elif content_display:
                    loc_key = "MSG_FROM_USER_WITH_CONTENT"
                    loc_args = [from_display, content_display]
                elif action_display:
                    loc_key = "ACTION_FROM_USER"
                    loc_args = [from_display, action_display]
                else:
                    loc_key = "MSG_FROM_USER"
                    loc_args = [from_display]

        elif n.type == "m.call.invite":
            is_video_call = False

            # This detection works only for hs that uses WebRTC for calls
            if n.content and "offer" in n.content and "sdp" in n.content["offer"]:
                sdp = n.content["offer"]["sdp"]
                if "m=video" in sdp:
                    is_video_call = True

            if is_video_call:
                loc_key = "VIDEO_CALL_FROM_USER"
            else:
                loc_key = "VOICE_CALL_FROM_USER"

            loc_args = [from_display]
        elif n.type == "m.room.member":
            if n.user_is_target:
                if n.membership == "invite":
                    if n.room_name:
                        loc_key = "USER_INVITE_TO_NAMED_ROOM"
                        loc_args = [
                            from_display,
                            n.room_name[0 : self.MAX_FIELD_LENGTH],
                        ]
                    elif n.room_alias:
                        loc_key = "USER_INVITE_TO_NAMED_ROOM"
                        loc_args = [
                            from_display,
                            n.room_alias[0 : self.MAX_FIELD_LENGTH],
                        ]
                    else:
                        loc_key = "USER_INVITE_TO_CHAT"
                        loc_args = [from_display]
        elif n.type:
            # A type of message was received that we don't know about
            # but it was important enough for a push to have got to us
            loc_key = "MSG_FROM_USER"
            loc_args = [from_display]

        badge = None
        if send_badge_counts:
            if n.counts.unread is not None:
                badge = n.counts.unread
            if n.counts.missed_calls is not None:
                if badge is None:
                    badge = 0
                badge += n.counts.missed_calls

        if loc_key is None and badge is None:
            log.info("Nothing to do for unsupported alert type")
            return None

        payload = {}

        if n.type and device.data:
            payload = copy.deepcopy(device.data.get("default_payload", {}))

        payload.setdefault("aps", {})

        if loc_key:
            payload["aps"].setdefault("alert", {})["loc-key"] = loc_key

        if loc_args:
            payload["aps"].setdefault("alert", {})["loc-args"] = loc_args

        if badge is not None:
            payload["aps"]["badge"] = badge

        if loc_key and n.room_id:
            payload["room_id"] = n.room_id
        if loc_key and n.event_id:
            payload["event_id"] = n.event_id

        # Liza-specific: NSE на iOS и AppDelegate на macOS читают top-level поля
        # для построения текста уведомления (sender, room_name, content и т.д.).
        # Без этого NSE рендерит fallback "Unknown — New message".
        if n.sender:
            payload["sender"] = n.sender[0 : self.MAX_FIELD_LENGTH]
        if n.sender_display_name:
            payload["sender_display_name"] = n.sender_display_name[
                0 : self.MAX_FIELD_LENGTH
            ]
        if n.room_name:
            payload["room_name"] = n.room_name[0 : self.MAX_FIELD_LENGTH]
        if n.type:
            payload["type"] = n.type
        # Из event.content NSE/AppDelegate читают msgtype, body (для preview) и
        # voice-флаг. Кладём минимум — иначе на длинных сообщениях/edits payload
        # не влезает в 4 KiB и apnstruncate сдаётся с BodyTooLongException.
        # LABA-2238: у медиа body — это имя файла. Для медиа БЕЗ реальной подписи
        # body НЕ шлём — NSE/AppDelegate по msgtype (+voice) строят локализованную
        # строку-по-типу («🎤 Голосовое сообщение» и т.п.), а не имя файла. Реальную
        # подпись (body != filename) шлём как есть.
        if n.content:
            content_preview: Dict[str, Any] = {}
            msgtype = n.content.get("msgtype")
            if isinstance(msgtype, str):
                content_preview["msgtype"] = msgtype
            if isinstance(msgtype, str) and is_media_msgtype(n.content):
                # voice-флаг нужен только для медиа (NSE: «Голосовое» vs «Аудио»).
                if has_voice_marker(n.content):
                    content_preview["voice"] = True
                caption = media_caption(n.content)
                if caption is not None:
                    content_preview["body"] = caption[0 : self.MAX_FIELD_LENGTH]
            else:
                body = n.content.get("body")
                if isinstance(body, str):
                    content_preview["body"] = clean_message_body(body)[
                        0 : self.MAX_FIELD_LENGTH
                    ]
            if content_preview:
                payload["content"] = content_preview
        if n.counts and (
            n.counts.unread is not None or n.counts.missed_calls is not None
        ):
            # NSE на iOS и AppDelegate на macOS читают counts как JSON-строку.
            counts: Dict[str, Any] = {}
            if n.counts.unread is not None:
                counts["unread"] = n.counts.unread
            if n.counts.missed_calls is not None:
                counts["missed_calls"] = n.counts.missed_calls
            payload["counts"] = json.dumps(counts)

        return payload

    async def _send_notification(
        self, request: NotificationRequest
    ) -> NotificationResult:
        return await Deferred.fromFuture(
            asyncio.ensure_future(self._send_with_deadline(request))
        )

    async def _send_with_deadline(
        self, request: NotificationRequest
    ) -> NotificationResult:
        # Дедлайн покрывает ожидание лока пула + connect + ответ APNs: у aioapns
        # ни на что из этого таймаута нет.
        try:
            return await asyncio.wait_for(
                self.apns_client.send_notification(request), self.SEND_TIMEOUT
            )
        except asyncio.TimeoutError:
            self._drop_hung_connection(request.notification_id)
            raise ApnsSendTimeout() from None

    def _drop_hung_connection(self, notification_id: str) -> None:
        """Закрыть соединение, на котором повис ответ на этот запрос.

        Остальные соединения пула не трогаем — на них чужие запросы в полёте.
        Future запроса уже отменён wait_for'ом: вынимаем его до close(), иначе
        connection_lost сделает set_exception на отменённом future.
        """
        for connection in list(self.apns_client.pool.connections):
            if connection.requests.pop(notification_id, None) is not None:
                connection.close()
