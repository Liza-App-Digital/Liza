// ignore_for_file: depend_on_referenced_packages
// ledger:RL-direct-chat-draft-on-first-send
// AC:RL-direct-chat-draft-on-first-send/1
// AC:RL-direct-chat-draft-on-first-send/15
// guard.render:real-widget
//
// Real-widget страж чернового экрана DraftChatPage: показывает подсказку «чат
// появится после первого сообщения» и держит кнопку отправки ВЫКЛЮЧЕННОЙ пока
// поле пусто (первое сообщение — осознанное действие, а не побочка открытия).
// Рендерится РЕАЛЬНЫЙ DraftChatPage (не реплика). Materialize/навигация требуют
// MatrixState и покрыты юнитами в test/utils/direct_chat_draft_test.dart.
//
// Red-proof: если кнопка отправки была бы активна на пустом поле (тап → создание
// комнаты «ни с чем») — expect(onPressed, isNull) упадёт.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/draft_chat_page.dart';
import 'package:liza/widgets/matrix.dart';

// Avatar (даже без mxContent) заводит MxcImage._tryLoad с exp-backoff
// (2/4/8/16/30с). Автофокус-TextField даёт периодический cursor-таймер →
// pumpAndSettle не сходится. Сливаем backoff-таймеры вручную, как в
// test/pages/contacts/contacts_screen_test.dart.
Future<void> _drainAvatarRetryTimers(WidgetTester tester) async {
  for (final delay in const [
    Duration(seconds: 3),
    Duration(seconds: 5),
    Duration(seconds: 9),
    Duration(seconds: 17),
    Duration(seconds: 31),
  ]) {
    await tester.pump(delay);
  }
}

void main() {
  // Базу открываем вне fake-async testWidgets: реальный I/O sqflite там виснет.
  late DatabaseApi database;
  setUpAll(() async {
    database = await MatrixSdkDatabase.init(
      'draft-enter-test',
      database: await databaseFactoryFfi.openDatabase(':memory:'),
      sqfliteFactory: databaseFactoryFfi,
    );
  });

  Widget wrap(Widget child) => MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        home: child,
      );

  IconButton sendButton(WidgetTester tester) => tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.send_outlined),
      );

  testWidgets(
    'AC-1(UI): подсказка видна, кнопка отправки выключена пока поле пусто, '
    'включается при вводе',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          DraftChatPage(
            '@bob:server',
            initialProfile: Profile(
              userId: '@bob:server',
              displayName: 'Боб',
            ),
          ),
        ),
      );
      // Deferred-локализация ru грузится через future — даём кадры.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Подсказка (русская строка — ловит и дыру intl_ru).
      expect(
        find.text('Чат появится после отправки первого сообщения.'),
        findsOneWidget,
      );
      // Имя собеседника в шапке.
      expect(find.text('Боб'), findsOneWidget);

      // Пусто → отправка выключена.
      expect(sendButton(tester).onPressed, isNull);

      // Ввод текста → отправка включается.
      await tester.enterText(find.byType(TextField), 'привет');
      await tester.pump();
      expect(sendButton(tester).onPressed, isNotNull);

      // Стёрли (пробелы) → снова выключена.
      await tester.enterText(find.byType(TextField), '   ');
      await tester.pump();
      expect(sendButton(tester).onPressed, isNull);

      await _drainAvatarRetryTimers(tester);
    },
  );

  // AC:RL-direct-chat-draft-on-first-send/15
  // Саша 18.10: «В новом чате не работает [Enter]… После того, как первое
  // сообщение отправил через кнопку с самолетиком, далее отправка по ентер
  // начинает работать». До фикса Enter в черновике вставлял «\n» и комнату
  // не создавал.
  //
  // Red-proof: вернуть `FocusNode()` без onKeyEvent → startDirectChat не
  // вызван, экрана комнаты нет — тест красный.
  testWidgets(
    'AC-15(UI): desktop — Enter в черновике создаёт комнату и открывает её, '
    'Shift+Enter — нет',
    (tester) async {
      final client = _CountingClient(database);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Provider<MatrixState>.value(
              value: _MatrixWithClient(client),
              child: DraftChatPage(
                '@bob:server',
                initialProfile: Profile(
                  userId: '@bob:server',
                  displayName: 'Боб',
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/rooms/:roomid',
            builder: (_, state) =>
                Text('room ${state.pathParameters['roomid']}'),
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
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(find.byType(TextField), 'привет');
      await tester.pump();

      // Shift+Enter — перенос строки, не отправка. Сам «\n» в тесте не
      // вставится: текст в TextField идёт через TextInputClient, а не через
      // key-события, поэтому проверяем «комнату не создавали».
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(client.calls, 0);

      // Два Enter подряд — одна комната (дедуп ensureDirectChat + _sending).
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(client.calls, 1);
      expect(find.text('room !room:server'), findsOneWidget);
    },
  );
}

class _CountingClient extends Client {
  _CountingClient(DatabaseApi database)
    : super('draft-enter-test', database: database);

  int calls = 0;

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
    return '!room:server';
  }
}

/// Материализация берёт `Matrix.of(context).client`; в тесте нет
/// смонтированного Matrix — отдаём тестовый клиент.
class _MatrixWithClient extends MatrixState {
  final Client testClient;
  _MatrixWithClient(this.testClient);

  @override
  Client get client => testClient;
}
