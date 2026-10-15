"""Юнит-тесты чистой логики knock_notify (без Synapse).

ledger:RL-knock-push-to-inviters
Стиль — unittest + прямой вызов (pytest-asyncio в servers/synapse/src нет,
урок из channel_sync/tests).
"""

import unittest

from synapse_modules.knock_notify._logic import (
    MODERATOR_POWER_LEVEL,
    build_push_content,
    is_knock_membership,
    knock_reviewers,
    review_threshold,
    user_power_level,
)


def _local(user_id: str) -> bool:
    """Фейковый is_mine: локальны все @…:local.test."""
    return user_id.endswith(":local.test")


class _Ev:
    def __init__(self, event_id="$knock", room_id="!r:local.test", sender="@x:local.test"):
        self.event_id = event_id
        self.room_id = room_id
        self.sender = sender


class IsKnockMembershipTest(unittest.TestCase):
    def test_true_for_knock(self):
        self.assertTrue(is_knock_membership("m.room.member", {"membership": "knock"}))

    def test_false_for_invite_join_leave(self):
        for m in ("invite", "join", "leave", "ban"):
            self.assertFalse(
                is_knock_membership("m.room.member", {"membership": m}),
                msg=m,
            )

    def test_false_for_non_member_event(self):
        self.assertFalse(
            is_knock_membership("m.room.message", {"membership": "knock"})
        )

    def test_false_for_empty_content(self):
        self.assertFalse(is_knock_membership("m.room.member", None))


class UserPowerLevelTest(unittest.TestCase):
    def test_explicit_user_level(self):
        pl = {"users": {"@a:local.test": 100}, "users_default": 0}
        self.assertEqual(user_power_level("@a:local.test", pl), 100)

    def test_users_default_when_absent(self):
        pl = {"users": {"@a:local.test": 100}, "users_default": 0}
        self.assertEqual(user_power_level("@b:local.test", pl), 0)

    def test_default_zero_when_no_power_levels(self):
        self.assertEqual(user_power_level("@a:local.test", None), 0)


