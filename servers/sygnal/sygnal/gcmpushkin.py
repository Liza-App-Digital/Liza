# -*- coding: utf-8 -*-
# Copyright 2017-2025 New Vector Ltd.
# Copyright 2019, 2020 The Matrix.org Foundation C.I.C.
# Copyright 2014 Leon Handreke
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE files in the repository root for full details.
#
# Originally licensed under the Apache License, Version 2.0:
# <http://www.apache.org/licenses/LICENSE-2.0>.
import asyncio
import json
import logging
import os
import time
from enum import Enum
from io import BytesIO
from typing import TYPE_CHECKING, Any, AnyStr, Dict, List, Optional, Tuple

# We are using an unstable async google-auth API, but it's there since 3+ years
# https://github.com/googleapis/google-auth-library-python/issues/613
import aiohttp
import google.auth.transport._aiohttp_requests
from google.auth._default_async import load_credentials_from_file
from google.oauth2._credentials_async import Credentials
from opentracing import Span, logs, tags
from prometheus_client import Counter, Gauge, Histogram
from twisted.internet.defer import Deferred, DeferredSemaphore
from twisted.web.client import FileBodyProducer, HTTPConnectionPool, readBody
from twisted.web.http_headers import Headers
from twisted.web.iweb import IResponse

from sygnal._clean_body import (
    STORY_PUBLISHED_BODY,
    clean_message_body,
    is_media_msgtype,
    is_story,
    media_caption,
    media_type_label,
)
from sygnal._push_outcomes import PushOutcome
from sygnal.exceptions import (
    NotificationDispatchException,
    NotificationQuotaDispatchException,
    PushkinSetupException,
    TemporaryNotificationDispatchException,
)
from sygnal.helper.context_factory import ClientTLSOptionsFactory
from sygnal.helper.proxy.proxyagent_twisted import ProxyAgent
from sygnal.notifications import (
    ConcurrencyLimitedPushkin,
    Device,
    Notification,
    NotificationContext,
)
from sygnal.utils import NotificationLoggerAdapter, json_decoder, twisted_sleep

if TYPE_CHECKING:
    from sygnal.sygnal import Sygnal

QUEUE_TIME_HISTOGRAM = Histogram(
    "sygnal_gcm_queue_time", "Time taken waiting for a connection to GCM"
)

SEND_TIME_HISTOGRAM = Histogram(
    "sygnal_gcm_request_time", "Time taken to send HTTP request to GCM"
)

PENDING_REQUESTS_GAUGE = Gauge(
    "sygnal_pending_gcm_requests", "Number of GCM requests waiting for a connection"
)

ACTIVE_REQUESTS_GAUGE = Gauge(
    "sygnal_active_gcm_requests", "Number of GCM requests in flight"
)

RESPONSE_STATUS_CODES_COUNTER = Counter(
    "sygnal_gcm_status_codes",
    "Number of HTTP response status codes received from GCM",
    labelnames=["pushkin", "code"],
)

logger = logging.getLogger(__name__)

GCM_URL = b"https://fcm.googleapis.com/fcm/send"
GCM_URL_V1 = "https://fcm.googleapis.com/v1/projects/{ProjectID}/messages:send"
MAX_TRIES = 3
RETRY_DELAY_BASE = 10
RETRY_DELAY_BASE_QUOTA_EXCEEDED = 60
MAX_BYTES_PER_FIELD = 1024
MAX_FIREBASE_MESSAGE_SIZE = 4096

# Subtract 1 since the combined size of the other non-overflowing fields will push it over the
# edge otherwise.
MAX_NOTIFICATION_OVERFLOW_FIELDS = MAX_FIREBASE_MESSAGE_SIZE / MAX_BYTES_PER_FIELD - 1

AUTH_SCOPES = ["https://www.googleapis.com/auth/firebase.messaging"]

