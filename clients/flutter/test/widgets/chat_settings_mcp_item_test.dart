// Пункт «MCP-подключения» в меню «три точки» — на РЕАЛЬНОМ меню, не на реплике.
//
// Требование продакта (2026-09-10): «в Лиза ИИ, где три точки добавить раздел
// МСР-подключения». Ключевое слово — «в Лиза ИИ»: пункт обязан быть ТОЛЬКО в DM
// с живым ассистентом.
//
// Очевидный на вид гейт `isAiUser` здесь НЕВЕРЕН: роль `ai` носят также @gpt,
// @deepseek, @botfather, @liza-news, @cup (см. `_fallbackAiMxids` в
// widgets/matrix.dart) — пункт всплыл бы в чатах со всеми ними. Правильный
// предикат — полный mxid через геттер `MatrixState.lizaMxid` (не литерал:
// на локальном стенде mxid другой).
//
// С 2026-10-19 (Надежда, В5 18.10) витрина — только developer: роль ставится
// через РЕАЛЬНЫЙ кэш UserRoleService (applyOwnAccountData), без подмены
// геттера isCurrentUserDeveloper. Чужие кейсы гоняются ПОД developer — иначе
// они зеленели бы от ролевого гейта, а не от гейта по mxid.
//
// ledger:RL-mcp-showcase-entry-points

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/chat_settings_popup_menu.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/matrix.dart';

import '../utils/test_client.dart';

void main() {
  late Client client;
  late SharedPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    // Фоновый sync-цикл держит таймер живым и роняет тест на
    // «A Timer is still pending even after the widget tree was disposed».
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  /// Тестовый шрифт Ahem рисует каждый глиф квадратом в кегль, поэтому длинные
  /// русские пункты СОСЕДНИХ строк меню дают overflow там, где реальный шрифт
  /// укладывается. Глушим ровно overflow — всё прочее по-прежнему роняет тест.
  void ignoreAhemOverflow() {
    final defaultOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('A RenderFlex overflowed')) {
        return;
      }
      defaultOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = defaultOnError);
  }

  /// DM с заданным собеседником. `directChatMatrixID` SDK вычисляет из
  /// `m.direct` в accountData, поэтому его и заполняем.
  Room buildDirectChat(String peer, {String id = '!dm:example.invalid'}) {
    final room = Room(id: id, client: client, membership: Membership.join);
    room.setState(
      Event(
        eventId: '\$create',
        senderId: peer,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomCreate,
        content: {'creator': peer},
        room: room,
        stateKey: '',
      ),
    );
    // Оба участника: SDK требует ровно двоих, чтобы счесть комнату DM.
    for (final mxid in [peer, client.userID!]) {
      room.setState(
        Event(
          eventId: '\$m_$mxid',
          senderId: mxid,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          type: EventTypes.RoomMember,
          content: const {'membership': 'join'},
          room: room,
          stateKey: mxid,
        ),
      );
    }
    client.rooms.add(room);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        peer: [id],
      },
    );
    return room;
  }

  Room buildGroup({String id = '!group:example.invalid'}) {
    final room = Room(id: id, client: client, membership: Membership.join);
    room.setState(
      Event(
        eventId: '\$create',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomCreate,
        content: const {'creator': '@creator:example.invalid'},
        room: room,
        stateKey: '',
      ),
    );
    client.rooms.add(room);
    return room;
  }

  Future<void> openMenu(
    WidgetTester tester,
    Room room, {
    bool developer = true,
  }) async {
    ignoreAhemOverflow();
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Matrix(
            clients: [client],
            store: store,
            child: Scaffold(
              appBar: AppBar(actions: [ChatSettingsPopupMenu(room, true)]),
            ),
          ),
        ),
        GoRoute(
          path: '/rooms',
          builder: (context, state) => const SizedBox.shrink(),
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
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));

    if (developer) {
      tester
          .state<MatrixState>(find.byType(Matrix))
          .userRoleService
          .applyOwnAccountData(client.userID!, {
            'role_v2': {
              'code': 'developer',
              'label': 'Разработчик',
              'color': null,
            },
          });
    }

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
  }

  /// Matrix-виджет держит живой таймер; без разбора дерева тест падает на
  /// «A Timer is still pending even after the widget tree was disposed».
  /// `pumpAndSettle` тут не годится — нужен именно прогон времени вперёд.
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets(
    'AC:RL-mcp-showcase-entry-points/11 — пункт есть в DM с Лизой ИИ '
    'у developer, с меткой «Р»',
    (tester) async {
      final room = buildDirectChat(MatrixState.lizaMxid);
      await openMenu(tester, room);

      final item = find.text('MCP-подключения');
      expect(
        item,
        findsOneWidget,
        reason:
            'в DM с живым ассистентом у developer пункт обязан быть — это '
            'одна из трёх точек входа в витрину',
      );
      expect(
        find.descendant(
          of: find.ancestor(of: item, matching: find.byType(Row)).first,
          matching: find.byType(DeveloperMark),
        ),
        findsOneWidget,
        reason: 'скрытый за ролью пункт обязан нести метку «Р»',
      );
      await teardownTree(tester);
    },
  );

  testWidgets(
    'AC:RL-mcp-showcase-entry-points/11 — пункта НЕТ в DM с Лизой ИИ '
    'у обычного пользователя',
    (tester) async {
      final room = buildDirectChat(MatrixState.lizaMxid);
      await openMenu(tester, room, developer: false);

      expect(
        find.text('MCP-подключения'),
        findsNothing,
        reason:
            'витрина MCP только для developer (Надежда, В5 18.10) — у '
            'обычного пользователя пункт вёл бы в скрытый раздел',
      );
      await teardownTree(tester);
    },
  );

  // ∀ кейсы, где пункта быть НЕ должно. Квантор из требования «в Лиза ИИ»:
  // мультикейс, а не один пример — именно на этих mxid ломается наивный
  // гейт `isAiUser` (у всех них роль `ai`).
  for (final peer in const [
    '@gpt:bots.liza.ru',
    '@deepseek:bots.liza.ru',
    '@botfather:bots.liza.ru',
    '@liza-news:bots.liza.ru',
    '@alice:example.invalid',
  ]) {
    testWidgets(
      'AC:RL-mcp-showcase-entry-points/11 — пункта НЕТ в DM с $peer',
      (tester) async {
        final room = buildDirectChat(peer);
        await openMenu(tester, room);

        expect(
          find.text('MCP-подключения'),
          findsNothing,
          reason:
              'пункт вылез в чате с $peer — гейт судит по роли `ai`, а не по '
              'полному mxid ассистента',
        );
        await teardownTree(tester);
      },
    );
  }

  testWidgets(
    'AC:RL-mcp-showcase-entry-points/11 — пункта НЕТ в групповом чате',
    (tester) async {
      final room = buildGroup();
      await openMenu(tester, room);

      expect(find.text('MCP-подключения'), findsNothing);
      await teardownTree(tester);
    },
  );
}
