// ledger:RL-ghost-room-local-prune
//
// Чистка призраков на настоящем Client + FakeMatrixApi: комнату, которой
// сервер не знает, вкладываем в локальный стор через handleSync — то же
// состояние, что осталось у клиентов после отката сервера (заявка №55).
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/ghost_room_prune.dart';
import 'package:liza/utils/leave_room.dart';

import 'utils/test_client.dart';

const _ghost = '!ghost:fakeServer.notExisting';
final _ghostPath = '/client/v3/rooms/${Uri.encodeComponent(_ghost)}';

Future<Client> _clientWithGhost(FakeMatrixApi api) async {
  final client = await prepareTestClient(loggedIn: true, httpClient: api);
  while (client.prevBatch == null) {
    await client.onSync.stream.first;
  }
  await client.handleSync(
    SyncUpdate(
      nextBatch: '',
      rooms: RoomsUpdate(
        join: {
          _ghost: JoinedRoomUpdate(
            timeline: TimelineUpdate(
              events: [
                MatrixEvent(
                  type: EventTypes.Message,
                  content: {'msgtype': MessageTypes.Audio, 'body': 'voice'},
                  senderId: '@sasha:fakeServer.notExisting',
                  eventId: r'$lost',
                  originServerTs: DateTime.utc(2026, 10, 7, 16),
                ),
              ],
            ),
            unreadNotifications: UnreadNotificationCounts(notificationCount: 1),
          ),
        },
      ),
    ),
  );
  api.api['GET']!['/client/v3/joined_rooms'] = (_) => {
    'joined_rooms': [
      for (final r in client.rooms)
        if (r.id != _ghost) r.id,
    ],
  };
  return client;
}

const _me = '@test:fakeServer.notExisting';
final _probePath =
    '$_ghostPath/state/m.room.member/${Uri.encodeComponent(_me)}';

void _probeReturns(FakeMatrixApi api, Map<String, Object?> body) =>
    api.api['GET']![_probePath] = (_) => body;

