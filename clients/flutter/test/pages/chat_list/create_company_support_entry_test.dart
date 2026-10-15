// ledger:RL-create-company-support-entry
// AC:RL-create-company-support-entry/1 AC:RL-create-company-support-entry/2
// AC:RL-create-company-support-entry/3 AC:RL-create-company-support-entry/4
// AC:RL-create-company-support-entry/5 AC:RL-create-company-support-entry/6
// AC:RL-create-company-support-entry/8 AC:RL-create-company-support-entry/9
// AC:RL-create-company-support-entry/10 AC:RL-create-company-support-entry/11
// AC:RL-create-company-support-entry/12 AC:RL-create-company-support-entry/13
// AC:RL-create-company-support-entry/14 AC:RL-create-company-support-entry/15
// ledger:RL-company-request-intro
// AC:RL-company-request-intro/13 AC:RL-company-request-intro/14
// AC:RL-company-request-intro/15 AC:RL-company-request-intro/16
// guard.render:real-widget
//
// Страж входа «Создать компанию» → чат поддержки: реальный SpacesNavigationRail
// (развилка «+» по подтверждённому ответу single_space, двухстрочный тултип,
// тап → DM с @support), реальный CreateCompanyListTile + предикат его показа,
// контракт openSupportChat (один вызов на двойной тап, ошибка без перехода).
// Плюс интент «Создать компанию» (RL-company-request-intro): новый DM получает
// state `com.liza.support.intent` в initial_state, существующий — PUT state;
// пути без интента state не шлют; событие в ленте невидимо.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/l10n/l10n_en.dart';
import 'package:liza/l10n/l10n_ru.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/create_company_list_tile.dart';
import 'package:liza/pages/chat_list/navi_rail_item.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/utils/support_chat.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/navigation_rail.dart';

import '../../utils/test_client.dart';

const _railKey = ValueKey('rail_create_company');

enum _Root { exists, confirmedAbsent, guardDisabled, fetchFailed, pending }

/// Ответ /single_space/v1/root без сети. `fetchFailed` повторяет реальный
/// SingleSpaceService на сбое: fetch() отдаёт exists:false, но ничего не кэширует.
class _FakeSingleSpaceService extends SingleSpaceService {
  _FakeSingleSpaceService(super.client, this.root);

  final _Root root;
  final _never = Completer<({bool exists, String? roomId})>();

  @override
  Future<({bool exists, String? roomId})> fetch() => switch (root) {
    _Root.exists => Future.value((exists: true, roomId: '!root:x')),
    _Root.confirmedAbsent ||
    _Root.guardDisabled ||
    _Root.fetchFailed => Future.value((exists: false, roomId: null)),
    _Root.pending => _never.future,
  };

  @override
  bool get knownNotToExist => root == _Root.confirmedAbsent;

  @override
  bool get guardDisabled => root == _Root.guardDisabled;
}

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._spaces, this._store);

  final Client _client;
  final SingleSpaceService _spaces;
  final SharedPreferences _store;

  @override
  Client get client => _client;

  @override
  SingleSpaceService get singleSpaceService => _spaces;

  @override
  SharedPreferences get store => _store;
}

Widget _app({
  required Client client,
  required SharedPreferences store,
  required Widget home,
  _Root root = _Root.exists,
}) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (context, state) => home),
      GoRoute(
        path: '/rooms/newspace',
        builder: (context, state) => const Scaffold(body: Text('NEWSPACE')),
      ),
      GoRoute(
        path: '/rooms/:roomId',
        builder: (context, state) =>
            Scaffold(body: Text('ROOM ${state.pathParameters['roomId']}')),
      ),
    ],
  );
  return Provider<liza_matrix.MatrixState>.value(
    value: _TestMatrixState(
      client,
      _FakeSingleSpaceService(client, root),
      store,
    ),
    child: MaterialApp.router(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('ru'),
      routerConfig: router,
    ),
  );
}

