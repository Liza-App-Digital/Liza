"""Pure-logic tests for single_space_guard predicates (no HomeServer)."""

import importlib.util
from pathlib import Path

# Загружаем _guard.py напрямую по пути, без триггера package __init__
# (тот импортирует synapse.module_api, недоступный без живого HS).
_guard_path = Path(__file__).resolve().parent.parent / "_guard.py"
_spec = importlib.util.spec_from_file_location("ssg_guard", _guard_path)
guard = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(guard)


class TestIsRootSpaceCreation:
    def test_space_without_parent_is_root(self):
        config = {"creation_content": {"type": "m.space"}}
        assert guard.is_root_space_creation(config) is True

    def test_plain_room_is_not_root(self):
        config = {"creation_content": {}}
        assert guard.is_root_space_creation(config) is False

    def test_space_with_parent_in_initial_state_is_not_root(self):
        config = {
            "creation_content": {"type": "m.space"},
            "initial_state": [
                {"type": "m.space.parent", "state_key": "!parent:hs", "content": {}}
            ],
        }
        assert guard.is_root_space_creation(config) is False

    def test_missing_creation_content_is_not_root(self):
        assert guard.is_root_space_creation({}) is False

    # Контракт с клиентом (LABA-2532). Тела ниже — литералы того, что реально
    # шлёт Flutter-клиент; их зеркало — clients/flutter/test/utils/
    # create_subspace_test.dart (AC-1/2) и new_group.dart::_createSpace.
    # Расходятся клиент и предикат — краснеет одна из двух сторон.
    # ledger:RL-subspace-create-with-parent

    def test_client_subspace_body_is_not_root(self):
        # AC:RL-subspace-create-with-parent/6 — тело createSubspace():
        # подпространство с родителем в initial_state гард пропускает.
        config = {
            "name": "Отдел",
            "visibility": "private",
            "creation_content": {"type": "m.space"},
            "power_level_content_override": {"events_default": 100, "invite": 99},
            "initial_state": [
                {
                    "type": "m.space.parent",
                    "state_key": "!company:example.invalid",
                    "content": {"via": ["example.invalid"]},
                }
            ],
        }
        assert guard.is_root_space_creation(config) is False

    def test_client_company_body_is_root(self):
        # AC:RL-subspace-create-with-parent/4 — тело _createSpace() экрана
        # «Создать компанию» (/rooms/newspace): initial_state без
        # m.space.parent → это root-space, и второй такой гард обязан резать.
        # Если сюда когда-нибудь попадёт m.space.parent — гард ослепнет.
        config = {
            "preset": "private_chat",
            "creation_content": {"type": "m.space"},
            "visibility": "private",
            "name": "Компания 1",
            "power_level_content_override": {"events_default": 100, "invite": 99},
            "initial_state": [
                {"type": "m.room.avatar", "content": {"url": "mxc://hs/avatar"}},
                {"type": "m.room.join_rules", "content": {"join_rule": "invite"}},
            ],
        }
        assert guard.is_root_space_creation(config) is True


class TestIsMainSpaceLeave:
    def test_leave_of_main_space_matches(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.member",
            membership="leave",
            room_id="!main:hs",
            main_root_space_id="!main:hs",
        ) is True

    def test_ban_of_main_space_matches(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.member",
            membership="ban",
            room_id="!main:hs",
            main_root_space_id="!main:hs",
        ) is True

    def test_leave_of_other_space_does_not_match(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.member",
            membership="leave",
            room_id="!other:hs",
            main_root_space_id="!main:hs",
        ) is False

    def test_join_of_main_space_does_not_match(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.member",
            membership="join",
            room_id="!main:hs",
            main_root_space_id="!main:hs",
        ) is False

    def test_non_member_event_does_not_match(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.message",
            membership=None,
            room_id="!main:hs",
            main_root_space_id="!main:hs",
        ) is False

    def test_no_main_space_yet_does_not_match(self):
        assert guard.is_protected_membership_change(
            event_type="m.room.member",
            membership="leave",
            room_id="!main:hs",
            main_root_space_id=None,
        ) is False


class TestDeduplicateCompanies:
    def test_no_duplicates_unchanged(self):
        companies = [
            {"room_id": "!a:hs", "name": "Acme"},
            {"room_id": "!b:hs", "name": "Beta"},
        ]
        result = guard.deduplicate_companies(companies)
        assert [c["room_id"] for c in result] == ["!a:hs", "!b:hs"]

    def test_duplicate_removed_first_kept(self):
        companies = [
            {"room_id": "!a:hs", "name": "Acme"},
            {"room_id": "!b:hs", "name": "Beta"},
            {"room_id": "!a:hs", "name": "Acme duplicate"},
        ]
        result = guard.deduplicate_companies(companies)
        assert len(result) == 2
        assert result[0]["name"] == "Acme"
        assert result[1]["room_id"] == "!b:hs"

    def test_empty_list(self):
        assert guard.deduplicate_companies([]) == []

    def test_skips_entries_without_room_id(self):
        companies = [{"name": "No ID"}, {"room_id": "!a:hs", "name": "Valid"}]
        result = guard.deduplicate_companies(companies)
        assert len(result) == 1
        assert result[0]["room_id"] == "!a:hs"


