# ledger:RL-channel-discussion-restricted-join
from synapse_modules.channel_sync._logic import (
    POST_REF_KEY,
    join_rules_content,
    build_mirror_content,
    channel_deleted_of,
    discussion_room_of,
    discussion_settings_for,
    edited_event_id,
    is_edit,
    is_membership_leave,
    is_public_channel,
    is_root_post,
    join_rule_of,
    pick_discussion_actor,
    plan_discussion_migration,
    plan_is_noop,
    should_cleanup_mappings,
)

CHAN = "!chan:h"
RESTRICTED = {
    "join_rule": "restricted",
    "allow": [{"type": "m.room_membership", "room_id": CHAN}],
}


def test_is_root_post_true_for_plain_message():
    assert is_root_post("m.room.message", {"body": "hi", "msgtype": "m.text"})


def test_is_root_post_false_for_reply():
    assert not is_root_post(
        "m.room.message",
        {"body": "hi", "m.relates_to": {"m.in_reply_to": {"event_id": "$x"}}},
    )


def test_is_root_post_false_for_edit():
    assert not is_root_post(
        "m.room.message",
        {"body": "*", "m.relates_to": {"rel_type": "m.replace", "event_id": "$x"}},
    )


def test_is_root_post_false_for_non_message():
    assert not is_root_post("m.reaction", {})


def test_is_edit_true():
    assert is_edit({"m.relates_to": {"rel_type": "m.replace", "event_id": "$p"}})


def test_is_edit_false_plain():
    assert not is_edit({"body": "hi"})


def test_edited_event_id():
    assert edited_event_id(
        {"m.relates_to": {"rel_type": "m.replace", "event_id": "$p"}}
    ) == "$p"


def test_discussion_room_of_present():
    assert discussion_room_of({}, {"room_id": "!disc:h"}) == "!disc:h"


def test_discussion_room_of_absent():
    assert discussion_room_of({}, None) is None


def test_build_mirror_content_copies_and_marks():
    src = {"body": "post", "msgtype": "m.text"}
    out = build_mirror_content(src, "!chan:h", "$post")
    assert out["body"] == "post"
    assert out["msgtype"] == "m.text"
    assert out[POST_REF_KEY] == {"channel_id": "!chan:h", "post_event_id": "$post"}
    # исходный не мутируется
    assert POST_REF_KEY not in src


def test_is_public_channel():
    assert is_public_channel("public") is True
    assert is_public_channel("invite") is False
    assert is_public_channel("knock") is False
    assert is_public_channel(None) is False


def test_join_rule_of():
    assert join_rule_of({"join_rule": "public"}) == "public"
    assert join_rule_of({"join_rule": "invite"}) == "invite"
    assert join_rule_of({}) is None
    assert join_rule_of(None) is None


def test_discussion_settings_for_public_channel():
    """Открытый канал: чат читается без членства (peek) и открыт на вход."""
    out = discussion_settings_for("public", CHAN)
    assert out == {
        "join_rule": "public",
        "history_visibility": "world_readable",
    }
    assert join_rules_content(out) == {"join_rule": "public"}


def test_discussion_settings_closed_channel_is_restricted_to_subscribers():
    """AC:RL-channel-discussion-restricted-join/1 — закрытый канал: вход в чат по
    членству в КАНАЛЕ, без инвайта (механика Telegram, Надежда 15.10). Любое
    не-public правило, включая неизвестное, — fail-safe в приватность: чат
    никогда не становится public."""
    for rule in ("invite", "knock", "restricted", "knock_restricted", None, "weird"):
        out = discussion_settings_for(rule, CHAN)
        assert out == {**RESTRICTED, "history_visibility": "shared"}, rule
        assert join_rules_content(out) == RESTRICTED, rule


def test_is_membership_leave_true_for_leave_and_ban():
    """Отписка и бан одинаково лишают доступа к комментариям."""
    assert is_membership_leave("m.room.member", {"membership": "leave"}) is True
    assert is_membership_leave("m.room.member", {"membership": "ban"}) is True


def test_is_membership_leave_false_for_other_memberships():
    assert is_membership_leave("m.room.member", {"membership": "join"}) is False
    assert is_membership_leave("m.room.member", {"membership": "invite"}) is False
    assert is_membership_leave("m.room.member", {"membership": "knock"}) is False
    assert is_membership_leave("m.room.member", {}) is False


def test_is_membership_leave_false_for_non_member_event():
    assert is_membership_leave("m.room.message", {"membership": "leave"}) is False


