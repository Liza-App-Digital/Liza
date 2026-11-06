"""knock_notify: пуш админам/модераторам о заявке на вступление (knock).

При m.room.member membership=knock («постучаться» в закрытую группу/компанию)
шлёт HTTP-push всем ЛОКАЛЬНЫМ joined-участникам комнаты с PL>=модератора (кроме
самого стучащегося) через module_api.send_http_push_notification — НАПРЯМУЮ в
HttpPusher, минуя event_push_actions. Значит notification_count/бейдж админа НЕ
инфлируется (правка ядра bulk_push_rule_evaluator порождала бы задокументированный
дрейф счётчика, howItWoks/nortifications.md §2.2 — поэтому отвергнута).

Внеядерный модуль вместо форк-правки push-ядра — тот же принцип, что выбран для
event_reports (LABA-2241): не патчить ядро push, когда достаточно ModuleApi.
Откат = убрать модуль из homeserver.yaml.

Охват: группы и компании (space) с join_rule=knock/knock_restricted. Каналы knock
не поддерживают (channel_sync форсит invite) — событие knock там не возникает.

Доступ только через публичный ModuleApi (is_mine, send_http_push_notification,
register_third_party_rules_callbacks) — БД не трогаем; api._hs читает только
общий хелпер synapse_modules._ha (в каком процессе слать пуш).
"""

import logging
from typing import Any

from synapse_modules._ha import register_on_new_event_once
from synapse_modules.knock_notify._logic import (
    MEMBER_EVENT_TYPE,
    POWER_LEVELS_TYPE,
    ROOM_NAME_TYPE,
    build_push_content,
    is_knock_membership,
    knock_reviewers,
)

logger = logging.getLogger(__name__)


class KnockNotifyModule:
    @staticmethod
    def parse_config(config: dict[str, Any]) -> dict[str, Any]:
        return dict(config or {})

    def __init__(self, config: dict[str, Any], api: Any) -> None:
        self._api = api
        # HA: пуш шлёт один процесс инстанса, а не каждый (см. synapse_modules._ha).
        register_on_new_event_once(api, self._on_new_event)

    async def _on_new_event(self, event: Any, state_events: Any) -> None:
        content = dict(getattr(event, "content", {}) or {})
        if not is_knock_membership(getattr(event, "type", None), content):
            return

        knocker = getattr(event, "state_key", None)
        power_levels = self._state_content(state_events, POWER_LEVELS_TYPE)
        members = self._members(state_events)
        reviewers = knock_reviewers(
            members, power_levels, knocker, self._api.is_mine
        )
        if not reviewers:
            return

        push_content = build_push_content(
            event,
            sender_display_name=content.get("displayname"),
            room_name=self._room_name(state_events),
        )
        room_id = getattr(event, "room_id", None)
        logger.info(
            "knock_notify: заявка от %s в %s → пуш %d ревьюер(ам)",
            knocker, room_id, len(reviewers),
        )
        for user_id in reviewers:
            try:
                # device_id=None → все зарегистрированные HTTP-пушеры юзера.
                await self._api.send_http_push_notification(
                    user_id, None, push_content
                )
            except Exception:
                logger.exception(
                    "knock_notify: не удалось отправить пуш %s о заявке в %s",
                    user_id, room_id,
                )

    @staticmethod
    def _state_content(state_events: Any, event_type: str) -> dict | None:
        """content состояния (event_type, "") из карты state_events.

        state_events — StateMap: ключ (type, state_key), значение — событие с
        .content (тот же контракт, что в stories_membership._on_new_event).
        """
        try:
            ev = state_events.get((event_type, ""))
        except Exception:
            return None
        return getattr(ev, "content", None) if ev is not None else None

    @staticmethod
    def _members(state_events: Any) -> list[tuple[str, Any]]:
        """Пары (user_id, membership) из всех m.room.member state-событий.

        Материализуем items() снимком и обрабатываем поэлементно: сбой на ОДНОМ
        элементе (битый ключ/контент, гонка модификации) не должен обрезать
        остаток списка — иначе пуш дойдёт не всем ревьюерам.
        """
        try:
            items = list(state_events.items())
        except Exception:
            return []
        result: list[tuple[str, Any]] = []
        for key, ev in items:
            try:
                t, state_key = key
                if t != MEMBER_EVENT_TYPE:
                    continue
                membership = (getattr(ev, "content", None) or {}).get("membership")
                result.append((state_key, membership))
            except Exception:
                continue
        return result

    def _room_name(self, state_events: Any) -> str | None:
        content = self._state_content(state_events, ROOM_NAME_TYPE)
        name = (content or {}).get("name") if content else None
        return name if isinstance(name, str) and name else None
