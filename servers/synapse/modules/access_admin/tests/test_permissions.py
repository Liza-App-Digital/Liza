"""Тесты матрицы прав access_admin."""

import asyncio
import unittest

from synapse_modules.access_admin._permissions import PermissionChecker

SERVER = "liza.example"


def _run(coro):
    return asyncio.run(coro)


class _FakeAccountData:
    def __init__(self, roles: dict[str, str]):
        self._roles = roles

    async def get_global(self, user_id: str, type_: str):
        role = self._roles.get(user_id)
        return None if role is None else {"role": role}


class _FakeSpaces:
    def __init__(
        self,
        powers: dict[tuple[str, str], list[int]] = None,
        room_powers: dict[tuple[str, str], int] = None,
    ):
        self._powers = powers or {}
        self._room_powers = room_powers or {}

    async def shared_space_power_pairs(self, caller_id: str, target_id: str):
        # Короткая запись [100] = PL вызывающего, цель — обычный участник (0).
        return [
            p if isinstance(p, tuple) else (p, 0)
            for p in self._powers.get((caller_id, target_id), [])
        ]

    async def power_in_room(self, user_id: str, room_id: str) -> int:
        return self._room_powers.get((user_id, room_id), 0)


def _checker(roles=None, powers=None, server_admins=None, room_powers=None):
    admins = set(server_admins or ())

    async def _is_server_admin(user_id: str) -> bool:
        return user_id in admins

    return PermissionChecker(
        account_data=_FakeAccountData(roles or {}),
        spaces_lookup=_FakeSpaces(powers, room_powers),
        server_name=SERVER,
        is_server_admin=_is_server_admin,
    )


class MayViewTestCase(unittest.TestCase):
    def test_server_admin_by_role_may_view(self):
        c = _checker(roles={"@boss:liza.example": "admin"})
        self.assertTrue(
            _run(c.may_view("@boss:liza.example", "@u:liza.example"))
        )

    def test_space_admin_may_view(self):
        c = _checker(powers={("@boss:liza.example", "@u:liza.example"): [100]})
        self.assertTrue(
            _run(c.may_view("@boss:liza.example", "@u:liza.example"))
        )

    def test_moderator_may_not_view(self):
        c = _checker(powers={("@mod:liza.example", "@u:liza.example"): [50]})
        self.assertFalse(
            _run(c.may_view("@mod:liza.example", "@u:liza.example"))
        )

    def test_plain_user_may_not_view(self):
        c = _checker(roles={"@u:liza.example": "user"})
        self.assertFalse(
            _run(c.may_view("@u:liza.example", "@other:liza.example"))
        )

    def test_admin_in_unrelated_space_may_not_view(self):
        """PL 100 в чужом пространстве не даёт прав: список пуст."""
        c = _checker(powers={("@boss:liza.example", "@other:liza.example"): []})
        self.assertFalse(
            _run(c.may_view("@boss:liza.example", "@other:liza.example"))
        )

    def test_server_admin_flag_without_role_may_view(self):
        """users.admin=1 в Synapse, но роль в каталоге НЕ admin (прод-кейс)."""
        c = _checker(
            roles={"@admin:liza.example": "user"},
            server_admins={"@admin:liza.example"},
        )
        self.assertTrue(
            _run(c.may_view("@admin:liza.example", "@u:liza.example"))
        )

    def test_server_admin_flag_without_any_role_entry_may_view(self):
        c = _checker(server_admins={"@admin:liza.example"})
        self.assertTrue(
            _run(c.may_view("@admin:liza.example", "@u:liza.example"))
        )

    def test_no_shared_space_with_federated_target_may_not_view(self):
        """Страховка после Task 4: is_local_room больше не фильтрует по
        домену, поэтому shared_space_power_pairs теперь способен вернуть
        пространства и с федеративным участием. Но право по-прежнему
        держится на ФАКТЕ общего пространства — если у вызывающего и
        федеративной цели общих пространств нет, доступа быть не должно.
        """
        c = _checker(powers={("@boss:liza.example", "@ivan:other.example"): []})
        self.assertFalse(
            _run(c.may_view("@boss:liza.example", "@ivan:other.example"))
        )


