"""Проверка прав вызывающего для операций управления доступами.

Право даёт: серверный admin-флаг Synapse (``users.admin``), либо роль admin
в каталоге user_roles, либо PL>=99 (админ) в пространстве, где состоит целевой
пользователь. Деактивация через пространство — по механике ВК: владелец (100)
над любым, админ (99) только над теми, кто ниже его. Проверка живёт на сервере: клиент прячет UI для удобства, но
скрытая кнопка — не защита.
"""

from collections.abc import Awaitable, Callable, Mapping

from ._logic import ADMIN_POWER_LEVEL, MODERATOR_POWER_LEVEL, OWNER_POWER_LEVEL

ROLE_ACCOUNT_DATA = "com.liza.user_role"
ROLE_ADMIN = "admin"

IsServerAdmin = Callable[[str], Awaitable[bool]]


class PermissionChecker:
    def __init__(
        self,
        account_data,
        spaces_lookup,
        server_name: str,
        is_server_admin: IsServerAdmin,
    ) -> None:
        self._account_data = account_data
        self._spaces = spaces_lookup
        self._server_name = server_name
        self._is_server_admin = is_server_admin

    async def _has_admin_role(self, user_id: str) -> bool:
        data = await self._account_data.get_global(user_id, ROLE_ACCOUNT_DATA)
        # get_global возвращает immutabledict, не dict — проверяем Mapping.
        role = data.get("role") if isinstance(data, Mapping) else None
        return role == ROLE_ADMIN

    async def _is_space_admin_over(self, caller_id: str, target_id: str) -> bool:
        pairs = await self._spaces.shared_space_power_pairs(caller_id, target_id)
        return any(caller >= ADMIN_POWER_LEVEL for caller, _target in pairs)

    async def _may_manage_in_space(self, caller_id: str, target_id: str) -> bool:
        """Право на ДЕЙСТВИЕ над пользователем через общие пространства.

        Владелец (100) — над любым, в т.ч. над со-владельцем 100 в старых
        компаниях (как было до роли «владелец»). Админ (99) — только над
        теми, кто строго ниже: админ не деактивирует владельца и другого
        админа, как и протокол Matrix не даёт ему их исключить.

        Деактивация ГЛОБАЛЬНА (аккаунт целиком), поэтому одного «удобного»
        пространства мало: если хоть в одном общем пространстве цель —
        админ/владелец на уровне вызывающего или выше, а вызывающий там не
        владелец, — отказ. Иначе админ-99 деактивировал бы владельца 100
        компании X через пространство Y, где тот рядовой.
        """
        pairs = await self._spaces.shared_space_power_pairs(caller_id, target_id)
        if any(
            target >= ADMIN_POWER_LEVEL
            and target >= caller
            and caller < OWNER_POWER_LEVEL
            for caller, target in pairs
        ):
            return False
        return any(
            caller >= OWNER_POWER_LEVEL
            or (caller >= ADMIN_POWER_LEVEL and target < caller)
            for caller, target in pairs
        )

    async def may_view(self, caller_id: str, target_id: str) -> bool:
        if await self._is_server_admin(caller_id):
            return True
        if await self._has_admin_role(caller_id):
            return True
        return await self._is_space_admin_over(caller_id, target_id)

    async def may_view_space(self, caller_id: str, space_id: str) -> bool:
        """Право на список участников ПРОСТРАНСТВА (не пользователя).

        Порог — модератор (PL>=50), не админ: список участников space
        клиент показывает уже модератору (chat_topology.dart
        canSeeMembersAt), а не только тому, кто может им управлять.
        """
        if await self._is_server_admin(caller_id):
            return True
        if await self._has_admin_role(caller_id):
            return True
        power = await self._spaces.power_in_room(caller_id, space_id)
        return power >= MODERATOR_POWER_LEVEL

    async def may_deactivate(
        self, caller_id: str, target_id: str
    ) -> tuple[bool, str | None]:
        if caller_id == target_id:
            return False, "self"
        if not target_id.endswith(":" + self._server_name):
            return False, "foreign_server"
        if await self._is_server_admin(caller_id):
            return True, None
        if await self._has_admin_role(caller_id):
            return True, None
        if await self._may_manage_in_space(caller_id, target_id):
            return True, None
        return False, "forbidden"
