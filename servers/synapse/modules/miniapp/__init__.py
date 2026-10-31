"""Synapse-модуль для Liza Mini Apps.

Тонкий слой identity/membership в reactor Synapse (НЕ блокировать!). Делает только
микроскопические операции: подпись init_data (HMAC + опц. Ed25519), доказательство
членства в комнате, выдачу opaque user_hash, проверку app_id против реестра,
одноразовый nonce. Вся тяжёлая логика (реестр-истина, манифесты, LLM, платежи) —
во внешних сервисах.

Конфигурация в homeserver.yaml:

    modules:
      - module: synapse_modules.miniapp.MiniAppModule
        config:
          secret: "some-secret-string"          # или env MINIAPP_SECRET
          internal_token: "shared-token"         # для validate_nonce / registry
          per_app_keys: false                    # B5: per-app derived key (включать за флагом)
          auth_date_ttl: 300                      # TTL подписи initData, сек (цель — 5 мин)
          nonce_ttl: 1800                         # TTL nonce, сек
          verify_room_membership: true            # B8: room_id только из проверенного членства
          cors_allowed_origins:                   # для встраиваемого/стороннего фронта
            - "https://shell.app.tech.liza.ru"
          ed25519_private_key_path: "/secrets/miniapp.ed25519"  # 32 байта seed (опц., §3)
          ed25519_key_id: "1"
          registry_url: "http://developer-portal:8000/internal/v1/apps?state=listed"  # опц.
          registry_token: "shared-devportal-token"   # заголовок X-DevPortal-Token
          registry_ttl: 60
          apps:
            prodamus-store:
              url: "https://store.app.tech.liza.ru"
              name: "Магазин Prodamus"
              scopes: ["users:contact"]           # email/phone отдаём только при этом scope

Совместимость: при `per_app_keys: false` и app без `scopes` поведение совпадает с
исторической версией — prodamus-store продолжает работать без изменений.
"""

import json
import logging
import os
import time
from typing import Any

from twisted.internet import reactor
from twisted.web import resource, server

from synapse.logging.context import run_in_background
from synapse.module_api import ModuleApi

from . import _crypto
from ._registry import AppRegistry, map_portal_apps
from ._stores import NonceStore as _NonceStore
from ._stores import RateLimiter as _RateLimiter

logger = logging.getLogger(__name__)

# Дефолтные TTL (переопределяются конфигом)
_DEFAULT_NONCE_TTL = 30 * 60
_DEFAULT_AUTH_DATE_TTL = 5 * 60

# Интервал очистки протухших nonce
_NONCE_CLEANUP_INTERVAL = 5 * 60

# Scope, открывающий контактные данные (email/phone) стороннему app.
_SCOPE_CONTACT = "users:contact"


# ---------------------------------------------------------------------------
# Twisted Resources
# ---------------------------------------------------------------------------


