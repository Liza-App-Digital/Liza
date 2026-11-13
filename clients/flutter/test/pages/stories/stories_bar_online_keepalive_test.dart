// ignore_for_file: depend_on_referenced_packages
// ledger:RL-stories-bar-order-online-keepalive
//
// РЕАЛЬНЫЙ StoriesBar: категория «онлайн» (точка, порядок, DM без сообщений) и
// сохранение горизонтальной позиции ленты при прокрутке списка чатов.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/stories/stories_bar.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
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

Finder _tile(String userId) => find.byKey(ValueKey('frequentContact:$userId'));
Finder _dot(String userId) => find.byKey(ValueKey('onlineDot:$userId'));

void main() {
  late Client client;

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

  void setOnline(String id, int agoMs) {
    // ignore: deprecated_member_use
    client.presences[id] = CachedPresence(
      PresenceType.online,
      agoMs,
      null,
      true,
      id,
    );
  }

  Future<void> pumpBar(
    WidgetTester tester, {
    required Future<void> Function() seed,
    bool inScrollView = false,
  }) async {
    late SharedPreferences prefs;
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      client = await prepareTestClient(loggedIn: true);
      await client.abortSync();
      client.rooms.clear();
      client.accountData.remove('m.direct');
      await seed();
    });
    final matrix = _MatrixWithClient(client, prefs);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: inScrollView
                ? CustomScrollView(
                    key: const ValueKey('outer'),
                    slivers: [
                      SliverList(
                        delegate: SliverChildListDelegate([
                          const StoriesBar(),
                          for (var i = 0; i < 40; i++)
                            const SizedBox(height: 100),
                        ]),
                      ),
                    ],
                  )
                : const StoriesBar(),
          ),
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
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    await tester.pump();
  }

  Future<void> teardown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 40));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });
  }

  testWidgets('онлайн: точка, порядок «вышел позже — левее», DM без сообщений '
      'тоже онлайн; боты скрыты; остальные правее', (tester) async {
    await pumpBar(
      tester,
      seed: () async {
        await addDm('@helper:example.invalid', 9); // свежий, не онлайн
        await addDm('@bob:example.invalid', 5, ageMin: 10);
        await addDm('@carol:example.invalid', 2, ageMin: 30);
        await addDm('@silent:example.invalid', 0); // DM без сообщений
        await addDm('@shop_bot:bots.liza.ru', 3, ageMin: 5);
        setOnline('@carol:example.invalid', 5 * 60000);
        setOnline('@silent:example.invalid', 4 * 60000);
        setOnline('@bob:example.invalid', 1 * 60000);
        setOnline('@shop_bot:bots.liza.ru', 1000);
      },
    );
    double x(String id) => tester.getCenter(_tile(id)).dx;
    // AC:RL-stories-bar-order-online-keepalive/1
    expect(_dot('@bob:example.invalid'), findsOneWidget);
    expect(_dot('@carol:example.invalid'), findsOneWidget);
    expect(_dot('@silent:example.invalid'), findsOneWidget);
    expect(_dot('@helper:example.invalid'), findsNothing);
    expect(_dot('@shop_bot:bots.liza.ru'), findsNothing);
    // AC:RL-stories-bar-order-online-keepalive/2
    expect(_tile('@silent:example.invalid'), findsOneWidget);
    expect(x('@bob:example.invalid') < x('@silent:example.invalid'), isTrue);
    expect(x('@silent:example.invalid') < x('@carol:example.invalid'), isTrue);
    expect(x('@carol:example.invalid') < x('@helper:example.invalid'), isTrue);
    // боты в категории «онлайн» не показываются, а в кат.3 — считаются (правее)
    expect(x('@helper:example.invalid') < x('@shop_bot:bots.liza.ru'), isTrue);
    await teardown(tester);
  });

  testWidgets(
    'кат.3: DM без дневной переписки, но со свежим lastEvent, левее старого',
    (tester) async {
      await pumpBar(
        tester,
        seed: () async {
          await addDm('@old:example.invalid', 3, ageMin: 60);
          await addDm('@new:example.invalid', 3, ageMin: 5);
        },
      );
      double x(String id) => tester.getCenter(_tile(id)).dx;
      expect(x('@new:example.invalid') < x('@old:example.invalid'), isTrue);
      await teardown(tester);
    },
  );

  testWidgets('лента не сбрасывает горизонтальную позицию, когда список чатов '
      'прокрутили вниз и обратно', (tester) async {
    await pumpBar(
      tester,
      inScrollView: true,
      seed: () async {
        for (var i = 0; i < 14; i++) {
          await addDm('@u$i:example.invalid', 1, ageMin: i);
        }
      },
    );
    final scrollable = find.descendant(
      of: find.byType(StoriesBar),
      matching: find.byType(Scrollable),
    );
    ScrollPosition pos() => tester.state<ScrollableState>(scrollable).position;
    await tester.drag(find.byType(StoriesBar), const Offset(-300, 0));
    await tester.pump();
    final before = pos().pixels;
    expect(before > 0, isTrue, reason: 'ленту удалось сдвинуть');
    final outer = find.byKey(const ValueKey('outer'));
    await tester.drag(outer, const Offset(0, -3000));
    await tester.pump();
    await tester.drag(outer, const Offset(0, 3000));
    await tester.pump();
    // AC:RL-stories-bar-order-online-keepalive/3
    expect(pos().pixels, before);
    await teardown(tester);
  });
}