# The error codes that mean a registration ID will never
# succeed and we should reject it upstream.
# We include NotRegistered here too for good measure, even
# though gcm-client 'helpfully' extracts these into a separate
# list.
BAD_PUSHKEY_FAILURE_CODES = [
    "MissingRegistration",
    "InvalidRegistration",
    "NotRegistered",
    "InvalidPackageName",
    "MismatchSenderId",
]

# Failure codes that mean the message in question will never
# succeed, so don't retry, but the registration ID is fine
# so we should not reject it upstream.
BAD_MESSAGE_FAILURE_CODES = ["MessageTooBig", "InvalidDataKey", "InvalidTtl"]

DEFAULT_MAX_CONNECTIONS = 20


class APIVersion(Enum):
    Legacy = "legacy"
    V1 = "v1"


class GcmPushkin(ConcurrencyLimitedPushkin):
    """
    Pushkin that relays notifications to Google/Firebase Cloud Messaging.
    """

    UNDERSTOOD_CONFIG_FIELDS = {
        "type",
        "api_key",
        "api_version",
        "fcm_options",
        "max_connections",
        "project_id",
        "service_account_file",
        "send_badge_counts",
    } | ConcurrencyLimitedPushkin.UNDERSTOOD_CONFIG_FIELDS

    def __init__(self, name: str, sygnal: "Sygnal", config: Dict[str, Any]) -> None:
        super().__init__(name, sygnal, config)

        nonunderstood = set(self.cfg.keys()).difference(self.UNDERSTOOD_CONFIG_FIELDS)
        if len(nonunderstood) > 0:
            logger.warning(
                "The following configuration fields are not understood: %s",
                nonunderstood,
            )

        self.http_pool = HTTPConnectionPool(reactor=sygnal.reactor)
        self.max_connections = self.get_config(
            "max_connections", int, DEFAULT_MAX_CONNECTIONS
        )

        self.connection_semaphore = DeferredSemaphore(self.max_connections)
        self.http_pool.maxPersistentPerHost = self.max_connections

        tls_client_options_factory = ClientTLSOptionsFactory()

        # use the Sygnal global proxy configuration
        proxy_url = sygnal.config.get("proxy")

        self.http_agent = ProxyAgent(
            reactor=sygnal.reactor,
            pool=self.http_pool,
            contextFactory=tls_client_options_factory,
            proxy_url_str=proxy_url,
        )

        self.api_version = APIVersion.Legacy
        version_str = self.get_config("api_version", str)
        if not version_str:
            logger.warning(
                "API version not set in config, defaulting to %s",
                self.api_version.value,
            )
        else:
            try:
                self.api_version = APIVersion(version_str)
            except ValueError:
                raise PushkinSetupException(
                    "Invalid API version set in config",
                    version_str,
                )

        if self.api_version is APIVersion.Legacy:
            self.api_key = self.get_config("api_key", str)
            if not self.api_key:
                raise PushkinSetupException("No API key set in config")

        self.project_id = self.get_config("project_id", str)
        if self.api_version is APIVersion.V1 and not self.project_id:
            raise PushkinSetupException(
                "Must configure `project_id` when using FCM api v1",
            )

        self.credentials: Optional[Credentials] = None

        if self.api_version is APIVersion.V1:
            self.service_account_file = self.get_config("service_account_file", str)
            if not self.service_account_file:
                raise PushkinSetupException(
                    "Must configure `service_account_file` when using FCM api v1",
                )
            try:
                self.credentials, _ = load_credentials_from_file(
                    str(self.service_account_file),
                    scopes=AUTH_SCOPES,
                )
            except google.auth.exceptions.DefaultCredentialsError as e:
                raise PushkinSetupException(
                    f"`service_account_file` must be valid: {str(e)}",
                )

        # Use the fcm_options config dictionary as a foundation for the body;
        # this lets the Sygnal admin choose custom FCM options
        # (e.g. content_available).
        self.base_request_body = self.get_config("fcm_options", dict, {})
        if not isinstance(self.base_request_body, dict):
            raise PushkinSetupException(
                "Config field fcm_options, if set, must be a dictionary of options"
            )

        session = None
        proxy_url = sygnal.config.get("proxy")
        if proxy_url:
            # `ClientSession` can't directly take the proxy URL, so we need to
            # set the usual env var and use `trust_env=True`
            os.environ["HTTPS_PROXY"] = proxy_url

            session = aiohttp.ClientSession(trust_env=True, auto_decompress=False)

        self.google_auth_request = google.auth.transport._aiohttp_requests.Request(
            session=session
        )

    async def _perform_http_request(
        self, body: Dict[str, Any], headers: Dict[AnyStr, List[AnyStr]]
    ) -> Tuple[IResponse, str]:
        """
        Perform an HTTP request to the FCM server with the body and headers
        specified.
        Args:
            body: Body. Will be JSON-encoded.
            headers: HTTP Headers.

        Returns:

        """
        body_producer = FileBodyProducer(BytesIO(json.dumps(body).encode()))

        # we use the semaphore to actually limit the number of concurrent
        # requests, since the HTTPConnectionPool will actually just lead to more
        # requests being created but not pooled – it does not perform limiting.
        with QUEUE_TIME_HISTOGRAM.time():
            with PENDING_REQUESTS_GAUGE.track_inprogress():
                await self.connection_semaphore.acquire()

        url = GCM_URL
        if self.api_version is APIVersion.V1:
            url = str.encode(GCM_URL_V1.format(ProjectID=self.project_id))

        try:
            with SEND_TIME_HISTOGRAM.time():
                with ACTIVE_REQUESTS_GAUGE.track_inprogress():
                    response = await self.http_agent.request(
                        b"POST",
                        url,
                        headers=Headers(headers),
                        bodyProducer=body_producer,
                    )
                    response_text = (await readBody(response)).decode()
        except Exception as exception:
            raise TemporaryNotificationDispatchException(
                "GCM request failure"
            ) from exception
        finally:
            self.connection_semaphore.release()
        return response, response_text

    async def _request_dispatch(
        self,
        n: Notification,
        log: NotificationLoggerAdapter,
        body: Dict[str, Any],
        headers: Dict[AnyStr, List[AnyStr]],
        pushkeys: List[str],
        span: Span,
        attempt: int = 0,
    ) -> Tuple[List[str], List[str]]:
        outcomes = [
            PushOutcome(
                log,
                "fcm",
                self.name,
                key,
                n.event_id,
                attempt,
                not n.event_id and not n.type,
            )
            for key in pushkeys
        ]
        for outcome in outcomes:
            outcome.emit("attempt", "dispatch")
        code = None
        poke_start_time = time.time()
        try:
            response, response_text = await self._perform_http_request(body, headers)
            code = response.code
            RESPONSE_STATUS_CODES_COUNTER.labels(pushkin=self.name, code=code).inc()
            log.debug("GCM request took %f seconds", time.time() - poke_start_time)
            span.set_tag(tags.HTTP_STATUS_CODE, code)

            if self.api_version is APIVersion.Legacy:
                result = self._handle_legacy_response(
                    n,
                    log,
                    response,
                    response_text,
                    pushkeys,
                    span,
                )
            elif self.api_version is APIVersion.V1:
                result = self._handle_v1_response(
                    log,
                    response,
                    response_text,
                    pushkeys,
                    span,
                )
            else:
                for outcome in outcomes:
                    outcome.emit("error", "invalid_request", code)
                return [], []
        except TemporaryNotificationDispatchException as exc:
            for outcome in outcomes:
                outcome.emit(
                    "retryable",
                    "connection_failure" if code is None else "provider_unavailable",
                    code,
                )
            raise TemporaryNotificationDispatchException(
                "FCM temporary failure",
                custom_retry_delay=exc.custom_retry_delay,
            ) from None
        except NotificationQuotaDispatchException as exc:
            for outcome in outcomes:
                outcome.emit("retryable", "quota_exceeded", code)
            raise NotificationQuotaDispatchException(
                "FCM quota exceeded",
                custom_retry_delay=exc.custom_retry_delay,
            ) from None
        except Exception:
            reason = {
                400: "invalid_request",
                401: "unauthorized",
                403: "sender_mismatch",
            }.get(
                code,
                "invalid_response" if code and 200 <= code < 300 else "provider_error",
            )
            for outcome in outcomes:
                outcome.emit("error", reason, code)
            # Тело ответа и исходное исключение не уходят в traceback HTTP-handler.
            raise NotificationDispatchException("FCM request failed") from None

        failed, retry = result
        # Legacy HTTP 200 содержит отдельный результат каждого адресата.
        # Успех HTTP или отсутствие ключа в retry ещё не означает принятия.
        results = (
            json_decoder.decode(response_text).get("results", [])
            if self.api_version is APIVersion.Legacy and 200 <= code < 300
            else None
        )
        for index, (key, outcome) in enumerate(zip(pushkeys, outcomes)):
            if key in failed:
                outcome.emit(
                    "rejected", "unregistered" if code == 404 else "bad_token", code
                )
            elif key in retry:
                outcome.emit("retryable", "provider_retry", code)
            elif results is not None and index >= len(results):
                outcome.emit("error", "invalid_response", code)
            elif results is not None and "error" in results[index]:
                outcome.emit("error", "bad_message", code)
            elif results is not None and (
                not isinstance(results[index], dict)
                or not results[index].get("message_id")
            ):
                outcome.emit("error", "invalid_response", code)
            else:
                outcome.emit("accepted", "accepted", code)
        return result

    def _handle_legacy_response(
        self,
        n: Notification,
        log: NotificationLoggerAdapter,
        response: IResponse,
        response_text: str,
        pushkeys: List[str],
        span: Span,
    ) -> Tuple[List[str], List[str]]:
        failed = []
        if 500 <= response.code < 600:
            log.debug("%d from server, waiting to try again", response.code)

            retry_after = None

            for header_value in response.headers.getRawHeaders(
                b"retry-after", default=[]
            ):
                retry_after = int(header_value)
                span.log_kv({"event": "gcm_retry_after", "retry_after": retry_after})

            raise TemporaryNotificationDispatchException(
                "GCM server error, hopefully temporary.", custom_retry_delay=retry_after
            )
        elif response.code == 400:
            log.error("FCM rejected an invalid request (HTTP 400)")
            # permanent failure: give up
            raise NotificationDispatchException("Invalid request")
        elif response.code == 401:
            log.error("FCM authentication failed (HTTP 401)")
            # permanent failure: give up
            raise NotificationDispatchException("Not authorised to push")
        elif response.code == 404:
            # assume they're all failed
            log.info("FCM reports unregistered devices (HTTP 404)")
            return pushkeys, []
        elif 200 <= response.code < 300:
            try:
                resp_object = json_decoder.decode(response_text)
            except ValueError:
                raise NotificationDispatchException("Invalid JSON response from GCM.")
            if "results" not in resp_object:
                log.error("FCM response contained no results")
            if len(resp_object["results"]) < len(pushkeys):
                log.error(
                    "Sent %d notifications but only got %d responses!",
                    len(n.devices),
                    len(resp_object["results"]),
                )
                span.log_kv(
                    {
                        logs.EVENT: "gcm_response_mismatch",
                        "num_devices": len(n.devices),
                        "num_results": len(resp_object["results"]),
                    }
                )

            # determine which pushkeys to retry or forget about
            new_pushkeys = []
            for i, result in enumerate(resp_object["results"]):
                if "error" in result:
                    # Ошибка провайдера может содержать токен: только класс в span.
                    span.set_tag("gcm_error", "provider_error")
                    if result["error"] in BAD_PUSHKEY_FAILURE_CODES:
                        failed.append(pushkeys[i])
                    elif result["error"] in BAD_MESSAGE_FAILURE_CODES:
                        pass
                    else:
                        new_pushkeys.append(pushkeys[i])
            return failed, new_pushkeys
        else:
            raise NotificationDispatchException(
                f"Unknown GCM response code {response.code}"
            )

    def _handle_v1_response(
        self,
        log: NotificationLoggerAdapter,
        response: IResponse,
        response_text: str,
        pushkeys: List[str],
        span: Span,
    ) -> Tuple[List[str], List[str]]:
        if 500 <= response.code < 600:
            log.debug("%d from server, waiting to try again", response.code)

            retry_after = None

            for header_value in response.headers.getRawHeaders(
                b"retry-after", default=[]
            ):
                retry_after = int(header_value)
                span.log_kv({"event": "gcm_retry_after", "retry_after": retry_after})

            raise TemporaryNotificationDispatchException(
                "GCM server error, hopefully temporary.", custom_retry_delay=retry_after
            )
        elif response.code == 400:
            log.error("FCM rejected an invalid request (HTTP 400)")
            # permanent failure: give up
            raise NotificationDispatchException("Invalid request")
        elif response.code == 401:
            log.error("FCM authentication failed (HTTP 401)")
            # permanent failure: give up
            raise NotificationDispatchException("Not authorised to push")
        elif response.code == 403:
            log.error("FCM sender mismatch (HTTP 403)")
            # permanent failure: give up
            raise NotificationDispatchException("Sender ID mismatch")
        elif response.code == 429:
            log.debug("%d from server, waiting to try again", response.code)

            # Minimum 1 minute delay required
            retry_after = None

            for header_value in response.headers.getRawHeaders(
                b"retry-after", default=[]
            ):
                retry_after = int(header_value)

            span.log_kv({"event": "gcm_retry_after", "retry_after": retry_after})
            raise NotificationQuotaDispatchException(
                "Message rate quota exceeded.", custom_retry_delay=retry_after
            )
        elif response.code == 404:
            log.info("FCM reports unregistered devices (HTTP 404)")
            return pushkeys, []
        elif 200 <= response.code < 300:
            return [], []
        else:
            raise NotificationDispatchException(
                f"Unknown GCM response code {response.code}"
            )

    async def _get_auth_header(self) -> str:
        """Retrieve the auth header that can be used to authorize requests.

        :return: Needed content of the `Authorization` header
        """
        if self.api_version is APIVersion.Legacy:
            return "key=%s" % (self.api_key,)
        else:
            assert self.credentials is not None
            await self._refresh_credentials()
            return "Bearer %s" % self.credentials.token

    async def _refresh_credentials(self) -> None:
        assert self.credentials is not None
        if not self.credentials.valid:
            await Deferred.fromFuture(
                asyncio.ensure_future(
                    self.credentials.refresh(self.google_auth_request)
                )
            )

    async def _dispatch_notification_unlimited(
        self, n: Notification, device: Device, context: NotificationContext
    ) -> List[str]:
        log = NotificationLoggerAdapter(logger, {"request_id": context.request_id})

        pushkeys: list[str] = []
        if self.api_version is APIVersion.Legacy:
            # `_dispatch_notification_unlimited` gets called once for each device in the
            # `Notification` with a matching app ID. We do something a little dirty and
            # perform all of our dispatches the first time we get called for a
            # `Notification` and do nothing for the rest of the times we get called.
            pushkeys = [
                device.pushkey
                for device in n.devices
                if self.handles_appid(device.app_id)
            ]
            # `pushkeys` ought to never be empty here. At the very least it should contain
            # `device`'s pushkey.

            if pushkeys[0] != device.pushkey:
                # We've already been asked to dispatch for this `Notification` and have
                # previously sent out the notification to all devices.
                return []
        elif self.api_version is APIVersion.V1:
            pushkeys = [device.pushkey]

        # The pushkey is kind of secret because you can use it to send push
        # to someone.
        # span_tags = {"pushkeys": pushkeys}
        span_tags = {"gcm_num_devices": len(pushkeys)}

        with self.sygnal.tracer.start_span(
            "gcm_dispatch", tags=span_tags, child_of=context.opentracing_span
        ) as span_parent:
            # TODO: Implement collapse_key to queue only one message per room.
            failed: List[str] = []

            send_badge_counts = self.get_config("send_badge_counts", bool, True)
            data = GcmPushkin._build_data(
                n, device, self.api_version, send_badge_counts
            )

            # Reject pushkey(s) if default_payload is misconfigured
            if data is None:
                log.warning(
                    "Rejecting pushkey(s) due to misconfigured default_payload, "
                    "please ensure that default_payload is a dict."
                )
                return pushkeys
            elif len(data) == 0:
                log.warning("Discarding notification since it contains no data.")
                return []

            headers = {
                "User-Agent": ["sygnal"],
                "Content-Type": ["application/json"],
            }

            headers["Authorization"] = [await self._get_auth_header()]

            body = self.base_request_body.copy()
            body["data"] = data
            # Liza-specific: ВСЕГДА high-priority для FCM.
            # Synapse шлёт prio=low для обычных сообщений в незашифрованных
            # групповых чатах (httppusher: high только для encrypted / mention /
            # sound-tweak DM). Наши пуши — data-only (FcmSharedIsolate будит
            # isolate → pushHelper рисует уведомление). Normal-priority
            # data-сообщения Android в Doze/фоне задерживает или дропает — у
            # пользователя в фоне пропадают уведомления групповых чатов. Для
            # мессенджера каждое сообщение должно будить устройство, поэтому
            # игнорируем n.prio и форсим high.
            if self.api_version is APIVersion.Legacy:
                body["priority"] = "high"
            elif self.api_version is APIVersion.V1:
                android = body.get("android", {})
                android["priority"] = "high"
                # LABA-1891: гибридный notification-блок для Android.
                # data-only пуш показывает уведомление, только если ОС разбудит
                # наш Flutter-isolate. После долгого простоя Android держит
                # приложение в Doze / restricted App-Standby bucket, исчерпывает
                # квоту high-priority и isolate НЕ будит → баннер не появляется
                # (жалоба: рассылка давно-неактивному клиенту не доходит; форс
                # high-priority этот класс не лечит — квота всё равно режется).
                # С notification-блоком баннер рисует сама система (Play
                # Services), НЕ пробуждая isolate — доходит и в Doze. data
                # остаётся для тап-роутинга и богатого рендера живым процессом.
                # ТОЛЬКО для событий с event_id: counts-only пуш (обновление
                # бейджа после прочтения на другом устройстве) не должен рисовать
                # ложный баннер «Новое сообщение».
                if n.event_id:
                    android["notification"] = {
                        **android.get("notification", {}),
                        **GcmPushkin._build_android_notification(n),
                    }
                body["android"] = android

            if self.api_version is APIVersion.V1:
                body["token"] = device.pushkey
                new_body = body
                body = {}
                body["message"] = new_body

            for retry_number in range(0, MAX_TRIES):
                # This has to happen inside the retry loop since `pushkeys` can be modified in the
                # event of a failure that warrants a retry.
                if self.api_version is APIVersion.Legacy:
                    if len(pushkeys) == 1:
                        body["to"] = pushkeys[0]
                    else:
                        body["registration_ids"] = pushkeys

                try:
                    span_tags = {"retry_num": retry_number}

                    with self.sygnal.tracer.start_span(
                        "gcm_dispatch_try", tags=span_tags, child_of=span_parent
                    ) as span:
                        new_failed, new_pushkeys = await self._request_dispatch(
                            n, log, body, headers, pushkeys, span, attempt=retry_number
                        )
                    pushkeys = new_pushkeys
                    failed += new_failed

                    if len(pushkeys) == 0:
                        break
                except TemporaryNotificationDispatchException as exc:
                    retry_delay = RETRY_DELAY_BASE * (2**retry_number)
                    if exc.custom_retry_delay is not None:
                        retry_delay = exc.custom_retry_delay

                    log.warning(
                        "Temporary failure, will retry in %d seconds",
                        retry_delay,
                    )

                    span_parent.log_kv(
                        {"event": "temporary_fail", "retrying_in": retry_delay}
                    )

                    await twisted_sleep(
                        retry_delay, twisted_reactor=self.sygnal.reactor
                    )
                except NotificationQuotaDispatchException as exc:
                    retry_delay = RETRY_DELAY_BASE_QUOTA_EXCEEDED * (2**retry_number)
                    if exc.custom_retry_delay is not None:
                        retry_delay = exc.custom_retry_delay

                    log.warning(
                        "Quota exceeded, will retry in %d seconds",
                        retry_delay,
                    )

                    span_parent.log_kv(
                        {"event": "temporary_fail", "retrying_in": retry_delay}
                    )

                    await twisted_sleep(
                        retry_delay, twisted_reactor=self.sygnal.reactor
                    )

            if len(pushkeys) > 0:
                for key in pushkeys:
                    PushOutcome(
                        log,
                        "fcm",
                        self.name,
                        key,
                        n.event_id,
                        MAX_TRIES - 1,
                        not n.event_id and not n.type,
                    ).emit("error", "retry_exhausted")
            # Count the number of failed devices.
            span_parent.set_tag("gcm_num_failed", len(failed))
            return failed

    @staticmethod
    def _build_data(
        n: Notification,
        device: Device,
        api_version: APIVersion,
        send_badge_counts: bool,
    ) -> Optional[Dict[str, Any]]:
        """
        Build the payload data to be sent.
        Args:
            n: Notification to build the payload for.
            device: Device information to which the constructed payload
            will be sent.
            api_version: API version used by Firebase/GCM.
            send_badge_counts: If set to `True`, will send the unread and missed_call counts.

        Returns:
            JSON-compatible dict. The dict will be empty if the payload was
            discarded. In this case, the notification should be ignored. Can
            instead be `None` if the `default_payload` is misconfigured.
        """
        data = {}
        overflow_fields = 0

        if device.data:
            default_payload = device.data.get("default_payload", {})
            if isinstance(default_payload, dict):
                data.update(default_payload)
            else:
                logger.warning(
                    "default_payload was misconfigured, this value must be a dict."
                )
                return None

        for attr in [
            "event_id",
            "type",
            "sender",
            "room_name",
            "room_alias",
            "membership",
            "sender_display_name",
            "content",
            "room_id",
        ]:
            if hasattr(n, attr):
                current = getattr(n, attr)
                if current is None:
                    continue
                # Truncate fields to a sensible maximum length. If the whole
                # body is too long, GCM will reject it.
                if current is not None and isinstance(current, str):
                    # The only `attr` that shouldn't be of type `str` is `content`,
                    # which is handled explicitly later on.
                    data[attr], truncated = truncate_str(current, MAX_BYTES_PER_FIELD)
                    if truncated:
                        overflow_fields += 1
                elif attr == "content" and current is not None:
                    data["content"] = current

        if api_version is APIVersion.V1:
            if isinstance(data.get("content"), dict):
                for attr, value in data["content"].items():
                    if not isinstance(value, str):
                        continue
                    value, truncated = truncate_str(value, MAX_BYTES_PER_FIELD)
                    if truncated:
                        overflow_fields += 1
                    data["content_" + attr] = value
                del data["content"]

        data["prio"] = "high"
        if n.prio == "low":
            data["prio"] = "normal"

        counts: Dict[str, Any] = {}
        if send_badge_counts and getattr(n, "counts", None):
            if api_version is APIVersion.Legacy:
                if n.counts.unread:
                    counts["unread"] = n.counts.unread
                if n.counts.missed_calls:
                    counts["missed_calls"] = n.counts.missed_calls
            elif api_version is APIVersion.V1:
                if n.counts.unread:
                    counts["unread"] = str(n.counts.unread)
                if n.counts.missed_calls:
                    counts["missed_calls"] = str(n.counts.missed_calls)

        if not data.get("room_id") and not data.get("event_id") and not counts:
            logger.debug(
                "Notification is badge-only but contains no badge count values. Discarding data. "
                + "If this is not intended, check the `send_badge_counts` parameter in the config."
            )
            return {}

        # Add count data to the payload data
        data.update(counts)

        if overflow_fields > MAX_NOTIFICATION_OVERFLOW_FIELDS:
            logger.warning(
                "Payload contains too many overflowing fields. Notification likely to be rejected by Firebase."
            )

        return data

    @staticmethod
    def _build_android_notification(n: Notification) -> Dict[str, Any]:
        """
        Построить `android.notification` для гибридного FCM-сообщения (LABA-1891).

        Системный баннер, который Play Services рисует БЕЗ пробуждения Flutter-
        isolate — доходит, даже когда приложение давно не открывали и Android
        заморозил его в Doze / App-Standby bucket (где data-only isolate не
        будится, и уведомление молча теряется).

        E2EE-безопасно: `notification.body` уходит в системный трей и логи FCM,
        поэтому НИКОГДА не несёт секретный текст. Для зашифрованного события
        `content.body` отсутствует → обобщённое «Новое сообщение»; расшифрованный
        текст берём строкой, целиком content-dict не сериализуем.
        """
        title = n.room_name or n.sender_display_name or "Liza"
        body = "Новое сообщение"
        if isinstance(n.content, dict):
            # LABA-1970: публикация сторис — в title имя автора (НЕ room_name
            # "Stories - ivan"), в body «опубликовал историю».
            if is_story(n.content):
                title = n.sender_display_name or "Liza"
                body = STORY_PUBLISHED_BODY
            # LABA-2238: у медиа `body` — это имя файла (`recording…ogg`). Для медиа
            # БЕЗ реальной подписи показываем строку-по-типу («🎤 Голосовое
            # сообщение» и т.п.), а не имя файла; с подписью — очищенную подпись.
            # Текст — очищаем от reply-fallback/меншенов. E2EE (нет msgtype/body) →
            # «Новое сообщение».
            elif is_media_msgtype(n.content):
                body = media_caption(n.content) or media_type_label(n.content)
            else:
                raw = n.content.get("body")
                if isinstance(raw, str) and raw.strip():
                    body = clean_message_body(raw)
        title, _ = truncate_str(title, MAX_BYTES_PER_FIELD)
        body, _ = truncate_str(body, MAX_BYTES_PER_FIELD)
        return {
            "title": title,
            "body": body,
            # HIGH-канал клиента. Если его ещё нет (isolate ни разу не
            # запускался на свежей установке), firebase-messaging покажет баннер
            # на fallback-канале — доставка не теряется. Правильный канал/иконку
            # закрепляет meta-data в манифесте следующей сборкой.
            "channel_id": "liza_push",
            "sound": "default",
            "notification_priority": "PRIORITY_HIGH",
            "default_vibrate_timings": True,
            # Один баннер на комнату: новое сообщение заменяет предыдущее — как
            # группировка по room_id в богатом рендере. Плюс якорь для будущего
            # клиентского дедупа (cancel по tag в узком окне «свёрнуто-живо»).
            "tag": n.room_id or "liza",
        }


def truncate_str(input: str, max_bytes: int) -> Tuple[str, bool]:
    """
    Truncate the given string. If the truncation would occur in the middle of a unicode
    character, that character will be removed entirely instead.
    Appends a `…` character to the resulting string when truncation occurs.

    Args:
        `input`: the string to be truncated
        `max_bytes`: maximum length, in bytes, that the payload should occupy when truncated

    Returns:
        Tuple of (truncated string, whether truncation took place)
    """

    str_bytes = input.encode("utf-8")
    if len(str_bytes) <= max_bytes:
        return (input, False)

    try:
        return (str_bytes[: max_bytes - 3].decode("utf-8") + "…", True)
    except UnicodeDecodeError as err:
        return (str_bytes[: err.start].decode("utf-8") + "…", True)
