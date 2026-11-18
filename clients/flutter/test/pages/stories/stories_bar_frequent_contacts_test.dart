// ignore_for_file: depend_on_referenced_packages
// ledger:RL-stories-bar-frequent-contacts
//
// РЕАЛЬНЫЙ виджет StoriesBar над тестовым Client: после «Мой сторис» идут
// недавние DM людей (локальная БД), без ботов и BotFather;
// настоящие публикации ботов сохраняются, тап открывает личный чат.
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

  /// Роль ai без сервера ролей: тест сам решает, кто бот.
  final Set<String> aiIds = {};

  @override
  bool isAiUser(String userId) => aiIds.contains(userId);
}

Finder _tile(String userId) => find.byKey(ValueKey('frequentContact:$userId'));

// Проверяем всех детей реального ListView, включая ещё не построенные за viewport.
List<String> _contactIds(WidgetTester tester) {
  final list = tester.widget<ListView>(
    find.descendant(
      of: find.byType(StoriesBar),
      matching: find.byType(ListView),
    ),
  );
  return (list.childrenDelegate as SliverChildListDelegate).children
      .map((w) => w.key)
      .whereType<ValueKey<String>>()
      .map((k) => k.value)
      .where((k) => k.startsWith('frequentContact:'))
      .map((k) => k.substring('frequentContact:'.length))
      .toList();
}

