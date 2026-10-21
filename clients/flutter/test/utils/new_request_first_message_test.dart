// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/6 AC:RL-empty-panel-new-request/7
//
// Первый вопрос из пустой правой панели (задача 14): уходит в чат-запрос
// ПОСЛЕ приветствия Лизы, а не над ним. Живой Client + FakeMatrixApi, отправку
// видим по реальному PUT …/send/m.room.message.
//
// Red-proof:
//   RP-1 (AC-6): убрать `await waitForLizaGreeting` в sendFirstRequestMessage →
//     PUT уходит до события Лизы, «до приветствия — не шлём» красный.
//   RP-2 (AC-6): фильтр `e.senderId == lizaMxid` убрать → своё эхо засчитается
//     приветствием, «чужое событие не приветствие» красный.
//   RP-3 (AC-7): слать и при `lizaJoined == false` → PUT есть, черновика нет.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/liza_dm.dart';
import 'test_client.dart';

const _liza = '@liza:bots.liza.ru';
// Комната, на PUT /send которой FakeMatrixApi отвечает event_id.
const _roomId = '!1234:fakeServer.notExisting';

void main() {
  late Client client;
  late Room room;
  late SharedPreferences store;

  Iterable<String> sends() => FakeMatrixApi.calledEndpoints.keys.where(
    (k) => k.contains('/send/m.room.message/'),
  );

  Event fromSender(String sender, {String type = EventTypes.Message}) => Event(
    type: type,
    content: {'msgtype': 'm.text', 'body': 'Какую задачу решим сегодня?'},
    eventId: '\$${sender.hashCode}',
    senderId: sender,
    originServerTs: DateTime.now(),
    room: room,
  );

  Future<void> waitForSend() async {
    for (var i = 0; i < 100 && sends().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    FakeMatrixApi.client = client;
    FakeMatrixApi.calledEndpoints.clear();
    room = Room(id: _roomId, client: client, membership: Membership.join);
    client.rooms.add(room);
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
  });

  tearDown(() => client.dispose(closeDatabase: true));

  group('AC-6: вопрос уходит после приветствия Лизы', () {
    test('до приветствия — не шлём; пришло — шлём', () async {
      var done = false;
      final sending = sendFirstRequestMessage(
        client,
        store,
        _roomId,
        _liza,
        'сгенерируй 5 идей постов',
        lizaJoined: true,
      ).then((_) => done = true);

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(done, isFalse);
      expect(sends(), isEmpty);

      client.onTimelineEvent.add(fromSender(_liza));
      await sending;
      await waitForSend();
      expect(sends(), hasLength(1));
      expect(store.getString('draft_$_roomId'), isNull);
    });

    test('зашифрованное приветствие тоже считается', () async {
      final sending = sendFirstRequestMessage(
        client,
        store,
        _roomId,
        _liza,
        'вопрос',
        lizaJoined: true,
      );
      client.onTimelineEvent.add(fromSender(_liza, type: EventTypes.Encrypted));
      await sending;
      await waitForSend();
      expect(sends(), hasLength(1));
    });

    test('приветствие пришло раньше вызова (lastEvent) — шлём сразу', () async {
      room.lastEvent = fromSender(_liza);
      expect(
        await waitForLizaGreeting(
          client,
          _roomId,
          _liza,
          timeout: const Duration(seconds: 30),
        ),
        isTrue,
      );
    });

    test('чужое событие и событие другой комнаты — не приветствие', () async {
      final waiting = waitForLizaGreeting(
        client,
        _roomId,
        _liza,
        timeout: const Duration(milliseconds: 300),
      );
      client.onTimelineEvent.add(fromSender('@alice:example.invalid'));
      final other = Room(id: '!other:x', client: client);
      client.onTimelineEvent.add(
        Event(
          type: EventTypes.Message,
          content: {'msgtype': 'm.text', 'body': 'привет'},
          eventId: r'$other',
          senderId: _liza,
          originServerTs: DateTime.now(),
          room: other,
        ),
      );
      expect(await waiting, isFalse);
    });

    test('приветствия нет — по таймауту всё равно шлём', () async {
      await sendFirstRequestMessage(
        client,
        store,
        _roomId,
        _liza,
        'вопрос',
        lizaJoined: true,
        greetingTimeout: const Duration(milliseconds: 100),
      );
      await waitForSend();
      expect(sends(), hasLength(1));
    });
  });

  test('AC-7: Лиза не вступила — не шлём, текст в черновике чата', () async {
    await sendFirstRequestMessage(
      client,
      store,
      _roomId,
      _liza,
      'сгенерируй 5 идей постов',
      lizaJoined: false,
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sends(), isEmpty);
    expect(store.getString('draft_$_roomId'), 'сгенерируй 5 идей постов');
  });
}
