import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';

/// Тип state-event, в котором живёт список включённых MCP-расширений.
///
/// Именно **state-event** (`state_key: ''`) в DM с ботом, а не служебное
/// `m.room.message`, как у XL-ключа (`com.liza.xl.credentials`). Причины:
/// запись идемпотентна (повторное включение не плодит событий в таймлайне),
/// бот читает актуальное значение по требованию через `room_get_state_event`
/// и не теряет его при рестарте контейнера, а state-события в Matrix НИКОГДА
/// не шифруются — значит бот прочитает их независимо от статуса E2EE комнаты.
/// Тот же приём уже используется для мини-аппов (`com.liza.miniapp.config`).
const String mcpConnectionsStateType = 'com.liza.mcp.connections';

/// Тематика расширения: человеческий заголовок + тул, который её обеспечивает.
///
/// [toolSlug] — НЕ украшение: страж `test_mcp_showcase_truth.py` сверяет его с
/// серверным allowlist (`mcp_ext.CATALOG[...]['tools']`). Тематика без живого
/// тула = обещание, которое Лиза не выполнит, и тест краснеет. Именно так
/// вчера молча соврало бы описание, когда `vkusvill_shops` убрали из allowlist.
@immutable
class McpTopic {
  const McpTopic(this.slug, this.toolSlug);

  /// ASCII-слаг: из него собирается ключ L10n (`settingsMcpTopic_<id>_<slug>`).
  /// ASCII — чтобы ратчет «кириллица вне поля name запрещена» не ломался.
  final String slug;

  /// Имя тула БЕЗ префикса сервера: `products_search` → `vkusvill_products_search`.
  final String toolSlug;
}

/// Описание MCP-сервера в витрине.
///
/// [tint] и [mark] — плашка-логотип (инициалы на цветном квадрате): готовых
/// логотипов у сервисов нет, а плашка читается в обеих темах.
@immutable
class McpServer {
  const McpServer({
    required this.id,
    required this.name,
    required this.mark,
    required this.tint,
    this.requiresKey = false,
    this.topics = const [],
    this.examples = const [],
    this.addressee = McpAddressee.liza,
  });

  final String id;

  /// Имя сервиса — ЕДИНСТВЕННОЕ поле-литерал: это бренд, он не переводится.
  /// Всё остальное текстовое живёт в `.arb` (правило CLAUDE.md «UI-строки
  /// только через L10n»); ратчет в тесте запрещает кириллицу вне этого поля.
  final String name;

  final String mark;
  final Color tint;

  /// Сервер требует персонального ключа (как XL). Такие подключаются не
  /// тумблером, а вводом ключа — у них своя, уже существующая механика.
  final bool requiresKey;

  /// Тематики для раскрытой карточки. Пусто → блок не рендерится.
  final List<McpTopic> topics;

  /// ASCII-слаги примеров команд (`settingsMcpEx_<id>_<slug>`). Пусто → блока
  /// примеров нет (INV-5: тогда карточка ОБЯЗАНА назвать адресата).
  ///
  /// ⚠️ Каждый пример машинно проверяется на прохождение серверного гейта
  /// `mcp_intent`. Писать «на глаз» нельзя: «Состав хумуса» и «Найди авокадо»
  /// гейт НЕ пропускает, «Что есть из скидок» ломается на морфологии.
  final List<String> examples;

  /// Кому адресованы команды: у ВкусВилла — Лизе, у XL — отдельному боту.
  final McpAddressee addressee;
}

/// Кому пользователь пишет команды этого расширения.
///
/// Не косметика: ВкусВилл работает в DM с Лизой, а XL — это ОТДЕЛЬНЫЙ бот
/// `@xl_bot`, и его `'xl'` вообще отсутствует в серверном `CATALOG` Лизы, то
/// есть через Лизу он невключаем в принципе. Не назвать адресата = отправить
/// пользователя писать команду туда, где её никто не слушает.
enum McpAddressee { liza, xlBot }