void main() {
  late Client client;
  late _MatrixWithClient matrix;

  setUp(FrequentContactsCache.instance.reset);

  Future<void> addDm(String peer, int messages, {int ageMin = 0}) async {
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
        originServerTs: DateTime.now().subtract(
          Duration(minutes: ageMin + i + 1),
        ),
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

  Future<GoRouter> pumpBar(
    WidgetTester tester, {
    String? storyAuthor,
    bool withLiveBot = false,
    bool fillLimit = false,
  }) async {
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      client = await prepareTestClient(loggedIn: true);
      // Фоновый sync FakeMatrixApi не нужен: лента читает только локальное.
      await client.abortSync();
      client.rooms.clear();
      client.accountData.remove('m.direct');
      await addDm('@bob:example.invalid', 5, ageMin: 10);
      await addDm('@carol:example.invalid', 2, ageMin: 30);
      await addDm('@shop_bot:bots.liza.ru', 20, ageMin: 60);
      await addDm(MatrixState.lizaMxid, 30, ageMin: 90);
      await addDm('@helper:example.invalid', 9);
      for (final bot in [
        '@botfather:bots.liza.ru',
        '@botfather:example.invalid',
        '@bot_father:example.invalid',
        '@botfather:liza.local',
        '@bot_father:liza.local',
        '@liza:company.invalid',
        '@company_bot:company.invalid',
      ]) {
        await addDm(bot, 1, ageMin: 70);
        // ignore: deprecated_member_use
        client.presences[bot] = CachedPresence(
          PresenceType.online,
          0,
          null,
          true,
          bot,
        );
      }
      await addDm('@botfather_helper:example.invalid', 1, ageMin: 45);
      if (fillLimit) {
        for (var i = 0; i < 30; i++) {
          await addDm('@person$i:example.invalid', 1, ageMin: -1);
        }
        for (var i = 0; i < 31; i++) {
          await addDm('@bot$i:bots.liza.ru', 1, ageMin: -1);
        }
      }
      // Кэш содержит ботов: фильтр должен работать и без пересчёта.
      await FrequentContactsCache.instance.refreshIfStale(client);
      if (withLiveBot) await addDm('@live_bot:bots.liza.ru', 1);
      // Роль ещё не загружена; идентичность не должна зависеть от неё.
      // ignore: deprecated_member_use
      client.presences[MatrixState.lizaMxid] = CachedPresence(
        PresenceType.online,
        0,
        null,
        true,
        MatrixState.lizaMxid,
      );
      if (storyAuthor != null) {
        const roomId = '!liza-story:example.invalid';
        final room = Room(id: roomId, client: client);
        client.rooms.add(room);
        room.setState(
          Event(
            eventId: r'$create-story',
            senderId: storyAuthor,
            originServerTs: DateTime.now(),
            type: EventTypes.RoomCreate,
            stateKey: '',
            content: const {'com.liza.chat.type': 'stories'},
            room: room,
          ),
        );
        await client.handleSync(
          SyncUpdate(
            nextBatch: 'liza-story',
            rooms: RoomsUpdate(
              join: {
                roomId: JoinedRoomUpdate(
                  timeline: TimelineUpdate(
                    events: [
                      MatrixEvent(
                        eventId: r'$liza-story',
                        senderId: storyAuthor,
                        originServerTs: DateTime.now(),
                        type: EventTypes.Message,
                        content: {
                          'msgtype': 'm.image',
                          'com.liza.story': {
                            'expires_ts':
                                DateTime.now().millisecondsSinceEpoch + 3600000,
                            'overlays': [],
                          },
                        },
                      ),
                    ],
                  ),
                ),
              },
            ),
          ),
        );
      }
    });
    matrix = _MatrixWithClient(client, prefs);
    matrix.aiIds.add('@company_bot:company.invalid');
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: StoriesBar()),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (_, state) => Text('room:${state.pathParameters['roomid']}'),
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

  testWidgets('порядок: «Мой сторис» → остальные по времени последнего '
      'сообщения; боты и BotFather скрыты', (tester) async {
    await pumpBar(tester);
    // AC:RL-stories-bar-frequent-contacts/13
    final contacts = _contactIds(tester);
    expect(contacts, contains('@botfather_helper:example.invalid'));
    expect(
      contacts,
      unorderedEquals([
        '@helper:example.invalid',
        '@bob:example.invalid',
        '@carol:example.invalid',
        '@botfather_helper:example.invalid',
      ]),
    );
    final add = tester.getCenter(find.byIcon(Icons.add_outlined)).dx;
    final helper = tester.getCenter(_tile('@helper:example.invalid')).dx;
    final bob = tester.getCenter(_tile('@bob:example.invalid')).dx;
    final carol = tester.getCenter(_tile('@carol:example.invalid')).dx;
    // AC:RL-stories-bar-frequent-contacts/1
    expect(add < helper, isTrue, reason: '«Мой сторис» первым');
    expect(
      helper < bob && bob < carol,
      isTrue,
      reason: 'свежий диалог левее: helper, bob, carol',
    );
    // AC:RL-stories-bar-frequent-contacts/10
    expect(_tile(MatrixState.lizaMxid), findsNothing);
    // AC:RL-stories-bar-frequent-contacts/11
    expect(_tile('@shop_bot:bots.liza.ru'), findsNothing);
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
      expect(
        avatar.storyRing,
        isNull,
        reason: 'у частого без сторис нет кольца',
      );
    }
    expect(find.bySemanticsLabel('Открыть чат с bob'), findsOneWidget);
    await teardown(tester);
  });

  testWidgets('главный чат Лизы скрыт после загрузки роли и повторного '
      'mount с прогретым кэшем', (tester) async {
    final router = await pumpBar(tester);
    final cached = FrequentContactsCache.instance.cached(client.userID);
    expect(cached.any((d) => d.userId == MatrixState.lizaMxid), isTrue);
    // AC:RL-stories-bar-frequent-contacts/10
    expect(_tile(MatrixState.lizaMxid), findsNothing);
    matrix.aiIds.add(MatrixState.lizaMxid);
    matrix.userRoleService.rolesVersion.value++;
    await tester.pump();
    expect(_tile(MatrixState.lizaMxid), findsNothing);
    router.go('/rooms/temporary');
    await tester.pumpAndSettle();
    router.go('/');
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    expect(FrequentContactsCache.instance.cached(client.userID), same(cached));
    expect(_tile(MatrixState.lizaMxid), findsNothing);
    // AC:RL-stories-bar-frequent-contacts/15
    expect(cached.any((d) => d.userId == '@shop_bot:bots.liza.ru'), isTrue);
    expect(_contactIds(tester), isNot(contains('@shop_bot:bots.liza.ru')));
    await teardown(tester);
  });

  for (final author in [
    MatrixState.lizaMxid,
    '@shop_bot:bots.liza.ru',
    '@bot_father:example.invalid',
  ]) {
    testWidgets('активная публикация $author сохраняется без DM-дубля', (
      tester,
    ) async {
      await pumpBar(tester, storyAuthor: author);
      // AC:RL-stories-bar-frequent-contacts/12
      final authorAvatar = find.byWidgetPredicate(
        (w) => w is Avatar && w.name == author.localpart && w.storyRing != null,
      );
      expect(authorAvatar, findsOneWidget);
      expect(_tile(author), findsNothing);
      matrix.aiIds.add(author);
      matrix.userRoleService.rolesVersion.value++;
      await tester.pump();
      // AC:RL-stories-bar-frequent-contacts/9
      expect(tester.widget<Avatar>(authorAvatar).isHexagonal, isTrue);
      await teardown(tester);
    });
  }

  testWidgets('новый живой DM бота отсутствует вне прогретого кэша', (
    tester,
  ) async {
    await pumpBar(tester, withLiveBot: true);
    final cached = FrequentContactsCache.instance.cached(client.userID);
    expect(cached.any((d) => d.userId == '@live_bot:bots.liza.ru'), isFalse);
    expect(
      client.rooms.any((r) => r.directChatMatrixID == '@live_bot:bots.liza.ru'),
      isTrue,
    );
    // AC:RL-stories-bar-frequent-contacts/15
    expect(_contactIds(tester), isNot(contains('@live_bot:bots.liza.ru')));
    await teardown(tester);
  });

  testWidgets('31 свежий бот не вытесняет 30 людей из лимита', (tester) async {
    await pumpBar(tester, fillLimit: true);
    // AC:RL-stories-bar-frequent-contacts/16
    expect(
      _contactIds(tester),
      unorderedEquals([
        for (var i = 0; i < 30; i++) '@person$i:example.invalid',
      ]),
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

  testWidgets('поздняя ai-роль убирает DM без пересчёта кэша', (tester) async {
    // ledger:RL-stories-bar-frequent-contacts
    await pumpBar(tester);
    final cached = FrequentContactsCache.instance.cached(client.userID);
    expect(_tile('@helper:example.invalid'), findsOneWidget);
    matrix.aiIds.add('@helper:example.invalid');
    matrix.userRoleService.rolesVersion.value++;
    await tester.pump();
    // AC:RL-stories-bar-frequent-contacts/14
    expect(_contactIds(tester), isNot(contains('@helper:example.invalid')));
    expect(FrequentContactsCache.instance.cached(client.userID), same(cached));
    for (final id in ['@bob:example.invalid', '@carol:example.invalid']) {
      expect(_contactIds(tester), contains(id), reason: '$id — человек');
    }
    await teardown(tester);
  });
}