class MayDeactivateTestCase(unittest.TestCase):
    def test_server_admin_may_deactivate_local(self):
        c = _checker(roles={"@boss:liza.example": "admin"})
        allowed, reason = _run(
            c.may_deactivate("@boss:liza.example", "@u:liza.example")
        )
        self.assertTrue(allowed)
        self.assertIsNone(reason)

    def test_space_admin_may_deactivate_local(self):
        c = _checker(powers={("@boss:liza.example", "@u:liza.example"): [100]})
        allowed, reason = _run(
            c.may_deactivate("@boss:liza.example", "@u:liza.example")
        )
        self.assertTrue(allowed)
        self.assertIsNone(reason)

    def test_cannot_deactivate_self(self):
        c = _checker(roles={"@boss:liza.example": "admin"})
        allowed, reason = _run(
            c.may_deactivate("@boss:liza.example", "@boss:liza.example")
        )
        self.assertFalse(allowed)
        self.assertEqual(reason, "self")

    def test_cannot_deactivate_foreign_server_account(self):
        c = _checker(roles={"@boss:liza.example": "admin"})
        allowed, reason = _run(
            c.may_deactivate("@boss:liza.example", "@u:other.example")
        )
        self.assertFalse(allowed)
        self.assertEqual(reason, "foreign_server")

    def test_plain_user_forbidden(self):
        c = _checker()
        allowed, reason = _run(
            c.may_deactivate("@u:liza.example", "@other:liza.example")
        )
        self.assertFalse(allowed)
        self.assertEqual(reason, "forbidden")

    def test_self_check_precedes_permission_check(self):
        """Обычный юзер на самом себе получает 'self', не 'forbidden'."""
        c = _checker()
        allowed, reason = _run(
            c.may_deactivate("@u:liza.example", "@u:liza.example")
        )
        self.assertFalse(allowed)
        self.assertEqual(reason, "self")

    def test_server_admin_flag_may_deactivate_without_role_or_pl(self):
        c = _checker(
            roles={"@admin:liza.example": "user"},
            server_admins={"@admin:liza.example"},
        )
        allowed, reason = _run(
            c.may_deactivate("@admin:liza.example", "@u:liza.example")
        )
        self.assertTrue(allowed)
        self.assertIsNone(reason)


