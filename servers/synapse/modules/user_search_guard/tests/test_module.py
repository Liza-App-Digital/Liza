"""Модульные тесты фильтра приватных ботов в UserSearchGuardModule.

Без живого HomeServer: модуль собирается через настоящий __init__ на
фейковом ModuleApi (проверяем регистрацию колбэка и фонового обновления),
federation-сервлет — через __new__ (минуем BaseFederationServlet.__init__,
которому нужен живой hs). Запуск — см. README модулей, раздел про тесты.
"""

import asyncio

from synapse_modules.user_search_guard import UserSearchGuardModule
from synapse_modules.user_search_guard._federation_servlet import (
    UserSearchFederationServlet,
)

SERVER = "bots.liza.ru"
BOT = f"@manage-admin-db:{SERVER}"
PUBLIC = f"@support:{SERVER}"
ADMIN = f"@admin:{SERVER}"
OWNER = "@daniel.furman:synapse.liza.laba.prodamus.tech"
STRANGER = "@ivan:synapse.liza.laba.prodamus.tech"
REMOTE_PRIVATE = "@xl_test_bot:synapse.liza.laba.prodamus.tech"


def _row(user_id, name):
    return {"user_id": user_id, "display_name": name, "avatar_url": None}


class _Store:
    def __init__(self, rows):
        self.rows = rows
        # {room_id: (is_public, has_auth_chain_index)} и {user_id: {room_id}}
        self.rooms = {}
        self.memberships = {}
        self.membership_calls = []

    async def search_user_dir(self, user_id, term, limit, *args):
        return {"limited": False, "results": list(self.rows)}

    async def get_room(self, room_id):
        return self.rooms.get(room_id)

    async def get_rooms_for_user(self, user_id):
        self.membership_calls.append(user_id)
        return frozenset(self.memberships.get(user_id, ()))


class _FedClient:
    def __init__(self, rows, policies=None):
        self.rows = rows
        self.policies = policies or {}
        self.searchers = []

    async def search(self, query, domains, searcher=None):
        self.searchers.append(searcher)
        return list(self.rows)

    async def fetch_policies(self, domains):
        return {d: p for d, p in self.policies.items() if d in domains}


class SingleSpaceGuardModule:
    """Двойник класса для hs.config.modules.loaded_modules (матч по имени)."""


class _Modules:
    def __init__(self, loaded):
        self.loaded_modules = loaded


class _Federation:
    def __init__(self, whitelist):
        self.federation_domain_whitelist = whitelist


class _Config:
    def __init__(self, loaded, whitelist):
        self.modules = _Modules(loaded)
        self.federation = _Federation(whitelist)


class _Hs:
    def __init__(self, hostname=SERVER, loaded=(), whitelist=None):
        self.hostname = hostname
        self.config = _Config(list(loaded), whitelist)

    def get_federation_http_client(self):
        return object()


class _HttpClient:
    def __init__(self, payload):
        self.payload = payload
        self.calls = []

    async def get_json(self, url, args=None, headers=None):
        self.calls.append((url, headers))
        return self.payload


class _FakeApi:
    def __init__(self, rows=(), payload=None, hostname=SERVER, loaded=(), main_root=None):
        self._hs = _Hs(hostname, loaded)
        self.main_root = main_root
        self._store = _Store(list(rows))
        self.http_client = _HttpClient(payload or {"bots": []})
        self.spam_callbacks = {}
        self.web_resources = []
        self.background = []
        self.looping = []

    def register_spam_checker_callbacks(self, **kwargs):
        self.spam_callbacks.update(kwargs)

    def register_web_resource(self, path, resource):
        self.web_resources.append(path)

    def run_as_background_process(self, desc, func, *args):
        self.background.append(desc)
        return asyncio.run(func(*args))

    def looping_background_call(self, f, msec, *args, desc=None, run_on_all_instances=False):
        self.looping.append((f, msec, desc, run_on_all_instances))

    async def sleep(self, seconds):
        pass

    async def run_db_interaction(self, desc, func, *args):
        return self.main_root


ROWS = [
    _row(BOT, "Управление БД"),
    _row(PUBLIC, "Управление поддержкой"),
    _row(ADMIN, "admin"),
]
REGISTRY = {"bots": [{"mxid": BOT, "owner": OWNER}]}
CONFIG = {
    "registry_url": "http://liza-bot-api-bots:9998",
    "registry_secret": "s3cret",
    "hidden_users": [ADMIN],
}


def _module(rows=ROWS, payload=REGISTRY, config=CONFIG):
    api = _FakeApi(rows, payload)
    module = UserSearchGuardModule(dict(config), api)
    return module, api


def _ids(results):
    return [r["user_id"] for r in results]