def _migrated_public_snapshot(**overrides):
    """Уже мигрированный ОТКРЫТЫЙ канал: план по нему обязан быть пустым."""
    snapshot = {
        "channel_id": CHAN,
        "channel_join_rule": "public",
        "discussion_join_rules": {"join_rule": "public"},
        "discussion_history_visibility": "world_readable",
        "discussion_hidden": True,
    }
    snapshot.update(overrides)
    return snapshot


def _migrated_private_snapshot(**overrides):
    """Уже мигрированный ЗАКРЫТЫЙ канал: чат restricted по членству в канале."""
    snapshot = {
        "channel_id": CHAN,
        "channel_join_rule": "invite",
        "discussion_join_rules": dict(RESTRICTED),
        "discussion_history_visibility": "shared",
        "discussion_hidden": True,
    }
    snapshot.update(overrides)
    return snapshot


def test_plan_migration_noop_when_public_channel_already_correct():
    plan = plan_discussion_migration(_migrated_public_snapshot())
    assert plan == {
        "set_join_rules": None,
        "set_history_visibility": None,
        "set_hidden": False,
    }
    assert plan_is_noop(plan) is True


def test_plan_migration_noop_when_private_channel_already_correct():
    """AC:RL-channel-discussion-restricted-join/2 — повторный прогон ничего не пишет."""
    assert plan_is_noop(plan_discussion_migration(_migrated_private_snapshot())) is True


def test_plan_migration_legacy_public_channel_opens_chat():
    """Чат создан клиентом как privateChat — открытый канал должен его открыть."""
    plan = plan_discussion_migration(
        _migrated_public_snapshot(
            discussion_join_rules={"join_rule": "invite"},
            discussion_history_visibility="shared",
            discussion_hidden=None,
        )
    )
    assert plan["set_join_rules"] == {"join_rule": "public"}
    assert plan["set_history_visibility"] == "world_readable"
    assert plan["set_hidden"] is True


def test_plan_migration_closed_channel_cases():
    """AC:RL-channel-discussion-restricted-join/2 — ∀ состояние чата закрытого
    канала план приводит его к restricted с allow ровно на этот канал."""
    cases = {
        "invite-чат (старая модель)": {"join_rule": "invite"},
        "restricted без allow": {"join_rule": "restricted"},
        "restricted на чужую комнату": {
            "join_rule": "restricted",
            "allow": [{"type": "m.room_membership", "room_id": "!other:h"}],
        },
        "public (был открытым каналом)": {"join_rule": "public"},
        "нет события": {},
    }
    for name, rules in cases.items():
        plan = plan_discussion_migration(
            _migrated_private_snapshot(discussion_join_rules=rules)
        )
        assert plan["set_join_rules"] == RESTRICTED, name
        assert plan_is_noop(plan) is False, name


def test_plan_migration_closed_to_open_channel():
    """AC:RL-channel-discussion-restricted-join/2 — канал открыли: чат public."""
    plan = plan_discussion_migration(
        _migrated_private_snapshot(channel_join_rule="public")
    )
    assert plan["set_join_rules"] == {"join_rule": "public"}
    assert plan["set_history_visibility"] == "world_readable"


def test_plan_migration_ignores_extra_allow_on_public():
    """Хвост allow у public-чата не порождает вечной перезаписи."""
    plan = plan_discussion_migration(
        _migrated_public_snapshot(
            discussion_join_rules={"join_rule": "public", "allow": []}
        )
    )
    assert plan["set_join_rules"] is None


def test_plan_migration_explicit_hidden_false_is_rewritten():
    """hidden=false (а не отсутствие state) тоже приводим к hidden=true.

    Ловит подмену `is not True` на `is None`: при ней явный false остался бы.
    """
    plan = plan_discussion_migration(_migrated_public_snapshot(discussion_hidden=False))
    assert plan["set_hidden"] is True
    assert plan_is_noop(plan) is False


def test_plan_is_noop_false_for_each_field():
    """Каждое поле плана в одиночку обязано делать его не-пустым."""
    for field, value in (
        ("set_join_rules", {"join_rule": "public"}),
        ("set_history_visibility", "shared"),
        ("set_hidden", True),
    ):
        plan = {
            "set_join_rules": None,
            "set_history_visibility": None,
            "set_hidden": False,
            field: value,
        }
        assert plan_is_noop(plan) is False, field