class OwnerModelTestCase(unittest.TestCase):
    """ledger:RL-room-owner-transfer — владелец 100, админ 99 (механика ВК).

    Red-proof: ADMIN_POWER_LEVEL = 100 → падают test_admin_99_*; убрать
    условие `target < caller` → падают test_admin_cannot_deactivate_*;
    убрать вето «цель ≥ вызывающего хоть в одном общем пространстве» (ревью
    2026-10-14) → падают *_via_other_space и owner_in_one_space_protected.
    """

    BOSS = "@boss:liza.example"
    U = "@u:liza.example"

    def _deactivate(self, pairs):
        c = _checker(powers={(self.BOSS, self.U): pairs})
        return _run(c.may_deactivate(self.BOSS, self.U))

    def test_admin_99_may_view(self):
        """AC:RL-room-owner-transfer/9 — новый админ компании видит досье."""
        c = _checker(powers={(self.BOSS, self.U): [(99, 100)]})
        self.assertTrue(_run(c.may_view(self.BOSS, self.U)))

    def test_98_may_not_view(self):
        c = _checker(powers={(self.BOSS, self.U): [98]})
        self.assertFalse(_run(c.may_view(self.BOSS, self.U)))

    def test_admin_99_may_deactivate_below(self):
        for target in (0, 50, 98):
            self.assertEqual(self._deactivate([(99, target)]), (True, None))

    def test_admin_cannot_deactivate_owner_or_admin(self):
        """AC:RL-room-owner-transfer/9 — ∀ цель ∈ {владелец 100, админ 99}."""
        for target in (99, 100):
            self.assertEqual(
                self._deactivate([(99, target)]), (False, "forbidden"), target
            )

    def test_owner_may_deactivate_admin(self):
        self.assertEqual(self._deactivate([(100, 99)]), (True, None))

    def test_legacy_co_owners_still_equal_as_before(self):
        """Старая компания с двумя 100: как до роли «владелец»."""
        self.assertEqual(self._deactivate([(100, 100)]), (True, None))

    def test_owner_in_one_space_protected_from_owner_of_another(self):
        """Цель — владелец X (там вызывающий админ 99), вызывающий — владелец
        Y. Деактивация глобальна: владелец X вне власти вызывающего."""
        self.assertEqual(
            self._deactivate([(99, 100), (100, 99)]), (False, "forbidden")
        )

    def test_admin_cannot_deactivate_owner_via_other_space(self):
        """AC:RL-room-owner-transfer/13 — владелец 100 в X и рядовой (0) в Y,
        вызывающий админ 99 в обоих: ∀ порядок пространств → отказ."""
        for pairs in ([(99, 100), (99, 0)], [(99, 0), (99, 100)]):
            self.assertEqual(self._deactivate(pairs), (False, "forbidden"), pairs)

    def test_admin_cannot_deactivate_admin_via_other_space(self):
        """AC:RL-room-owner-transfer/13 — равный админ 99 в X, 50 в Y."""
        self.assertEqual(
            self._deactivate([(99, 99), (99, 50)]), (False, "forbidden")
        )

    def test_legit_cases_still_allowed_across_spaces(self):
        """AC:RL-room-owner-transfer/13 — легитимное не сломано: владелец над
        админом/рядовым, админ над рядовым/модератором в нескольких общих
        пространствах, в т.ч. где оба рядовые."""
        for pairs in (
            [(100, 99), (100, 0)],
            [(100, 0), (0, 0)],
            [(99, 0), (99, 50)],
            [(99, 0), (0, 0)],
            [(99, 0), (0, 50)],
            [(100, 100), (100, 0)],
        ):
            self.assertEqual(self._deactivate(pairs), (True, None), pairs)

    def test_moderator_never(self):
        self.assertEqual(self._deactivate([(50, 0)]), (False, "forbidden"))

    def test_server_admin_unaffected_by_target_level(self):
        c = _checker(
            server_admins={self.BOSS}, powers={(self.BOSS, self.U): [(0, 100)]}
        )
        self.assertEqual(_run(c.may_deactivate(self.BOSS, self.U)), (True, None))


class MayViewSpaceTestCase(unittest.TestCase):
    """Порог модератора (PL>=50) — иначе список участников пространства
    "ломается" для роли, которой клиент его показывает (chat_topology.dart
    canSeeMembersAt: moderatorPowerLevel), см. согласование Task 6."""

    SPACE = "!space:liza.example"

    def test_pl_100_in_space_may_view(self):
        c = _checker(room_powers={("@boss:liza.example", self.SPACE): 100})
        self.assertTrue(_run(c.may_view_space("@boss:liza.example", self.SPACE)))

    def test_pl_50_in_space_may_view(self):
        """Граница — главный кейс правки: модератор, не только админ."""
        c = _checker(room_powers={("@mod:liza.example", self.SPACE): 50})
        self.assertTrue(_run(c.may_view_space("@mod:liza.example", self.SPACE)))

    def test_pl_49_in_space_may_not_view(self):
        c = _checker(room_powers={("@u:liza.example", self.SPACE): 49})
        self.assertFalse(_run(c.may_view_space("@u:liza.example", self.SPACE)))

    def test_pl_0_or_not_member_may_not_view(self):
        c = _checker()
        self.assertFalse(_run(c.may_view_space("@u:liza.example", self.SPACE)))

    def test_server_admin_may_view_without_pl(self):
        c = _checker(server_admins={"@admin:liza.example"})
        self.assertTrue(
            _run(c.may_view_space("@admin:liza.example", self.SPACE))
        )

    def test_admin_role_may_view_without_pl(self):
        c = _checker(roles={"@boss:liza.example": "admin"})
        self.assertTrue(_run(c.may_view_space("@boss:liza.example", self.SPACE)))


if __name__ == "__main__":
    unittest.main()
