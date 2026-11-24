// Подпись действия выхода на РЕАЛЬНОМ меню, а не на реплике (LABA-2540).
//
// До фикса пункт назывался «Удалить чат» с красной корзиной, а вызывал
// room.leave(): чат оставался у всех остальных участников и уезжал к тебе в
// архив. Диалог при этом говорил «переместится в архив», кнопка — «Покинуть».
// Три разных обещания и четвёртое фактическое поведение на одном пути.
//
// ledger:RL-leave-chat-not-delete

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:liza/widgets/chat_settings_popup_menu.dart';
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
    FakeMatrixApi.calledEndpoints.clear();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  /// Тесты рендерят шрифтом Ahem, где каждый глиф — квадрат в кегль: русский
  /// пункт «Отключить уведомления» (21 символ) даёт 294px там, где реальный
  /// шрифт укладывается в ширину меню Material (256px). Это артефакт тестового
  /// шрифта на СОСЕДНЕМ пункте, а не вёрстка проверяемого — глушим ровно
  /// overflow и ровно его, всё остальное по-прежнему роняет тест.
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

  /// [chatType] — `com.liza.chat.type` в `m.room.create` (канал/обсуждение).
  /// [isSpace] даёт `m.room.create.type = m.space`.
  Room buildRoom({
    String id = '!group:example.invalid',
    String? chatType,
    bool isSpace = false,
    Membership membership = Membership.join,
  }) {
    final room = Room(id: id, client: client, membership: membership);
    room.setState(
      Event(
        eventId: '\$create',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomCreate,
        content: {
          'creator': '@creator:example.invalid',
          if (chatType != null) 'com.liza.chat.type': chatType,
          if (isSpace) 'type': 'm.space',
        },
        room: room,
        stateKey: '',
      ),
    );
    room.setState(
      Event(
        eventId: '\$name',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomName,
        content: const {'name': 'Тестовая комната'},
        room: room,
        stateKey: '',
      ),
    );
    // Кроме меня в комнате есть второй участник: иначе это «последний участник
    // группы» и диалог (по RL-last-member-leave-deletes-room) честно говорит
    // про удаление, а не про архив.
    room.setState(
      Event(
        eventId: '\$other',
        senderId: '@other:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomMember,
        content: const {'membership': 'join'},
        room: room,
        stateKey: '@other:example.invalid',
      ),
    );
    // Я не владелец (PL 0), владелец — создатель: выход идёт обычным путём.
    room.setState(
      Event(
        eventId: '\$pl',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomPowerLevels,
        content: const {
          'users': {'@creator:example.invalid': 100},
        },
        room: room,
        stateKey: '',
      ),
    );
    room.summary.mJoinedMemberCount = 2;
    client.rooms.add(room);
    return room;
  }

  Future<void> pump(WidgetTester tester, Room room) async {
    ignoreAhemOverflow();

    // Обработчик выхода первым делом берёт GoRouter.of(context) — без роутера
    // в дереве тап по пункту падает.
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
    // Matrix отдаёт child не сразу (async init) — несколько pump'ов, чтобы
    // дерево устоялось.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  /// Matrix-виджет держит живой таймер; без разбора дерева тест падает на
  /// «A Timer is still pending even after the widget tree was disposed».
  Future<void> teardownTree(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  // AC:RL-leave-chat-not-delete/1
  testWidgets('группа: пункт называется «Выйти из чата», без корзины', (
    tester,
  ) async {
    await pump(tester, buildRoom());
    await openMenu(tester);

    expect(find.text('Выйти из чата'), findsOneWidget);
    expect(
      find.text('Удалить чат'),
      findsNothing,
      reason: 'слово «удалить» на действии leave() — жалоба LABA-2540',
    );
    expect(
      find.byIcon(Icons.delete_outlined),
      findsNothing,
      reason: 'красная корзина обещает удаление сильнее любой подписи',
    );
    expect(find.byIcon(Icons.logout_outlined), findsOneWidget);
    await teardownTree(tester);
  });

  // AC:RL-leave-chat-not-delete/2 + AC:RL-leave-chat-not-delete/3
  testWidgets('группа: диалог правдив, зовётся leave() и НЕ зовётся forget()', (
    tester,
  ) async {
    await pump(tester, buildRoom());
    await openMenu(tester);
    await tester.tap(find.text('Выйти из чата').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // Заголовок, тело и кнопка — один и тот же глагол, без «Вы уверены?».
    expect(find.text('Вы уверены?'), findsNothing);
    expect(
      find.textContaining('переместится в архив'),
      findsOneWidget,
      reason: 'тело диалога описывает реальное последствие',
    );
    expect(
      find.textContaining('Другие участники останутся в чате'),
      findsOneWidget,
      reason: 'прямой ответ на вопрос тикета: у остальных чат сохранится',
    );
    expect(
      find.textContaining('в разделе «Архив»'),
      findsOneWidget,
      reason:
          'честный текст без маршрута порождает следующий вопрос — «а как '
          'тогда удалить?»',
    );

    final ok = find.widgetWithText(AdaptiveDialogAction, 'Выйти из чата');
    expect(ok, findsOneWidget);
    await tester.tap(ok);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    // NEGATIVE-ассерт: forget() необратим без повторного join, и этот путь его
    // звать НЕ должен — «удалить насовсем» живёт только на экране «Архив».
    final called = FakeMatrixApi.calledEndpoints.keys.join('\n');
    expect(
      called.contains('/forget'),
      isFalse,
      reason: 'выход из чата не имеет права необратимо забывать комнату',
    );
    await teardownTree(tester);
  });

  // AC:RL-leave-chat-not-delete/4 — анти-инверсия: канал не задет фиксом.
  testWidgets('канал: подпись осталась «Покинуть канал»', (tester) async {
    await pump(
      tester,
      buildRoom(id: '!ch:example.invalid', chatType: 'channel'),
    );
    await openMenu(tester);

    expect(find.text('Покинуть канал'), findsOneWidget);
    expect(find.text('Выйти из чата'), findsNothing);
    await teardownTree(tester);
  });

  // AC:RL-leave-chat-not-delete/5 + AC:RL-delete-company-via-support/2
  testWidgets('своё главное пространство: у участника пункта выхода нет', (
    tester,
  ) async {
    // Top-level space на ДОМЕНЕ пользователя = своя компания. Сервер отвечает
    // на leave 403 (single_space_guard), поэтому кнопки быть не должно.
    // Гейт есть в chat_list и space_view, но был потерян в меню шапки — куда
    // и ведут «Настройки» пространства.
    // Домен — из client.userID: тест-клиент логинится НЕ как @alice:example.invalid,
    // и «!company:example.invalid» здесь был чужой компанией — страж зеленел
    // «даром» (поймано на LABA-2533).
    final ownDomain = client.userID!.split(':').last;
    await pump(tester, buildRoom(id: '!company:$ownDomain', isSpace: true));
    await openMenu(tester);

    expect(find.text('Выйти из чата'), findsNothing);
    expect(find.text('Удалить чат'), findsNothing);
    expect(find.text('Покинуть'), findsNothing);
    expect(
      find.text('Отписаться'),
      findsNothing,
      reason: 'своя компания, а не подписка на чужую',
    );
    expect(
      find.text('Удалить компанию через поддержку'),
      findsNothing,
      reason: 'заявка на удаление — только админу (PL≥100), участник PL0',
    );
    await teardownTree(tester);
  });

  // AC:RL-leave-chat-not-delete/6
  testWidgets('чужая компания: выход подписан как отписка', (tester) async {
    // Другой домен + top-level space = подписка на чужую компанию.
    await pump(tester, buildRoom(id: '!company:other.invalid', isSpace: true));
    await openMenu(tester);

    expect(find.text('Отписаться'), findsOneWidget);
    await tester.tap(find.text('Отписаться').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(
      find.textContaining('отпишетесь от компании'),
      findsOneWidget,
      reason: 'текст про «чат в архиве» здесь был неверен — это компания',
    );
    expect(find.textContaining('переместится в архив'), findsNothing);
    await teardownTree(tester);
  });
}