class _JsonResource(resource.Resource):
    """Базовый ресурс с JSON-хелперами и CORS (по паттерну user_roles)."""

    cors_origins: tuple[str, ...] = ()

    def _set_cors(self, request: server.Request) -> None:
        """Выставляет CORS-заголовки, если Origin запроса в allowlist.

        Без этого встраиваемый/сторонний фронт не сможет звать модуль cross-origin.
        """
        if not self.cors_origins:
            return
        origin = request.getHeader(b"Origin")
        if origin is None:
            return
        origin_s = origin.decode("utf-8") if isinstance(origin, bytes) else origin
        if origin_s in self.cors_origins:
            request.setHeader(b"Access-Control-Allow-Origin", origin_s.encode("utf-8"))
            request.setHeader(b"Access-Control-Allow-Credentials", b"true")
            request.setHeader(b"Access-Control-Allow-Headers", b"Authorization, Content-Type, X-MiniApp-Token")
            request.setHeader(b"Access-Control-Allow-Methods", b"GET, POST, OPTIONS")
            request.setHeader(b"Vary", b"Origin")

    def render_OPTIONS(self, request: server.Request) -> bytes:
        """CORS preflight. Размещён в самом ресурсе (а не вложенным путём) —
        иначе ловушка isLeaf/getChild→self перехватит."""
        self._set_cors(request)
        request.setResponseCode(204)
        return b""

    def getChild(self, path: bytes, request: server.Request) -> resource.Resource:
        return self

    def _json_response(self, request: server.Request, data: dict, status: int = 200) -> None:
        self._set_cors(request)
        request.setResponseCode(status)
        request.setHeader(b"Content-Type", b"application/json")
        request.write(json.dumps(data, ensure_ascii=False).encode("utf-8"))
        request.finish()

    def _error(self, request: server.Request, error: str, message: str, status: int) -> None:
        self._json_response(request, {"error": error, "message": message}, status)

    def _on_errback(self, failure, request: server.Request) -> None:
        logger.error("MiniApp API error: %s", failure)
        if not request.finished:
            from synapse.api.errors import AuthError, SynapseError

            ex = failure.value
            if isinstance(ex, AuthError):
                self._error(request, "unauthorized", "Missing or invalid access token", 401)
            elif isinstance(ex, SynapseError):
                self._error(request, ex.errcode, str(ex), ex.code)
            else:
                self._error(request, "internal_error", "Internal server error", 500)

    def _read_body(self, request: server.Request) -> dict:
        request.content.seek(0)
        body = request.content.read()
        if not body:
            return {}
        return json.loads(body)