class TestIsSpaceChunk:
    def test_space_chunk_is_space(self):
        chunk = {"room_type": "m.space", "room_id": "!a:hs", "name": "Acme"}
        assert guard.is_space_chunk(chunk) is True

    def test_plain_room_chunk_is_not_space(self):
        chunk = {"room_id": "!b:hs", "name": "General"}
        assert guard.is_space_chunk(chunk) is False

    def test_matches_query_case_insensitive(self):
        assert guard.matches_query("Cyber Agro", "agro") is True
        assert guard.matches_query("Cyber Agro", "AGRO") is True
        assert guard.matches_query("Cyber Agro", "xyz") is False

    def test_empty_query_matches_all(self):
        assert guard.matches_query("Anything", "") is True
        assert guard.matches_query("Anything", None) is True

    def test_matches_query_handles_none_name(self):
        assert guard.matches_query(None, "agro") is False
        assert guard.matches_query(None, "") is True

    def test_matches_query_normalizes_dashes(self):
        # длинное тире (U+2013) в имени vs обычный дефис в запросе
        assert guard.matches_query("Кибер–Агро", "Кибер-Агро") is True
        assert guard.matches_query("Кибер-Агро", "Кибер–Агро") is True
        # em dash (U+2014) и minus (U+2212)
        assert guard.matches_query("Кибер—Агро", "кибер-агро") is True
        assert guard.matches_query("A−B", "a-b") is True

    def test_matches_query_cyrillic_case_insensitive(self):
        assert guard.matches_query("Кибер-Агро", "КИБЕР") is True
        assert guard.matches_query("ОБЩЕСТВО", "общество") is True

    def test_matches_query_collapses_whitespace(self):
        assert guard.matches_query("Cyber   Agro", "cyber agro") is True


class TestIsAutoAddCandidate:
    def test_plain_local_group_is_candidate(self):
        assert guard.is_auto_add_candidate(
            room_type=None,
            is_direct=False,
            has_space_parent=False,
            is_local=True,
        ) is True

    def test_space_is_not_candidate(self):
        assert guard.is_auto_add_candidate(
            room_type="m.space",
            is_direct=False,
            has_space_parent=False,
            is_local=True,
        ) is False

    def test_dm_is_not_candidate(self):
        assert guard.is_auto_add_candidate(
            room_type=None,
            is_direct=True,
            has_space_parent=False,
            is_local=True,
        ) is False

    def test_room_already_in_space_is_not_candidate(self):
        assert guard.is_auto_add_candidate(
            room_type=None,
            is_direct=False,
            has_space_parent=True,
            is_local=True,
        ) is False

    def test_remote_room_is_not_candidate(self):
        assert guard.is_auto_add_candidate(
            room_type=None,
            is_direct=False,
            has_space_parent=False,
            is_local=False,
        ) is False


class TestIsDmCreation:
    def test_is_direct_true(self):
        assert guard.is_dm_creation({"is_direct": True}) is True

    def test_is_direct_false(self):
        assert guard.is_dm_creation({"is_direct": False}) is False

    def test_is_direct_absent(self):
        assert guard.is_dm_creation({}) is False

    def test_is_direct_truthy_nonbool_coerced(self):
        assert guard.is_dm_creation({"is_direct": 1}) is True
        assert guard.is_dm_creation({"is_direct": 0}) is False


class TestIsLocalRoom:
    def test_local_room_matches_server_name(self):
        assert guard.is_local_room("!abc:liza.cyber-agro.ru", "liza.cyber-agro.ru") is True

    def test_remote_room_does_not_match(self):
        assert guard.is_local_room("!abc:synapse.liza.laba.prodamus.tech", "liza.cyber-agro.ru") is False

    def test_empty_room_id_is_not_local(self):
        assert guard.is_local_room("", "liza.cyber-agro.ru") is False

    def test_server_name_as_substring_does_not_falsely_match(self):
        # ведущий ":" защищает от ложного совпадения по суффиксу домена
        assert guard.is_local_room("!abc:evil-liza.cyber-agro.ru", "liza.cyber-agro.ru") is False

    def test_server_name_present_but_not_at_end(self):
        assert guard.is_local_room("!liza.cyber-agro.ru:other.tld", "liza.cyber-agro.ru") is False


# Группа из компании/подпространства — ровно один родитель (задача 04).
# Тела ниже — литералы того, что шлёт клиент; зеркало —
# clients/flutter/test/utils/create_group_in_space_test.dart.
# ledger:RL-company-group-single-parent

_GROUP_IN_SPACE_BODY = {
    "name": "Отдел продаж",
    "preset": "private_chat",
    "visibility": "private",
    "power_level_content_override": {"invite": 50},
    "initial_state": [
        {
            "type": "m.space.parent",
            "state_key": "!sub:example.invalid",
            "content": {"via": ["example.invalid"]},
        }
    ],
}

