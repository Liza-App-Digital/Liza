"""Приватный формат исходов провайдера; принятие не доказывает показ баннера."""

import hashlib
import json
from typing import Optional

from sygnal.utils import NotificationLoggerAdapter

REASONS = frozenset(
    {
        "dispatch",
        "accepted",
        "bad_token",
        "unregistered",
        "provider_unavailable",
        "connection_failure",
        "provider_timeout",
        "invalid_request",
        "unauthorized",
        "sender_mismatch",
        "quota_exceeded",
        "bad_message",
        "provider_retry",
        "provider_error",
        "invalid_response",
        "unexpected_error",
        "retry_exhausted",
        "deduplicated",
    }
)


class PushOutcome:
    """Храним только хэши исходных Matrix ID, до преобразований транспорта."""

    def __init__(
        self,
        log: NotificationLoggerAdapter,
        provider: str,
        app_id: str,
        pushkey: str,
        event_id: Optional[str],
        attempt: int,
        clearing: bool,
    ) -> None:
        self.log = log
        self.fields = {
            "provider": provider,
            "app_id": app_id,
            "pushkey_hash": hashlib.sha256(pushkey.encode("utf-8")).hexdigest()[:32],
            "event_hash": (
                hashlib.sha256(event_id.encode("utf-8")).hexdigest()[:32]
                if event_id
                else None
            ),
            "hash_version": "sha256-128",
            "attempt": attempt,
            "clearing": clearing,
        }

    def emit(self, outcome: str, reason: str, status: Optional[int] = None) -> None:
        # Непредвиденный ответ провайдера нельзя превращать в произвольный лог.
        if reason not in REASONS:
            reason = "provider_error"
        self.log.info(
            "PUSH_OUTCOME %s",
            json.dumps(
                {
                    **self.fields,
                    "outcome": outcome,
                    "status": status,
                    "reason": reason,
                },
                separators=(",", ":"),
                sort_keys=True,
            ),
        )


# M6 (спека 2026-11-12-push-sync-industry-alignment): момент отправки пуша Sygnal'ом
# в payload (флаг `sent_timestamp`, мс эпохи). Устройство пишет его в журнал, и
# подтверждение несёт `s` — приёмник считает задержку «отправлено → дошло».
SENT_MS_KEY = "liza_sent_ms"


def _hash128(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()[:32]


def emit_apns_id(
    log: NotificationLoggerAdapter,
    pushkey: str,
    event_id: Optional[str],
    apns_id: str,
    apns_unique_id: Optional[str],
    stable: bool,
    status: Optional[int],
) -> None:
    """Отдельная строка, чтобы набор ключей PUSH_OUTCOME (его читает
    push_fleet_report) не менялся. apns-id — не PII: случайный или UUIDv5
    от токена, обратно не разворачивается."""
    log.info(
        "PUSH_APNS_ID %s",
        json.dumps(
            {
                "pushkey_hash": _hash128(pushkey),
                "event_hash": _hash128(event_id) if event_id else None,
                "hash_version": "sha256-128",
                "apns_id": apns_id,
                "apns_unique_id": apns_unique_id,
                "stable": stable,
                "status": status,
            },
            separators=(",", ":"),
            sort_keys=True,
        ),
    )
