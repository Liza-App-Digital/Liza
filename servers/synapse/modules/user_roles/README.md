# user_roles

Synapse-модуль управления ролями пользователей с динамическим каталогом в БД.

Каждый юзер имеет ровно одну роль, хранящуюся в его `account_data` под типом `com.liza.user_role`. Список доступных ролей и их человекочитаемых названий (русский label + опциональный hex-цвет) живёт в таблице `user_roles_catalog` (см. `_catalog.py`).

Поверх основной роли можно выставить персональные доп. роли — необязательное поле `extra_roles` (список кодов каталога): `PUT …/role/<user_id>` `{"role": "admin", "extra_roles": ["developer"]}`. PUT без ключа `extra_roles` сохраняет их, только если основная роль не меняется; смена основной роли без ключа их снимает, `[]` — снимает всегда. `admin` в `extra_roles` → 400: серверные гейты (`channel_guard`, `access_admin`) читают только основную роль. v2-ответы (GET/batch/to-device/federation) добавляют `extra_roles` в объект роли тех, у кого поле записано, — видно любому, кто читает роль; у остальных формат не меняется.

## Доступные эндпоинты

### Клиентские (любой залогиненный юзер)

```
GET  /_synapse/client/roles/v1/role            # своя роль
GET  /_synapse/client/roles/v1/role/<user_id>  # роль произвольного юзера
POST /_synapse/client/roles/v1/batch           # массовое чтение ролей
GET  /_synapse/client/roles/v1/roles           # список всех ролей в каталоге
```

Все клиентские эндпоинты принимают опциональный query-флаг `?v=2`. Без флага возвращается legacy-формат (голая строка `"ai"`), с флагом - объект `{code,label,color}`. Старые клиенты продолжают работать; новые сразу получают денормализованный payload.

### Federation (server-to-server)

```
GET /_matrix/federation/v1/com.liza/user_roles_batch?user_ids=...
```

Доступен по X-Matrix federation signing (без admin-токена, без user access_token). Возвращает `{code,label,color}|null` для каждого ЛОКАЛЬНОГО `user_id` из запроса; запросы по чужим `user_id` молча игнорируются (анти-loop защита: federated server не должен пере-проксировать дальше).

Используется внутренне самим сервером: когда в batch-запрос приходят federated user_ids, наш Synapse ходит по этому пути на чужие HS и кэширует ответ на 5 минут. Если админ поменял роль на удалённом HS, локальный кэш протухнет максимум через TTL.

### Админские (требуют admin-токен)

```
GET    /_synapse/admin/v1/user_roles/role                     # своя роль
GET    /_synapse/admin/v1/user_roles/role/<user_id>           # роль юзера
PUT    /_synapse/admin/v1/user_roles/role/<user_id>           # сменить роль юзера
POST   /_synapse/admin/v1/user_roles/catalog                  # добавить роль
PATCH  /_synapse/admin/v1/user_roles/catalog/<code>           # переименовать/перекрасить
DELETE /_synapse/admin/v1/user_roles/catalog/<code>           # удалить роль
POST   /_synapse/admin/v1/user_roles/catalog/reload           # подхватить прямые SQL правки
```

Старый путь `PUT /_synapse/client/roles/v1/role/<user_id>` сохранён как deprecated alias на тот же handler. Будет удалён после раскатки нового Flutter-клиента (см. Phase 3 в spec).

### ⚠️ Почему админ-эндпоинты не через `register_web_resource`

`/_synapse/admin` — это `JsonResource` с `isLeaf = True`
(`synapse/http/server.py`). `create_resource_tree` цепляет ресурсы модуля
детьми этого листа, но Twisted не обходит детей листа: запрос сразу уходит в
`render` админского `JsonResource`, и вложенный ресурс отдаёт 404
`M_UNRECOGNIZED`. Именно так админ-пути ролей молча не работали с момента
появления (Task 6/7): клиентский deprecated-алиас работал, а `PUT` в
`/_synapse/admin/...` — нет.

Поэтому модуль регистрирует админ-маршруты servlet'ами **на самом**
admin-JsonResource (`_admin_servlets.py`, патч
`synapse.rest.admin.register_servlets`). Не возвращайте
`api.register_web_resource("…/_synapse/admin/…")` — пути снова станут
недостижимыми. Тест-страж:
`tests/test_admin_servlets.py` (`ledger:RL-user-roles-admin-route-reachable`).

