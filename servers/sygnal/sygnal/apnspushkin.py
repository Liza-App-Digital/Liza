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
import logging
import json
import os
from datetime import timezone
from typing import TYPE_CHECKING, Any, Dict, List, Optional
from uuid import uuid4

import aioapns
from aioapns import APNs, NotificationRequest
from aioapns.common import NotificationResult, PushType
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

    MAX_TRIES = 3
    RETRY_DELAY_BASE = 10

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
    } | ConcurrencyLimitedPushkin.UNDERSTOOD_CONFIG_FIELDS

    # Clearing-пуш живёт в очереди APNs недолго: через час чистить шторку уже
    # поздно — это сделает сам клиент на resume.
    CLEARING_PUSH_TTL_SECONDS = 3600

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

        # without this, aioapns will retry every second forever.
        self.apns_client.pool.max_connection_attempts = 3

        # without this, aioapns will not use the proxy if one is configured.
        self.apns_client.pool.loop = loop

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
    ) -> List[str]:
        """
        Actually attempts to dispatch the notification once.

        push_type — на запрос, а не на pushkin: clearing-пуш уходит background,
        обычные — с типом из конфига. None → тип pushkin'а.
        """
        span.set_tag("apns_id", notif_id)

        # Some client libraries will provide the push token in hex format already. Avoid
        # attempting to convert from base 64 to hex.
        if self.get_config("convert_device_token_to_hex", bool, True):
            device_token = base64.b64decode(device.pushkey).hex()
        else:
            device_token = device.pushkey

        request = NotificationRequest(
            device_token=device_token,
            message=shaved_payload,
            priority=prio,
            notification_id=notif_id,
            time_to_live=time_to_live,
            push_type=push_type or self.push_type,
        )

        try:
            with ACTIVE_REQUESTS_GAUGE.track_inprogress():
                with SEND_TIME_HISTOGRAM.time():
                    response = await self._send_notification(request)
        except aioapns.ConnectionError:
            raise TemporaryNotificationDispatchException("aioapns Connection Failure")

        code = int(response.status)

        span.set_tag(tags.HTTP_STATUS_CODE, code)

        RESPONSE_STATUS_CODES_COUNTER.labels(pushkin=self.name, code=code).inc()

        if response.is_successful:
            return []
        else:
            # .description corresponds to the 'reason' response field
            span.set_tag("apns_reason", response.description or "None")
            if (code, response.description) in self.TOKEN_ERRORS:
                log.info(
                    "APNs token %s for pushkin %s was rejected: %d %s",
                    device_token,
                    self.name,
                    code,
                    response.description,
                )
                return [device.pushkey]
            else:
                if 500 <= code < 600:
                    raise TemporaryNotificationDispatchException(
                        f"{response.status} {response.description}"
                    )
                else:
                    raise NotificationDispatchException(
                        f"{response.status} {response.description}"
                    )

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
            if self._is_clearing_push(n, default_payload):
                payload: Optional[Dict[str, Any]] = self._get_payload_clearing(
                    n, default_payload
                )
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
                    "event_id-only (room=%s, event=%s)",
                    n.room_id,
                    n.event_id,
                )
                shaved_payload = self._get_payload_event_id_only(
                    n, default_payload, send_badge_counts
                )

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

            for retry_number in range(self.MAX_TRIES):
                try:
                    span_tags = {"retry_num": retry_number}

                    with self.sygnal.tracer.start_span(
                        "apns_dispatch_try", tags=span_tags, child_of=span_parent
                    ) as span:
                        assert shaved_payload is not None

                        # this is no good: APNs expects ID to be in their format
                        # so we can't just derive a
                        # notif_id = context.request_id + f"-{n.devices.index(device)}"
                        notif_id = str(uuid4())
                        # XXX: shouldn't we use the same notif_id for each retry?

                        # Второе поле — device.pushkey (токен устройства, константа), а не
                        # APNs-ID запроса: старый лейбл «APNs-ID:» выдавал одинаковый токен
                        # у всех отправок за коалесцирование (разбор 2026-09-28). Токен
                        # позволяет слать пуши на устройство — в лог только префикс
                        # (security-secrets.md), его хватает для сверки с pushers.
                        log.info(
                            "Sending (attempt %i) => %s pushkey:%s… room:%s, event:%s%s",
                            retry_number,
                            notif_id,
                            device.pushkey[:8],
                            n.room_id,
                            n.event_id,
                            " (clearing)" if push_type is PushType.BACKGROUND else "",
                        )

                        return await self._dispatch_request(
                            log,
                            span,
                            device,
                            shaved_payload,
                            prio,
                            notif_id,
                            push_type=push_type,
                            time_to_live=time_to_live,
                        )
                except TemporaryNotificationDispatchException as exc:
                    retry_delay = self.RETRY_DELAY_BASE * (2**retry_number)
                    if exc.custom_retry_delay is not None:
                        retry_delay = exc.custom_retry_delay

                    log.warning(
                        "Temporary failure, will retry in %d seconds",
                        retry_delay,
                        exc_info=True,
                    )

                    span_parent.log_kv(
                        {"event": "temporary_fail", "retrying_in": retry_delay}
                    )
                    if retry_number < self.MAX_TRIES - 1:
                        await twisted_sleep(
                            retry_delay, twisted_reactor=self.sygnal.reactor
                        )

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
        return default_payload.get("liza_clear_v") == 1

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
            return self._get_payload_story(
                n, device, from_display, send_badge_counts
            )

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
            log.info("Nothing to do for alert of type %s", n.type)
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
        if n.counts and (n.counts.unread is not None or n.counts.missed_calls is not None):
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
            asyncio.ensure_future(self.apns_client.send_notification(request))
        )