class TestInit:
    def test_регистрирует_колбэк_и_фоновое_обновление(self):
        module, api = _module()
        assert api.spam_callbacks["check_username_for_spam"] == module.check_username_for_spam
        hidden_loops = [x for x in api.looping if x[2] == "user_search_guard_hidden_refresh"]
        assert len(hidden_loops) == 1
        _, msec, desc, all_instances = hidden_loops[0]
        assert msec == 60_000
        assert all_instances is True
        # стартовая загрузка прошла фоном — набор уже в памяти
        assert module.hidden_cache.hidden_bots == {BOT: OWNER}
        url, headers = api.http_client.calls[0]
        assert url == "http://liza-bot-api-bots:9998/registry/v1/hidden"
        assert headers == {b"X-Registry-Secret": [b"s3cret"]}

    def test_секрет_из_файла_оверлея(self, tmp_path):
        p = tmp_path / "homeserver-secrets.yaml"
        p.write_text("liza_registry_secret: from-file\n")
        config = {"registry_url": "http://r", "registry_secret_path": str(p)}
        _, api = _module(config=config)
        assert api.http_client.calls[0][1] == {b"X-Registry-Secret": [b"from-file"]}

    def test_без_registry_url_только_deny_list(self):
        module, api = _module(config={"hidden_users": [ADMIN]})
        assert module.hidden_cache is None
        assert [x for x in api.looping if x[2] == "user_search_guard_hidden_refresh"] == []
        assert api.http_client.calls == []
        assert module.is_hidden(ADMIN, STRANGER) is True
        assert module.is_hidden(BOT, STRANGER) is False


class TestSpamCallback:
    def test_постороннему_приватный_бот_выкидывается(self):
        module, _ = _module()
        assert asyncio.run(module.check_username_for_spam(_row(BOT, "x"), STRANGER)) is True

    def test_владельцу_приватный_бот_остаётся(self):
        module, _ = _module()
        assert asyncio.run(module.check_username_for_spam(_row(BOT, "x"), OWNER)) is False

    def test_публичный_остаётся(self):
        module, _ = _module()
        assert asyncio.run(module.check_username_for_spam(_row(PUBLIC, "x"), STRANGER)) is False

    def test_deny_list_выкидывается_у_всех(self):
        module, _ = _module()
        assert asyncio.run(module.check_username_for_spam(_row(ADMIN, "admin"), OWNER)) is True

    def test_реестр_недоступен_держим_прошлый_набор(self):
        module, api = _module()

        async def boom(url, args=None, headers=None):
            raise ConnectionError("liza-bot-api down")

        api.http_client.get_json = boom
        assert asyncio.run(module.hidden_cache.refresh()) is False
        assert asyncio.run(module.check_username_for_spam(_row(BOT, "x"), STRANGER)) is True


class TestSearchLocalUsers:
    def test_посторонний_не_видит_приватного_и_deny(self):
        module, _ = _module()
        res = asyncio.run(module.search_local_users("Упр", 50, STRANGER))
        assert _ids(res) == [PUBLIC]

    def test_владелец_видит_своего_бота(self):
        module, _ = _module()
        res = asyncio.run(module.search_local_users("Упр", 50, OWNER))
        assert _ids(res) == [BOT, PUBLIC]

    def test_по_умолчанию_ищущий_неизвестен(self):
        module, _ = _module()
        res = asyncio.run(module.search_local_users("Упр", 50))
        assert _ids(res) == [PUBLIC]

    def test_admin_скрыт(self):
        module, _ = _module()
        assert asyncio.run(module.search_local_users("adm", 50, OWNER)) == []

    def test_federated_search_добивает_выдачу_соседа(self):
        """Не обновлённый сосед отдал приватного бота — режем своим набором."""
        payload = {"bots": [{"mxid": BOT, "owner": OWNER},
                            {"mxid": REMOTE_PRIVATE, "owner": OWNER}]}
        module, api = _module(payload=payload)
        module._fed_client = _FedClient([_row(REMOTE_PRIVATE, "XL test")])
        module._federation_whitelist = lambda: ["synapse.liza.laba.prodamus.tech"]
        assert _ids(asyncio.run(module.search("Упр", STRANGER))) == [PUBLIC]
        assert REMOTE_PRIVATE in _ids(asyncio.run(module.search("XL", OWNER)))
        assert REMOTE_PRIVATE not in _ids(asyncio.run(module.search("XL", STRANGER)))


class TestFederationServlet:
    def _servlet(self, module):
        servlet = UserSearchFederationServlet.__new__(UserSearchFederationServlet)
        servlet._module = module
        return servlet

    def test_ответ_соседу_без_приватных_и_deny(self):
        module, _ = _module()
        servlet = self._servlet(module)
        code, body = asyncio.run(servlet.on_GET("synapse.liza.laba.prodamus.tech", None, {b"query": ["Упр".encode()]}))
        assert code == 200
        assert _ids(body["results"]) == [PUBLIC]

    def test_даже_для_сервера_владельца_приватный_не_уходит(self):
        """origin — сервер, а не пользователь: владельца не отличить."""
        module, _ = _module()
        servlet = self._servlet(module)
        _, body = asyncio.run(servlet.on_GET("synapse.liza.laba.prodamus.tech", None, {b"query": [b"manage"]}))
        assert body["results"] == []