## Управление каталогом

### Добавить роль

```bash
curl -X POST https://synapse.liza.laba.prodamus.tech/_synapse/admin/v1/user_roles/catalog \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "cyber_agronom",
    "display_name": "Кибер-Агроном",
    "color": "#7CB342"
  }'
```

Ответы:
- `201` - создано, возврат `{code,label,color}`.
- `400` - невалидный `code` (regex `^[a-z0-9_]{1,64}$`) или невалидный `color` (regex `^#[0-9a-fA-F]{6}$`), либо пустой `display_name`.
- `409` - роль с таким `code` уже существует.

Поле `color` опциональное. NULL означает "клиент использует свой дефолтный цвет" (зелёный `#4CAF50`).

### Переименовать или перекрасить

```bash
curl -X PATCH https://synapse.liza.laba.prodamus.tech/_synapse/admin/v1/user_roles/catalog/cyber_agronom \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"display_name": "Кибер-Агрохимик"}'
```

Можно передавать только `display_name`, только `color`, или оба. `{"color": null}` явно очищает цвет (в отличие от отсутствия ключа, которое означает "не трогать").

После PATCH сервер триггерит to-device рассылку `com.liza.user_role` всем носителям этой роли и их со-участникам по комнатам - клиенты получают новый label мгновенно через `/sync`.

### Удалить

```bash
curl -X DELETE https://synapse.liza.laba.prodamus.tech/_synapse/admin/v1/user_roles/catalog/cyber_agronom \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

Ответы:
- `204` - удалено.
- `404` - такой роли нет.
- `409` - у роли есть носители. Сначала переназначь их (`PUT /role/<uid>`), потом удаляй. Это защита от случайного удаления массово используемой роли.

### Прямой SQL + reload

Если удобнее ввести роль через psql на сервере:

```sql
INSERT INTO user_roles_catalog (code, display_name, color, created_ts, updated_ts)
VALUES ('cyber_agronom', 'Кибер-Агроном', '#7CB342', extract(epoch from now())*1000, extract(epoch from now())*1000);
```

После этого обязательно дёрни reload, чтобы Synapse подхватил кэш и разослал to-device:

```bash
curl -X POST https://synapse.liza.laba.prodamus.tech/_synapse/admin/v1/user_roles/catalog/reload \
  -H "Authorization: Bearer $ADMIN_TOKEN"
```

Ответ: `{"reloaded": true, "count": <N>, "changed": [<codes>]}`. Только коды из `changed` (добавленные или изменённые) триггерят broadcast - убранные напрямую через SQL не обрабатываются (если такое надо, сначала PATCH'ом перенази носителей, потом удаляй через DELETE).

## Назначение ролей пользователям

```bash
curl -X PUT https://synapse.liza.laba.prodamus.tech/_synapse/admin/v1/user_roles/role/@bob:synapse.liza.laba.prodamus.tech \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"role": "cyber_agronom"}'
```

Ответы:
- `200` - роль обновлена. В account_data юзера пишутся ОБА поля: `role` (legacy строка) + `role_v2` (объект `{code,label,color}`). Триггерится to-device рассылка.
- `404` - юзер не существует, либо `role` не в каталоге.
- `400` - тело не валидно (`role` должен быть непустой строкой).
- `403` - не admin.

## Конфигурация в `homeserver.yaml`

```yaml
modules:
  - module: synapse_modules.user_roles.UserRolesModule
    config:
      default_role: "user"
```

`default_role` - роль, присваиваемая новым пользователям при регистрации. Должна существовать в каталоге; если нет - модуль залогирует error, но не сломает старт Synapse (запросы PUT с этой ролью просто будут возвращать 404).

## Дефолтные роли (seed при первой миграции)

| code | display_name | color |
|---|---|---|
| `user` | Пользователь | NULL |
| `ai` | ИИ | `#4CAF50` |
| `developer` | Разработчик | NULL |
| `moderator` | Модератор | NULL |
| `manager` | Менеджер | NULL |
| `admin` | Администратор | NULL |

Сид идемпотентный (ON CONFLICT DO NOTHING). При повторных миграциях существующие записи не перезаписываются.

## Где взять admin-token

Synapse admin token хранится в `secrets/synapse/admin.json`.