class InitDataResource(_JsonResource):
    """POST /_synapse/client/miniapp/v1/init_data — подписанный init_data."""

    def __init__(
        self,
        module_api: ModuleApi,
        *,
        master_secret: str,
        per_app_keys: bool,
        registry: AppRegistry,
        nonce_store: _NonceStore,
        rate_limiter: _RateLimiter,
        auth_date_ttl: int,
        verify_room_membership: bool,
        ed25519_seed: bytes | None,
        ed25519_key_id: str,
        cors_origins: tuple[str, ...],
    ) -> None:
        super().__init__()
        self._module_api = module_api
        self._master_secret = master_secret
        self._per_app_keys = per_app_keys
        self._registry = registry
        self._nonce_store = nonce_store
        self._rate_limiter = rate_limiter
        self._auth_date_ttl = auth_date_ttl
        self._verify_room_membership = verify_room_membership
        self._ed25519_seed = ed25519_seed
        self._ed25519_key_id = ed25519_key_id
        self.cors_origins = cors_origins

    def render_POST(self, request: server.Request) -> int:
        d = run_in_background(self._handle_post, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _check_membership(self, user_id: str, room_id: str) -> bool:
        """Проверяет, что user_id — участник room_id (B8).

        Стабильный запрос к local_current_membership через run_db_interaction
        (так же, как single_space_guard читает комнаты).
        """

        def _txn(txn) -> str | None:
            txn.execute(
                "SELECT membership FROM local_current_membership "
                "WHERE room_id = ? AND user_id = ?",
                (room_id, user_id),
            )
            row = txn.fetchone()
            return row[0] if row else None

        try:
            membership = await self._module_api.run_db_interaction("miniapp_check_membership", _txn)
        except Exception:
            logger.warning("MiniApp: не удалось проверить членство %s в %s", user_id, room_id, exc_info=True)
            return False
        return membership == "join"

    async def _handle_post(self, request: server.Request) -> None:
        requester = await self._module_api.get_user_by_req(request)
        user_id = requester.user.to_string()

        if not self._rate_limiter.check(user_id):
            self._error(request, "rate_limited", "Слишком много запросов, попробуйте позже", 429)
            return

        try:
            body = self._read_body(request)
        except Exception:
            self._error(request, "bad_request", "Invalid JSON body", 400)
            return

        app_id = body.get("app_id")
        if not isinstance(app_id, str) or not app_id:
            self._error(request, "bad_request", "app_id is required", 400)
            return

        # app_id валидируется против динамического реестра (кэш) + kill-switch.
        await self._registry.maybe_refresh()
        app = self._registry.get(app_id)
        if app is None:
            self._error(request, "not_found", f"Приложение '{app_id}' не зарегистрировано", 404)
            return
        if not self._registry.is_listed(app_id):
            self._error(request, "suspended", f"Приложение '{app_id}' отключено", 403)
            return

        room_id = body.get("room_id")
        if room_id is not None and (not isinstance(room_id, str) or not room_id):
            self._error(request, "bad_request", "room_id должен быть непустой строкой", 400)
            return

        # B8: room_id принимаем только из проверенного членства.
        if room_id is not None and self._verify_room_membership:
            if not await self._check_membership(user_id, room_id):
                self._error(request, "forbidden", "Вы не участник указанной комнаты", 403)
                return

        # Ключ подписи: per-app derived (B5) или legacy-единый.
        key = _crypto.signing_key(self._master_secret, app_id, per_app_keys=self._per_app_keys)

        # Профиль
        display_name: str | None = None
        avatar_url: str | None = None
        try:
            profile = await self._module_api.get_profile_for_user(user_id)
            display_name = profile.get("display_name")
            avatar_url = profile.get("avatar_url")
        except Exception:
            logger.warning("Не удалось получить профиль для %s", user_id)

        # Контактные данные — только при granted scope users:contact.
        # Совместимость: app без ключа `scopes` считается legacy (контакт включён).
        scopes = app.get("scopes")
        contact_allowed = scopes is None or _SCOPE_CONTACT in scopes
        email: str | None = None
        if contact_allowed:
            try:
                threepids = await self._module_api.get_threepids_for_user(user_id)
                for tp in threepids:
                    if tp.get("medium") == "email":
                        email = tp.get("address")
                        break
            except Exception:
                logger.warning("Не удалось получить threepids для %s", user_id)

        user_hash = _crypto.compute_user_hash(key, user_id)

        user_obj: dict[str, Any] = {"id": user_hash}
        if display_name:
            user_obj["display_name"] = display_name
        if avatar_url:
            user_obj["avatar_url"] = avatar_url
        if email:
            user_obj["email"] = email

        user_json = json.dumps(user_obj, ensure_ascii=False)

        nonce = self._nonce_store.create(user_id, app_id, room_id)
        auth_date = int(time.time())

        params: dict[str, str] = {
            "app_id": app_id,
            "auth_date": str(auth_date),
            "nonce": nonce,
            "user": user_json,
        }
        if room_id is not None:
            params["room_id"] = room_id
        if self._ed25519_seed is not None:
            params["key_id"] = self._ed25519_key_id

        dcs = _crypto.build_data_check_string(params)
        hash_value = _crypto.hmac_sign(key, dcs)
        signature = None
        if self._ed25519_seed is not None:
            signature = _crypto.ed25519_sign_b64url(self._ed25519_seed, dcs)

        init_data = _crypto.encode_init_data(params, hash_value, signature)

        self._json_response(request, {"init_data": init_data, "ttl": self._auth_date_ttl})


class ValidateNonceResource(_JsonResource):
    """GET /_synapse/client/miniapp/v1/validate_nonce — одноразовое гашение nonce.

    Доступ: shared token (X-MiniApp-Token) или приватная сеть.
    Опц. query app_id / room_id — сверка привязки nonce.
    """

    def __init__(self, nonce_store: _NonceStore, *, internal_token: str | None = None) -> None:
        super().__init__()
        self._nonce_store = nonce_store
        self._internal_token = internal_token

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        if not self._check_access(request):
            self._error(request, "forbidden", "Доступ запрещён", 403)
            return

        nonce_values = request.args.get(b"nonce", [])
        if not nonce_values or not nonce_values[0]:
            self._error(request, "bad_request", "Параметр nonce обязателен", 400)
            return

        nonce = nonce_values[0].decode("utf-8", errors="replace")
        app_vals = request.args.get(b"app_id", [])
        room_vals = request.args.get(b"room_id", [])
        app_id = app_vals[0].decode("utf-8", errors="replace") if app_vals else None
        room_id = room_vals[0].decode("utf-8", errors="replace") if room_vals else None

        valid = self._nonce_store.validate_and_consume(nonce, app_id=app_id, room_id=room_id)
        self._json_response(request, {"valid": valid})

    def _check_access(self, request: server.Request) -> bool:
        import hmac as _hmac

        if self._internal_token:
            auth_header = request.getHeader(b"X-MiniApp-Token")
            if auth_header is not None:
                token = auth_header.decode("utf-8") if isinstance(auth_header, bytes) else auth_header
                if _hmac.compare_digest(token, self._internal_token):
                    return True

        client_ip = request.getClientAddress()
        if hasattr(client_ip, "host"):
            host = client_ip.host
            # Docker отдаёт IPv4-mapped IPv6 (::ffff:172.x) — нормализуем, иначе
            # приватная сеть не распознаётся и registry_refresh от devportal → 403.
            if host.startswith("::ffff:"):
                host = host[len("::ffff:"):]
            if host in ("127.0.0.1", "::1", "localhost"):
                return True
            if host.startswith("172.") or host.startswith("10.") or host.startswith("192.168."):
                return True
        return False


class RegistryRefreshResource(_JsonResource):
    """POST /_synapse/client/miniapp/v1/registry_refresh — форс-обновление реестра.

    Дёргается developer-portal сразу после публикации app (X-MiniApp-Token /
    приватная сеть), чтобы init_data для свежесозданного app выдавался немедленно,
    а не через TTL (до 60с). Аддитивный ресурс — на прод-Synapse безвреден.
    """

    def __init__(self, registry: AppRegistry, *, internal_token: str | None = None) -> None:
        super().__init__()
        self._registry = registry
        self._internal_token = internal_token

    def render_POST(self, request: server.Request) -> int:
        d = run_in_background(self._handle_post, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_post(self, request: server.Request) -> None:
        if not self._check_access(request):
            self._error(request, "forbidden", "Доступ запрещён", 403)
            return
        self._registry.invalidate()
        await self._registry.maybe_refresh()
        self._json_response(
            request, {"refreshed": True, "count": len(self._registry.all_listed())}
        )

    def _check_access(self, request: server.Request) -> bool:
        import hmac as _hmac

        if self._internal_token:
            auth_header = request.getHeader(b"X-MiniApp-Token")
            if auth_header is not None:
                token = auth_header.decode("utf-8") if isinstance(auth_header, bytes) else auth_header
                if _hmac.compare_digest(token, self._internal_token):
                    return True
        client_ip = request.getClientAddress()
        if hasattr(client_ip, "host"):
            host = client_ip.host
            # Docker отдаёт IPv4-mapped IPv6 (::ffff:172.x) — нормализуем, иначе
            # приватная сеть не распознаётся и registry_refresh от devportal → 403.
            if host.startswith("::ffff:"):
                host = host[len("::ffff:"):]
            if host in ("127.0.0.1", "::1", "localhost"):
                return True
            if host.startswith("172.") or host.startswith("10.") or host.startswith("192.168."):
                return True
        return False


class AppsResource(_JsonResource):
    """GET /_synapse/client/miniapp/v1/apps — динамический список доступных app."""

    def __init__(self, registry: AppRegistry, *, cors_origins: tuple[str, ...]) -> None:
        super().__init__()
        self._registry = registry
        self.cors_origins = cors_origins

    def render_GET(self, request: server.Request) -> int:
        d = run_in_background(self._handle_get, request)
        d.addErrback(self._on_errback, request)
        return server.NOT_DONE_YET

    async def _handle_get(self, request: server.Request) -> None:
        await self._registry.maybe_refresh()
        apps = self._registry.all_listed()
        # Отдаём только безопасные поля, без внутренних секретов. Системные app
        # (кабинет разработчика, system=true) — подписываемы, но НЕ в каталоге.
        public = {
            app_id: {
                "name": rec.get("name"),
                "url": rec.get("url"),
                "icon": rec.get("icon"),
                "type": rec.get("type", "first_party"),
                "short_description": rec.get("short_description"),
            }
            for app_id, rec in apps.items()
            if not rec.get("system")
        }
        self._json_response(request, {"apps": public})


class KeysResource(_JsonResource):
    """GET /_synapse/client/miniapp/v1/keys — публичные Ed25519-ключи (§3).

    Сторонний бэкенд берёт публичный ключ отсюда (или из .well-known) и проверяет
    initData офлайн, не зная master_secret. Возвращает key_id + alg + public_key.
    """

    def __init__(self, *, public_key_b64url: str | None, key_id: str, cors_origins: tuple[str, ...]) -> None:
        super().__init__()
        self._public_key = public_key_b64url
        self._key_id = key_id
        self.cors_origins = cors_origins

    def render_GET(self, request: server.Request) -> int:
        keys = []
        if self._public_key is not None:
            keys.append({"key_id": self._key_id, "alg": "ed25519", "public_key": self._public_key})
        self._json_response(request, {"keys": keys})
        return server.NOT_DONE_YET


class MiniAppDispatcher(resource.Resource):
    """Dispatcher для /_synapse/client/miniapp/v1/* (маршрутизация putChild)."""

    def __init__(self) -> None:
        super().__init__()


# ---------------------------------------------------------------------------
# Модуль
# ---------------------------------------------------------------------------


class MiniAppModule:
    """Synapse-модуль для Liza Mini Apps (см. docstring файла)."""

    def __init__(self, config: dict[str, Any], api: ModuleApi) -> None:
        self._api = api

        # B2: секрет обязателен, fail-fast при старте (никакого fail-open).
        miniapp_secret = os.environ.get("MINIAPP_SECRET") or config.get("secret", "")
        if not miniapp_secret or miniapp_secret.startswith("${"):
            raise ValueError("MiniAppModule: задайте MINIAPP_SECRET в env или 'secret' в конфиге")
        self._master_secret = miniapp_secret

        self._per_app_keys: bool = bool(config.get("per_app_keys", False))
        auth_date_ttl: int = int(config.get("auth_date_ttl", _DEFAULT_AUTH_DATE_TTL))
        nonce_ttl: int = int(config.get("nonce_ttl", _DEFAULT_NONCE_TTL))
        # ВАЖНО: дефолты хардненинга — legacy-совместимые (opt-in через конфиг),
        # т.к. код модуля шарится с прод-Synapse по bind-mount. Так рестарт прода
        # (без новых ключей в его homeserver.yaml) остаётся поведенческим no-op;
        # хардненинг включается явно в dev-конфиге. verify_room_membership=False =
        # старое поведение (room_id из тела); в dev стоит true.
        verify_room_membership: bool = bool(config.get("verify_room_membership", False))
        cors_origins: tuple[str, ...] = tuple(config.get("cors_allowed_origins", []) or [])

        # Synapse НЕ раскрывает ${VAR} в YAML — резолвим плейсхолдеры через env
        # сами (так же, как secret выше).
        def _resolve_env(val):
            if isinstance(val, str) and val.startswith("${") and val.endswith("}"):
                return os.environ.get(val[2:-1])
            return val

        internal_token: str | None = _resolve_env(config.get("internal_token"))

        static_apps: dict[str, dict] = config.get("apps", {}) or {}
        if not static_apps:
            logger.warning("MiniAppModule: статический список apps пуст")

        # Ed25519 (опц.): seed читаем из файла (gitignored secret).
        self._ed25519_seed: bytes | None = None
        ed25519_public: str | None = None
        ed25519_key_id: str = str(config.get("ed25519_key_id", "1"))
        key_path = config.get("ed25519_private_key_path")
        if key_path:
            try:
                with open(key_path, "rb") as f:
                    seed = f.read().strip()
                # Допускаем raw 32 байта или hex 64 символа.
                if len(seed) == 64:
                    seed = bytes.fromhex(seed.decode("ascii"))
                if len(seed) != 32:
                    raise ValueError(f"ожидается 32 байта seed, получено {len(seed)}")
                self._ed25519_seed = seed
                ed25519_public = _crypto.ed25519_public_key_b64url(seed)
                logger.info("MiniAppModule: Ed25519-подпись включена (key_id=%s)", ed25519_key_id)
            except Exception:
                logger.exception("MiniAppModule: не удалось загрузить Ed25519-ключ %s", key_path)

        # Динамический реестр (опц.): fetcher через http-клиент Synapse.
        # registry_token — отдельный shared-token developer-portal (заголовок
        # X-DevPortal-Token); по умолчанию переиспользуем internal_token.
        fetcher = None
        registry_url = config.get("registry_url")
        registry_token = _resolve_env(config.get("registry_token")) or internal_token
        if registry_url:
            fetcher = self._make_registry_fetcher(registry_url, registry_token)
        self._registry = AppRegistry(
            static_apps,
            ttl=float(config.get("registry_ttl", 60)),
            fetcher=fetcher,
        )

        self._nonce_store = _NonceStore(ttl=nonce_ttl)
        self._rate_limiter = _RateLimiter()

        init_data_resource = InitDataResource(
            api,
            master_secret=self._master_secret,
            per_app_keys=self._per_app_keys,
            registry=self._registry,
            nonce_store=self._nonce_store,
            rate_limiter=self._rate_limiter,
            auth_date_ttl=auth_date_ttl,
            verify_room_membership=verify_room_membership,
            ed25519_seed=self._ed25519_seed,
            ed25519_key_id=ed25519_key_id,
            cors_origins=cors_origins,
        )
        validate_nonce_resource = ValidateNonceResource(self._nonce_store, internal_token=internal_token)
        registry_refresh_resource = RegistryRefreshResource(self._registry, internal_token=internal_token)
        apps_resource = AppsResource(self._registry, cors_origins=cors_origins)
        keys_resource = KeysResource(public_key_b64url=ed25519_public, key_id=ed25519_key_id, cors_origins=cors_origins)

        dispatcher = MiniAppDispatcher()
        dispatcher.putChild(b"init_data", init_data_resource)
        dispatcher.putChild(b"validate_nonce", validate_nonce_resource)
        dispatcher.putChild(b"registry_refresh", registry_refresh_resource)
        dispatcher.putChild(b"apps", apps_resource)
        dispatcher.putChild(b"keys", keys_resource)

        api.register_web_resource("/_synapse/client/miniapp/v1", dispatcher)

        self._schedule_nonce_cleanup()

        logger.info(
            "MiniAppModule загружен (per_app_keys=%s, ed25519=%s, registry=%s, apps: %s)",
            self._per_app_keys,
            self._ed25519_seed is not None,
            "dynamic" if registry_url else "static",
            ", ".join(static_apps.keys()) or "<пусто>",
        )

    def _make_registry_fetcher(self, url: str, registry_token: str | None):
        """Возвращает async-callable, тянущий listed-app из developer-portal.

        Использует http-клиент Synapse (treq) — не блокирует reactor. Контракт
        developer-portal (`GET /internal/v1/apps?state=listed`,
        `servers/developer-portal/.../routes/registry.py`): JSON-СПИСОК объектов
        `{app_id, slug, name, icon_url, base_url, state, manifest_version, scopes, type}`.
        Маппим в формат реестра модуля. Реестровые app по умолчанию внешние
        (`type=third_party`); `first_party` портал ставит только своим системным
        записям (капсулы). Статические из конфига остаются first_party.
        """

        async def _fetch() -> dict[str, dict]:
            headers = {b"X-DevPortal-Token": [registry_token.encode("utf-8")]} if registry_token else {}
            client = self._api.http_client
            body = await client.get_json(url, headers=headers)
            return map_portal_apps(body)

        return _fetch

    # Имя query-параметра состояния у портала — `state`; модуль зовёт
    # `<registry_url>?state=listed` (см. конфиг homeserver.yaml).

    def _schedule_nonce_cleanup(self) -> None:
        def _cleanup():
            try:
                removed = self._nonce_store.cleanup()
                if removed > 0:
                    logger.debug("MiniApp: очищено %d протухших nonce", removed)
            except Exception:
                logger.exception("MiniApp: ошибка при очистке nonce")
            reactor.callLater(_NONCE_CLEANUP_INTERVAL, _cleanup)  # type: ignore[attr-defined]

        reactor.callLater(_NONCE_CLEANUP_INTERVAL, _cleanup)  # type: ignore[attr-defined]
