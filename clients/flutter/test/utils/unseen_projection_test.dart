// ledger:RL-edited-message-read-cursor
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/utils/confirmed_read_state.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/matrix.dart' as liza;

import 'test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  resourceTests();
  late Client client;
  late Room room;
  late _ProjectionApi api;
  setUp(() async {
    UnseenProjectionSubscription.initialHydration = true;
    addTearDown(() => UnseenProjectionSubscription.initialHydration = false);
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    UnseenOrderCache.reset();
    api = _ProjectionApi();
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    await client.abortSync();
    client.rooms.clear();
    room = Room(
      id: '!projection:example.invalid',
      client: client,
      membership: Membership.join,
    );
    client.rooms.add(room);
  });
  tearDown(() async => client.dispose(closeDatabase: true));

  Event event(String id, int ts, {String type = EventTypes.Message}) => Event(
    eventId: id,
    type: type,
    senderId: '@bob:example.invalid',
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    content: {'msgtype': 'm.text', 'body': id},
    room: room,
  );
  Future<void> store(List<Event> events) async {
    for (final e in events) {
      await client.database.storeEventUpdate(
        room.id,
        e,
        EventUpdateType.timeline,
        client,
      );
    }
  }

  Future<void> receipt(String id, String type, int ts) async {
    await client.handleSync(
      SyncUpdate.fromJson({
        'next_batch': 'receipt-$id-$type',
        'rooms': {
          'join': {
            room.id: {
              'unread_notifications': {
                'notification_count': 0,
                'highlight_count': 0,
              },
              'ephemeral': {
                'events': [
                  {
                    'type': 'm.receipt',
                    'content': {
                      id: {
                        type: {
                          client.userID!: {'ts': ts},
                        },
                      },
                    },
                  },
                ],
              },
            },
          },
        },
      }),
    );
  }

  // AC:RL-edited-message-read-cursor/18
  test('SDK unknown private does not cancel exact public coverage', () async {
    final preview = event(r'$preview', 50000);
    await store([preview]);
    room.lastEvent = preview;
    await receipt(r'$unknown-private', 'm.read.private', 1000);
    await receipt(preview.eventId, 'm.read', 60000);
    expect(
      room.receiptState.global.latestOwnReceipt?.eventId,
      r'$unknown-private',
      reason: 'unchanged SDK bug is not the app oracle',
    );
    expect(room.hasNewMessages, isTrue);
    expect(room.hasUnseenMessages, isFalse);
  });

  test(
    'count0 bulk refresh covers future dated preview by actual DB order',
    () async {
      final preview = event(r'$preview', 50000);
      final later = event(r'$later', 2000, type: EventTypes.RoomName);
      await store([preview, later]);
      room.lastEvent = preview;
      await receipt(later.eventId, 'm.read.private', 3000);
      expect(room.hasUnseenMessages, isTrue);
      await UnseenOrderCache.reconcile(client);
      // Numeric badge path returns promptly; count0 hydration is background work.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(room.hasUnseenMessages, isFalse);
      expect(room.notificationCount, 0);
    },
  );

  for (final privateCovers in [true, false]) {
    test(
      'known receipt covers regardless of other unknown: private=$privateCovers',
      () async {
        final preview = event(r'$preview', 50000);
        final later = event(r'$later', 1000, type: EventTypes.RoomName);
        await store([preview, later]);
        room.lastEvent = preview;
        await receipt(
          r'$missing',
          privateCovers ? 'm.read' : 'm.read.private',
          90000,
        );
        await receipt(
          later.eventId,
          privateCovers ? 'm.read.private' : 'm.read',
          3000,
        );
        await UnseenOrderCache.reconcileRoom(room);
        expect(room.hasUnseenMessages, isFalse);
      },
    );
  }

  test('known old plus unknown remains explicit SDK fallback', () async {
    final old = event(r'$old', 1000);
    final preview = event(r'$preview', 50000);
    await store([old, preview]);
    room.lastEvent = preview;
    await receipt(old.eventId, 'm.read.private', 3000);
    await receipt(r'$missing', 'm.read', 90000);
    await UnseenOrderCache.reconcileRoom(room);
    expect(UnseenOrderCache.lookup(room), isNull);
    expect(room.hasUnseenMessages, room.hasNewMessages);
  });

  // AC:RL-edited-message-read-cursor/18 — обе known, оба направления и same ID.
  for (final privateLatest in [true, false]) {
    test(
      'two known receipts use order with privateLatest=$privateLatest',
      () async {
        final old = event(r'$old', 1000);
        final preview = event(r'$preview', 50000);
        final later = event(r'$later', 2000, type: EventTypes.RoomName);
        await store([old, preview, later]);
        room.lastEvent = preview;
        await receipt(
          privateLatest ? later.eventId : old.eventId,
          'm.read.private',
          90000,
        );
        await receipt(
          privateLatest ? old.eventId : later.eventId,
          'm.read',
          3000,
        );
        await UnseenOrderCache.reconcileRoom(room);
        expect(room.hasUnseenMessages, isFalse);
        await receipt(old.eventId, 'm.read.private', 99000);
        await receipt(old.eventId, 'm.read', 99001);
        await UnseenOrderCache.reconcileRoom(room);
        expect(
          room.hasUnseenMessages,
          isTrue,
          reason: 'same old ID remains behind preview',
        );
      },
    );
  }

  // AC:RL-edited-message-read-cursor/20 — count0 не означает прочитанность.
  test('genuine count0 unseen and manual unread survive hydration', () async {
    final old = event(r'$old', 1000);
    final preview = event(r'$preview', 2000);
    await store([old, preview]);
    room.lastEvent = preview;
    await receipt(old.eventId, 'm.read.private', 90000);
    await UnseenOrderCache.reconcileRoom(room);
    expect(room.hasUnseenMessages, isTrue);
    expect(room.notificationCount, 0);
    expect(room.highlightCount, 0);
    await receipt(preview.eventId, 'm.read.private', 95000);
    room.roomAccountData['m.marked_unread'] = BasicEvent(
      type: 'm.marked_unread',
      content: {'unread': true},
    );
    await UnseenOrderCache.reconcileRoom(room);
    expect(room.hasUnseenMessages, isFalse);
    expect(room.markedUnread, isTrue);
    expect(room.isUnread, isTrue);
  });

  test(
    'history completion invalidates negative cache without live finished',
    () async {
      final preview = event(r'$preview', 50000);
      await store([preview]);
      room.lastEvent = preview;
      await receipt(r'$later', 'm.read.private', 3000);
      await UnseenOrderCache.reconcileRoom(room);
      expect(room.hasUnseenMessages, isTrue);
      final subscription = UnseenProjectionSubscription(client);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final transactionGate = Completer<void>();
      final transaction = client.database.transaction(() async {
        await store([event(r'$later', 2000, type: EventTypes.RoomName)]);
        await client.handleSync(
          SyncUpdate(
            nextBatch: '',
            rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()}),
          ),
        );
        await transactionGate.future;
      });
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(room.hasUnseenMessages, isTrue, reason: 'onSync is before commit');
      transactionGate.complete();
      await transaction;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(room.hasUnseenMessages, isFalse);
      subscription.dispose();
    },
  );

  // AC:RL-edited-message-read-cursor/26 — finished не обходит commit истории.
  test(
    'bulk badge refresh cannot hydrate count0 from precommit quick cache',
    () async {
      final preview = event(r'$preview', 50000);
      await store([preview]);
      room.lastEvent = preview;
      await receipt(r'$later', 'm.read.private', 3000);
      final gate = Completer<void>();
      final transaction = client.database.transaction(() async {
        await store([event(r'$later', 2000, type: EventTypes.RoomName)]);
        await gate.future;
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await UnseenOrderCache.reconcile(client);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final beforeCommit = room.hasUnseenMessages;
      gate.complete();
      await transaction;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(beforeCommit, isTrue);
      expect(room.hasUnseenMessages, isFalse);
    },
  );

  // AC:RL-edited-message-read-cursor/26
  test('live finished waits for overlapping history physical commit', () async {
    final preview = event(r'$preview', 50000);
    await store([preview]);
    room.lastEvent = preview;
    await receipt(r'$later', 'm.read.private', 3000);
    final subscription = UnseenProjectionSubscription(client);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(room.hasUnseenMessages, isTrue);
    // Контракт статусов проверяется отдельно от настоящего oneShotSync ниже.
    client.onSyncStatus.add(
      const SyncStatusUpdate(SyncStatus.waitingForResponse),
    );
    await Future<void>.delayed(Duration.zero);
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.processing));
    await Future<void>.delayed(Duration.zero);
    client.onSync.add(SyncUpdate(nextBatch: client.prevBatch!));
    await Future<void>.delayed(Duration.zero);
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.cleaningUp));
    await Future<void>.delayed(Duration.zero);
    final gate = Completer<void>();
    final transaction = client.database.transaction(() async {
      await store([event(r'$later', 2000, type: EventTypes.RoomName)]);
      await client.handleSync(
        SyncUpdate(
          nextBatch: '',
          rooms: RoomsUpdate(join: {room.id: JoinedRoomUpdate()}),
        ),
      );
      await gate.future;
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final beforeCommit = room.hasUnseenMessages;
    gate.complete();
    await transaction;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final afterCommit = room.hasUnseenMessages;
    subscription.dispose();
    expect(
      beforeCommit,
      isTrue,
      reason: 'history quick cache is not physical commit',
    );
    expect(afterCommit, isFalse);
    expect(
      room.hasUnseenMessages,
      isTrue,
      reason: 'detach discards its cache proof',
    );
  });

  // AC:RL-edited-message-read-cursor/19 — смонтированная точка, без remount.
  testWidgets('ten mounted rebuilds perform no database reads', (tester) async {
    final db = _OrderDb((_) => Future.value([r'$receipt', r'$preview']));
    final client = Client('build-only', database: db);
    final room = faultRoom(client, '!build');
    for (var i = 0; i < 10; i++) {
      await tester.pumpWidget(MaterialApp(home: UnreadBubble(room: room)));
    }
    expect(db.calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    UnseenOrderCache.detach(client);
  });

  // AC:RL-edited-message-read-cursor/19
  testWidgets('mounted UnreadBubble updates after hydration without remount', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final preview = event(r'$preview', 50000);
      final later = event(r'$later', 2000, type: EventTypes.RoomName);
      await store([preview, later]);
      room.lastEvent = preview;
      await receipt(later.eventId, 'm.read.private', 3000);
    });
    await tester.pumpWidget(MaterialApp(home: UnreadBubble(room: room)));
    final bubble = find.descendant(
      of: find.byType(UnreadBubble),
      matching: find.byType(AnimatedContainer),
    );
    double? height() =>
        tester.widget<AnimatedContainer>(bubble).constraints?.maxHeight;
    expect(height(), 14);
    await tester.runAsync(() async {
      await UnseenOrderCache.reconcileRoom(room);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(height(), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // AC:RL-edited-message-read-cursor/19
  // AC:RL-edited-message-read-cursor/26 — настоящий oneShotSync, без monitoring.
  testWidgets(
    'actual live SDK commit updates mounted dot and bold without opening room',
    (tester) async {
      UnseenProjectionSubscription? subscription;
      final preview = event(r'$preview', 50000);
      final old = event(r'$old', 1000);
      final later = event(r'$later', 2000, type: EventTypes.RoomName);
      await tester.runAsync(() async {
        await store([old, preview, later]);
        room.lastEvent = preview;
        room.setState(
          Event(
            eventId: r'$member',
            type: EventTypes.RoomMember,
            stateKey: '@bob:example.invalid',
            senderId: '@bob:example.invalid',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
            content: {'membership': 'join', 'displayname': 'Bob'},
            room: room,
          ),
        );
        room.setState(
          Event(
            eventId: r'$name',
            type: EventTypes.RoomName,
            stateKey: '',
            senderId: '@bob:example.invalid',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
            content: {'name': 'Projection room'},
            room: room,
          ),
        );
        await receipt(old.eventId, 'm.read.private', 3000);
        subscription = UnseenProjectionSubscription(client);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
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
          home: Provider<liza.MatrixState>.value(
            value: _MatrixContext(client),
            child: Scaffold(body: ChatListItem(room, onTap: () {})),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ChatListItem), findsOneWidget);
      expect(find.byType(UnreadBubble), findsOneWidget);
      final bubble = find.descendant(
        of: find.byType(UnreadBubble),
        matching: find.byType(AnimatedContainer),
      );
      double? height() =>
          tester.widget<AnimatedContainer>(bubble).constraints?.maxHeight;
      FontWeight? weight() =>
          tester.widget<Text>(find.text('Projection room')).style?.fontWeight;
      expect(height(), 14);
      expect(weight(), FontWeight.w500);
      await tester.runAsync(() async {
        api.response = {
          'next_batch': 'real-committed-receipt',
          'rooms': {
            'join': {
              room.id: {
                'ephemeral': {
                  'events': [
                    {
                      'type': 'm.receipt',
                      'content': {
                        later.eventId: {
                          'm.read.private': {
                            client.userID!: {'ts': 3000},
                          },
                        },
                      },
                    },
                  ],
                },
                'unread_notifications': {
                  'notification_count': 0,
                  'highlight_count': 0,
                },
              },
            },
          },
        };
        await client.oneShotSync(timeout: Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(client.prevBatch, 'real-committed-receipt');
      expect(height(), 0);
      expect(weight(), isNull);
      expect(room.notificationCount, 0);
      // Настоящее e3 после границы должно вернуть точку и жирность.
      await tester.runAsync(() async {
        final e3 = event(r'$e3', 60000);
        api.response = {
          'next_batch': 'real-e3',
          'rooms': {
            'join': {
              room.id: {
                'timeline': {
                  'events': [e3.toJson()],
                  'limited': false,
                },
                'unread_notifications': {
                  'notification_count': 0,
                  'highlight_count': 0,
                },
              },
            },
          },
        };
        await client.oneShotSync(timeout: Duration.zero);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(height(), 14);
      expect(weight(), FontWeight.w500);
      subscription!.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _OrderDb extends DatabaseApi {
  final Future<List<String>> Function(Room) read;
  final Completer<void>? gate;
  int calls = 0;
  int transactions = 0;
  _OrderDb(this.read, {this.gate});
  @override
  Future<void> transaction(Future<void> Function() action) async {
    transactions++;
    if (gate != null) await gate!.future;
    await action();
  }

  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    bool includeSending = false,
    int? limit,
  }) {
    calls++;
    return read(room);
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Room faultRoom(Client client, String id, {int count = 0}) {
  final room = Room(id: id, client: client, membership: Membership.join)
    ..notificationCount = count;
  room.lastEvent = Event(
    eventId: r'$preview',
    senderId: '@other:test',
    originServerTs: DateTime.fromMillisecondsSinceEpoch(50000),
    type: EventTypes.Message,
    content: {'body': 'preview', 'msgtype': 'm.text'},
    room: room,
  );
  room.roomAccountData[LatestReceiptState.eventType] = BasicEvent(
    type: LatestReceiptState.eventType,
    content: {
      'global': {
        'private': {'e': r'$receipt', 'ts': 1000},
        'latest': {'e': r'$receipt', 'ts': 1000},
      },
    },
  );
  client.rooms.add(room);
  return room;
}

void resourceTests() {
  group('resource and stale guards', () {
    // AC:RL-edited-message-read-cursor/23 — обратный переход перед стартом.
    test(
      'queued positive becoming count0 still takes transaction and budget',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final pending = Completer<List<String>>();
          var reads = 0;
          final db = _OrderDb(
            (_) => ++reads == 1
                ? pending.future
                : Future.value([r'$receipt', r'$preview']),
          );
          final client = Client('reverse', database: db);
          final room = faultRoom(client, '!r');
          unawaited(UnseenOrderCache.reconcileRoom(room));
          async.flushMicrotasks();
          room.notificationCount = 1;
          UnseenOrderCache.committedRooms(client, [room.id]);
          room.notificationCount = 0;
          pending.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(db.calls, 2);
          expect(db.transactions, 2);
          expect(room.hasUnseenMessages, isFalse);
          async.elapse(Duration.zero);
          UnseenOrderCache.detach(client);
        });
      },
    );
    // AC:RL-edited-message-read-cursor/21 — identity seam, не полный logout SDK.
    for (final transition in ['user', 'same-user session']) {
      test('same Client $transition transition rejects pending proof', () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final pending = Completer<List<String>>();
          final db = _OrderDb((_) => pending.future);
          final client = _IdentityClient(db);
          final room = faultRoom(client, '!identity');
          final subscription = UnseenProjectionSubscription(client);
          async.flushMicrotasks();
          expect(db.calls, 1);
          if (transition == 'user') {
            client.identity = '@other-account:test';
          } else {
            client.onLoginStateChanged.add(LoginState.loggedOut);
          }
          async.flushMicrotasks();
          pending.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(UnseenOrderCache.lookup(room), isNull);
          expect(room.hasUnseenMessages, isTrue);
          subscription.dispose();
          async.elapse(Duration.zero);
        });
      });
    }

    // AC:RL-edited-message-read-cursor/23 — budget у read, не dispatch очереди.
    test(
      'deferred transaction release still permits only eight actual starts',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final gate = Completer<void>();
          final databases = <_OrderDb>[];
          final clients = <Client>[];
          for (var i = 0; i < 10; i++) {
            final db = _OrderDb(
              (_) => Future.value([r'$receipt', r'$preview']),
              gate: i < 2 ? gate : null,
            );
            databases.add(db);
            final client = Client('deferred-$i', database: db);
            clients.add(client);
            unawaited(UnseenOrderCache.reconcileRoom(faultRoom(client, '!r')));
          }
          async.flushMicrotasks();
          expect(databases.fold(0, (sum, db) => sum + db.calls), 0);
          async.elapse(const Duration(milliseconds: 1));
          gate.complete();
          async.flushMicrotasks();
          expect(databases.fold(0, (sum, db) => sum + db.calls), 8);
          async.elapse(Duration.zero);
          async.flushMicrotasks();
          expect(databases.fold(0, (sum, db) => sum + db.calls), 10);
          for (final client in clients) {
            UnseenOrderCache.detach(client);
          }
        });
      },
    );

    // AC:RL-edited-message-read-cursor/24
    test('DB error is negative cached and predicates perform no IO', () {
      fakeAsync((async) {
        UnseenOrderCache.reset();
        final db = _OrderDb((_) => Future.error(StateError('DB unavailable')));
        final client = Client('error', database: db);
        final room = faultRoom(client, '!r');
        unawaited(UnseenOrderCache.reconcileRoom(room));
        async.flushMicrotasks();
        expect(UnseenOrderCache.lookup(room), isNull);
        for (var i = 0; i < 10; i++) {
          expect(room.hasUnseenMessages, room.hasNewMessages);
          unawaited(UnseenOrderCache.reconcileRoom(room));
        }
        async.flushMicrotasks();
        expect(db.calls, 1);
        async.elapse(Duration.zero);
        UnseenOrderCache.detach(client);
      });
    });

    test(
      'one batch notification and none for identical recomputed decision',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final db = _OrderDb((_) => Future.value([r'$receipt', r'$preview']));
          final client = Client('notify', database: db);
          for (var i = 0; i < 7; i++) {
            faultRoom(client, '!$i');
          }
          var notifications = 0;
          ConfirmedReadState.forClient(
            client,
          ).revision.addListener(() => notifications++);
          unawaited(UnseenOrderCache.reconcile(client));
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          expect(notifications, 1);
          UnseenOrderCache.committedRooms(
            client,
            client.rooms.map((r) => r.id),
          );
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          expect(notifications, 1);
          UnseenOrderCache.detach(client);
        });
      },
    );

    test('ten refreshes coalesce; unknown waits for committed change', () {
      fakeAsync((async) {
        UnseenOrderCache.reset();
        final result = Completer<List<String>>();
        final db = _OrderDb((_) => result.future);
        final client = Client('coalesce', database: db);
        final room = faultRoom(client, '!r');
        for (var i = 0; i < 10; i++) {
          unawaited(UnseenOrderCache.reconcileRoom(room));
        }
        async.flushMicrotasks();
        expect(db.calls, 1);
        result.complete([r'$preview']);
        async.flushMicrotasks();
        for (var i = 0; i < 10; i++) {
          unawaited(UnseenOrderCache.reconcileRoom(room));
          expect(room.hasUnseenMessages, isTrue);
        }
        async.elapse(const Duration(milliseconds: 1));
        expect(db.calls, 1);
        UnseenOrderCache.committedRooms(client, [room.id]);
        async.flushMicrotasks();
        expect(db.calls, 2);
        async.elapse(const Duration(milliseconds: 1));
        UnseenOrderCache.detach(client);
      });
    });

    // AC:RL-edited-message-read-cursor/23
    for (final count in [7, 8, 9]) {
      test('B=$count rooms yield after eight starts per event turn', () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final db = _OrderDb((_) => Future.value([r'$receipt', r'$preview']));
          final client = Client('batch', database: db);
          for (var i = 0; i < count; i++) {
            faultRoom(client, '!$i');
          }
          unawaited(UnseenOrderCache.reconcile(client));
          async.flushMicrotasks();
          expect(db.calls, count > 8 ? 8 : count);
          async.elapse(Duration.zero);
          async.flushMicrotasks();
          expect(db.calls, count);
          expect(client.rooms.every((r) => !r.hasUnseenMessages), isTrue);
          UnseenOrderCache.detach(client);
        });
      });
    }

    test(
      // AC:RL-edited-message-read-cursor/23
      // AC:RL-edited-message-read-cursor/25
      'global M2 holds through timeout; other client and positive badge proceed',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final hungA = Completer<List<String>>();
          final hungB = Completer<List<String>>();
          final a = _OrderDb((_) => hungA.future);
          final b = _OrderDb((_) => hungB.future);
          final c = _OrderDb((_) => Future.value([r'$receipt', r'$preview']));
          final ca = Client('a', database: a);
          final cb = Client('b', database: b);
          final cc = Client('c', database: c);
          final ra = faultRoom(ca, '!a');
          final rb = faultRoom(cb, '!b');
          final rc = faultRoom(cc, '!c');
          var returned = 0;
          var queuedReturned = false;
          UnseenOrderCache.reconcileRoom(ra).then((_) => returned++);
          UnseenOrderCache.reconcileRoom(rb).then((_) => returned++);
          UnseenOrderCache.reconcileRoom(rc).then((_) => queuedReturned = true);
          async.flushMicrotasks();
          expect([a.calls, b.calls, c.calls], [1, 1, 0]);
          async.elapse(const Duration(seconds: 3));
          expect(returned, 2);
          expect(
            queuedReturned,
            isTrue,
            reason: 'queued callers also have a deadline',
          );
          expect(c.calls, 0, reason: 'timeout cannot release physical slots');
          final positive = faultRoom(cc, '!positive', count: 1);
          unawaited(UnseenOrderCache.reconcileRoom(positive));
          async.flushMicrotasks();
          expect(c.calls, 1, reason: 'numeric badge does not wait for count0');
          expect(positive.hasUnseenMessages, isFalse);
          hungA.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(c.calls, 2);
          expect(rc.hasUnseenMessages, isFalse);
          expect(
            ra.hasUnseenMessages,
            isTrue,
            reason: 'expired read is not proof',
          );
          hungB.complete([]);
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          for (final client in [ca, cb, cc]) {
            UnseenOrderCache.detach(client);
          }
        });
      },
    );

    test(
      // AC:RL-edited-message-read-cursor/25
      'positive generation cannot duplicate a hung count0 physical read',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final first = Completer<List<String>>();
          final second = Completer<List<String>>();
          var reads = 0;
          final db = _OrderDb(
            (_) => ++reads == 1 ? first.future : second.future,
          );
          final client = Client('mixed', database: db);
          final room = faultRoom(client, '!r');
          unawaited(UnseenOrderCache.reconcileRoom(room));
          async.flushMicrotasks();
          room.notificationCount = 1;
          for (var i = 0; i < 10; i++) {
            UnseenOrderCache.committedRooms(client, [room.id]);
          }
          var badgeReturned = false;
          UnseenOrderCache.reconcile(client).then((_) => badgeReturned = true);
          async.flushMicrotasks();
          expect(badgeReturned, isTrue);
          expect(db.calls, 1);
          async.elapse(const Duration(seconds: 3));
          expect(db.calls, 1, reason: 'timeout preserves physical lock');
          first.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(db.calls, 2, reason: 'only latest dirty generation reruns');
          expect(UnseenOrderCache.lookup(room), isNull);
          second.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(room.hasUnseenMessages, isFalse);
          async.elapse(Duration.zero);
          UnseenOrderCache.detach(client);
        });
      },
    );

    // AC:RL-edited-message-read-cursor/23
    test(
      'queued count0 promotion cannot bypass two occupied physical slots',
      () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final pending = [
            Completer<List<String>>(),
            Completer<List<String>>(),
          ];
          final clients = <Client>[];
          for (var i = 0; i < 2; i++) {
            final client = Client(
              'occupied-$i',
              database: _OrderDb((_) => pending[i].future),
            );
            clients.add(client);
            unawaited(UnseenOrderCache.reconcileRoom(faultRoom(client, '!r')));
          }
          final db = _OrderDb((_) => Future.value([r'$receipt', r'$preview']));
          final third = Client('queued-positive', database: db);
          clients.add(third);
          final room = faultRoom(third, '!r');
          unawaited(UnseenOrderCache.reconcileRoom(room));
          async.flushMicrotasks();
          room.notificationCount = 1;
          var returned = false;
          UnseenOrderCache.reconcileRoom(room).then((_) => returned = true);
          async.flushMicrotasks();
          expect(returned, isTrue);
          expect(db.calls, 0);
          for (final read in pending) {
            read.complete([]);
          }
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          expect(db.calls, 1);
          for (final client in clients) {
            UnseenOrderCache.detach(client);
          }
        });
      },
    );

    // AC:RL-edited-message-read-cursor/21
    for (final change in [
      'receipt',
      'preview',
      'room',
      'generation',
      'detach',
    ]) {
      test('stale $change during await does not publish', () {
        fakeAsync((async) {
          UnseenOrderCache.reset();
          final result = Completer<List<String>>();
          final next = Completer<List<String>>();
          var reads = 0;
          final db = _OrderDb(
            (_) => ++reads == 1 ? result.future : next.future,
          );
          final client = Client('stale', database: db);
          final room = faultRoom(client, '!r');
          unawaited(UnseenOrderCache.reconcileRoom(room));
          async.flushMicrotasks();
          switch (change) {
            case 'receipt':
              room.roomAccountData[LatestReceiptState.eventType] = BasicEvent(
                type: LatestReceiptState.eventType,
                content: {
                  'global': {
                    'private': {'e': r'$new', 'ts': 1},
                    'latest': {'e': r'$new', 'ts': 1},
                  },
                },
              );
            case 'preview':
              room.lastEvent = Event(
                eventId: r'$new',
                senderId: '@other:test',
                type: EventTypes.Message,
                originServerTs: DateTime.now(),
                content: {'body': 'new'},
                room: room,
              );
            case 'room':
              client.rooms.clear();
              faultRoom(client, room.id);
            case 'generation':
              UnseenOrderCache.committedRooms(client, [room.id]);
            case 'detach':
              UnseenOrderCache.detach(client);
          }
          result.complete([r'$receipt', r'$preview']);
          async.flushMicrotasks();
          expect(UnseenOrderCache.lookup(room), isNull);
          UnseenOrderCache.detach(client);
          if (!next.isCompleted) next.complete([]);
          async.flushMicrotasks();
          async.elapse(Duration.zero);
          UnseenOrderCache.detach(client);
        });
      });
    }

    // AC:RL-edited-message-read-cursor/22
    test('same room and event IDs in two clients do not share proof', () {
      fakeAsync((async) {
        UnseenOrderCache.reset();
        final a = Client(
          'a',
          database: _OrderDb((_) => Future.value([r'$receipt', r'$preview'])),
        );
        final b = Client(
          'b',
          database: _OrderDb((_) => Future.value([r'$preview', r'$receipt'])),
        );
        final ra = faultRoom(a, '!same');
        final rb = faultRoom(b, '!same');
        unawaited(UnseenOrderCache.reconcileRoom(ra));
        unawaited(UnseenOrderCache.reconcileRoom(rb));
        async.flushMicrotasks();
        expect(ra.hasUnseenMessages, isFalse);
        expect(rb.hasUnseenMessages, isTrue);
        async.elapse(Duration.zero);
        UnseenOrderCache.detach(a);
        UnseenOrderCache.detach(b);
      });
    });
  });
}

class _ProjectionApi extends FakeMatrixApi {
  Map<String, dynamic>? response;
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (request.url.path.endsWith('/sync') && response != null) {
      return http.Response(jsonEncode(response), 200);
    }
    return super.mockIntercept(request);
  }
}

class _MatrixContext extends liza.MatrixState {
  final Client _client;
  _MatrixContext(this._client);
  @override
  Client get client => _client;
}

class _IdentityClient extends Client {
  String identity = '@first-account:test';
  _IdentityClient(DatabaseApi database) : super('identity', database: database);
  @override
  String get userID => identity;
}