/// Каталог доступных расширений.
///
/// Константа, а НЕ серверный реестр: серверов пока два, и публичный эндпоинт
/// с аутентификацией под каталог из двух карточек — преждевременная абстракция
/// (`project-standards.md`: «Три похожих места лучше преждевременной
/// абстракции»). Условие пересмотра зафиксировано в спеке: **третий сервер
/// ⇒ каталог переезжает на сервер** по образцу `GET /liza/mybots`, чтобы
/// добавление MCP перестало требовать релиза в сторы.
///
/// Карточек-заглушек «скоро будет» здесь намеренно нет: в макете-прототипе их
/// восемь (Google Drive, Notion, Jira…), но ни один из них не подключается —
/// восемь кнопок «+», семь из которых ничего не делают, хуже одного честного
/// тумблера.
const List<McpServer> mcpCatalog = [
  McpServer(
    id: 'vkusvill',
    name: 'ВкусВилл',
    mark: 'BB',
    tint: Color(0xFF4A9E5C),
    // По тематике на каждый из 8 тулов сервера (с 2026-09-11 все идут через
    // фасад `vkusvill_facade.py`). Страж правдивости краснеет и на тематику
    // без тула, и на тул без тематики.
    topics: [
      McpTopic('search', 'products_search'),
      McpTopic('price', 'products_search'),
      McpTopic('details', 'product_details'),
      McpTopic('cart', 'cart_link_create'),
      McpTopic('shops', 'shops'),
      McpTopic('recipes', 'recipes'),
      McpTopic('discount', 'products_discount'),
      McpTopic('analogs', 'product_analogs'),
      McpTopic('barcode', 'product_barcode'),
    ],
    // Не больше шести: примеры рисуются строкой каждый, и восемь превращали
    // раскрытую карточку в простыню. Все проходят живой mcp_intent. Для
    // штрихкода примера нет намеренно — реального кода товара под рукой у
    // пользователя нет, а выдуманный пример — обещание неработающего.
    examples: ['milk', 'kbju', 'cart', 'shop', 'recipe', 'discount'],
  ),
  McpServer(
    id: 'xl',
    name: 'Платформа XL',
    mark: 'XL',
    tint: Color(0xFF3A6EA5),
    requiresKey: true,
    // topics/examples ПУСТЫ намеренно: у xl.py нет allowlist вовсе, его
    // XL_MCP_URL по умолчанию тестовый, а 'xl' отсутствует в серверном
    // CATALOG Лизы. Обещать проверяемые тематики нечем — вместо этого
    // раскрытие называет адресата.
    addressee: McpAddressee.liza,
  ),
];

/// Работа со списком включённых MCP-расширений.
abstract final class McpConnections {
  /// Читает включённые расширения из ЛОКАЛЬНОГО кеша комнаты.
  ///
  /// ⚠️ Это ЗАПАСНОЙ путь (офлайн/первый кадр), а не источник истины: в
  /// partial-комнате кеш врёт молча. Авторитетное чтение — [fetch]. Подробно,
  /// почему одного кеша мало, — в докстринге [fetch].
  static Set<String> readEnabled(Room? room) {
    if (room == null) return {};
    final content = room.getState(mcpConnectionsStateType, '')?.content;
    return _parse(content?['enabled']);
  }

  /// Спрашивает состояние подключений У СЕРВЕРА.
  ///
  /// Источник истины — комната на сервере: то же значение читает бот, поэтому
  /// UI и бот не могут разойтись (в отличие от схемы «состояние в памяти бота
  /// + переотправка клиентом», где рестарт контейнера ронял подключение).
  ///
  /// ⚠️ Почему НЕЛЬЗЯ обойтись локальным кешем (выстрадано 2026-09-10, жалоба
  /// владельца «нажимаю плюсик, но ничего не происходит»). Два независимых
  /// механизма делают кеш ненадёжным ИМЕННО на этом экране:
  ///  1. **partial-комната.** DM с Лизой на экране настроек не открыт, а
  ///     `client.dart:3115` кладёт state в память лишь при `!room.partial ||
  ///     importantStateEvents.contains(type)`. Плюс промоушен типа в
  ///     `importantStateEvents` ПОСТФАКТУМ — это миграция: значение, записанное
  ///     до промоушена, лежит в non-preload-боксе, а `postLoad()` важные типы
  ///     ИСКЛЮЧАЕТ (`getUnimportantRoomEventStatesForRoom`) — то есть оно не
  ///     читается уже НИОТКУДА.
  ///  2. **Synapse дедуплицирует state-событие с идентичным содержимым**
  ///     (`EventCreationHandler.deduplicate_state_event`: тот же отправитель +
  ///     равный canonical-JSON ⇒ возвращается прежнее событие, новое НЕ
  ///     персистится). Значит «перезапишем — и кеш починится сам» НЕ работает:
  ///     PUT того же значения не рождает события, в sync ничего не приходит,
  ///     UI остаётся прежним. Ровно это и выглядело как мёртвый плюсик.
  ///
  /// `null` — «спросить не удалось» (сеть/таймаут): вызывающий обязан НЕ
  /// затирать этим уже показанное состояние. Отсутствие события (`M_NOT_FOUND`)
  /// — это не ошибка, а пустой набор.
  static Future<Set<String>?> fetch(Room room) async {
    try {
      final content = await room.client
          .getRoomStateWithKey(room.id, mcpConnectionsStateType, '')
          .timeout(const Duration(seconds: 15));
      return _parse(content['enabled']);
    } on MatrixException catch (e) {
      if (e.errcode == 'M_NOT_FOUND') return <String>{};
      Logs().w('MCP: не удалось прочитать состояние подключений', e);
      return null;
    } catch (e, s) {
      // Логируем ОБЯЗАТЕЛЬНО: без записи программная ошибка (регресс парсера,
      // NoSuchMethodError) неотличима от честного «сеть не ответила» — экран в
      // обоих случаях молча остаётся как был, и дефект не виден ниоткуда.
      Logs().w('MCP: сбой запроса состояния подключений', e, s);
      return null;
    }
  }