Widget _railHome() => Scaffold(
  body: Row(
    children: [
      SpacesNavigationRail(
        activeSpaceId: null,
        onGoToChats: () {},
        onGoToSpaceId: (_) {},
      ),
    ],
  ),
);

final _newSpaceItem = find.byWidgetPredicate(
  (w) => w is NaviRailItem && w.toolTip == 'Новое пространство',
);

/// Тела `PUT /rooms/<id>/state/com.liza.support.intent/` из FakeMatrixApi.
List<Map> _intentPuts() => FakeMatrixApi.calledEndpoints.entries
    .where((e) => e.key.contains('/state/com.liza.support.intent'))
    .expand((e) => e.value)
    .map((d) => jsonDecode(d as String) as Map)
    .toList();

/// Существующий DM с ботом — в памяти клиента (как is_botfather_room_test):
/// joined-комната + `m.direct`, и getDirectChatFromUserId видит её, как на проде
/// у пользователя с историей обращений. Через FakeMatrixApi.setAccountData
/// нельзя — handleSync внутри транзакции виснет.
void _setSupportDm(Client client, String roomId) {
  client.rooms.add(Room(id: roomId, client: client));
  client.accountData['m.direct'] = BasicEvent(
    type: 'm.direct',
    content: {
      '@support:bots.liza.ru': [roomId],
    },
  );
  expect(client.getDirectChatFromUserId('@support:bots.liza.ru'), roomId);
}

/// Роутер и отложенно загружаемые локализации дорисовываются за несколько
/// реальных пауз — pumpAndSettle в fake-async их не дожидается (тот же приём,
/// что в test/utils/open_user_profile_test.dart).
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _introText = ValueKey('create_company_intro_text');
const _introRequest = ValueKey('create_company_intro_request');
const _introCancel = ValueKey('create_company_intro_cancel');

List<dynamic> _createRoomCalls() => FakeMatrixApi.calledEndpoints.entries
    .where((e) => e.key.contains('/client/v3/createRoom'))
    .expand((e) => e.value)
    .toList();

/// Тап по входу «Создать компанию» → попап. До подтверждения ни DM, ни интента
/// (AC-11); затем «Оставить заявку».
Future<void> _tapEntryAndConfirm(WidgetTester tester, Finder entry) async {
  final rooms = _createRoomCalls().length;
  final puts = _intentPuts().length;
  await tester.tap(entry);
  await _settle(tester);
  expect(find.byKey(_introText), findsOneWidget);
  expect(
    _createRoomCalls(),
    hasLength(rooms),
    reason: 'попап до подтверждения',
  );
  expect(_intentPuts(), hasLength(puts), reason: 'попап до подтверждения');
  await tester.tap(find.byKey(_introRequest));
}

