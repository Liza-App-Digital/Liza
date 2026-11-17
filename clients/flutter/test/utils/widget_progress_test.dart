import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/widget_progress.dart';

import 'test_client.dart';

// ledger:RL-telegram-widgets
// AC:RL-telegram-widgets/15
const _bot = '@assistant:example.invalid';
const _roomId = '!dm:example.invalid';

Event _member(Room room, String mxid) => Event(
  eventId: '\$m-$mxid',
  senderId: mxid,
  originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
  type: EventTypes.RoomMember,
  stateKey: mxid,
  content: {'membership': 'join'},
  room: room,
);

ToDeviceEvent _progress(Map<String, Object?> content, {String sender = _bot}) =>
    ToDeviceEvent(
      sender: sender,
      type: widgetProgressEventType,
      content: content,
    );

void main() {
  late Client client;
  late Room room;
  late WidgetProgressStore store;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    room = Room(id: _roomId, client: client);
    room.setState(_member(room, client.userID!));
    room.setState(_member(room, _bot));
    client.rooms.add(room);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        _bot: [_roomId],
      },
    );
    store = WidgetProgressStore.debug(client);
  });

  tearDown(() async {
    store.dispose();
    await client.dispose(closeDatabase: true);
  });

  test('прогресс от собеседника лички принимается, процент не убывает', () {
    expect(
      store.handle(
        _progress({'room_id': _roomId, 'stage': 'writing', 'percent': 40}),
      ),
      isTrue,
    );
    expect(store.forRoom(_roomId)!.percent, 40);
    expect(store.forRoom(_roomId)!.stage, 'writing');

    // Оценка может «просесть» на сервере; карточка не откатывается.
    store.handle(
      _progress({'room_id': _roomId, 'stage': 'writing', 'percent': 30}),
    );
    expect(store.forRoom(_roomId)!.percent, 40);
  });

  test('done/failed убирают прогресс', () {
    store.handle(
      _progress({'room_id': _roomId, 'stage': 'writing', 'percent': 10}),
    );
    expect(store.forRoom(_roomId), isNotNull);
    store.handle(
      _progress({'room_id': _roomId, 'stage': 'done', 'percent': 100}),
    );
    expect(store.forRoom(_roomId), isNull);

    store.handle(
      _progress({'room_id': _roomId, 'stage': 'writing', 'percent': 10}),
    );
    store.handle(_progress({'room_id': _roomId, 'stage': 'failed'}));
    expect(store.forRoom(_roomId), isNull);
  });

  test('чужой отправитель, чужая комната и мусор игнорируются', () {
    expect(
      store.handle(
        _progress({
          'room_id': _roomId,
          'stage': 'writing',
          'percent': 10,
        }, sender: '@stranger:example.invalid'),
      ),
      isFalse,
    );
    expect(
      store.handle(
        _progress({'room_id': '!other:example.invalid', 'stage': 'writing'}),
      ),
      isFalse,
    );
    expect(
      store.handle(_progress({'room_id': _roomId, 'stage': 'nonsense'})),
      isFalse,
    );
    expect(
      store.handle(_progress({'room_id': _roomId, 'stage': 'writing'})),
      isTrue,
    );
  });

  test('протухший прогресс не показывается', () {
    store.debugPut(
      WidgetGenerationProgress(
        roomId: _roomId,
        senderId: _bot,
        stage: 'writing',
        percent: 50,
        updatedAt: DateTime.now().subtract(
          widgetProgressTtl + const Duration(seconds: 1),
        ),
      ),
    );
    expect(store.forRoom(_roomId), isNull);
  });
}
