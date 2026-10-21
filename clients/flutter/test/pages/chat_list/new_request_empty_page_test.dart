// ignore_for_file: depend_on_referenced_packages
// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/2 AC:RL-empty-panel-new-request/3
// AC:RL-empty-panel-new-request/4 AC:RL-empty-panel-new-request/5
// AC:RL-empty-panel-new-request/8
// guard.render:real-widget
//
// Пустая правая панель на компьютере (задача 14): РЕАЛЬНЫЙ NewRequestEmptyPage
// в ru-локали (ловит и дыру intl_ru). Отправка идёт по настоящей воронке
// openNewLizaRequest → startLizaRequestChat → ensureDirectChat; клиент считает
// startDirectChat. Порядок «приветствие → вопрос» — в
// test/utils/new_request_first_message_test.dart.
//
// Red-proof:
//   RP-1 (AC-3): кнопка без проверки `trim().isEmpty` → на «   » активна, красный.
//   RP-2 (AC-5): убрать проверку `_sending` в _send → второй Enter приходит
//     раньше барьер-диалога, вопрос уходит дважды — `sent` красный.
//   RP-3 (AC-4): `FocusNode()` без onKeyEvent → Enter не создаёт комнату.
//   RP-4 (AC-8): показывать поле при read-only → `update_read_only_bar` не найден.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/new_request_empty_page.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/matrix.dart';

