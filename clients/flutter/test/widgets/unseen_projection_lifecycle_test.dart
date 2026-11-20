// ledger:RL-edited-message-read-cursor
// AC:RL-edited-message-read-cursor/26
// Настоящий Matrix.initState → initMatrix → _registerSubs для двух SDK Client.
// Не создаём UnseenProjectionSubscription вручную и не подменяем MatrixState.
// Cohort — публичный enabled-сигнал настоящей monitoring session; transport
// выдачи cohort отдельно покрыт scheduler tests. Web использует IndexedDB.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/widgets/matrix.dart' as liza;

import '../utils/test_client.dart'
    if (dart.library.js_interop) '../utils/lifecycle_client_web.dart';

class _LifecycleApi extends FakeMatrixApi {
  final String user;
  Map<String, dynamic>? nextSync;
  _LifecycleApi(this.user);

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) async {
    // FakeMatrixApi штатно знает filter endpoint только своего @test. Здесь
    // два других настоящих SDK userID, каждому нужен ответ создания фильтра.
    if (request.url.path.endsWith('/filter') && request.method == 'POST') {
      return http.Response('{"filter_id":"lifecycle-filter"}', 200);
    }
    if (request.url.path.endsWith('/sync') && nextSync != null) {
      return http.Response(jsonEncode(nextSync), 200);
    }
    final response = await super.mockIntercept(request);
    if (request.url.path.endsWith('/login') &&
        request.method == 'POST' &&
        response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      data['user_id'] = user;
      return http.Response(jsonEncode(data), response.statusCode);
    }
    return response;
  }
}

Event _event(Room room, String id, int ts, {bool reaction = false}) => Event(
  eventId: id,
  senderId: '@sender:example.invalid',
  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
  type: reaction ? EventTypes.Reaction : EventTypes.Message,
  content: reaction
      ? {
          'm.relates_to': {
            'rel_type': 'm.annotation',
            'event_id': r'$preview',
            'key': '+',
          },
        }
      : {'msgtype': 'm.text', 'body': id},
  room: room,
);

Map<String, dynamic> _sync(
  Room room,
  String token, {
  List<Event> events = const [],
  String? receipt,
}) => {
  'next_batch': token,
  'rooms': {
    'join': {
      room.id: {
        if (events.isNotEmpty)
          'timeline': {
            'events': events.map((e) => e.toJson()).toList(),
            'limited': false,
          },
        if (receipt != null)
          'ephemeral': {
            'events': [
              {
                'type': 'm.receipt',
                'content': {
                  receipt: {
                    'm.read.private': {
                      room.client.userID!: {'ts': 3000},
                    },
                  },
                },
              },
            ],
          },
        'unread_notifications': {'notification_count': 0, 'highlight_count': 0},
      },
    },
  },
};

