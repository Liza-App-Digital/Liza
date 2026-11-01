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
