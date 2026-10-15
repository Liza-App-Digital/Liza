"""Люди скрытой (приватной) компании не находятся поиском по имени у посторонних.

ledger:RL-hidden-company-members-search

Решение постановщика (Надежда Розенталь, 14.10): «Скрывать, да, но если знает
номер телефона или точный id - то написать можно». Спека —
docs/superpowers/specs/2026-10-14-hidden-company-members-search-design.md.

Два инстанса: nadezhda — компания с приватным главным пространством (её люди
скрыты), prod — компания, в чью директорию люди nadezhda попадают через общие
комнаты. Фейки — из test_module.py.
"""

import asyncio

from synapse_modules.user_search_guard import UserSearchGuardModule
from synapse_modules.user_search_guard._company import (
    OPEN,
    CompanyPolicy,
    is_company_instance,
    parse_policy_payload,
    trusted_remote_searcher,
)
from synapse_modules.user_search_guard._federation_servlet import (
    UserSearchFederationServlet,
    UserSearchPolicyFederationServlet,
)
from synapse_modules.user_search_guard._search import matches_prefix
from synapse_modules.user_search_guard.tests.test_module import (
    BOT,
    OWNER,
    REGISTRY,
    ROWS,
    SingleSpaceGuardModule,
    _FakeApi,
    _FedClient,
    _ids,
    _row,
)
from synapse_modules.user_search_guard.tests.test_module import CONFIG as BOTS_CONFIG
from synapse_modules.user_search_guard.tests.test_module import SERVER as BOTS

NAD = "nadezhda.liza.ru"
PROD = "synapse.liza.laba.prodamus.tech"
CYBER = "liza.cyber-agro.ru"
ROOT = f"!root:{NAD}"

ANNA = f"@anna:{NAD}"            # человек скрытой компании
BOSS = f"@boss:{NAD}"            # её коллега на том же сервере
GUEST = f"@guest:{PROD}"         # гость компании с другого сервера (join в ROOT)
STRANGER = f"@ivan:{PROD}"       # посторонний
PROD_PEER = f"@petr:{PROD}"      # человек открытой компании prod

COMPANY = [(SingleSpaceGuardModule, {})]
COMMON = [(SingleSpaceGuardModule, {"auto_add_new": False})]
NAD_ROWS = [_row(ANNA, "Анна Петрова"), _row(BOSS, "Анна Босс")]


def _nadezhda(*, public=False, loaded=COMPANY, main_root=ROOT, rows=NAD_ROWS):
    api = _FakeApi(rows, hostname=NAD, loaded=loaded, main_root=main_root)
    api._store.rooms[ROOT] = (public, True)
    api._store.memberships[GUEST] = {ROOT, "!other:x"}
    module = UserSearchGuardModule({}, api)
    return module, api


def _prod(policies, rows=()):
    """prod: соседские политики приходят из опроса federation."""
    api = _FakeApi(rows, hostname=PROD, loaded=COMPANY, main_root=None)
    api._store.memberships[GUEST] = {ROOT}
    module = UserSearchGuardModule({}, api)
    module._federation_whitelist = lambda: [PROD, NAD, CYBER]
    module._fed_client = _FedClient([], policies)
    asyncio.run(module.refresh_policies())
    return module, api


def _servlet(cls, module):
    servlet = cls.__new__(cls)
    servlet._module = module
    return servlet


def _fed_search(module, query, origin, searcher=None):
    args = {b"query": [query.encode()]}
    if searcher is not None:
        args[b"searcher"] = [searcher.encode()]
    servlet = _servlet(UserSearchFederationServlet, module)
    code, body = asyncio.run(servlet.on_GET(origin, None, args))
    assert code == 200
    return _ids(body["results"])


def _spam(module, user_id, searcher):
    return asyncio.run(module.check_username_for_spam(_row(user_id, "x"), searcher))


HIDDEN = CompanyPolicy(hidden=True, room_id=ROOT)


