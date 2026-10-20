import logging

from synapse_modules.channel_guard._logic import (
    is_channel_creation,
    mark_channel_room_type,
)

logger = logging.getLogger(__name__)


# Канал создаёт любая роль (решение встречи 05.10, задание Надежды 18.10):
# по поверхности злоупотреблений он равен группе, создаётся приватным, права
# внутри держит m.room.power_levels. Модуль только помечает тип для каталога;
# куда канал можно класть внутри компании — решает single_space_guard.
class ChannelGuardModule:
    def __init__(self, config: dict, api) -> None:
        self._api = api
        api.register_third_party_rules_callbacks(
            on_create_room=self._on_create_room,
        )

    @staticmethod
    def parse_config(config: dict) -> dict:
        return config or {}

    async def _on_create_room(
        self, requester, config: dict, is_requester_admin: bool
    ) -> None:
        if not is_channel_creation(config):
            return
        if mark_channel_room_type(config):
            logger.info("channel_guard: каналу проставлен room_type для каталога")
