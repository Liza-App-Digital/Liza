// ignore_for_file: depend_on_referenced_packages
// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/2 AC:RL-empty-panel-new-request/3
// AC:RL-empty-panel-new-request/4 AC:RL-empty-panel-new-request/5
// AC:RL-empty-panel-new-request/6 AC:RL-empty-panel-new-request/7
// AC:RL-empty-panel-new-request/8 AC:RL-empty-panel-new-request/10
// guard.render:real-widget
//
// Пустая правая панель на компьютере (задача 14): РЕАЛЬНЫЙ NewRequestEmptyPage
// в ru-локали (ловит и дыру intl_ru). Отправка идёт по настоящей воронке
// sendNewLizaRequest → createLizaRequestRoom → ensureDirectChat; клиент считает
// startDirectChat. С 22.10 (видео Надежды) — без барьер-диалога и без ожидания
// Лизы: чат открывается сразу, вопрос в нём первым сообщением.
//
// Red-proof:
//   RP-1 (AC-3): кнопка без проверки `trim().isEmpty` → на «   » активна, красный.
//   RP-2 (AC-5): убрать проверку `_sending` в _send → второй Enter создаёт
//     второй запрос — `calls` красный.
//   RP-3 (AC-4): `FocusNode()` без onKeyEvent → Enter не создаёт комнату.
//   RP-4 (AC-8): показывать поле при read-only → `update_read_only_bar` не найден.
//   RP-5 (AC-6): вернуть ожидание join Лизы → комната без Лизы, переход и PUT
//     не наступают — красный; вернуть showFutureLoadingDialog → AlertDialog найден.
//   RP-6 (AC-6): не ставить `first_message` → маркер без флага, красный.
import 'dart:async';

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
    'AC-4/AC-5/AC-6: Shift+Enter не шлёт; два Enter → один «Новый запрос» '
    'без диалога и без ожидания Лизы: вопрос отправлен один раз, чат открыт, '
    'поле очищено',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      final created = client.hold();
      await tester.enterText(find.byType(TextField), '  план на неделю ');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(client.calls, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // Пока сервер создаёт комнату — спиннер на кнопке, барьер-диалога нет.
      expect(find.byKey(const Key('new_request_sending')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(sendButton(tester).onPressed, isNull);

      created.complete();
      await tester.pump();
      await tester.pump();
      expect(client.calls, 1);
      expect(client.marker, {
        'placeholder': 'Новый запрос',
        'first_message': true,
      });
      // Лиза ещё не вступила — вопрос всё равно ушёл и чат открыт.
      expect(client.room?.sent, ['план на неделю']);
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(store.getString('draft_$_requestRoomId'), isNull);
    },
  );

  testWidgets(
    'AC-7: комната ещё не пришла в sync — вопрос в черновике чата, чат открыт',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      client.syncRoom = false;
      await tester.enterText(find.byType(TextField), 'план на неделю');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(client.calls, 1);
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(store.getString('draft_$_requestRoomId'), 'план на неделю');
      await store.remove('draft_$_requestRoomId');
    },
  );

  testWidgets(
    'AC-10: чат не создан — сообщение об ошибке, текст в поле, кнопка снова активна',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      client.fail = true;
      await tester.enterText(find.byType(TextField), 'план на неделю');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Ой, что-то пошло не так…'), findsOneWidget);
      expect(find.text('room $_requestRoomId'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'план на неделю',
      );
      expect(sendButton(tester).onPressed, isNotNull);
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
  Map<String, Object?>? marker;
  bool syncRoom = true;
  bool fail = false;
  Completer<void>? _hold;

  /// Задержать ответ сервера на создание комнаты до `complete()`.
  Completer<void> hold() => _hold = Completer<void>();

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
    marker = initialState
        ?.firstWhere((s) => s.type == 'com.liza.assistant.request')
        .content;
    await _hold?.future;
    if (fail) throw Exception('M_LIMIT_EXCEEDED');
    // Как на проде сразу после createRoom: Лиза только приглашена, не вступила.
    final created = room = _RecordingRoom(this);
    if (syncRoom) rooms.add(created);
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

/// `sendNewLizaRequest` берёт `Matrix.of(context).client` и `.store`; в тесте
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