void main() {
  late FakeMatrixApi api;
  late Client client;

  setUp(() async {
    api = FakeMatrixApi();
    client = await _clientWithGhost(api);
    expect(client.getRoomById(_ghost)?.notificationCount, 1);
  });

  tearDown(() => client.dispose(closeDatabase: true));

  // AC:RL-ghost-room-local-prune/10
  test(
    'призрак найден → один полный ресинк, призрак не возвращается',
    () async {
      _probeReturns(api, {'errcode': 'M_FORBIDDEN', 'error': 'not in room'});
      expect(await clientHasUnsentEvents(client), isFalse);
      var resyncs = 0;
      FakeMatrixApi.calledEndpoints.clear();

      await pruneGhostRooms(
        client,
        seenInSync: {},
        onResync: () => resyncs++,
        jitter: Duration.zero,
      );
      expect(resyncs, 1);
      expect(client.prevBatch, isNull, reason: 'since-токен сброшен');
      // FakeMatrixApi на незаписанные /sync отдаёт пустой ответ, поэтому
      // проверяем сам факт начальной синхронизации (без since) — на Synapse
      // она приносит всё, включая пропущенные приглашения.
      await client.onSync.stream.first.timeout(const Duration(seconds: 10));
      final syncs = FakeMatrixApi.calledEndpoints.keys.where(
        (k) => k.startsWith('/client/v3/sync'),
      );
      expect(syncs, isNotEmpty);
      expect(syncs.first, isNot(contains('since=')));
      expect(client.rooms.map((r) => r.id), isNot(contains(_ghost)));
      expect(
        FakeMatrixApi.calledEndpoints.keys,
        isNot(contains('$_ghostPath/leave')),
      );
    },
  );

  // AC:RL-ghost-room-local-prune/6
  test(
    'есть неотправленное → без ресинка, призрак удаляется точечно',
    () async {
      _probeReturns(api, {'errcode': 'M_FORBIDDEN', 'error': 'not in room'});
      final removed = <String>[];
      var resyncs = 0;

      await pruneGhostRooms(
        client,
        seenInSync: {},
        onRemoved: removed.add,
        onResync: () => resyncs++,
        hasUnsentEvents: (_) async => true,
        jitter: Duration.zero,
      );
      expect(resyncs, 0);
      expect(client.prevBatch, isNotNull);

      expect(client.rooms.map((r) => r.id), isNot(contains(_ghost)));
      expect(
        client.archivedRooms.map((a) => a.room.id),
        isNot(contains(_ghost)),
      );
      expect(removed, [_ghost]);
      expect(
        FakeMatrixApi.calledEndpoints.keys,
        isNot(contains('$_ghostPath/leave')),
      );
      expect(
        FakeMatrixApi.calledEndpoints.keys,
        isNot(contains('$_ghostPath/forget')),
      );
      final others = client.rooms.where((r) => r.membership == Membership.join);
      expect(others, isNotEmpty, reason: 'живые комнаты остались');
    },
  );

  // AC:RL-ghost-room-local-prune/11
  test(
    'упавшая отправка, после которой пришло чужое, — тоже «неотправленное»',
    () async {
      final room = client.getRoomById(_ghost)!;
      api.api['PUT']!['$_ghostPath/send/m.room.message'] = (_) => {
        'errcode': 'M_FORBIDDEN',
      };
      await room.sendTextEvent('не ушло').catchError((_) => null);
      await client.handleSync(
        SyncUpdate(
          nextBatch: '',
          rooms: RoomsUpdate(
            join: {
              _ghost: JoinedRoomUpdate(
                timeline: TimelineUpdate(
                  events: [
                    MatrixEvent(
                      type: EventTypes.Message,
                      content: {'msgtype': MessageTypes.Text, 'body': 'чужое'},
                      senderId: '@sasha:fakeServer.notExisting',
                      eventId: r'$after',
                      originServerTs: DateTime.now(),
                    ),
                  ],
                ),
              ),
            },
          ),
        ),
      );
      expect(room.lastEvent?.eventId, r'$after');
      expect(await clientHasUnsentEvents(client), isTrue);
    },
  );

  // AC:RL-ghost-room-local-prune/2
  test('пробник: мы в комнате (join) — жива, остаётся', () async {
    expect(client.userID, _me);
    _probeReturns(api, {'membership': 'join'});
    await pruneGhostRooms(client, seenInSync: {}, jitter: Duration.zero);
    expect(client.getRoomById(_ghost), isNotNull);
    expect(FakeMatrixApi.calledEndpoints.keys, contains(_probePath));
  });

  // AC:RL-ghost-room-local-prune/12
  for (final membership in ['leave', 'ban']) {
    test(
      'пробник 200, членство $membership — уход пропущен, удаляем',
      () async {
        _probeReturns(api, {'membership': membership});
        final removed = <String>[];
        await pruneGhostRooms(
          client,
          seenInSync: {},
          onRemoved: removed.add,
          hasUnsentEvents: (_) async => true,
          jitter: Duration.zero,
        );
        expect(removed, [_ghost]);
        expect(client.rooms.map((r) => r.id), isNot(contains(_ghost)));
      },
    );
  }

  // AC:RL-ghost-room-local-prune/2
  test('комната пришла в sync за сессию — даже пробник не зовём', () async {
    _probeReturns(api, {'errcode': 'M_FORBIDDEN'});
    FakeMatrixApi.calledEndpoints.clear();
    await pruneGhostRooms(client, seenInSync: {_ghost}, jitter: Duration.zero);
    expect(client.getRoomById(_ghost), isNotNull);
    expect(FakeMatrixApi.calledEndpoints.keys, isNot(contains(_probePath)));
  });

  // AC:RL-ghost-room-local-prune/3
  test('пробник 429 — не судим, остаётся', () async {
    _probeReturns(api, {'errcode': 'M_LIMIT_EXCEEDED'});
    await pruneGhostRooms(client, seenInSync: {}, jitter: Duration.zero);
    expect(client.getRoomById(_ghost), isNotNull);
  });

  // AC:RL-ghost-room-local-prune/3
  test('/joined_rooms ответил ошибкой — ничего не удаляем', () async {
    api.api['GET']!['/client/v3/joined_rooms'] = (_) => {
      'errcode': 'M_UNKNOWN',
    };
    _probeReturns(api, {'errcode': 'M_FORBIDDEN'});
    await pruneGhostRooms(client, seenInSync: {}, jitter: Duration.zero);
    expect(client.getRoomById(_ghost), isNotNull);
  });

  // AC:RL-ghost-room-local-prune/8
  test('«Покинуть» призрак: M_UNKNOWN — успех, комнаты нет', () async {
    api.api['POST']!['$_ghostPath/leave'] = (_) => {
      'errcode': 'M_UNKNOWN',
      'error': 'Not a known room',
    };
    await leaveRoomTolerant(client.getRoomById(_ghost)!);
    expect(client.rooms.map((r) => r.id), isNot(contains(_ghost)));
  });

  // AC:RL-ghost-room-local-prune/8
  test('«Покинуть»: прочие ошибки по-прежнему видны', () async {
    api.api['POST']!['$_ghostPath/leave'] = (_) => {
      'errcode': 'M_FORBIDDEN',
      'error': 'protected',
    };
    await expectLater(
      leaveRoomTolerant(client.getRoomById(_ghost)!),
      throwsA(isA<MatrixException>()),
    );
  });
}