class TestOwnInstance:
    """nadezhda отвечает соседям через federation-сервлет."""

    def test_постороннему_через_федерацию_людей_нет(self):
        """AC:RL-hidden-company-members-search/1"""
        module, _ = _nadezhda()
        assert _fed_search(module, "Анна", PROD, STRANGER) == []
        # старый сосед без searcher — ищущий неизвестен
        assert _fed_search(module, "Анна", PROD) == []
        assert _fed_search(module, "anna", PROD) == []

    def test_гостю_компании_через_федерацию_коллеги_видны(self):
        """AC:RL-hidden-company-members-search/3"""
        module, _ = _nadezhda()
        assert _fed_search(module, "Анна", PROD, GUEST) == [ANNA, BOSS]

    def test_searcher_чужого_домена_игнорируется(self):
        """AC:RL-hidden-company-members-search/6 — cyber-agro не может назваться гостем с prod."""
        module, _ = _nadezhda()
        assert _fed_search(module, "Анна", CYBER, GUEST) == []
        assert trusted_remote_searcher(GUEST, CYBER) is None
        assert trusted_remote_searcher(GUEST, PROD) == GUEST
        assert trusted_remote_searcher("guest", PROD) is None

    def test_свои_на_своём_сервере_видят_своих(self):
        """AC:RL-hidden-company-members-search/3 — локальный поиск и колбэк директории."""
        module, api = _nadezhda()
        res = asyncio.run(module.search_local_users("Анна", 50, BOSS))
        assert _ids(res) == [ANNA, BOSS]
        assert _spam(module, ANNA, BOSS) is False
        # свой сервер решается без запроса членства
        assert api._store.membership_calls == []

    def test_колбэк_директории_до_первой_загрузки_политики_скрывает(self):
        """AC:RL-hidden-company-members-search/8 — нет fail-open до первого
        пересчёта: фоновая загрузка ещё не прошла (или упала), а колбэк
        check_username_for_spam уже зовётся штатным /user_directory/search."""
        module, _ = _nadezhda()
        module._own_policy = None
        assert _spam(module, ANNA, STRANGER) is True
        assert module._own_policy == HIDDEN
        module._own_policy = None
        assert _spam(module, ANNA, BOSS) is False

    def test_публичная_компания_не_скрывает(self):
        """AC:RL-hidden-company-members-search/5"""
        module, _ = _nadezhda(public=True)
        assert _fed_search(module, "Анна", PROD, STRANGER) == [ANNA, BOSS]
        assert _fed_search(module, "Анна", PROD) == [ANNA, BOSS]

    def test_общий_инстанс_не_скрывает_даже_с_приватным_пространством(self):
        """AC:RL-hidden-company-members-search/5 — user.liza.ru / bots.liza.ru."""
        module, _ = _nadezhda(loaded=COMMON)
        assert _fed_search(module, "Анна", PROD, STRANGER) == [ANNA, BOSS]
        module, _ = _nadezhda(loaded=())
        assert _fed_search(module, "Анна", PROD) == [ANNA, BOSS]

    def test_компания_без_главного_пространства_не_скрывает(self):
        """AC:RL-hidden-company-members-search/5"""
        module, _ = _nadezhda(main_root=None)
        assert _fed_search(module, "Анна", PROD) == [ANNA, BOSS]

    def test_политика_для_соседей(self):
        module, _ = _nadezhda()
        servlet = _servlet(UserSearchPolicyFederationServlet, module)
        code, body = asyncio.run(servlet.on_GET(PROD, None, {}))
        assert (code, body) == (200, {"hidden_company": True, "room_id": ROOT})
        module, _ = _nadezhda(public=True)
        servlet = _servlet(UserSearchPolicyFederationServlet, module)
        assert asyncio.run(servlet.on_GET(PROD, None, {}))[1] == {
            "hidden_company": False, "room_id": None,
        }

    def test_смена_публичности_доходит_через_обновление(self):
        module, api = _nadezhda()
        assert _fed_search(module, "Анна", PROD) == []
        api._store.rooms[ROOT] = (True, True)
        asyncio.run(module.refresh_policies())
        assert _fed_search(module, "Анна", PROD) == [ANNA, BOSS]


