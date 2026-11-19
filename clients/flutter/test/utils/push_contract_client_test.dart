// ledger:RL-push-causal-contract
// guard.render:real-widget
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/app_badge.dart';
import 'package:liza/utils/push_contract.dart';
import 'package:liza/utils/push_contract_outbox.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/utils/push_contract_transport.dart';
import 'package:liza/widgets/matrix.dart' as app;
import 'package:liza/widgets/unread_rooms_badge.dart';

import 'test_client.dart';

const x = '!x:example.invalid', y = '!y:example.invalid';

class _SyncApi extends FakeMatrixApi {
  Map<String, Object?>? response;
  Completer<http.Response>? readAck;
  @override
  FutureOr<http.Response> mockIntercept(http.Request req) {
    if (readAck != null && req.url.path.endsWith('/read_markers')) {
      return readAck!.future;
    }
    if (response != null && req.url.path.endsWith('/sync')) {
      return http.Response(
        jsonEncode(response),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return super.mockIntercept(req);
  }
}

class _MatrixState extends app.MatrixState {
  _MatrixState(this.client);
  @override
  final Client client;
}

Map<String, Object?> _room(String tail, int count, String user) => {
  'timeline': {
    'events': [
      {
        'event_id': tail,
        'type': 'm.room.message',
        'origin_server_ts': 10,
        'sender': '@other:example.invalid',
        'content': {'msgtype': 'm.text', 'body': 'fixture'},
      },
    ],
  },
  'unread_notifications': {'notification_count': count, 'highlight_count': 0},
  'ephemeral': {
    'events': [
      {
        'type': 'm.receipt',
        'content': {
          r'$previous': {
            'm.read.private': {
              user: {'ts': 1},
            },
          },
        },
      },
    ],
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('реальный /sync SDK, transaction и кадр', () {
    late Client client;
    late _SyncApi api;
    late PushContractSession session;
    var active = true;
    Future<void> sync(
      String batch,
      String tail, {
      bool withSpace = false,
    }) async {
      api.response = {
        'next_batch': batch,
        'rooms': {
          'join': {
            x: _room(tail, 3, client.userID!),
            y: _room(r'$y', 1, client.userID!),
            if (withSpace)
              '!space:example.invalid': {
                'state': {
                  'events': [
                    {
                      'type': 'm.room.create',
                      'state_key': '',
                      'event_id': r'$space-create',
                      'sender': client.userID,
                      'origin_server_ts': 9,
                      'content': {'type': 'm.space'},
                    },
                    {
                      'type': 'm.space.child',
                      'state_key': x,
                      'event_id': r'$space-child',
                      'sender': client.userID,
                      'origin_server_ts': 10,
                      'content': {
                        'via': ['example.invalid'],
                      },
                    },
                  ],
                },
              },
          },
        },
      };
      final finished = client.onSyncStatus.stream.firstWhere(
        (e) => e.status == SyncStatus.finished,
      );
      await client.oneShotSync(timeout: Duration.zero);
      await finished.timeout(const Duration(seconds: 5));
    }

    setUp(() async {
      active = true;
      api = _SyncApi();
      client = await prepareTestClient(loggedIn: true, httpClient: api);
      client.backgroundSync = false;
      await client.abortSync();
      session = PushContractSession(
        client,
        changed: () {},
        isActiveAccount: () => active,
        isPrimaryAccount: () => true,
        lifecycle: () => 'resumed',
        leased: () => true,
      )..enabled = true;
    });
    tearDown(() async {
      session.dispose();
      await client.dispose(closeDatabase: true);
    });
    test(
      'onSync до finished ещё не heartbeat; history и ручной handleSync не создают commit',
      () async {
        await client.handleSync(SyncUpdate(nextBatch: ''));
        await client.handleSync(SyncUpdate(nextBatch: 'synthetic'));
        await Future<void>.delayed(Duration.zero);
        expect(session.syncSequence, 0);
        expect(session.capture('macos', '12', 0, 0), isNull);
        int? onWire;
        final sub = client.onSync.stream.listen(
          (_) => onWire = session.syncSequence,
        );
        await sync('live-e2', r'$e2');
        await sub.cancel();
        expect(onWire, 0); // AC:RL-push-causal-contract/3
        expect(client.prevBatch, 'live-e2');
        expect(session.syncSequence, 1);
        final batch = session.capture('macos', '12', 0, 0)!.envelope.json;
        final room = (batch['rooms'] as List).singleWhere(
          (v) => v['room_id'] == x,
        );
        expect(room['tail_event_id'], r'$e2');
        expect(room['wire_notification_count'], 3);
        expect(room['own_private_event_id'], r'$previous');
        expect(room['row'], isNull);
        expect(batch['read_targets'], isEmpty);
      },
    );
    test(
      'первый live tail сохраняется до GET status, затем receipt-only commit сохраняет доказательство',
      () async {
        session.dispose();
        session = PushContractSession(
          client,
          changed: () {},
          isActiveAccount: () => true,
          isPrimaryAccount: () => true,
          lifecycle: () => 'resumed',
          leased: () => true,
        );
        await sync('startup-wire', r'$e2');
        expect(session.capture('macos', '12', 0, 0), isNull);
        session.enabled = true;
        api.response = {
          'next_batch': 'receipt-only',
          'rooms': {
            'join': {
              x: {
                'unread_notifications': {
                  'notification_count': 0,
                  'highlight_count': 0,
                },
                'ephemeral': {
                  'events': [
                    {
                      'type': 'm.receipt',
                      'content': {
                        r'$e2': {
                          'm.read.private': {
                            client.userID: {'ts': 2},
                          },
                        },
                      },
                    },
                  ],
                },
              },
            },
          },
        };
        final finished = client.onSyncStatus.stream.firstWhere(
          (e) => e.status == SyncStatus.finished,
        );
        await client.oneShotSync(timeout: Duration.zero);
        await finished;
        final r =
            (session.capture('macos', '12', 0, 0)!.envelope.json['rooms']
                    as List)
                .singleWhere((r) => r['room_id'] == x);
        expect(r['tail_event_id'], r'$e2');
        expect(r['receipt_event_id'], r'$e2');
        expect(r['limited'], false);
      },
    );
    test('при переводе часов назад возраст commit продолжает расти', () async {
      session.dispose();
      var wall = 100000;
      session = PushContractSession(
        client,
        changed: () {},
        isActiveAccount: () => true,
        isPrimaryAccount: () => true,
        lifecycle: () => 'resumed',
        leased: () => true,
        clock: () => wall,
      )..enabled = true;
      await sync('time', r'$e2');
      wall -= 90000;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final e = session.capture('macos', '12', 0, 0)!.envelope;
      expect(e.json['captured_age_ms'], greaterThanOrEqualTo(100));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        e.ageMs(wall - 5000),
        greaterThanOrEqualTo((e.json['captured_age_ms'] as int) + 100),
      );
    });
    test(
      'настоящий HTTP read, начатый в processing, публикуется после matching finished и ACK',
      () async {
        await sync('before-incoming', r'$e1');
        api.readAck = Completer<http.Response>();
        final sent = Completer<void>(), done = Completer<void>();
        final sub = client.onTimelineEvent.stream.listen((event) async {
          if (event.eventId != r'$incoming' || sent.isCompleted) return;
          try {
            expect(client.onSyncStatus.value?.status, SyncStatus.processing);
            final proof = session.readProof(event.room, rawTail: event.eventId);
            expect(proof, isNotNull);
            final sending = event.room.setReadMarker(
              event.eventId,
              mRead: event.eventId,
              public: false,
            );
            sent.complete();
            await sending;
            session.afterReadAck(
              event.room,
              event.eventId,
              null,
              true,
              proof,
              rawTail: event.eventId,
            );
            done.complete();
          } catch (e, stack) {
            if (!sent.isCompleted) sent.complete();
            done.completeError(e, stack);
          }
        });
        addTearDown(sub.cancel);
        await sync('incoming', r'$incoming');
        await sent.future.timeout(const Duration(seconds: 2));
        expect(
          session.capture('macos', '12', 0, 0)!.envelope.json['read_targets'],
          isEmpty,
        );
        api.readAck!.complete(
          http.Response(
            '{}',
            200,
            headers: {'content-type': 'application/json'},
          ),
        );
        await done.future.timeout(const Duration(seconds: 2));
        final targets =
            session.capture('macos', '12', 0, 0)!.envelope.json['read_targets']
                as List;
        expect(targets.single['event_id'], r'$incoming');
      },
    );
    test(
      'manual unread и gap меняют отпечаток намерения до подтверждения',
      () async {
        await sync('manual', r'$e2');
        final room = client.getRoomById(x)!;
        final proof = session.readProof(room, rawTail: r'$e2');
        expect(proof, isNotNull);
        room.roomAccountData['m.marked_unread'] = BasicEvent(
          type: 'm.marked_unread',
          content: {'unread': true},
        );
        session.afterReadAck(room, r'$e2', null, true, proof, rawTail: r'$e2');
        room.roomAccountData.remove('m.marked_unread');
        session.afterReadAck(
          room,
          r'$e2',
          null,
          true,
          proof,
          rawTail: r'$e2',
          hasGap: true,
        );
        expect(
          session.capture('macos', '12', 0, 0)!.envelope.json['read_targets'],
          isEmpty,
        );
      },
    );
    test(
      'e3, switch или dispose в полёте отвергают предыдущий challenge и read ACK',
      () async {
        await sync('first', r'$e2');
        final e = session.capture('macos', '12', 0, 0)!.envelope;
        final room = client.getRoomById(x)!;
        final before = session.readProof(room);
        final ack = {
          'schema': 1,
          'accepted': true,
          'batch_id': e.id,
          'results': [
            {'room_id': x, 'status': 'pending', 'challenge': '1' * 32},
          ],
        };
        expect(session.acknowledge(e, {...ack, 'batch_id': 'wrong'}), isFalse);
        expect(session.acknowledge(e, ack), isTrue);
        final challenged = session.capture('macos', '12', 0, 0)!.envelope;
        expect(
          (challenged.json['rooms'] as List).singleWhere(
            (r) => r['room_id'] == x,
          )['challenge'],
          '1' * 32,
        );
        await sync('second', r'$e3');
        session.afterReadAck(room, r'$e2', null, true, before);
        expect(
          session.acknowledge(challenged, {...ack, 'batch_id': challenged.id}),
          true,
        ); // ingestion ACK, challenge устарел
        final batch = session.capture('macos', '12', 0, 0)!.envelope;
        expect(batch.json['read_targets'], isEmpty);
        expect(
          (batch.json['rooms'] as List).every((r) => r['challenge'] == null),
          isTrue,
        ); // AC:RL-push-causal-contract/5
        expect(room.notificationCount, 3);
        active = false;
        expect(session.unchanged(batch), false);
        active = true;
        session.dispose();
        expect(session.unchanged(batch), false);
      },
    );
    testWidgets('row X=3, row Y=1 и nav=2, снятая row не превращается в zero', (
      tester,
    ) async {
      await tester.runAsync(() => sync('live-ui', r'$e2'));
      final rx = client.getRoomById(x)!, ry = client.getRoomById(y)!;
      final shell = Provider<app.MatrixState>.value(
        value: _MatrixState(client),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                UnreadBubble(room: rx),
                UnreadBubble(room: ry, surface: 'compact'),
                UnreadRoomsBadge(filter: (r) => r.id == x || r.id == y),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(shell);
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      final e = session.capture('macos', '12', 0, 0)!.envelope;
      final rows = e.json['rooms'] as List;
      expect(
        rows.singleWhere((r) => r['room_id'] == x)['row']['notification_count'],
        3,
      ); // AC:RL-push-causal-contract/1
      expect(
        rows.singleWhere((r) => r['room_id'] == y)['row']['surface_id'],
        'compact',
      );
      expect((e.json['nav'] as List).single['observed'], 2);
      await tester.pumpWidget(const SizedBox());
      final next = session.capture('macos', '12', 0, 0)!.envelope;
      expect((next.json['rooms'] as List).every((r) => r['row'] == null), true);
      expect(next.json['nav'], isEmpty);
      expect(session.unchanged(e), false);
    });
    testWidgets(
      'выключение cohort отзывает уже запланированный post-frame callback',
      (tester) async {
        await tester.runAsync(() => sync('off-frame', r'$e2'));
        tester.binding.addPostFrameCallback((_) {
          session.enabled = false;
        });
        await tester.pumpWidget(
          Provider<app.MatrixState>.value(
            value: _MatrixState(client),
            child: MaterialApp(
              home: UnreadRoomsBadge(scope: 'all', filter: (_) => true),
            ),
          ),
        );
        expect(session.frames, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
    test(
      'status 503 затем 200 сохраняет настоящий предшествующий raw tail',
      () async {
        session.dispose();
        SharedPreferences.setMockInitialValues({});
        var now = 90000000, status = 503;
        var statusBody = '{}';
        final scheduler = PushContractScheduler(
          clients: () => [client],
          active: () => client,
          lifecycle: () => 'resumed',
          clock: () => now,
          queue: PushContractOutbox(),
          build: () async => '12',
          endpoint: (_) => Uri.parse('https://local.example/'),
          network: PushContractTransport(
            open: () => MockClient((r) async {
              if (r.method == 'GET') {
                return http.Response(statusBody, status);
              }
              return http.Response('', 503);
            }),
          ),
        );
        addTearDown(scheduler.dispose);
        scheduler.attach(client);
        session = PushContractSession.observing(client)!;
        await sync('before-transient', r'$e2');
        now += 2000;
        await scheduler.runDue();
        expect(session.enabled, false);
        status = 200;
        now += 60001;
        await scheduler.runDue();
        expect(session.enabled, false);
        statusBody = '{"contract":true}';
        now += 60001;
        await scheduler.runDue();
        expect(session.enabled, true);
        final packet = session.capture('macos', '12', 0, 0)?.envelope.json;
        expect(packet, isNotNull);
        expect(
          (packet!['rooms'] as List).singleWhere(
            (r) => r['room_id'] == x,
          )['tail_event_id'],
          r'$e2',
        );
      },
    );
    testWidgets(
      'Offstage снимает наблюдение; тот же Element после didUpdateWidget сообщает только новую Room',
      (tester) async {
        await tester.runAsync(() => sync('scope-widget', r'$e2'));
        final rx = client.getRoomById(x)!, ry = client.getRoomById(y)!;
        Widget shell(Room room, bool offstage) => MaterialApp(
          home: Scaffold(
            body: Offstage(
              offstage: offstage,
              child: UnreadBubble(key: const ValueKey('one-row'), room: room),
            ),
          ),
        );
        Map? row(String id) {
          final data = session.capture('macos', '12', 0, 0)!.envelope.json;
          return (data['rooms'] as List).singleWhere(
                (r) => r['room_id'] == id,
              )['row']
              as Map?;
        }

        await tester.pumpWidget(shell(rx, false));
        expect(row(x)?['notification_count'], 3);
        await tester.pumpWidget(shell(rx, true));
        expect(row(x), isNull);
        await tester.pumpWidget(shell(ry, false));
        expect(row(x), isNull);
        expect(row(y)?['notification_count'], 1);
        await tester.pumpWidget(const SizedBox());
        expect(row(y), isNull);
      },
    );
    testWidgets(
      'полный wire из реального SDK, четырёх nav scope и записи badge API',
      (tester) async {
        client.rooms.clear();
        await tester.runAsync(
          () => sync('fixture-batch', r'$e2', withSpace: true),
        );
        final space = client.getRoomById('!space:example.invalid')!;
        final children = space.spaceChildren.map((c) => c.roomId).toSet();
        expect(children, contains(x));
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const badger = MethodChannel('flutter_new_badger');
        const apns = MethodChannel('com.prodamus.laba.liza/apns');
        final writes = <MethodCall>[];
        messenger.setMockMethodCallHandler(badger, (m) async {
          writes.add(m);
          return true;
        });
        messenger.setMockMethodCallHandler(apns, (_) async => true);
        AppBadge.bindPrimary(session, () => client);
        AppBadge.resetDenied();
        addTearDown(() {
          AppBadge.unbindPrimary(session);
          messenger.setMockMethodCallHandler(badger, null);
          messenger.setMockMethodCallHandler(apns, null);
        });
        await tester.runAsync(() => AppBadge.refreshFrom(client));
        expect(writes.map((m) => m.method), contains('setBadge'));
        await tester.pumpWidget(
          Provider<app.MatrixState>.value(
            value: _MatrixState(client),
            child: MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    UnreadBubble(room: client.getRoomById(x)!),
                    UnreadBubble(
                      room: client.getRoomById(y)!,
                      surface: 'compact',
                    ),
                    UnreadRoomsBadge(scope: 'all', filter: (_) => true),
                    UnreadRoomsBadge(
                      scope: 'space',
                      scopeRoomId: space.id,
                      filter: (r) => children.contains(r.id),
                    ),
                    UnreadRoomsBadge(
                      scope: 'except_current',
                      scopeRoomId: x,
                      filter: (r) => r.id != x,
                    ),
                    UnreadRoomsBadge(filter: (r) => r.id == x || r.id == y),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final envelope = session.capture('macos', '12', 0, 0)!.envelope;
        final nav = envelope.json['nav'] as List;
        expect(nav.map((n) => n['scope']).toSet(), {
          'all',
          'space',
          'except_current',
          'filtered',
        });
        expect(nav.map((n) => n['scope_id']).toSet(), hasLength(4));
        expect(nav.singleWhere((n) => n['scope'] == 'space')['expected'], 1);
        expect(envelope.json['badge']['observed'], 2);
        expect(envelope.body, isNot(contains(client.accessToken!)));
        const output = String.fromEnvironment('LIZA_CONTRACT_FIXTURE_OUTPUT');
        if (output.isNotEmpty) {
          await tester.runAsync(
            () => File(output).writeAsString(envelope.body),
          );
        }
        final fixture =
            jsonDecode(
                  File(
                    '../../tests/fixtures/push_contract_client_v1.json',
                  ).readAsStringSync(),
                )
                as Map;
        Map stable(Map p) => Map.of(p)
          ..remove('batch_id')
          ..remove('session_id')
          ..remove('captured_age_ms');
        expect(
          stable(envelope.json),
          stable(fixture),
          reason: 'Producer и server validation используют один эталон wire.',
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
    for (final outcome in ['same', 'new', 'new-error']) {
      test(
        'зависший setBadge отпускает writer и не перезаписывает новую привязку ($outcome)',
        () async {
          client.rooms.clear();
          await sync('badge-timeout', r'$e2');
          final rx = client.getRoomById(x)!;
          final nextClient = outcome == 'same'
              ? client
              : await prepareTestClient(
                  loggedIn: true,
                  clientName: 'Next owner',
                );
          if (!identical(nextClient, client)) {
            nextClient.backgroundSync = false;
            await nextClient.abortSync();
            await nextClient.oneShotSync(timeout: Duration.zero);
            nextClient.rooms
              ..clear()
              ..add(
                Room(
                  id: '!next:example.invalid',
                  client: nextClient,
                  membership: Membership.invite,
                ),
              );
            addTearDown(() => nextClient.dispose(closeDatabase: true));
          }
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          const apns = MethodChannel('com.prodamus.laba.liza/apns'),
              badger = MethodChannel('flutter_new_badger');
          final first = Completer<void>(),
              started = Completer<void>(),
              repaired = Completer<void>();
          var count = 0, calls = 0;
          messenger.setMockMethodCallHandler(apns, (_) async => true);
          messenger.setMockMethodCallHandler(badger, (m) async {
            final requested = (m.arguments as Map)['count'] as int;
            calls++;
            if (calls == 1) {
              started.complete();
              await first.future;
              if (outcome == 'new-error') {
                throw PlatformException(code: 'PERMISSION_DENIED');
              }
            }
            count = requested;
            if (calls >= 3 && requested == 1 && !repaired.isCompleted) {
              repaired.complete();
            }
            return null;
          });
          AppBadge.resetDenied();
          AppBadge.bindPrimary(session, () => client);
          addTearDown(() {
            AppBadge.unbindPrimary(session);
            AppBadge.unbindPrimary(nextClient);
            messenger.setMockMethodCallHandler(badger, null);
            messenger.setMockMethodCallHandler(apns, null);
          });
          final before = AppBadge.writeSeq;
          final old = AppBadge.trySetPrimary(
            2,
            owner: client,
            primary: () => client,
          );
          await started.future.timeout(const Duration(seconds: 1));
          if (outcome == 'same') {
            client.rooms.remove(rx);
          } else {
            AppBadge.bindPrimary(nextClient, () => nextClient);
          }
          final next = AppBadge.trySetPrimary(
            1,
            owner: nextClient,
            primary: () => nextClient,
          );
          if (outcome == 'new-error') {
            // Ошибка прежней эпохи пришла после успеха новой, но до своего
            // timeout. Проверяем именно owner fence, а не только timeout.
            await next.timeout(const Duration(seconds: 1));
            first.complete();
          }
          await Future.wait([old, next]).timeout(const Duration(seconds: 4));
          expect(count, 1);
          expect(AppBadge.writeSeq, before + 1);
          if (!first.isCompleted) first.complete();
          if (outcome == 'new-error') {
            await Future<void>.delayed(Duration.zero);
            expect(AppBadge.isDenied, isFalse);
            expect(AppBadge.writeSeq, before + 1);
          } else {
            await repaired.future.timeout(const Duration(seconds: 1));
          }
          expect(count, 1);
        },
      );
    }
    test(
      'вторичный аккаунт не пишет число на иконку; primary с неизвестным состоянием пропускается',
      () async {
        final other = await prepareTestClient(
          loggedIn: true,
          clientName: 'Second',
        );
        other.backgroundSync = false;
        await other.abortSync();
        final fresh = await prepareTestClient(clientName: 'fresh');
        addTearDown(() => other.dispose(closeDatabase: true));
        addTearDown(() => fresh.dispose(closeDatabase: true));
        final saved = <Map>[];
        const channel = MethodChannel('com.prodamus.laba.liza/apns');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (m) async {
          if (m.method == 'saveBadgeCount') saved.add(m.arguments as Map);
          return true;
        });
        messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_new_badger'),
          (m) async => true,
        );
        addTearDown(() {
          messenger.setMockMethodCallHandler(channel, null);
          messenger.setMockMethodCallHandler(
            const MethodChannel('flutter_new_badger'),
            null,
          );
        });
        var primary = client;
        AppBadge.bindPrimary(thisTest, () => primary);
        addTearDown(() => AppBadge.unbindPrimary(thisTest));
        await sync('primary', r'$e2');
        await AppBadge.refreshFrom(other);
        expect(saved, isEmpty);
        await AppBadge.refreshFrom(client);
        expect(
          saved.single['count'],
          AppBadge.visibleUnreadCount(client),
        ); // AC:RL-push-causal-contract/1
        primary = fresh;
        await AppBadge.refreshFrom(fresh);
        expect(saved, hasLength(1));
      },
    );
  });

  test(
    'foreground init до mount сохраняет реальный raw tail и ждёт следующего commit для lease',
    () async {
      final api = _SyncApi();
      final c = await prepareTestClient(
        httpClient: api,
        homeserver: Uri.parse('https://hello.liza.ru'),
      );
      c.backgroundSync = false;
      addTearDown(() => c.dispose(closeDatabase: true));
      final startupErrors = <Object>[];
      runZonedGuarded(
        () => PushContractScheduler.beforeForegroundInit(c),
        (e, _) => startupErrors.add(e),
      );
      c.onLoginStateChanged.addError(StateError('fixture recoverable init'));
      await Future<void>.delayed(Duration.zero);
      expect(startupErrors, isEmpty);
      api.response = {
        'next_batch': 'startup',
        'rooms': {
          'join': {x: _room(r'$startup', 2, '@test:fakeServer.notExisting')},
        },
      };
      await c.login(
        LoginType.mLoginToken,
        identifier: AuthenticationUserIdentifier(
          user: '@test:fakeServer.notExisting',
        ),
        password: 'fixture',
      );
      await c.firstSyncReceived;
      await Future<void>.delayed(Duration.zero);
      final s = PushContractSession.bind(
        c,
        changed: () {},
        isActiveAccount: () => true,
        isPrimaryAccount: () => true,
        lifecycle: () => 'resumed',
        leased: () => true,
        clock: () => DateTime.now().millisecondsSinceEpoch,
      )..enabled = true;
      addTearDown(s.dispose);
      expect(s.syncSequence, greaterThan(0));
      expect(s.capture('macos', '12', 0, 0), isNull);
      api.response = {
        'next_batch': 'post-mount',
        'rooms': {
          'join': {
            x: {
              'unread_notifications': {
                'notification_count': 2,
                'highlight_count': 0,
              },
            },
          },
        },
      };
      final finished = c.onSyncStatus.stream.firstWhere(
        (e) => e.status == SyncStatus.finished,
      );
      await c.oneShotSync(timeout: Duration.zero);
      await finished;
      final room =
          (s.capture('macos', '12', 0, 0)!.envelope.json['rooms'] as List)
              .singleWhere((r) => r['room_id'] == x);
      expect(room['tail_event_id'], r'$startup');
    },
  );
  test(
    'очередь переживает рестарт, разделяет issuer/device, TTL и обе границы',
    () async {
      SharedPreferences.setMockInitialValues({});
      final queue = PushContractOutbox();
      ContractEnvelope item(int n, int at, int size) => ContractEnvelope(
        'https://a',
        at,
        'proof',
        jsonEncode({
          'batch_id': '$n',
          'user_id': '@a:b',
          'device_id': 'A',
          'pad': 'x' * size,
        }),
      );
      for (var i = 0; i < 33; i++) {
        await queue.add(item(i, 10, 20), 10);
      }
      final first = await PushContractOutbox().first(
        'https://a',
        '@a:b',
        'A',
        10,
      );
      expect(first!.id, '1');
      expect(queue.dropped, 1); // AC:RL-push-causal-contract/8
      expect(await queue.first('https://b', '@a:b', 'A', 10), isNull);
      expect(await queue.first('https://a', '@a:b', 'B', 10), isNull);
      for (var i = 33; i < 53; i++) {
        await queue.add(item(i, 10, 20000), 10);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(
        utf8.encode(prefs.getString(PushContractOutbox.key)!).length,
        lessThanOrEqualTo(256 * 1024),
      );
      expect(
        (jsonDecode(prefs.getString(PushContractOutbox.key)!)['items'] as List)
            .length,
        lessThan(20),
      );
      expect(
        await queue.first(
          'https://a',
          '@a:b',
          'A',
          10 + PushContractOutbox.ttlMs,
        ),
        isNull,
      );
    },
  );
  test(
    'транспорт выбирает только точный доверенный issuer и запрещает redirect',
    () async {
      expect(
        PushContractEndpoint.forIssuer(Uri.parse('https://hello.liza.ru')),
        isNotNull,
      );
      for (final url in [
        'https://hello.liza.ru.evil.test',
        'https://hello.liza.ru:444',
        'http://hello.liza.ru',
        'https://junk@hello.liza.ru',
        'https://hello.liza.ru/?q=1',
      ]) {
        expect(PushContractEndpoint.forIssuer(Uri.parse(url)), isNull);
      }
      var calls = 0;
      final net = PushContractTransport(
        open: () => MockClient((req) async {
          calls++;
          expect(req.followRedirects, false);
          expect(req.headers['Authorization'], 'Bearer sample');
          return http.Response(
            '',
            307,
            headers: {'location': 'https://untrusted.test'},
          );
        }),
      );
      final response = await net.request(
        Uri.parse('https://bot.example.test/contract'),
        token: 'sample',
        issuer: 'https://a',
        body: '{}',
      );
      expect(response.status, 307);
      expect(calls, 1); // AC:RL-push-causal-contract/2
    },
  );
}

final thisTest = Object();
