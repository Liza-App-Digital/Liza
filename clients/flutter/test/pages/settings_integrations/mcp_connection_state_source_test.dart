// Витрина MCP берёт состояние подключений У СЕРВЕРА и двигает его САМА.
//
// Жалоба владельца 2026-09-10: «нажимаю плюсик, чтобы подключить, но ничего не
// происходит» — при том, что на проде в комнате УЖЕ лежало
// `{"enabled":["vkusvill"]}`. Причина — ДВА независимых механизма, каждый из
// которых по отдельности выглядит безобидно:
//
//  1. **Кеш partial-комнаты врёт.** DM с Лизой на экране настроек не открыт,
//     значит `room.partial == true`, и `client.dart:3115` кладёт state в
//     память лишь для типов из `importantStateEvents`. Хуже: промоушен типа в
//     этот набор ПОСТФАКТУМ — это миграция, а не бесплатная строка. Значение,
//     записанное до промоушена, лежит в non-preload-боксе, а `postLoad()`
//     важные типы ИСКЛЮЧАЕТ (`getUnimportantRoomEventStatesForRoom`:
//     `!events.contains(type)`) — то есть оно перестаёт читаться ОТОВСЮДУ.
//
//  2. **Synapse дедуплицирует state-событие с идентичным содержимым.**
//     `EventCreationHandler.deduplicate_state_event`: тот же отправитель +
//     равный canonical-JSON ⇒ возвращается ПРЕЖНЕЕ событие, новое не
//     персистится. Поэтому «пользователь переключит тумблер, и кеш починится
//     перезаписью» — НЕВЕРНО: PUT того же значения не рождает события, в sync
//     ничего не приходит, экран замирает навсегда.
//
// Первый механизм делает картинку неверной, второй — не даёт ей исправиться.
// Отсюда инвариант: экран НЕ доверяет кешу комнаты и НЕ ждёт эха sync.
//
// ledger:RL-mcp-connection-state-source

// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' show Request, Response;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_integrations/settings_integrations.dart';
import 'package:liza/utils/mcp_connections.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

/// Заглушка нативного плагина уведомлений.
///
/// ⚠️ Обязательна для ЭТОГО файла, и вот почему. Экран спрашивает состояние у
/// сервера, поэтому тесту нужен `tester.runAsync` — реальные обороты
/// event-loop. За эти обороты успевают отработать подписки `MatrixState`, и
/// `BackgroundPush.updateBadgeCount` дёргает `cancelAll()` нативного плагина,
/// которого в host-тесте нет: `FlutterLocalNotificationsPlatform._instance`
/// объявлен `late` и никем не инициализирован. Падает это АСИНХРОННОЙ ошибкой
/// (`handleUncaughtError`), которую подмена `FlutterError.onError` уже НЕ
/// перехватывает, — поэтому глушим на уровне самого плагина, а не ошибки.
/// К витрине MCP отношения не имеет.
class _NoopLocalNotifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<void> cancelAll() async {}
}

/// FakeMatrixApi, умеющий ПРИДЕРЖАТЬ уже сформированный ответ.
///
/// Нужен, чтобы детерминированно воспроизвести гонку двух писателей состояния:
/// тело ответа снимается СРАЗУ (то есть отражает сервер ДО записи), а сам
/// ответ отдаётся клиенту только после `release()` — уже ПОСЛЕ того, как
/// пользователь нажал «+». Без такого контроля порядок ответов в тесте
/// случаен, и гонка ловилась бы флаки-режимом, а не красным тестом.
class _GateableApi extends FakeMatrixApi {
  _GateableApi(this.gatedPathFragment);

  final String gatedPathFragment;
  final Completer<void> _gate = Completer<void>();
  bool _armed = false;

  /// Придержать СЛЕДУЮЩИЙ GET по этому пути (ровно один — стартовый фетч).
  void armOnce() => _armed = true;
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  @override
  FutureOr<Response> mockIntercept(Request request) async {
    final gate =
        _armed &&
        request.method == 'GET' &&
        request.url.path.contains(gatedPathFragment);
    if (gate) _armed = false;
    // Ответ формируем ДО ожидания — иначе тело отразило бы уже новое
    // состояние сервера, и «устаревшего» ответа не получилось бы.
    final response = await super.mockIntercept(request);
    if (gate) await _gate.future;
    return response;
  }
}

