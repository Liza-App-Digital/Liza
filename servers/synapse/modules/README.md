# Модули Synapse для Liza

Модули работают внутри процесса Synapse (Module API) и образуют с ним одну
программу, поэтому распространяются на условиях GNU AGPL-3.0, как и сам
Synapse (см. `LICENSE`).

## Установка

Каталог устанавливается как Python-пакет `synapse_modules` рядом с исходниками
Synapse: модули импортируют друг друга как `synapse_modules.<модуль>`.
В нашем развёртывании каталог монтируется в контейнер Synapse по пути
`/editable-src/synapse_modules`. Для своей установки достаточно положить его в
`PYTHONPATH` под этим именем и подключить нужные модули в `homeserver.yaml`:

```yaml
modules:
  - module: synapse_modules.client_guard.ClientGuardModule
    config: {}
```

Точные имена классов и параметры `config` — в `__init__.py` каждого модуля.

## Модули

| Модуль | Назначение |
|---|---|
| `access_admin` | управление доступами: обратимая деактивация/реактивация пользователей |
| `block_guard` | блокировка пользователя на уровне сервера |
| `channel_guard` | каналы: создание и публикация только для ролей admin/moderator |
| `channel_stories` | раздача историй канала по членству |
| `channel_sync` | зеркалирование корневых постов канала в привязанный чат |
| `chat_topology_sync_gate` | capability-эндпоинт и учёт возможностей устройств |
| `client_guard` | вход только с клиентов Liza |
| `knock_notify` | пуш админам и модераторам о заявке на вступление |
| `media_lifecycle` | карантин медиа в media-repo при удалении сообщения |
| `media_variants` | постановка видео в очередь транскодинга |
| `miniapp` | платформа мини-приложений |
| `single_space_guard` | ровно одно главное пространство на инстанс |
| `stories_membership` | автоприглашение в сторис и очистка истёкших |
| `user_roles` | роли пользователей (user/ai/developer/moderator/manager/admin) |
| `user_search_guard` | федеративный поиск пользователей между инстансами; скрытие приватных ботов из поиска |

## `user_search_guard`: приватные боты в поиске

Бот по умолчанию приватный: его не находит в поиске никто, кроме владельца.
Видимость хранит реестр liza-bot-api (`bots.discoverable`), модуль только
применяет её на каждом инстансе, поэтому клиент любой версии фильтруется
одинаково.

**Правило** (`_visibility.is_hidden`, чистая функция):

```text
скрыт(user_id, ищущий) = user_id ∈ hidden_users
                         ИЛИ (user_id ∈ приватные_боты И владелец(user_id) ≠ ищущий)
```

`hidden_users` — служебные аккаунты (не боты), скрыты от всех без
исключения для владельца. Бот без владельца в реестре скрыт от всех.

**Где применяется** — один фильтр на трёх путях:

| Путь | Кто ищет | Как |
|---|---|---|
| штатный `/_matrix/client/v3/user_directory/search` | известен | spam-checker колбэк `check_username_for_spam` (True = строка выкидывается) |
| `/_synapse/client/user_search/v1/search` (свои + веер по соседям) | известен | фильтр в `search_local_users` и по ответам соседей (на случай ещё не обновлённого соседа) |
| federation `/_matrix/federation/v1/com.liza/user_search` | неизвестен (origin — сервер) | скрыты все приватные боты; владелец найдёт своего бота в директории своего HS через общий DM |

Точный MXID, профиль, список участников и переписка не затрагиваются —
приватность влияет только на поиск.

**Источник набора.** `GET <registry_url>/registry/v1/hidden` с заголовком
`X-Registry-Secret` → `{"bots": [{"mxid", "owner"}]}`. Опрос — фоном раз в
60 с (`looping_background_call`, на всех процессах инстанса, включая
воркеры) через Twisted-клиент Synapse; на пути запроса поиска сети нет,
читается словарь в памяти. На старте — 3 быстрые попытки с паузой 2 с.

**Fail-safe.** Ошибка сети, 401/5xx или кривой ответ (не объект, нет списка
`bots`) — держим последний удачный набор, поиск не падает. Отдельная битая
строка (нет `mxid`) пропускается, остальные применяются. Если реестр
недоступен с самого старта Synapse, до первого удачного опроса работает
только `hidden_users`.

**Ключи `config`:**

| Ключ | Значение |
|---|---|
| `share_users_over_federation` | отдавать ли своих пользователей соседям (было и раньше) |
| `hidden_users` | список MXID, скрытых от всех (`["@admin:bots.liza.ru"]`) |
| `registry_url` | база liza-bot-api на внутреннем порту, `http://liza-bot-api-bots:9998`; не задан — фильтр только по `hidden_users` (локальный стенд) |
| `registry_secret_path` | YAML, из которого берётся ключ `liza_registry_secret`; на проде — secrets-оверлей инстанса `/run/secrets/synapse/homeserver-secrets.yaml`. Значение — производный read-only секрет `HMAC-SHA256(REGISTRY_SHARED_SECRET, "registry-hidden")`, НЕ сам `REGISTRY_SHARED_SECRET` (тот открывает и создание ботов через agent-provision; `/hidden` исходный отвергает с 401). Модуль шлёт значение из файла как есть |
| `registry_secret` | секрет inline (только для локальной отладки; в tracked-конфиг не класть) |

Секрет и порядок выкладки — `secrets/README.md` и `deploy/DEPLOY.md`
(«Секрет реестра скрытых ботов»). Правка модуля едет volume-mount-ом во все
инстансы: деплой = рестарт каждого Synapse, только с явного «да» владельца.

**Тесты** (нужен venv с `matrix-synapse` и `pytest`; `synapse_modules` —
симлинк на этот каталог в отдельной папке из `PYTHONPATH`):

```bash
mkdir -p /tmp/usg-shim && ln -sfn "$PWD/servers/synapse/modules" /tmp/usg-shim/synapse_modules
PYTHONPATH=/tmp/usg-shim python -m pytest servers/synapse/modules/user_search_guard/tests -q
```