Future<Room> _seed(Client client, String name) async {
  client.rooms.clear();
  final room = Room(
    id: '!lifecycle:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  final preview = _event(room, r'$preview', 50000);
  final later = _event(room, r'$later', 2000, reaction: true);
  for (final event in [preview, later]) {
    await client.database.storeEventUpdate(
      room.id,
      event,
      EventUpdateType.timeline,
      client,
    );
  }
  room.lastEvent = preview;
  room.setState(
    Event(
      eventId: '\$name-$name',
      room: room,
      senderId: '@sender:example.invalid',
      type: EventTypes.RoomName,
      stateKey: '',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
      content: {'name': name},
    ),
  );
  room.setState(
    Event(
      eventId: '\$member-$name',
      room: room,
      senderId: '@sender:example.invalid',
      type: EventTypes.RoomMember,
      stateKey: '@sender:example.invalid',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
      content: {'membership': 'join', 'displayname': 'Sender'},
    ),
  );
  await client.handleSync(
    SyncUpdate.fromJson(_sync(room, 'seed-$name', receipt: later.eventId)),
  );
  return room;
}

// Matrix подписывается внутри fakeAsync, SQLite завершает работу через FFI.
// Чередуем реальные callbacks и fake microtasks; никакого ручного reconcile.
Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Полный Matrix содержит соседние one-shot rateLimit (до 5 мин), jitter
  // ghost-prune и DM timeout. После dispose даём им закончиться в fake time;
  // подписки/периодические timers уже сняты самим настоящим Matrix.dispose.
  await tester.pump(const Duration(minutes: 6));
  await _drain(tester);
  await tester.pump(const Duration(seconds: 30));
  await _drain(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Client primary;
  late Client secondary;
  late _LifecycleApi primaryApi;
  late _LifecycleApi secondaryApi;
  late Room primaryRoom;
  late Room secondaryRoom;
  late SharedPreferences store;

  setUp(() async {
    UnseenProjectionSubscription.initialHydration = true;
    addTearDown(() => UnseenProjectionSubscription.initialHydration = false);
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    store = await SharedPreferences.getInstance();
    UnseenOrderCache.reset();
    primaryApi = _LifecycleApi('@primary:example.invalid');
    secondaryApi = _LifecycleApi('@secondary:example.invalid');
    primary = await prepareTestClient(
      loggedIn: true,
      clientName: 'primary',
      httpClient: primaryApi,
      homeserver: Uri.parse('https://synapse.liza.laba.prodamus.tech'),
    );
    secondary = await prepareTestClient(
      loggedIn: true,
      clientName: 'secondary',
      httpClient: secondaryApi,
      homeserver: Uri.parse('https://liza.cyber-agro.ru'),
    );
    for (final client in [primary, secondary]) {
      client.backgroundSync = false;
      await client.abortSync();
    }
    primaryRoom = await _seed(primary, 'Primary');
    secondaryRoom = await _seed(secondary, 'Secondary');
  });

  tearDown(() async {
    await primary.dispose(closeDatabase: true);
    await secondary.dispose(closeDatabase: true);
  });

  for (final cohort in [false, true]) {
    testWidgets(
      'Matrix автоматически обслуживает secondary, cohort=$cohort, logout/dispose снимают подписки',
      (tester) => http.runWithClient(() async {
        addTearDown(() async {
          await _unmount(tester);
        });
        final clients = [primary, secondary];
        final key = GlobalKey<liza.MatrixState>();
        expect(primary.userID, isNot(secondary.userID));
        expect(primaryRoom.hasUnseenMessages, isTrue);
        expect(secondaryRoom.hasUnseenMessages, isTrue);
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: const [
              L10n.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: L10n.supportedLocales,
            home: liza.Matrix(
              key: key,
              clients: clients,
              store: store,
              child: Scaffold(
                body: Column(
                  children: [
                    ChatListItem(
                      primaryRoom,
                      key: const ValueKey('primary-row'),
                      onTap: () {},
                    ),
                    ChatListItem(
                      secondaryRoom,
                      key: const ValueKey('secondary-row'),
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final sessions = [
          PushContractSession.observing(primary),
          PushContractSession.observing(secondary),
        ];
        expect(
          sessions.every((s) => s != null),
          isTrue,
          reason: 'реальный Matrix привязал обе monitoring sessions',
        );
        for (final session in sessions) {
          session!.enabled = cohort;
        }
        await _drain(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        double? dot(String key) => tester
            .widget<AnimatedContainer>(
              find.descendant(
                of: find.descendant(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(UnreadBubble),
                ),
                matching: find.byType(AnimatedContainer),
              ),
            )
            .constraints
            ?.maxHeight;
        FontWeight? weight(String name) =>
            tester.widget<Text>(find.text(name)).style?.fontWeight;
        expect(key.currentState!.client, same(primary));
        expect(dot('primary-row'), 0);
        expect(dot('secondary-row'), 0);
        expect(weight('Secondary'), isNull);
        expect(UnseenOrderCache.lookup(primaryRoom), isFalse);
        expect(UnseenOrderCache.lookup(secondaryRoom), isFalse);
        debugPrint('[lifecycle] bootstrap обоих аккаунтов подтверждён');

        await tester.runAsync(() async {
          primaryApi.nextSync = _sync(
            primaryRoom,
            'primary-e3',
            events: [_event(primaryRoom, r'$e3', 60000)],
          );
          secondaryApi.nextSync = _sync(
            secondaryRoom,
            'secondary-e3',
            events: [_event(secondaryRoom, r'$e3', 60000)],
          );
          await primary.oneShotSync(timeout: Duration.zero);
          await secondary.oneShotSync(timeout: Duration.zero);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await _drain(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(primary.prevBatch, 'primary-e3');
        expect(secondary.prevBatch, 'secondary-e3');
        expect(primaryRoom.lastEvent?.eventId, r'$e3');
        expect(secondaryRoom.lastEvent?.eventId, r'$e3');
        expect(dot('primary-row'), 14);
        expect(dot('secondary-row'), 14);
        debugPrint('[lifecycle] e3 обоих аккаунтов подтверждён');
        await tester.runAsync(() async {
          final later = _event(
            secondaryRoom,
            r'$after-e3',
            2001,
            reaction: true,
          );
          secondaryApi.nextSync = _sync(
            secondaryRoom,
            'secondary-read',
            events: [later],
            receipt: later.eventId,
          );
          await secondary.oneShotSync(timeout: Duration.zero);
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await _drain(tester);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          key.currentState!.client,
          same(primary),
          reason: 'активный аккаунт не менялся',
        );
        expect(dot('primary-row'), 14);
        expect(dot('secondary-row'), 0);
        expect(weight('Secondary'), isNull);
        expect(sessions.every((s) => s!.enabled == cohort), isTrue);
        debugPrint(
          '[lifecycle] secondary receipt без смены primary подтверждён',
        );

        await tester.runAsync(() async {
          await secondary.logout();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await _drain(tester);
        await tester.pump();
        expect(clients, [primary]);
        expect(sessions.last!.disposed, isTrue);
        expect(UnseenOrderCache.lookup(secondaryRoom), isNull);
        debugPrint('[lifecycle] SDK logout secondary подтверждён');
        await _unmount(tester);
        expect(sessions.first!.disposed, isTrue);
        expect(UnseenOrderCache.lookup(primaryRoom), isNull);
        debugPrint('[lifecycle] Matrix dispose primary подтверждён');
        expect(tester.takeException(), isNull);
      }, () => MockClient((_) async => http.Response('{}', 400))),
      timeout: const Timeout(Duration(seconds: 30)),
    );
  }
}