class TestPickDiscussionActor:
    """AC:RL-channel-discussion-restricted-join/5 — уход создателя чата не
    обрывает работу модуля: пишет свой участник с наибольшим PL."""

    PL = {"users": {"@owner:h": 100, "@mod:h": 50, "@b:h": 50}, "users_default": 0}

    def test_создатель_в_чате(self):
        assert pick_discussion_actor("@owner:h", ["@a:h", "@owner:h"], self.PL) == "@owner:h"

    def test_создатель_ушёл_берём_наибольший_pl(self):
        assert pick_discussion_actor("@owner:h", ["@a:h", "@mod:h"], self.PL) == "@mod:h"

    def test_равные_pl_первый_по_mxid(self):
        assert pick_discussion_actor("@owner:h", ["@mod:h", "@b:h"], self.PL) == "@b:h"
        pl = {"users": {"@ab:h": 50, "@a:h": 50}}
        assert pick_discussion_actor("@x:h", ["@ab:h", "@a:h"], pl) == "@a:h"

    def test_свои_без_прав_никого(self):
        """Рядовой (PL < 50) не исполнитель: его запись упала бы 403 молча."""
        assert pick_discussion_actor("@owner:h", ["@a:h"], self.PL) is None
        assert pick_discussion_actor("@x:h", ["@ab:h", "@a:h"], None) is None

    def test_своих_в_чате_нет_остаётся_создатель(self):
        assert pick_discussion_actor("@owner:h", [], self.PL) == "@owner:h"


# Спек 2026-07-30 §3.2. Отвязка чата НЕ должна стирать связь пост→зеркало:
# группа-обсуждение переживает отвязку целиком и возвращается при
# повторной привязке. Чистим только при реальном удалении канала.
class TestShouldCleanupMappings:
    def test_отвязка_не_чистит_маппинги(self):
        assert not should_cleanup_mappings(
            prev_room="!disc:h", new_room=None, channel_deleted=False
        )

    def test_удаление_канала_чистит(self):
        assert should_cleanup_mappings(
            prev_room="!disc:h", new_room=None, channel_deleted=True
        )

    def test_перепривязка_на_другой_чат_чистит_старый(self):
        assert should_cleanup_mappings(
            prev_room="!old:h", new_room="!new:h", channel_deleted=False
        )

    def test_идемпотентная_перезапись_тем_же_чатом_не_чистит(self):
        assert not should_cleanup_mappings(
            prev_room="!disc:h", new_room="!disc:h", channel_deleted=False
        )

    def test_первая_привязка_нечего_чистить(self):
        assert not should_cleanup_mappings(
            prev_room=None, new_room="!disc:h", channel_deleted=False
        )

    def test_удаление_без_прошлой_привязки_нечего_чистить(self):
        """Канал без комментариев: удалять маппинги не от чего."""
        assert not should_cleanup_mappings(
            prev_room=None, new_room=None, channel_deleted=True
        )

    def test_удаление_чистит_даже_при_том_же_room_id(self):
        """Маркер удаления сильнее правила идемпотентной перезаписи."""
        assert should_cleanup_mappings(
            prev_room="!disc:h", new_room="!disc:h", channel_deleted=True
        )


# Маркер удаления канала. В Matrix нет события «комната удалена», поэтому
# клиент помечает удаление ЯВНО в content com.liza.channel.discussion —
# иначе сервер не отличает удаление от выключения комментариев.
class TestChannelDeletedOf:
    def test_маркер_удаления_распознан(self):
        assert channel_deleted_of({"deleted": True})

    def test_обычная_отвязка_не_удаление(self):
        assert not channel_deleted_of({})

    def test_привязка_чата_не_удаление(self):
        assert not channel_deleted_of({"room_id": "!disc:h"})

    def test_отсутствующий_content_не_удаление(self):
        assert not channel_deleted_of(None)

    def test_маркер_удаления_не_прячет_чат_от_сервера(self):
        """Инвариант порядка: маркер несёт room_id и НЕ делает чат ненаходимым.

        На этом держится кик подписчиков из чата обсуждения при удалении
        канала: кики обрабатываются фоново и часть из них читает привязку уже
        после маркера. Верни сюда None — и подписчики останутся членами чата
        обсуждения (см. ChannelLeaveKickTest
        .test_kick_works_after_deletion_marker_landed).
        """
        marker = {"room_id": "!disc:h", "deleted": True}
        assert discussion_room_of({}, marker) == "!disc:h"
        assert channel_deleted_of(marker)

    def test_нестрогая_истина_не_считается_маркером(self):
        """Только литеральный true: строка/1 из чужого клиента — не сигнал
        на необратимое удаление данных."""
        for value in ("true", 1, "1", "yes"):
            assert not channel_deleted_of({"deleted": value}), value
