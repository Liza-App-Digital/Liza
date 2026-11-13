"""Память об уже принятых провайдером пушах (Р2 спеки 2026-11-12).

Synapse повторяет запрос после любого не-2xx, в том числе когда Envoy оборвал
его по таймауту, а Sygnal уже успел отдать пуш в APNs/FCM. Без этой памяти
пользователь получает второй звук на то же сообщение.
"""

from collections import OrderedDict
from typing import Callable, Optional, Tuple

from sygnal.notifications import Device, Notification

SENT_CACHE_TTL_SECONDS = 600
SENT_CACHE_MAX_ENTRIES = 50_000

Key = Tuple[str, str, str]


def client_name_of(device: Device) -> Optional[str]:
    payload = (device.data or {}).get("default_payload")
    if not isinstance(payload, dict):
        return None
    name = payload.get("client_name")
    return name if isinstance(name, str) and name else None


class SentCache:
    def __init__(self, ttl: float, clock: Callable[[], float]) -> None:
        self.ttl = ttl
        self.clock = clock
        self._entries: "OrderedDict[Key, float]" = OrderedDict()

    def key(self, n: Notification, device: Device) -> Optional[Key]:
        # Без client_name один токен у двух аккаунтов дал бы ложный дубль,
        # а пуши без event_id (счётчики, снятие) повторять обязательно.
        client_name = client_name_of(device)
        if self.ttl <= 0 or not n.event_id or client_name is None:
            return None
        return (device.pushkey, client_name, n.event_id)

    def seen(self, key: Optional[Key]) -> bool:
        if key is None:
            return False
        expires = self._entries.get(key)
        if expires is None:
            return False
        if expires <= self.clock():
            del self._entries[key]
            return False
        return True

    def remember(self, key: Optional[Key]) -> None:
        if key is None:
            return
        self._entries[key] = self.clock() + self.ttl
        self._entries.move_to_end(key)
        while len(self._entries) > SENT_CACHE_MAX_ENTRIES:
            self._entries.popitem(last=False)