class TestRemoteInstance:
    """prod: люди nadezhda в его директории (общие комнаты) и в веере."""

    def test_колбэк_директории_скрывает_от_постороннего(self):
        """AC:RL-hidden-company-members-search/1 — штатный /user_directory/search."""
        module, _ = _prod({NAD: HIDDEN})
        assert _spam(module, ANNA, STRANGER) is True
        # человек открытой компании и свой человек prod — видны
        assert _spam(module, PROD_PEER, STRANGER) is False

    def test_колбэк_директории_пускает_гостя_компании(self):
        """AC:RL-hidden-company-members-search/3"""
        module, _ = _prod({NAD: HIDDEN})
        assert _spam(module, ANNA, GUEST) is False

    def test_добивка_выдачи_соседа(self):
        """AC:RL-hidden-company-members-search/1,3 — не обновлённый сосед отдал людей."""
        module, _ = _prod({NAD: HIDDEN})
        module._fed_client.rows = [_row(ANNA, "Анна Петрова")]
        assert _ids(asyncio.run(module.search("Анна", STRANGER))) == []
        assert _ids(asyncio.run(module.search("Анна", GUEST))) == [ANNA]
        # ищущий уходит соседу, чтобы тот пустил своих
        assert module._fed_client.searchers[-1] == GUEST

    def test_открытый_и_неизвестный_сосед_не_скрывает(self):
        """AC:RL-hidden-company-members-search/5"""
        module, _ = _prod({NAD: OPEN})
        assert _spam(module, ANNA, STRANGER) is False
        module, _ = _prod({})
        assert _spam(module, ANNA, STRANGER) is False

    def test_ошибка_опроса_не_сбрасывает_политику(self):
        """AC:RL-hidden-company-members-search/7"""
        module, _ = _prod({NAD: HIDDEN})
        module._fed_client.policies = {}
        asyncio.run(module.refresh_policies())
        assert _spam(module, ANNA, STRANGER) is True

    def test_членство_спрашивается_только_для_людей_скрытой_компании(self):
        module, api = _prod({NAD: HIDDEN})
        _spam(module, PROD_PEER, STRANGER)
        _spam(module, f"@x:{CYBER}", STRANGER)
        assert api._store.membership_calls == []
        _spam(module, ANNA, STRANGER)
        assert api._store.membership_calls == [STRANGER]


class TestExactIdAndBots:
    def test_точный_mxid_сервером_не_ищется_вовсе(self):
        """AC:RL-hidden-company-members-search/2 — точный ID решает клиент
        (подставляет MXID как есть), фильтр поиска его не касается."""
        assert matches_prefix("Анна Петрова", ANNA, ANNA) is False
        module, _ = _nadezhda(public=True)
        assert _fed_search(module, ANNA, PROD) == []

    def test_приватный_бот_через_федерацию_не_уходит_даже_названному_владельцу(self):
        """AC:RL-hidden-company-members-search/4 — RL-private-bots не изменился."""
        api = _FakeApi(ROWS, REGISTRY, hostname=BOTS, loaded=COMMON)
        module = UserSearchGuardModule(dict(BOTS_CONFIG), api)
        found = _fed_search(module, "Упр", PROD, OWNER)
        assert BOT not in found
        assert found == ["@support:" + BOTS]


class TestPure:
    def test_класс_инстанса(self):
        assert is_company_instance(COMPANY) is True
        assert is_company_instance([(SingleSpaceGuardModule, {"auto_add_new": True})]) is True
        assert is_company_instance(COMMON) is False
        assert is_company_instance([]) is False
        assert is_company_instance([(object, {})]) is False

    def test_разбор_политики(self):
        assert parse_policy_payload({"hidden_company": True, "room_id": ROOT}) == HIDDEN
        assert parse_policy_payload({"hidden_company": False, "room_id": ROOT}) == OPEN
        assert parse_policy_payload({"hidden_company": True, "room_id": "bad"}) == CompanyPolicy(True, None)
        assert parse_policy_payload({"hidden_company": "yes"}) is None
        assert parse_policy_payload([]) is None
