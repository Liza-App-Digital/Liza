"""Чистая логика видимости ботов: is_hidden, разбор ответа реестра, кэш.

Без HomeServer: _visibility.py грузится по пути, HTTP подменён async-заглушкой.
"""

import asyncio
import importlib.util
from pathlib import Path

_path = Path(__file__).resolve().parent.parent / "_visibility.py"
_spec = importlib.util.spec_from_file_location("usg_visibility", _path)
vis = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(vis)

BOT = "@manage-admin-db:bots.liza.ru"
OWNER = "@daniel.furman:synapse.liza.laba.prodamus.tech"
STRANGER = "@ivan:synapse.liza.laba.prodamus.tech"
PUBLIC = "@support:bots.liza.ru"
ADMIN = "@admin:bots.liza.ru"

HIDDEN = {BOT: OWNER}
DENY = frozenset({ADMIN})


class TestIsHidden:
    def test_приватный_бот_скрыт_от_постороннего(self):
        assert vis.is_hidden(BOT, STRANGER, HIDDEN, DENY) is True

    def test_владелец_видит_своего_приватного_бота(self):
        assert vis.is_hidden(BOT, OWNER, HIDDEN, DENY) is False

    def test_публичный_бот_виден_всем(self):
        assert vis.is_hidden(PUBLIC, STRANGER, HIDDEN, DENY) is False

    def test_обычный_пользователь_виден(self):
        assert vis.is_hidden(STRANGER, OWNER, HIDDEN, DENY) is False

    def test_deny_list_скрыт_от_всех(self):
        assert vis.is_hidden(ADMIN, STRANGER, HIDDEN, DENY) is True

    def test_deny_list_без_исключения_для_владельца(self):
        """Даже если аккаунт есть в реестре с владельцем — deny_list сильнее."""
        hidden = {ADMIN: OWNER}
        assert vis.is_hidden(ADMIN, OWNER, hidden, DENY) is True

    def test_ищущий_неизвестен_скрыт_любой_приватный(self):
        """Federation-ответ: searcher=None, владельца нет — скрыт."""
        assert vis.is_hidden(BOT, None, HIDDEN, DENY) is True

    def test_ищущий_неизвестен_публичный_виден(self):
        assert vis.is_hidden(PUBLIC, None, HIDDEN, DENY) is False

    def test_бот_без_владельца_скрыт_от_всех(self):
        assert vis.is_hidden(BOT, OWNER, {BOT: None}, DENY) is True


class TestParseHiddenPayload:
    def test_корректный_ответ(self):
        payload = {"bots": [{"mxid": BOT, "owner": OWNER}], "version": 3}
        assert vis.parse_hidden_payload(payload) == {BOT: OWNER}

    def test_пустой_список_валиден(self):
        assert vis.parse_hidden_payload({"bots": []}) == {}

    def test_не_объект_отвергается(self):
        assert vis.parse_hidden_payload([{"mxid": BOT}]) is None
        assert vis.parse_hidden_payload(None) is None

    def test_нет_списка_bots_отвергается(self):
        assert vis.parse_hidden_payload({"error": "unauthorized"}) is None
        assert vis.parse_hidden_payload({"bots": "x"}) is None

    def test_битая_строка_пропускается_остальные_принимаются(self):
        payload = {"bots": [
            {"mxid": None, "owner": OWNER},
            "мусор",
            {"mxid": "без-собаки", "owner": OWNER},
            {"mxid": BOT, "owner": OWNER},
        ]}
        assert vis.parse_hidden_payload(payload) == {BOT: OWNER}

    def test_пустой_owner_нормализуется_в_none(self):
        assert vis.parse_hidden_payload({"bots": [{"mxid": BOT, "owner": ""}]}) == {BOT: None}


class _FakeHttp:
    """Отдаёт ответы по очереди; Exception в очереди — бросается."""

    def __init__(self, *responses):
        self.responses = list(responses)
        self.calls = []

    async def __call__(self, url, headers):
        self.calls.append((url, headers))
        r = self.responses.pop(0)
        if isinstance(r, Exception):
            raise r
        return r


def _run(coro):
    return asyncio.run(coro)


class TestHiddenBotsCache:
    def test_успешное_обновление(self):
        http = _FakeHttp({"bots": [{"mxid": BOT, "owner": OWNER}]})
        cache = vis.HiddenBotsCache("http://liza-bot-api-bots:9998/", "s3cret", http)
        assert _run(cache.refresh()) is True
        assert cache.hidden_bots == {BOT: OWNER}
        assert cache.loaded is True
        url, headers = http.calls[0]
        assert url == "http://liza-bot-api-bots:9998/registry/v1/hidden"
        assert headers == {"X-Registry-Secret": "s3cret"}

    def test_ошибка_держит_последний_набор(self):
        http = _FakeHttp({"bots": [{"mxid": BOT, "owner": OWNER}]}, ConnectionError("down"))
        cache = vis.HiddenBotsCache("http://r", "s", http)
        _run(cache.refresh())
        assert _run(cache.refresh()) is False
        assert cache.hidden_bots == {BOT: OWNER}

    def test_кривой_ответ_игнорируется(self):
        http = _FakeHttp({"bots": [{"mxid": BOT, "owner": OWNER}]}, {"oops": 1})
        cache = vis.HiddenBotsCache("http://r", "s", http)
        _run(cache.refresh())
        assert _run(cache.refresh()) is False
        assert cache.hidden_bots == {BOT: OWNER}

    def test_бот_стал_публичным_пропадает_из_набора(self):
        http = _FakeHttp({"bots": [{"mxid": BOT, "owner": OWNER}]}, {"bots": []})
        cache = vis.HiddenBotsCache("http://r", "s", http)
        _run(cache.refresh())
        _run(cache.refresh())
        assert cache.hidden_bots == {}

    def test_старт_ретраит_до_успеха(self):
        http = _FakeHttp(ConnectionError("1"), ConnectionError("2"), {"bots": [{"mxid": BOT, "owner": OWNER}]})
        sleeps = []

        async def sleep(s):
            sleeps.append(s)

        cache = vis.HiddenBotsCache("http://r", "s", http)
        assert _run(cache.initial_load(sleep, attempts=3, delay_seconds=2.0)) is True
        assert sleeps == [2.0, 2.0]
        assert cache.hidden_bots == {BOT: OWNER}

    def test_старт_сдаётся_после_попыток_без_исключения(self):
        http = _FakeHttp(*[ConnectionError("x")] * 3)

        async def sleep(s):
            pass

        cache = vis.HiddenBotsCache("http://r", "s", http)
        assert _run(cache.initial_load(sleep, attempts=3)) is False
        assert cache.hidden_bots == {}
        assert cache.loaded is False


class TestReadSecretFile:
    def test_ключ_читается_из_оверлея(self, tmp_path):
        p = tmp_path / "homeserver-secrets.yaml"
        p.write_text("form_secret: x\nliza_registry_secret: abc\n")
        assert vis.read_secret_file(str(p)) == "abc"

    def test_нет_ключа_пустая_строка(self, tmp_path):
        p = tmp_path / "homeserver-secrets.yaml"
        p.write_text("form_secret: x\n")
        assert vis.read_secret_file(str(p)) == ""

    def test_нет_файла_пустая_строка(self, tmp_path):
        assert vis.read_secret_file(str(tmp_path / "нет.yaml")) == ""