void main() {
  const lizaMxid = '@liza:bots.liza.ru';
  const roomId = '!mcp:example.invalid';
  // ⚠️ Ключ маршрута считаем ТОЙ ЖЕ нормализацией `Uri`, что проходит реальный
  // запрос: `Uri.encodeComponent('!')` даёт `%21`, но `Uri` возвращает его
  // обратно в `!` (sub-delim разрешён в пути). Собранный «на глаз» путь с
  // `%21` не совпадёт с тем, что видит FakeMatrixApi, — маршрут молча не
  // сматчится, и тест померяет отсутствие ответа вместо поведения экрана.
  final statePath = Uri.parse(
    'https://fakeserver.notexisting/_matrix/client/v3/rooms/'
    '${Uri.encodeComponent(roomId)}/state/$mcpConnectionsStateType/',
  ).path.split('/_matrix').last.replaceFirst(RegExp(r'/$'), '');

  late Client client;
  late SharedPreferences store;
  late _GateableApi api;

  /// Что «лежит на сервере». Тест меняет это поле, а не кеш комнаты, —
  /// в этом вся суть: кеш и сервер обязаны уметь расходиться.
  late List<String> serverEnabled;

  /// Сколько раз клиент записал состояние (PUT).
  late int writes;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterLocalNotificationsPlatform.instance = _NoopLocalNotifications();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    serverEnabled = [];
    writes = 0;

    api = _GateableApi(mcpConnectionsStateType);
    // GET состояния — АВТОРИТЕТНЫЙ источник.
    api.api['GET'] ??= {};
    api.api['GET']![statePath] = (_) => {'enabled': serverEnabled};
    // PUT состояния отвечает event_id и НИЧЕГО не шлёт в sync — ровно так
    // ведёт себя Synapse при дедупликации (и так же выглядит любой лаг sync).
    api.api['PUT'] ??= {};
    api.api['PUT']![statePath] = (dynamic body) {
      writes++;
      // ⚠️ FakeMatrixApi отдаёт хендлеру СЫРОЕ тело запроса строкой (для GET —
      // queryParameters, для PUT — `request.body`). Без decode `body['enabled']`
      // молча null, и тест «проверил» бы запись, которой не было.
      final decoded = body is String ? jsonDecode(body) : body;
      final raw = decoded is Map ? decoded['enabled'] : null;
      if (raw is List) serverEnabled = raw.whereType<String>().toList();
      return {'event_id': '\$mcp_state_$writes'};
    };

    client = await prepareTestClient(loggedIn: true, httpClient: api);
    // Фоновый sync держит таймер живым и роняет тест на pending Timer.
    client.backgroundSync = false;
    client.rooms.clear();

    final room = Room(id: roomId, client: client);
    // Право писать state: без m.room.power_levels `canChangeStateEvent`
    // сравнивает с `state_default` (50) и вернул бы false.
    room.setState(
      Event(
        type: EventTypes.RoomPowerLevels,
        eventId: '\$pl',
        senderId: client.userID!,
        originServerTs: DateTime.now(),
        room: room,
        stateKey: '',
        content: {
          'users': {client.userID!: 100},
          'state_default': 50,
          'events_default': 0,
        },
      ),
    );
    // ⚠️ `com.liza.mcp.connections` в кеш комнаты НЕ кладём и `partial`
    // оставляем true — это и есть прод-ситуация, в которой экран сломался.
    client.rooms.add(room);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        lizaMxid: [roomId],
      },
    );

    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  /// Глушим РОВНО два чужих шума, каждый — поимённо.
  ///
  /// 1. overflow шрифта Ahem: он рисует глиф квадратом в кегль и переполняет
  ///    там, где реальный шрифт укладывается (вёрстку меряет Ярус B).
  /// 2. `LateInitializationError` из `flutter_local_notifications`: экран
  ///    прокручивается достаточно долго, чтобы `BackgroundPush.updateBadgeCount`
  ///    дотянулся до нативного плагина, которого в host-тесте нет. К витрине
  ///    MCP отношения не имеет; ловим ПО СТЕКУ, а не по типу ошибки, чтобы не
  ///    проглотить настоящий LateError экрана.
  void ignoreForeignNoise() {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      final stack = details.stack?.toString() ?? '';
      if (details.exception.toString().contains('A RenderFlex overflowed') ||
          stack.contains('flutter_local_notifications') ||
          stack.contains('background_push.dart')) {
        return;
      }
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);
  }

  /// `pumpAndSettle` + прокрутка РЕАЛЬНОГО async.
  ///
  /// ⚠️ Обязательно: экран спрашивает состояние у сервера, а под fake-async
  /// `testWidgets` реальный HTTP (пусть и через `FakeMatrixApi`) не доигрывает
  /// — фьючер повисает, `setState` не случается, и тест померил бы «экран не
  /// обновился» там, где не доработал сам тест. `runAsync` даёт настоящему
  /// event-loop провернуться.
  Future<void> settleWithNetwork(WidgetTester tester) async {
    // Два круга «реальный async → отрисовка», и ни один нельзя выкинуть:
    //  • сначала обороты РЕАЛЬНОГО event-loop одиночными кадрами. Наоборот
    //    нельзя — после тапа поверх экрана висит `showFutureLoadingDialog` со
    //    спиннером, и `pumpAndSettle` ждал бы конца анимации, которая
    //    закончится лишь когда доиграет запрос, а тот под fake-async не
    //    двигается. Дедлок выглядит как «pumpAndSettle timed out» при
    //    исправном коде;
    //  • затем `pumpAndSettle` — он доводит до конца сборку экрана и анимации;
    //  • и ещё круг: запрос, начатый уже ПОСЛЕ первой отрисовки (наш
    //    postFrame-фетч — ровно такой), успевает ответить только теперь.
    for (var round = 0; round < 2; round++) {
      await tester.pump();
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
    }
  }

  Future<void> pumpScreen(WidgetTester tester) async {
    ignoreForeignNoise();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Matrix(
            clients: [client],
            store: store,
            child: const SettingsIntegrationsPage(),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        locale: const Locale('ru'),
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10n.supportedLocales,
        routerConfig: router,
      ),
    );
    await settleWithNetwork(tester);
  }

  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  /// Иконка действия карточки: `check_circle` ⇒ подключено.
  bool cardShowsConnected(WidgetTester tester, String id) {
    final card = find.ancestor(
      of: find.byKey(Key('mcpBadge_$id')),
      matching: find.byType(Card),
    );
    expect(card, findsOneWidget, reason: 'карточка $id не найдена');
    return tester
        .widgetList<Icon>(
          find.descendant(of: card, matching: find.byType(Icon)),
        )
        .any((i) => i.icon == Icons.check_circle);
  }

  // AC:RL-mcp-connection-state-source/1
  testWidgets(
    'состояние читается с СЕРВЕРА, даже когда кеш partial-комнаты пуст',
    (tester) async {
      serverEnabled = ['vkusvill'];
      await pumpScreen(tester);
      final l10n = (await tester.runAsync(
        () => L10n.delegate.load(const Locale('ru')),
      ))!;

      // Кеш комнаты ПУСТ — убеждаемся, что тест меряет именно серверный путь,
      // а не случайно наполнившийся кеш.
      expect(
        McpConnections.readEnabled(client.getRoomById(roomId)),
        isEmpty,
        reason: 'предусловие теста: в кеше комнаты состояния быть не должно',
      );

      expect(
        find.text(l10n.settingsMcpConnectedSection),
        findsOneWidget,
        reason:
            'ВкусВилл включён на сервере — секция «Подключенные» обязана '
            'появиться, иначе экран врёт про состояние',
      );
      expect(cardShowsConnected(tester, 'vkusvill'), isTrue);

      await teardownTree(tester);
    },
  );

  // AC:RL-mcp-connection-state-source/2
  testWidgets(
    'тап по «+» переключает карточку БЕЗ эха sync (Synapse дедуплицирует)',
    (tester) async {
      await pumpScreen(tester);
      final l10n = (await tester.runAsync(
        () => L10n.delegate.load(const Locale('ru')),
      ))!;

      expect(cardShowsConnected(tester, 'vkusvill'), isFalse);
      expect(find.text(l10n.settingsMcpConnectedSection), findsNothing);

      final plus = find.descendant(
        of: find.ancestor(
          of: find.byKey(const Key('mcpBadge_vkusvill')),
          matching: find.byType(Card),
        ),
        matching: find.byIcon(Icons.add_circle_outline),
      );
      expect(plus, findsOneWidget);
      await tester.tap(plus);
      await settleWithNetwork(tester);

      expect(writes, 1, reason: 'запись на сервер не ушла вовсе');
      expect(serverEnabled, [
        'vkusvill',
      ], reason: 'на сервер уехало не то значение');
      // Ключевой ассерт: sync НИЧЕГО не прислал (как при дедупликации), а
      // экран обязан всё равно показать подключение.
      expect(
        cardShowsConnected(tester, 'vkusvill'),
        isTrue,
        reason:
            'после успешной записи карточка обязана показать подключение, '
            'не дожидаясь эха sync: Synapse его законно может не прислать',
      );
      expect(find.text(l10n.settingsMcpConnectedSection), findsOneWidget);

      await teardownTree(tester);
    },
  );

  // AC:RL-mcp-connection-state-source/4
  testWidgets(
    'устаревший ответ фонового запроса НЕ откатывает тап пользователя',
    (tester) async {
      // Стартовый фетч уходит, пока на сервере пусто, и ЗАСТРЕВАЕТ в полёте.
      api.armOnce();
      await pumpScreen(tester);
      expect(
        cardShowsConnected(tester, 'vkusvill'),
        isFalse,
        reason: 'предусловие: до тапа расширение отключено',
      );

      // Пользователь жмёт «+». Запись проходит, экран показывает подключение.
      await tester.tap(
        find.descendant(
          of: find.ancestor(
            of: find.byKey(const Key('mcpBadge_vkusvill')),
            matching: find.byType(Card),
          ),
          matching: find.byIcon(Icons.add_circle_outline),
        ),
      );
      await settleWithNetwork(tester);
      expect(writes, 1, reason: 'запись на сервер не ушла');
      expect(cardShowsConnected(tester, 'vkusvill'), isTrue);

      // ...и только ТЕПЕРЬ долетает придержанный ответ стартового запроса —
      // со снимком сервера ДО записи (пусто).
      api.release();
      await settleWithNetwork(tester);

      expect(
        cardShowsConnected(tester, 'vkusvill'),
        isTrue,
        reason:
            'ответ, отправленный ДО тапа, откатил состояние — для '
            'пользователя это снова «нажал плюсик, ничего не произошло», '
            'только по другой причине',
      );
      expect(serverEnabled, [
        'vkusvill',
      ], reason: 'на сервере запись должна была сохраниться');

      await teardownTree(tester);
    },
  );

  // AC:RL-mcp-connection-state-source/3
  testWidgets('сервер недоступен → показанное состояние не гасится', (
    tester,
  ) async {
    // GET падает: смоделируем недостижимый эндпоинт (405 от FakeMatrixApi).
    api.api['GET']![statePath] = (_) => {'errcode': 'M_UNKNOWN'};
    await pumpScreen(tester);

    // Кеш пуст и сервер не ответил — карточка просто остаётся неподключённой,
    // без исключений и без пустого экрана.
    expect(cardShowsConnected(tester, 'vkusvill'), isFalse);
    expect(tester.takeException(), isNull);

    await teardownTree(tester);
  });

  // AC:RL-mcp-xl-status-server-truth/1
  test('карточка XL не выставляет «подключено» сама', () {
    final src = File(
      'lib/pages/settings_integrations/settings_integrations.dart',
    ).readAsStringSync();
    // Статус и ключ — через серверный HTTP (Bot API → liza-memory), не state.
    expect(src, isNot(contains('XlStatus.write')));
    expect(src, isNot(contains('_serverXlConnected = true')));
    expect(src, contains('XlApi.connect'));
    // Ключ больше не отправляется сообщением в переписку.
    expect(src, isNot(contains('sendEvent(XlCredentials.buildEvent')));
  });
}
