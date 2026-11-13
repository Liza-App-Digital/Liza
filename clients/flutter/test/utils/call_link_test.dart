// ledger:RL-call-link-server-source
//
// «Ссылка на созвон» берётся у сервера, а не только из локального кеша:
// потерянная локально запись не должна прятать трубку при живом событии.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/call_link.dart';

import 'test_client.dart';

const _roomId = '!cl:fakeServer.notExisting';
final _path =
    '/client/v3/rooms/!cl%3AfakeServer.notExisting/state/io.element.call_link';

Future<(Client, Room, FakeMatrixApi)> _setup({String? localUrl}) async {
  final api = FakeMatrixApi();
  final client = await prepareTestClient(loggedIn: true, httpClient: api);
  while (client.prevBatch == null) {
    await client.onSync.stream.first;
  }
  await client.handleSync(
    SyncUpdate(
      nextBatch: 'n',
      rooms: RoomsUpdate(
        join: {
          _roomId: JoinedRoomUpdate(
            state: [
              if (localUrl != null)
                MatrixEvent(
                  type: CallLink.eventType,
                  stateKey: '',
                  content: {'url': localUrl},
                  senderId: '@a:fakeServer.notExisting',
                  eventId: r'$cl',
                  originServerTs: DateTime.utc(2026, 9, 1),
                ),
            ],
          ),
        },
      ),
    ),
  );
  final room = client.getRoomById(_roomId)!;
  await room.postLoad();
  return (client, room, api);
}

void main() {
  // AC:RL-call-link-server-source/1
  test('локально пусто, на сервере ссылка — подтягивается', () async {
    final (_, room, api) = await _setup();
    expect(CallLink.urlOf(room), isNull);
    api.api['GET']![_path] = (_) => {'url': 'https://telemost.yandex.ru/j/1'};
    expect(await CallLink.sync(room, force: true), isTrue);
    expect(CallLink.urlOf(room), 'https://telemost.yandex.ru/j/1');
  });

  // AC:RL-call-link-server-source/2
  test('на сервере ссылки нет (M_NOT_FOUND) — локальная снимается', () async {
    final (_, room, api) = await _setup(localUrl: 'https://old.example/j/1');
    expect(CallLink.urlOf(room), isNotNull);
    api.api['GET']![_path] = (_) => {
      'errcode': 'M_NOT_FOUND',
      'error': 'Event not found.',
    };
    expect(await CallLink.sync(room, force: true), isTrue);
    expect(CallLink.urlOf(room), isNull);
  });

  // AC:RL-call-link-server-source/3
  test('сбой сервера не затирает показанную ссылку', () async {
    final (_, room, api) = await _setup(localUrl: 'https://keep.example/j/1');
    api.api['GET']![_path] = (_) => {'errcode': 'M_UNKNOWN', 'error': 'boom'};
    expect(await CallLink.sync(room, force: true), isFalse);
    expect(CallLink.urlOf(room), 'https://keep.example/j/1');
  });

  // AC:RL-call-link-server-source/4
  test('совпадает с сервером — перерисовка не нужна', () async {
    final (_, room, api) = await _setup(localUrl: 'https://same.example/j/1');
    api.api['GET']![_path] = (_) => {'url': 'https://same.example/j/1'};
    expect(await CallLink.sync(room, force: true), isFalse);
  });

  // AC:RL-call-link-server-source/5
  // Окончательный отказ сервера (комната в превью/инвайте) — без повторного
  // запроса на каждое открытие чата до истечения TTL.
  test('M_FORBIDDEN запоминается до TTL', () async {
    CallLink.resetChecksForTest();
    final (_, room, api) = await _setup(localUrl: 'https://keep.example/j/2');
    var calls = 0;
    api.api['GET']![_path] = (_) {
      calls++;
      return {'errcode': 'M_FORBIDDEN', 'error': 'no'};
    };
    expect(await CallLink.sync(room, force: true), isFalse);
    expect(await CallLink.sync(room), isFalse);
    expect(calls, 1);
    expect(CallLink.urlOf(room), 'https://keep.example/j/2');
  });
}
