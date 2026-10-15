// ignore_for_file: depend_on_referenced_packages
// ledger:RL-stories-bar-frequent-contacts
//
// РЕАЛЬНЫЙ виджет StoriesBar над тестовым Client: после «Мой сторис» идут
// частые собеседники по числу сообщений в DM (локальная БД), без Лизы и
// ботов, без точки «в сети» и без кольца; тап открывает личный чат.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/stories/stories_bar.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

class _MatrixWithClient extends MatrixState {
  _MatrixWithClient(this.testClient, this.prefs);

  final Client testClient;
  final SharedPreferences prefs;

  @override
  Client get client => testClient;

  @override
  SharedPreferences get store => prefs;
}

Finder _tile(String userId) =>
    find.byKey(ValueKey('frequentContact:$userId'));

void main() {
  late Client client;

  setUp(FrequentContactsCache.instance.reset);

  Future<void> addDm(String peer, int messages) async {
    final roomId = '!dm-${peer.hashCode}:example.invalid';
    final room = Room(id: roomId, client: client);
    client.rooms.add(room);
    final direct = Map<String, Object?>.from(
      client.accountData['m.direct']?.content ?? const {},
    );
    direct[peer] = [roomId];
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: direct,
    );
    room.setState(
      Event(
        eventId: '\$m-$roomId',
        senderId: peer,
        originServerTs: DateTime.now(),
        type: EventTypes.RoomMember,
        stateKey: peer,
        content: {'membership': 'join', 'displayname': peer.localpart},
        room: room,
      ),
    );
    for (var i = 0; i < messages; i++) {
      final e = MatrixEvent(
        eventId: '\$e-$roomId-$i',
        senderId: peer,
        originServerTs: DateTime.now().subtract(Duration(minutes: i + 1)),
        type: EventTypes.Message,
        content: const {'msgtype': 'm.text', 'body': 'hi'},
      );
      await client.database.storeEventUpdate(
        roomId,
        e,
        EventUpdateType.timeline,
        client,
      );
      room.lastEvent ??= Event.fromMatrixEvent(e, room);
    }
  }

  Future<GoRouter> pumpBar(WidgetTester tester) async {
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      client = await prepareTestClient(loggedIn: true);
      // Фоновый sync FakeMatrixApi не нужен: лента читает только локальное.
      await client.abortSync();
      client.rooms.clear();
      client.accountData.remove('m.direct');
      await addDm('@bob:example.invalid', 5);
      await addDm('@carol:example.invalid', 2);
      await addDm('@shop_bot:bots.liza.ru', 20);
      await addDm('@liza:bots.liza.ru', 30);
      await addDm('@helper:example.invalid', 9);
    });
    final matrix = _MatrixWithClient(client, prefs);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: StoriesBar()),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (_, state) =>
              Text('room:${state.pathParameters['roomid']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: matrix,
        child: MaterialApp.router(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    // L10n (deferred) + post-frame загрузка ленты через реальную БД.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pump();
    return router;
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 40));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });
  }

  testWidgets('порядок: «Мой сторис» → частые по числу сообщений; без Лизы '
      'и ботов; без кольца и точки «в сети»', (tester) async {
    await pumpBar(tester);
    final add = tester.getCenter(find.byIcon(Icons.add_outlined)).dx;
    final helper = tester.getCenter(_tile('@helper:example.invalid')).dx;
    final bob = tester.getCenter(_tile('@bob:example.invalid')).dx;
    final carol = tester.getCenter(_tile('@carol:example.invalid')).dx;
    // AC:RL-stories-bar-frequent-contacts/1
    expect(add < helper, isTrue, reason: '«Мой сторис» первым');
    expect(helper < bob && bob < carol, isTrue, reason: '9 > 5 > 2 сообщений');
    // AC:RL-stories-bar-frequent-contacts/3
    expect(_tile('@shop_bot:bots.liza.ru'), findsNothing);
    expect(_tile('@liza:bots.liza.ru'), findsNothing);
    // AC:RL-stories-bar-frequent-contacts/7
    for (final id in [
      '@helper:example.invalid',
      '@bob:example.invalid',
      '@carol:example.invalid',
    ]) {
      final avatar = tester.widget<Avatar>(
        find.descendant(of: _tile(id), matching: find.byType(Avatar)),
      );
      expect(avatar.presenceUserId, isNull, reason: 'точки «в сети» нет');
      expect(avatar.storyRing, isNull, reason: 'у частого без сторис нет кольца');
    }
    expect(
      find.bySemanticsLabel('Открыть чат с bob'),
      findsOneWidget,
    );
    await teardown(tester);
  });

  testWidgets('тап по частому открывает его личный чат', (tester) async {
    // AC:RL-stories-bar-frequent-contacts/6
    final router = await pumpBar(tester);
    await tester.tap(_tile('@bob:example.invalid'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final bobRoom = '!dm-${'@bob:example.invalid'.hashCode}:example.invalid';
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/rooms/$bobRoom',
    );
    expect(find.text('room:$bobRoom'), findsOneWidget);
    await teardown(tester);
  });
}