_MENU_GROUP_BODY = {
    "name": "Без компании",
    "preset": "private_chat",
    "visibility": "private",
    "power_level_content_override": {"invite": 50},
}


_GRACE_MS = 60_000


def _delay(config: dict) -> int:
    """Повторяет путь модуля: on_create_room → content m.room.create → задержка."""
    import copy

    config = copy.deepcopy(config)
    guard.apply_space_parent_marker(config)
    return guard.auto_add_delay_ms(config.get("creation_content") or {}, _GRACE_MS)


class TestSpaceParentMarker:
    def test_parent_in_initial_state_detected(self):
        assert guard.has_initial_space_parent(_GROUP_IN_SPACE_BODY) is True

    def test_no_initial_state_not_detected(self):
        assert guard.has_initial_space_parent(_MENU_GROUP_BODY) is False

    def test_empty_state_key_not_detected(self):
        config = {"initial_state": [{"type": "m.space.parent", "state_key": ""}]}
        assert guard.has_initial_space_parent(config) is False

    def test_other_state_not_detected(self):
        config = {"initial_state": [{"type": "m.room.topic", "state_key": ""}]}
        assert guard.has_initial_space_parent(config) is False

    def test_marker_set_when_parent(self):
        # AC:RL-company-group-single-parent/5
        config = {"initial_state": _GROUP_IN_SPACE_BODY["initial_state"]}
        guard.apply_space_parent_marker(config)
        assert config["creation_content"] == {guard.SPACE_PARENT_MARKER: True}

    def test_marker_keeps_existing_creation_content(self):
        config = {
            "creation_content": {"type": "m.space"},
            "initial_state": _GROUP_IN_SPACE_BODY["initial_state"],
        }
        guard.apply_space_parent_marker(config)
        assert config["creation_content"] == {
            "type": "m.space",
            guard.SPACE_PARENT_MARKER: True,
        }

    def test_forged_marker_without_parent_removed(self):
        # AC:RL-company-group-single-parent/5 — маркер ставит только сервер.
        config = {"creation_content": {guard.SPACE_PARENT_MARKER: True}}
        guard.apply_space_parent_marker(config)
        assert guard.SPACE_PARENT_MARKER not in config["creation_content"]

    def test_no_parent_no_creation_content_added(self):
        config = dict(_MENU_GROUP_BODY)
        guard.apply_space_parent_marker(config)
        assert "creation_content" not in config

    def test_group_in_space_auto_add_is_deferred(self):
        # AC:RL-company-group-single-parent/6 — сразу в компанию не идёт: связь
        # пишет клиент со стороны родителя, компания — только запасной путь.
        assert _delay(_GROUP_IN_SPACE_BODY) == _GRACE_MS

    def test_menu_group_still_auto_added_immediately(self):
        # AC:RL-company-group-single-parent/6 — обычная группа по-прежнему
        # уходит в компанию сразу (RL-b2c-chat-outside-space не меняется).
        assert _delay(_MENU_GROUP_BODY) == 0

    def test_forged_marker_string_is_not_deferral(self):
        assert guard.auto_add_delay_ms(
            {guard.SPACE_PARENT_MARKER: "true"}, _GRACE_MS
        ) == 0

    def test_subspace_marker_does_not_make_it_root(self):
        config = {
            "creation_content": {"type": "m.space"},
            "initial_state": _GROUP_IN_SPACE_BODY["initial_state"],
        }
        guard.apply_space_parent_marker(config)
        assert guard.is_root_space_creation(config) is False


class TestModuleWiring:
    """Контракт исходника модуля: пакет без живого HS не импортируется."""

    _src = (Path(__file__).resolve().parent.parent / "__init__.py").read_text(
        encoding="utf-8"
    )

    def test_create_room_applies_marker(self):
        assert "apply_space_parent_marker(config)" in self._src

    def test_create_event_defers_by_marker(self):
        # AC:RL-company-group-single-parent/6 — красный на прежнем безусловном
        # run_as_background_process(_add_room_to_main_space).
        assert "auto_add_delay_ms(" in self._src
        assert "event.content" in self._src
        assert "delayed_background_call(" in self._src

    def test_fallback_adds_only_without_incoming_child(self):
        # AC:RL-company-group-single-parent/7 — поддельный/несуществующий
        # parent или упавший клиент не оставляют комнату вне компании.
        assert "_add_room_if_still_unparented" in self._src
        assert "WHERE type = 'm.space.child' AND state_key = ?" in self._src


class TestRootResponse:
    # ledger:RL-space-invite-admin-only
    # AC:RL-space-invite-admin-only/4 — поле company = класс инстанса
    # (auto_add_new); клиент без поля считает false.
    def test_company_instance(self):
        assert guard.root_response("!r:hs", True) == {
            "exists": True,
            "room_id": "!r:hs",
            "company": True,
        }

    def test_shared_instance(self):
        assert guard.root_response("!r:hs", False)["company"] is False

    def test_no_root_yet(self):
        assert guard.root_response(None, True) == {
            "exists": False,
            "room_id": None,
            "company": True,
        }

    def test_company_is_strict_bool(self):
        assert guard.root_response(None, 1)["company"] is True