class KnockReviewersTest(unittest.TestCase):
    # invite:50 — как в группах/компаниях Liza (groupPowerLevelOverride).
    PL_GROUP = {
        "users": {
            "@admin:local.test": 100,
            "@mod:local.test": 50,
            "@member:local.test": 0,
        },
        "users_default": 0,
        "invite": 50,
    }

    def test_ac1_admin_and_moderator_are_recipients(self):
        """AC:RL-knock-push-to-inviters/1 — все локальные PL>=50 (admin+mod)."""
        members = [
            ("@admin:local.test", "join"),
            ("@mod:local.test", "join"),
            ("@member:local.test", "join"),
            ("@knocker:local.test", "knock"),
        ]
        got = knock_reviewers(
            members, self.PL_GROUP, "@knocker:local.test", _local
        )
        self.assertEqual(got, ["@admin:local.test", "@mod:local.test"])

    def test_ac2_regular_member_not_recipient(self):
        """AC:RL-knock-push-to-inviters/2 — рядовой PL0 не получает."""
        members = [("@member:local.test", "join")]
        got = knock_reviewers(
            members, self.PL_GROUP, "@knocker:local.test", _local
        )
        self.assertNotIn("@member:local.test", got)
        self.assertEqual(got, [])

    def test_ac3_knocker_excluded_even_if_admin(self):
        """AC:RL-knock-push-to-inviters/3 — сам стучащийся пуш не получает."""
        # Гипотетический админ, который сам постучался (state_key=admin):
        members = [("@admin:local.test", "join")]
        got = knock_reviewers(
            members, self.PL_GROUP, "@admin:local.test", _local
        )
        self.assertEqual(got, [])

    def test_ac4_company_invite_zero_still_gated_by_moderator(self):
        """AC:RL-knock-push-to-inviters/4 — у компании (space) invite:0 не течёт
        всем: гейт по PL>=модератора, рядовой участник не получает."""
        pl_company = {
            "users": {"@owner:local.test": 100, "@member:local.test": 0},
            "users_default": 0,
            "invite": 0,  # space по умолчанию — утечка при гейте на invite
        }
        members = [
            ("@owner:local.test", "join"),
            ("@member:local.test", "join"),
            ("@knocker:local.test", "knock"),
        ]
        got = knock_reviewers(
            members, pl_company, "@knocker:local.test", _local
        )
        self.assertEqual(got, ["@owner:local.test"])

    def test_only_joined_members(self):
        members = [
            ("@admin:local.test", "invite"),  # приглашён, ещё не join
            ("@mod:local.test", "join"),
        ]
        got = knock_reviewers(
            members, self.PL_GROUP, "@knocker:local.test", _local
        )
        self.assertEqual(got, ["@mod:local.test"])

    def test_remote_reviewer_skipped(self):
        """Ревьюер на чужом инстансе не обслуживается этим модулем (is_mine)."""
        members = [
            ("@admin:remote.test", "join"),  # PL из users? нет → users_default 0
            ("@mod:local.test", "join"),
        ]
        pl = dict(self.PL_GROUP)
        pl = {
            "users": {"@admin:remote.test": 100, "@mod:local.test": 50},
            "users_default": 0,
            "invite": 50,
        }
        got = knock_reviewers(members, pl, "@knocker:local.test", _local)
        self.assertEqual(got, ["@mod:local.test"])

    def test_moderator_constant_is_50(self):
        self.assertEqual(MODERATOR_POWER_LEVEL, 50)

    # ledger:RL-space-invite-admin-only
    def test_review_threshold_is_max_of_moderator_and_invite(self):
        """AC:RL-space-invite-admin-only/6 — порог max(50, invite)."""
        self.assertEqual(review_threshold(None), 50)
        self.assertEqual(review_threshold({}), 50)
        self.assertEqual(review_threshold({"invite": 0}), 50)
        self.assertEqual(review_threshold({"invite": 50}), 50)
        self.assertEqual(review_threshold({"invite": 99}), 99)
        self.assertEqual(review_threshold({"invite": "bad"}), 50)

    def test_invite_99_moderator_not_recipient(self):
        """AC:RL-space-invite-admin-only/6 — «приглашают только админы»:
        модератор не может одобрить заявку и пуш не получает; админ получает."""
        pl = {
            "users": {
                "@owner:local.test": 100,
                "@admin:local.test": 99,
                "@mod:local.test": 50,
            },
            "users_default": 0,
            "invite": 99,
        }
        members = [
            ("@owner:local.test", "join"),
            ("@admin:local.test", "join"),
            ("@mod:local.test", "join"),
            ("@knocker:local.test", "knock"),
        ]
        got = knock_reviewers(members, pl, "@knocker:local.test", _local)
        self.assertEqual(got, ["@admin:local.test", "@owner:local.test"])


class BuildPushContentTest(unittest.TestCase):
    def test_carries_event_coords_and_knock(self):
        content = build_push_content(
            _Ev(), sender_display_name="Иван", room_name="Клуб"
        )
        self.assertEqual(content["event_id"], "$knock")
        self.assertEqual(content["room_id"], "!r:local.test")
        self.assertEqual(content["type"], "m.room.member")
        self.assertEqual(content["membership"], "knock")
        self.assertEqual(content["prio"], "high")
        self.assertEqual(content["sender_display_name"], "Иван")
        self.assertEqual(content["room_name"], "Клуб")

    def test_ac5_no_counts_field(self):
        """AC:RL-knock-push-to-inviters/5 — payload не несёт counts: доставка
        мимо event_push_actions, notification_count/бейдж не инфлируется."""
        content = build_push_content(_Ev())
        self.assertNotIn("counts", content)

    def test_optional_names_omitted(self):
        content = build_push_content(_Ev())
        self.assertNotIn("sender_display_name", content)
        self.assertNotIn("room_name", content)


if __name__ == "__main__":
    unittest.main()