void main() {
  // Базу открываем вне fake-async testWidgets: реальный I/O sqflite там виснет.
  late DatabaseApi database;
  late SharedPreferences store;
  setUpAll(() async {
    database = await MatrixSdkDatabase.init(
      'new-request-panel-test',
      database: await databaseFactoryFfi.openDatabase(':memory:'),
      sqfliteFactory: databaseFactoryFfi,
    );
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
  });

  tearDown(() => UpdatePolicyController.current.value = UpdatePolicy.none);

  Future<_PanelClient> pumpPanel(
    WidgetTester tester, {
    String? displayName,
  }) async {
    final client = _PanelClient(database, displayName);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Provider<MatrixState>.value(
            value: _TestMatrix(client, store),
            child: const NewRequestEmptyPage(),
          ),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (_, state) => Text('room ${state.pathParameters['roomid']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        routerConfig: router,
      ),
    );
    // Deferred-локализация ru и профиль приходят future'ами — даём кадры.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return client;
  }

  IconButton sendButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('new_request_send')));

  String greeting(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('new_request_greeting'))).data!;

  group('AC-2: обращение по имени', () {
    test('первое слово; email, пусто, пробелы, null — без имени', () {
      expect(greetingFirstName('Иван Петров'), 'Иван');
      expect(greetingFirstName('  Надежда  Розенталь '), 'Надежда');
      expect(greetingFirstName('Иван'), 'Иван');
      expect(greetingFirstName('ivan@mail.ru'), isNull);
      expect(greetingFirstName('@ivan:liza.ru'), isNull);
      expect(greetingFirstName(''), isNull);
      expect(greetingFirstName('   '), isNull);
      expect(greetingFirstName(null), isNull);
    });

    testWidgets('ru: «Какую задачу решим, Надежда?» и без имени', (
      tester,
    ) async {
      await pumpPanel(tester, displayName: 'Надежда Розенталь');
      expect(greeting(tester), 'Какую задачу решим, Надежда?');
      expect(find.text('Напишите, что нужно сделать.'), findsOneWidget);
      expect(
        find.text('Например: сгенерируй 5 идей постов для блога'),
        findsOneWidget,
      );
    });

    testWidgets('ru: имени нет (не залогинен / email)', (tester) async {
      await pumpPanel(tester, displayName: 'nadya@prodamus.ru');
      expect(greeting(tester), 'Какую задачу решим?');
    });
  });

  testWidgets('AC-3: кнопка неактивна на пустом и пробелах', (tester) async {
    await pumpPanel(tester, displayName: 'Иван');
    expect(sendButton(tester).onPressed, isNull);
    for (final blank in ['   ', '\n', ' \n ']) {
      await tester.enterText(find.byType(TextField), blank);
      await tester.pump();
      expect(sendButton(tester).onPressed, isNull, reason: '«$blank»');
    }
    await tester.enterText(find.byType(TextField), 'план на неделю');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets(
    'AC-4/AC-5: Shift+Enter не шлёт; два Enter → один «Новый запрос», '
    'вопрос отправлен один раз, чат открыт, поле очищено',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      await tester.enterText(find.byType(TextField), '  план на неделю ');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(client.calls, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(client.calls, 1);
      expect(client.lastInitialState, contains('com.liza.assistant.request'));
      expect(client.room?.sent, ['план на неделю']);
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(store.getString('draft_$_requestRoomId'), isNull);
    },
  );

  testWidgets('AC-8: режим чтения — плашка обновления вместо поля', (
    tester,
  ) async {
    UpdatePolicyController.current.value = const UpdatePolicy(
      stage: UpdateStage.hard,
    );
    final client = await pumpPanel(tester, displayName: 'Иван');
    expect(find.byKey(const Key('update_read_only_bar')), findsOneWidget);
    expect(find.byKey(const Key('new_request_field')), findsNothing);
    expect(client.calls, 0);
  });
}

class _PanelClient extends Client {
  _PanelClient(DatabaseApi database, this.displayName)
    : super('new-request-panel-test', database: database);

  final String? displayName;
  int calls = 0;
  List<String> lastInitialState = const [];

  @override
  String? get userID => '@ivan:liza.local';

  @override
  Future<Profile> fetchOwnProfile({
    bool getFromRooms = true,
    bool cache = true,
  }) async => Profile(userId: userID!, displayName: displayName);

  @override
  Future<String> startDirectChat(
    String mxid, {
    bool? enableEncryption,
    List<StateEvent>? initialState,
    bool waitForSync = true,
    Map<String, dynamic>? powerLevelContentOverride,
    CreateRoomPreset? preset = CreateRoomPreset.trustedPrivateChat,
    bool skipExistingChat = false,
  }) async {
    calls++;
    lastInitialState = [for (final s in initialState ?? []) s.type];
    // Комната «пришла» sync'ом: Лиза вступила и уже поприветствовала.
    final created = room = _RecordingRoom(this);
    created.setState(
      Event(
        type: EventTypes.RoomMember,
        eventId: r'$liza-join',
        senderId: mxid,
        originServerTs: DateTime.now(),
        room: created,
        content: {'membership': 'join'},
        stateKey: mxid,
      ),
    );
    created.lastEvent = Event(
      type: EventTypes.Message,
      eventId: r'$greeting',
      senderId: mxid,
      originServerTs: DateTime.now(),
      room: created,
      content: {'msgtype': 'm.text', 'body': 'Какую задачу решим сегодня?'},
    );
    rooms.add(created);
    return created.id;
  }

  _RecordingRoom? room;
}

const _requestRoomId = '!request:server';

class _RecordingRoom extends Room {
  _RecordingRoom(Client client)
    : super(id: _requestRoomId, client: client, membership: Membership.join);

  final sent = <String>[];

  @override
  Future<String?> sendTextEvent(
    String message, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    bool parseMarkdown = true,
    bool parseCommands = true,
    String msgtype = MessageTypes.Text,
    String? threadRootEventId,
    String? threadLastEventId,
    StringBuffer? commandStdout,
    bool addMentions = true,
    bool displayPendingEvent = true,
  }) async {
    sent.add(message);
    return r'$sent';
  }
}

/// `openNewLizaRequest` берёт `Matrix.of(context).client` и `.store`; в тесте
/// смонтированного Matrix нет.
class _TestMatrix extends MatrixState {
  _TestMatrix(this.testClient, this.testStore);
  final Client testClient;
  final SharedPreferences testStore;

  @override
  Client get client => testClient;

  @override
  SharedPreferences get store => testStore;
}