void main() {
  late Client client;
  late SharedPreferences store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() => client.dispose());

  group('rail: «+» — ledger:RL-create-company-support-entry', () {
    Future<void> pumpRail(WidgetTester tester, _Root root) async {
      await tester.pumpWidget(
        _app(client: client, store: store, root: root, home: _railHome()),
      );
      await _settle(tester);
    }

    for (final root in [_Root.exists, _Root.fetchFailed]) {
      testWidgets(
        'AC-1: ${root.name} → ровно один «Создать компанию», «Новое пространство» нет '
        '— AC:RL-create-company-support-entry/1',
        (tester) async {
          await pumpRail(tester, root);
          expect(find.byKey(_railKey), findsOneWidget);
          expect(
            _newSpaceItem,
            findsNothing,
            reason: 'сбой fetch() не должен вести прод-юзера на 403 newspace',
          );
        },
      );
    }

    testWidgets(
      'AC-1: подтверждённо нет главного пространства → только «Новое пространство» '
      '— AC:RL-create-company-support-entry/1',
      (tester) async {
        await pumpRail(tester, _Root.confirmedAbsent);
        expect(_newSpaceItem, findsOneWidget);
        expect(find.byKey(_railKey), findsNothing);
        await tester.tap(_newSpaceItem);
        await _settle(tester);
        expect(find.text('NEWSPACE'), findsOneWidget);
      },
    );

    testWidgets(
      'AC-1: модуля single_space_guard нет (локальный стенд) → оба «+» '
      '— AC:RL-create-company-support-entry/1',
      (tester) async {
        await pumpRail(tester, _Root.guardDisabled);
        expect(_newSpaceItem, findsOneWidget);
        expect(find.byKey(_railKey), findsOneWidget);
        expect(
          tester.getTopLeft(_newSpaceItem).dy,
          lessThan(tester.getTopLeft(find.byKey(_railKey)).dy),
        );
      },
    );

    testWidgets(
      'AC-1: до ответа сервера «+» нет вовсе — AC:RL-create-company-support-entry/1',
      (tester) async {
        await pumpRail(tester, _Root.pending);
        expect(find.byKey(_railKey), findsNothing);
        expect(_newSpaceItem, findsNothing);
      },
    );

    testWidgets(
      'AC-2: тултип — «Создать компанию» жирным + пояснение, ≤240, цвет задан '
      '— AC:RL-create-company-support-entry/2',
      (tester) async {
        await pumpRail(tester, _Root.exists);
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(find.byKey(_railKey)));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));

        final tipFinder = find
            .descendant(of: find.byKey(_railKey), matching: find.byType(Text))
            .last;
        final tip = tester.widget<Text>(tipFinder);
        final span = tip.textSpan! as TextSpan;
        expect(
          span.toPlainText(),
          'Создать компанию\nУзнать подробности и оставить заявку',
        );
        final title = span.children!.first as TextSpan;
        expect(title.text, 'Создать компанию');
        expect(title.style?.fontWeight, FontWeight.bold);
        expect(tip.style?.color, isNotNull);
        expect(tester.getSize(tipFinder).width, lessThanOrEqualTo(240.0));
      },
    );

    testWidgets(
      'AC-9: «+» по макету — квадрат размером с аватар компании, пунктир, '
      'пояснение карточкой справа — AC:RL-create-company-support-entry/9',
      (tester) async {
        await pumpRail(tester, _Root.exists);
        final icon = find.byKey(const ValueKey('rail_create_company_icon'));
        expect(tester.getSize(icon), const Size.square(Avatar.defaultSize));
        expect(
          find.descendant(of: icon, matching: find.byType(CustomPaint)),
          findsWidgets,
        );
        final gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.addPointer(location: Offset.zero);
        addTearDown(gesture.removePointer);
        await gesture.moveTo(tester.getCenter(icon));
        await tester.pump();
        await tester.pump(const Duration(seconds: 2));

        final tip = find
            .descendant(of: find.byKey(_railKey), matching: find.byType(Text))
            .last;
        final button = tester.getRect(icon);
        final card = tester.getRect(tip);
        expect(
          card.left,
          greaterThan(button.right),
          reason: 'пояснение справа от кнопки, как в макете',
        );
        expect(card.top, lessThan(button.bottom));
        expect(card.bottom, greaterThan(button.top));
      },
    );

    testWidgets(
      'AC-3: тап по «+» → попап → «Оставить заявку» → DM с ботом поддержки '
      '— AC:RL-create-company-support-entry/3',
      (tester) async {
        await pumpRail(tester, _Root.exists);
        await _tapEntryAndConfirm(tester, find.byKey(_railKey));
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        final createRoom = FakeMatrixApi.calledEndpoints.entries
            .where((e) => e.key.contains('/client/v3/createRoom'))
            .expand((e) => e.value)
            .toList();
        expect(createRoom, hasLength(1));
        expect(createRoom.single.toString(), contains('@support:bots.liza.ru'));
        // AC-13 (новый DM): интент уезжает в initial_state, PUT state — нет.
        final body = jsonDecode(createRoom.single as String) as Map;
        final intents = (body['initial_state'] as List)
            .cast<Map>()
            .where((e) => e['type'] == supportIntentStateType)
            .toList();
        expect(intents, hasLength(1));
        expect(intents.single['state_key'], '');
        expect(intents.single['content']['intent'], 'create_company');
        expect(intents.single['content']['next'], 'request');
        expect(intents.single['content']['ts'], isA<int>());
        expect(_intentPuts(), isEmpty);
        // FakeMatrixApi не доносит комнату через sync → startDirectChat висит;
        // у ensureDirectChat на выдаваемом Future 30-с таймаут — даём ему
        // сработать, иначе тест падает на «Timer is still pending».
        await tester.pump(ensureDirectChatTimeout + const Duration(seconds: 1));
      },
    );
  });

  group('плашка на «Компаниях» — ledger:RL-create-company-support-entry', () {
    testWidgets('AC-4: предикат истинен только для «Компаний» вне поиска '
        '— AC:RL-create-company-support-entry/4', (tester) async {
      for (final filter in ActiveFilter.values) {
        for (final isSearchMode in [false, true]) {
          expect(
            shouldShowCreateCompanyRow(filter, isSearchMode: isSearchMode),
            filter == ActiveFilter.spaces && !isSearchMode,
            reason: '${filter.name}, поиск=$isSearchMode',
          );
        }
      }
    });

    testWidgets(
      'AC-4: реальная плашка — заголовок и пояснение по-русски, тап-строка '
      '— AC:RL-create-company-support-entry/4',
      (tester) async {
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: const Scaffold(body: CreateCompanyListTile()),
          ),
        );
        await _settle(tester);
        expect(find.text('Создать компанию'), findsOneWidget);
        expect(
          find.text('Узнать подробности и оставить заявку'),
          findsOneWidget,
        );
        final tap = find.descendant(
          of: find.byType(CreateCompanyListTile),
          matching: find.byType(InkWell),
        );
        expect(tester.widget<InkWell>(tap).onTap, isNotNull);
      },
    );
  });

  testWidgets(
    'AC-10: плашка по макету — акцентная карточка со скруглением, «+» в светлом '
    'квадрате слева, заголовок жирный — AC:RL-create-company-support-entry/10',
    (tester) async {
      await tester.pumpWidget(
        _app(
          client: client,
          store: store,
          home: const Scaffold(body: CreateCompanyListTile()),
        ),
      );
      await _settle(tester);
      final scheme = Theme.of(
        tester.element(find.byType(CreateCompanyListTile)),
      ).colorScheme;
      final cardFinder = find
          .descendant(
            of: find.byType(CreateCompanyListTile),
            matching: find.byType(Material),
          )
          .first;
      final card = tester.widget<Material>(cardFinder);
      expect(card.color, scheme.primaryContainer);
      expect(card.borderRadius, BorderRadius.circular(AppConfig.borderRadius));
      final tileLeft = tester.getTopLeft(find.byType(CreateCompanyListTile)).dx;
      expect(
        tester.getTopLeft(cardFinder).dx - tileLeft,
        moreOrLessEquals(16),
        reason: 'левый край карточки на уровне аватаров списка',
      );
      final plus = find.byKey(const ValueKey('create_company_row_plus'));
      expect(tester.getSize(plus), const Size.square(32));
      expect(
        find.descendant(of: plus, matching: find.byIcon(Icons.add)),
        findsOneWidget,
      );
      final title = find.text('Создать компанию');
      expect(tester.widget<Text>(title).style?.fontWeight, FontWeight.bold);
      expect(tester.getRect(plus).right, lessThan(tester.getTopLeft(title).dx));
    },
  );

  group('openSupportChat — ledger:RL-create-company-support-entry', () {
    // Инцидент 2026-09-15: local-сборка + прод-аккаунт звала @support:liza.local,
    // прод отвечал 403 «Federation denied with liza.local» и оставлял пустую комнату.
    test('AC-8: адрес бота поддержки — по серверу аккаунта, не по сборке '
        '— AC:RL-create-company-support-entry/8', () {
      const cases = {
        'synapse.liza.laba.prodamus.tech': '@support:bots.liza.ru',
        'nadezhda.liza.laba.prodamus.tech': '@support:bots.liza.ru',
        'liza.cyber-agro.ru': '@support:bots.liza.ru',
        'liza.local': '@support:liza.local',
        'localhost': '@support:liza.local',
        '127.0.0.1': '@support:liza.local',
      };
      cases.forEach((host, mxid) {
        expect(AppConfig.supportBotMxidForHomeserver(host), mxid, reason: host);
      });
    });

    Widget button(Future<String> Function(String) start) => Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              openSupportChat(context, client: client, start: start),
          child: const Text('OPEN'),
        ),
      ),
    );

    testWidgets('AC-3: старт с mxid бота → переход в /rooms/<id> '
        '— AC:RL-create-company-support-entry/3', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _app(
          client: client,
          store: store,
          home: button((mxid) async {
            calls.add(mxid);
            return '!dm:x';
          }),
        ),
      );
      await _settle(tester);
      await tester.tap(find.text('OPEN'));
      await tester.pump(const Duration(milliseconds: 100));
      await _settle(tester);
      expect(calls, ['@support:bots.liza.ru']);
      expect(find.text('ROOM !dm:x'), findsOneWidget);
    });

    testWidgets(
      'AC-5: повторный тап, пока DM создаётся, второго старта не даёт '
      '— AC:RL-create-company-support-entry/5',
      (tester) async {
        final pending = Completer<String>();
        var calls = 0;
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: button((_) {
              calls++;
              return pending.future;
            }),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('OPEN'));
        await tester.pump();
        await tester.tap(find.text('OPEN'), warnIfMissed: false);
        await tester.pump();
        expect(calls, 1);

        pending.complete('!dm:x');
        await tester.pump(const Duration(milliseconds: 400));
        await _settle(tester);
        expect(find.text('ROOM !dm:x'), findsOneWidget);
      },
    );

    testWidgets(
      'AC-6: ошибка старта → перехода нет — AC:RL-create-company-support-entry/6',
      (tester) async {
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: button((_) async => throw Exception('federation down')),
          ),
        );
        await _settle(tester);
        await tester.tap(find.text('OPEN'));
        await tester.pump(const Duration(milliseconds: 100));
        await _settle(tester);
        expect(find.textContaining('ROOM'), findsNothing);
      },
    );
  });

  group('интент «Создать компанию» — ledger:RL-company-request-intro', () {
    // PUT state FakeMatrixApi принимает только для этой комнаты — на любую
    // другую отвечает M_UNRECOGNIZED (нужно для AC-16).
    const dm = '!1234:fakeServer.notExisting';
    const dmNoState = '!nostate:example.invalid';

    Future<void> tapAndSettle(WidgetTester tester, Finder target) async {
      await tester.tap(target);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _settle(tester);
    }

    List<dynamic> createRoomCalls() => _createRoomCalls();

    Future<void> confirmAndSettle(WidgetTester tester, Finder entry) async {
      await _tapEntryAndConfirm(tester, entry);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _settle(tester);
    }

    testWidgets(
      'AC-13: ∀ вход {rail «+», плашка} + DM есть → без createRoom, ровно один '
      'PUT state create_company, затем переход — AC:RL-company-request-intro/13',
      (tester) async {
        _setSupportDm(client, dm);
        final entries = <String, Widget>{
          'rail': _railHome(),
          'tile': const Scaffold(body: CreateCompanyListTile()),
        };
        var expectedPuts = 0;
        for (final entry in entries.entries) {
          await tester.pumpWidget(
            _app(client: client, store: store, home: entry.value),
          );
          await _settle(tester);
          final target = entry.key == 'rail'
              ? find.byKey(_railKey)
              : find.byType(CreateCompanyListTile);
          await confirmAndSettle(tester, target);
          expectedPuts++;
          expect(createRoomCalls(), isEmpty, reason: entry.key);
          final puts = _intentPuts();
          expect(puts, hasLength(expectedPuts), reason: entry.key);
          expect(puts.last['intent'], 'create_company');
          expect(puts.last['next'], 'request');
          expect(puts.last['ts'], isA<int>());
          expect(find.text('ROOM $dm'), findsOneWidget, reason: entry.key);
          expect(
            FakeMatrixApi.calledEndpoints.keys.where(
              (k) => k.contains(
                '$dm/state/com.liza.support.intent'.replaceAll(':', '%3A'),
              ),
            ),
            isNotEmpty,
            reason: 'state ставится именно в комнату DM',
          );
        }
      },
    );

    testWidgets(
      'AC-14 NEGATIVE: openSupportChat без интента (меню «Поддержка») → ни PUT '
      'state, ни initial_state — AC:RL-company-request-intro/14',
      (tester) async {
        _setSupportDm(client, dm);
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => openSupportChat(context, client: client),
                  child: const Text('OPEN'),
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await tapAndSettle(tester, find.text('OPEN'));
        expect(find.text('ROOM $dm'), findsOneWidget);
        expect(_intentPuts(), isEmpty);
        expect(createRoomCalls(), isEmpty);
      },
    );

    testWidgets(
      'AC-15: событие интента невидимо в ленте даже при hideUnknownEvents=false '
      '— AC:RL-company-request-intro/15',
      (tester) async {
        await AppSettings.init(loadWebConfigFile: false);
        await AppSettings.hideUnknownEvents.setItem(false);
        addTearDown(() => AppSettings.hideUnknownEvents.setItem(true));
        final room = Room(id: dm, client: client);
        final intent = Event(
          eventId: '\$intent',
          senderId: client.userID!,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          type: supportIntentStateType,
          stateKey: '',
          content: {'intent': 'create_company', 'ts': 1},
          room: room,
        );
        final text = Event(
          eventId: '\$txt',
          senderId: client.userID!,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(2000),
          type: EventTypes.Message,
          content: {'msgtype': MessageTypes.Text, 'body': 'привет'},
          room: room,
        );
        expect(intent.isVisibleInGui, isFalse);
        expect(text.isVisibleInGui, isTrue);
      },
    );

    testWidgets(
      'AC-16: сбой PUT state → переход в чат всё равно, второго PUT нет '
      '— AC:RL-company-request-intro/16',
      (tester) async {
        // FakeMatrixApi отвечает на PUT state только по комнатам с обработчиком;
        // для dmNoState — M_UNRECOGNIZED → setRoomStateWithKey бросает.
        _setSupportDm(client, dmNoState);
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: const Scaffold(body: CreateCompanyListTile()),
          ),
        );
        await _settle(tester);
        await confirmAndSettle(tester, find.byType(CreateCompanyListTile));
        expect(find.text('ROOM $dmNoState'), findsOneWidget);
        expect(_intentPuts(), hasLength(1));
        expect(createRoomCalls(), isEmpty);
      },
    );
  });

  group('попап «Создать компанию» — ledger:RL-create-company-support-entry', () {
    const dm = '!1234:fakeServer.notExisting';

    Map<String, Widget> entries() => {
      'rail': _railHome(),
      'tile': const Scaffold(body: CreateCompanyListTile()),
    };

    Finder entryFinder(String name) => name == 'rail'
        ? find.byKey(_railKey)
        : find.byType(CreateCompanyListTile);

    testWidgets(
      'AC-11: ∀ вход {rail, плашка} → ровно один попап с текстом и двумя '
      'кнопками, до подтверждения ни createRoom, ни PUT — '
      'AC:RL-create-company-support-entry/11',
      (tester) async {
        _setSupportDm(client, dm);
        for (final entry in entries().entries) {
          await tester.pumpWidget(
            _app(client: client, store: store, home: entry.value),
          );
          await _settle(tester);
          await tester.tap(entryFinder(entry.key));
          await _settle(tester);
          final l10n = L10n.of(tester.element(find.byKey(_introText)));
          expect(find.byKey(_introText), findsOneWidget, reason: entry.key);
          expect(find.text(l10n.createCompanyIntroText), findsOneWidget);
          expect(find.text(l10n.createCompanyViaSupport), findsWidgets);
          expect(
            find.descendant(
              of: find.byKey(_introRequest),
              matching: find.text('Оставить заявку'),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(_introCancel),
              matching: find.text(l10n.cancel),
            ),
            findsOneWidget,
          );
          expect(_createRoomCalls(), isEmpty, reason: entry.key);
          expect(_intentPuts(), isEmpty, reason: entry.key);
          expect(find.textContaining('ROOM'), findsNothing);
          await tester.tap(find.byKey(_introCancel));
          await _settle(tester);
        }
      },
    );

    testWidgets(
      'AC-12 NEGATIVE: ∀ вход × {«Отмена», тап по фону} → попап закрыт, ни '
      'createRoom, ни PUT, перехода нет — AC:RL-create-company-support-entry/12',
      (tester) async {
        _setSupportDm(client, dm);
        for (final entry in entries().entries) {
          for (final dismiss in ['cancel', 'barrier']) {
            await tester.pumpWidget(
              _app(client: client, store: store, home: entry.value),
            );
            await _settle(tester);
            await tester.tap(entryFinder(entry.key));
            await _settle(tester);
            expect(find.byKey(_introText), findsOneWidget);
            if (dismiss == 'cancel') {
              await tester.tap(find.byKey(_introCancel));
            } else {
              await tester.tapAt(const Offset(4, 4));
            }
            await _settle(tester);
            final reason = '${entry.key}/$dismiss';
            expect(find.byKey(_introText), findsNothing, reason: reason);
            expect(_createRoomCalls(), isEmpty, reason: reason);
            expect(_intentPuts(), isEmpty, reason: reason);
            expect(find.textContaining('ROOM'), findsNothing, reason: reason);
          }
        }
      },
    );

    testWidgets('AC-13: двойной тап по входу → один попап — '
        'AC:RL-create-company-support-entry/13', (tester) async {
      _setSupportDm(client, dm);
      await tester.pumpWidget(
        _app(
          client: client,
          store: store,
          home: const Scaffold(body: CreateCompanyListTile()),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byType(CreateCompanyListTile));
      await tester.tap(find.byType(CreateCompanyListTile), warnIfMissed: false);
      await _settle(tester);
      expect(find.byKey(_introText), findsOneWidget);
      await tester.tap(find.byKey(_introCancel));
      await _settle(tester);
      expect(find.byKey(_introText), findsNothing);
    });

    testWidgets(
      'AC-14: 320×480 и textScaler 2.0 → без overflow, «Оставить заявку» '
      'достижима — AC:RL-create-company-support-entry/14',
      (tester) async {
        _setSupportDm(client, dm);
        tester.view.physicalSize = const Size(320, 480);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          _app(
            client: client,
            store: store,
            home: const Scaffold(
              body: SingleChildScrollView(child: CreateCompanyListTile()),
            ),
          ),
        );
        await _settle(tester);
        await tester.tap(find.byType(CreateCompanyListTile));
        await _settle(tester);
        expect(tester.takeException(), isNull);
        final request = find.byKey(_introRequest);
        expect(request, findsOneWidget);
        final rect = tester.getRect(request);
        expect(rect.bottom, lessThanOrEqualTo(480));
        expect(rect.top, greaterThanOrEqualTo(0));
        await tester.tap(find.byKey(_introCancel));
        await _settle(tester);
      },
    );

    test('AC-15: ключи попапа есть и в ru, и в en — '
        'AC:RL-create-company-support-entry/15', () {
      final ru = L10nRu();
      final en = L10nEn();
      for (final l10n in <L10n>[ru, en]) {
        expect(
          l10n.createCompanyIntroText,
          contains('🏢'),
          reason: l10n.localeName,
        );
        expect(
          l10n.createCompanyLeaveRequest,
          isNotEmpty,
          reason: l10n.localeName,
        );
      }
      expect(ru.createCompanyIntroText, startsWith('Привет! Коротко'));
      expect(
        ru.createCompanyLeaveRequest,
        isNot(en.createCompanyLeaveRequest),
        reason: 'ru не подменён английским',
      );
    });
  });
}
