// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/unseen_messages.dart';

import 'test_client.dart';

/// `Room.hasUnseenMessages` — порядковое «есть чужие сообщения новее моей
/// квитанции» вместо SDK-`hasNewMessages`, который сравнивает ВРЕМЯ КВИТАНЦИИ
/// с ts события и после частичной квитанции (модель популярных мессенджеров «прочитано =
/// увидено», 2026-09-17) врёт `false` при реально непрочитанных.
///
/// ledger:RL-read-receipt-viewport-based
/// ledger:RL-badge-receipt-based
void main() {
  late Client client;
  const me = '@test:fakeServer.notExisting';
  const other = '@other:example.invalid';

  setUp(() async {
    UnseenOrderCache.reset();
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Room newRoom() => Room(id: '!r:example.invalid', client: client)
    ..setState(
      Event(
        eventId: '\$create',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomCreate,
        content: {},
        room: Room(id: '!r:example.invalid', client: client),
        stateKey: '',
      ),
    );

  Event msg(
    Room room, {
    required int ts,
    String sender = other,
    String type = EventTypes.Message,
  }) => Event(
    eventId: '\$msg$ts',
    senderId: sender,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: type,
    content: {'msgtype': 'm.text', 'body': 'hi'},
    room: room,
  );

  void setReceipt(Room room, {required String eventId, required int ts}) {
    room.roomAccountData[LatestReceiptState.eventType] = BasicEvent(
      type: LatestReceiptState.eventType,
      content: {
        'global': {
          'latest': {'e': eventId, 'ts': ts},
          'others': <String, dynamic>{},
        },
      },
    );
  }

  void setFullyRead(Room room, String eventId) {
    room.roomAccountData['m.fully_read'] = BasicEvent(
      type: 'm.fully_read',
      content: {'event_id': eventId},
    );
  }

  /// Кладём события в локальную БД (порядок: новейшие первыми, как в
  /// `_timelineFragmentsBox`), чтобы `getEventIdList` их знал.
  Future<void> storeTimeline(Room room, List<Event> oldestFirst) async {
    for (final e in oldestFirst) {
      await client.database.storeEventUpdate(
        room.id,
        e,
        EventUpdateType.timeline,
        client,
      );
    }
  }

  group('UnseenOrderCache.decide (чистая)', () {
    test('квитанция СТАРШЕ последнего → есть невидённое', () {
      expect(
        UnseenOrderCache.decide(
          eventIdsNewestFirst: ['e12', 'e11', 'e10', 'e9', 'e8'],
          receiptEventId: 'e9',
          lastEventId: 'e12',
        ),
        isTrue,
      );
    });

    test('квитанция НОВЕЕ последнего preview-события (реакция) → нет', () {
      expect(
        UnseenOrderCache.decide(
          eventIdsNewestFirst: ['reaction', 'e12', 'e11'],
          receiptEventId: 'reaction',
          lastEventId: 'e12',
        ),
        isFalse,
      );
    });

    test('хотя бы одного id нет в списке → порядок неизвестен (null)', () {
      expect(
        UnseenOrderCache.decide(
          eventIdsNewestFirst: ['e12', 'e11'],
          receiptEventId: 'e0',
          lastEventId: 'e12',
        ),
        isNull,
      );
      expect(
        UnseenOrderCache.decide(
          eventIdsNewestFirst: ['e11'],
          receiptEventId: 'e11',
          lastEventId: 'e12',
        ),
        isNull,
      );
    });
  });

  group('Room.hasUnseenMessages — Tier0 (без порядка)', () {
    test('нет lastEvent / не preview-тип → false', () {
      final room = newRoom();
      expect(room.hasUnseenMessages, isFalse);
      room.lastEvent = msg(room, ts: 2000, type: EventTypes.RoomMember);
      expect(room.hasUnseenMessages, isFalse);
    });

    test('последнее — моё → false', () {
      final room = newRoom();
      room.lastEvent = msg(room, ts: 2000, sender: me);
      expect(room.hasUnseenMessages, isFalse);
    });

    test('квитанция стоит на lastEvent → false (как SDK)', () {
      final room = newRoom();
      room.lastEvent = msg(room, ts: 2000);
      setReceipt(room, eventId: '\$msg2000', ts: 3000);
      expect(room.hasUnseenMessages, isFalse);
    });

    test('только m.fully_read на lastEvent (чужой клиент) → false', () {
      final room = newRoom();
      room.lastEvent = msg(room, ts: 2000);
      setFullyRead(room, '\$msg2000');
      expect(room.hasUnseenMessages, isFalse);
    });

    test('квитанции нет вовсе → true (как readAt=0 в SDK)', () {
      final room = newRoom();
      room.lastEvent = msg(room, ts: 2000);
      expect(room.hasUnseenMessages, isTrue);
    });
  });

  group('Room.hasUnseenMessages — залипшая точка у прочитанной комнаты', () {
    test('AC:RL-badge-receipt-based/8 квитанция на lastEvent, но её ts старше '
        'ts события (бот-алерт, сдвиг часов): hasUnseenMessages — false '
        '(точка списка чатов не залипает)', () {
      final room = newRoom();
      final last = msg(room, ts: 50000);
      room.lastEvent = last;
      setReceipt(room, eventId: last.eventId, ts: 40000);
      expect(room.hasUnseenMessages, isFalse);
    });
  });

  group('Room.hasUnseenMessages — Tier1/Tier2 (частичная квитанция)', () {
    test(
      'AC:RL-read-receipt-viewport-based/11 частичная квитанция: ts новее '
      'lastEvent, но eventId старее по порядку → true (SDK врёт false)',
      () async {
        final room = newRoom();
        final events = [
          for (var ts = 1000; ts <= 12000; ts += 1000) msg(room, ts: ts),
        ];
        await storeTimeline(room, events);
        room.lastEvent = events.last; // $msg12000
        // Увидел 5 из 12 → квитанция на $msg5000, отправлена «сейчас».
        setReceipt(room, eventId: '\$msg5000', ts: 99000);
        expect(room.hasNewMessages, isFalse, reason: 'sanity: SDK по ts');

        // До досчёта порядка — фолбэк на SDK (false).
        expect(room.hasUnseenMessages, isFalse);
        await UnseenOrderCache.reconcileRoom(room);
        expect(room.hasUnseenMessages, isTrue);
      },
    );

    test('AC:RL-badge-receipt-based/7 notif>0 + частичная квитанция → комната '
        'ОСТАЁТСЯ в бейдже иконки (честное число, не 0)', () async {
      final room = newRoom()..notificationCount = 7;
      final events = [
        for (var ts = 1000; ts <= 12000; ts += 1000) msg(room, ts: ts),
      ];
      await storeTimeline(room, events);
      room.lastEvent = events.last;
      setReceipt(room, eventId: '\$msg5000', ts: 99000);
      await UnseenOrderCache.reconcile(client);
      // reconcile(client) идёт по client.rooms — наша комната там не
      // зарегистрирована, досчитываем точечно.
      await UnseenOrderCache.reconcileRoom(room);
      expect(room.countsTowardAppBadge, isTrue);
    });

    test(
      'застрявший серверный счётчик (§9 pushes.md): квитанция на НОВЕЙШЕЕ '
      'событие (реакция новее preview-lastEvent) → false, комната не в бейдже',
      () async {
        final room = newRoom()..notificationCount = 3;
        final m = msg(room, ts: 2000);
        final reaction = Event(
          eventId: '\$reaction',
          senderId: other,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(3000),
          type: EventTypes.Reaction,
          content: {
            'm.relates_to': {
              'rel_type': 'm.annotation',
              'event_id': '\$msg2000',
              'key': '👍',
            },
          },
          room: room,
        );
        await storeTimeline(room, [m, reaction]);
        room.lastEvent = m;
        setReceipt(room, eventId: '\$reaction', ts: 4000);
        await UnseenOrderCache.reconcileRoom(room);
        expect(room.hasUnseenMessages, isFalse);
        expect(room.countsTowardAppBadge, isFalse);
      },
    );

    test('порядок неизвестен (квитанция вне локальной БД) → как SDK', () async {
      final room = newRoom();
      final m = msg(room, ts: 2000);
      await storeTimeline(room, [m]);
      room.lastEvent = m;
      setReceipt(room, eventId: '\$ancient', ts: 5000);
      await UnseenOrderCache.reconcileRoom(room);
      expect(room.hasUnseenMessages, room.hasNewMessages);
    });

    test('кэш инвалидируется при смене пары (квитанция, lastEvent)', () async {
      final room = newRoom();
      final events = [
        for (var ts = 1000; ts <= 3000; ts += 1000) msg(room, ts: ts),
      ];
      await storeTimeline(room, events);
      room.lastEvent = events.last;
      setReceipt(room, eventId: '\$msg1000', ts: 9000);
      await UnseenOrderCache.reconcileRoom(room);
      expect(room.hasUnseenMessages, isTrue);
      // Докрутил до низа — квитанция на lastEvent: Tier0 решает без кэша.
      setReceipt(room, eventId: '\$msg3000', ts: 9500);
      expect(room.hasUnseenMessages, isFalse);
    });
  });
}