  static Set<String> _parse(Object? raw) =>
      raw is List ? raw.whereType<String>().toSet() : <String>{};

  /// Несёт ли sync-апдейт изменение подключений (правка с другого устройства
  /// или самим ботом). Конкретный room id здесь проверять нельзя — на момент
  /// фильтрации комната могла ещё не появиться в `client.rooms`.
  static bool syncAffectsConnections(SyncUpdate sync) =>
      sync.rooms?.join?.values.any(
        (room) =>
            room.state?.any((e) => e.type == mcpConnectionsStateType) ?? false,
      ) ??
      false;

  /// Может ли пользователь писать состояние в эту комнату.
  ///
  /// DM создаёт клиент (`startDirectChat`), поэтому автор обычно PL100. Но
  /// легаси-DM (эпоха деактивированного `@liza:synapse…`, инстанс-компании)
  /// могут отличаться — без проверки пользователь увидел бы «Подключено» при
  /// молча провалившейся записи.
  ///
  /// ⚠️ Именно `canChangeStateEvent`, а НЕ `canSendEvent`: последний считает
  /// порог по `events_default` (обычно 0), тогда как для state-события порог
  /// берётся из `state_default` (обычно 50). `canSendEvent` вернул бы `true`
  /// там, где сервер ответит `M_FORBIDDEN`.
  static bool canWrite(Room? room) {
    if (room == null) return false;
    return room.canChangeStateEvent(mcpConnectionsStateType);
  }

  /// Записывает новый набор включённых расширений.
  ///
  /// Идемпотентно: `PUT .../state/<type>/` заменяет текущее значение, а не
  /// добавляет новое — сколько бы раз ни щёлкнули тумблером.
  static Future<void> write(Room room, Set<String> enabled) =>
      room.client.setRoomStateWithKey(room.id, mcpConnectionsStateType, '', {
        'enabled': enabled.toList()..sort(),
      });
}

// ── Резолверы текста витрины ────────────────────────────────────────────────
// Проза живёт в `.arb` (правило CLAUDE.md «UI-строки только через L10n»), а в
// каталоге — ASCII-слаги. Это НЕ лишний слой: страж
// `test_mcp_showcase_truth.py` читает `.arb` как обычный JSON и сверяет
// примеры с серверным `mcp_intent`, а тематики — с allowlist. Была бы проза в
// .dart — сверить было бы нечем, и витрина молча разошлась бы с поведением.
// `null` вместо пустой строки: у сервиса может не быть блока (у XL нет тематик).

String mcpServerDescription(L10n l10n, String id) => switch (id) {
  'vkusvill' => l10n.settingsMcpDescVkusvill,
  'xl' => l10n.settingsMcpDescXl,
  _ => '',
};

String? mcpServerAbout(L10n l10n, String id) => switch (id) {
  'vkusvill' => l10n.settingsMcpAboutVkusvill,
  'xl' => l10n.settingsMcpAboutXl,
  _ => null,
};

String? mcpServerLimits(L10n l10n, String id) => switch (id) {
  'vkusvill' => l10n.settingsMcpLimitsVkusvill,
  _ => null,
};

String mcpTopicTitle(L10n l10n, String serverId, String slug) =>
    switch ('$serverId/$slug') {
      'vkusvill/search' => l10n.settingsMcpTopic_vkusvill_search,
      'vkusvill/price' => l10n.settingsMcpTopic_vkusvill_price,
      'vkusvill/details' => l10n.settingsMcpTopic_vkusvill_details,
      'vkusvill/cart' => l10n.settingsMcpTopic_vkusvill_cart,
      'vkusvill/shops' => l10n.settingsMcpTopic_vkusvill_shops,
      'vkusvill/recipes' => l10n.settingsMcpTopic_vkusvill_recipes,
      'vkusvill/discount' => l10n.settingsMcpTopic_vkusvill_discount,
      'vkusvill/analogs' => l10n.settingsMcpTopic_vkusvill_analogs,
      'vkusvill/barcode' => l10n.settingsMcpTopic_vkusvill_barcode,
      _ => slug,
    };

String mcpExampleText(L10n l10n, String serverId, String slug) =>
    switch ('$serverId/$slug') {
      'vkusvill/milk' => l10n.settingsMcpEx_vkusvill_milk,
      'vkusvill/kbju' => l10n.settingsMcpEx_vkusvill_kbju,
      'vkusvill/cart' => l10n.settingsMcpEx_vkusvill_cart,
      'vkusvill/shop' => l10n.settingsMcpEx_vkusvill_shop,
      'vkusvill/recipe' => l10n.settingsMcpEx_vkusvill_recipe,
      'vkusvill/discount' => l10n.settingsMcpEx_vkusvill_discount,
      _ => slug,
    };
