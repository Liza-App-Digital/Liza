// ignore_for_file: depend_on_referenced_packages
// ledger:RL-stories-bar-frequent-contacts
//
// Ранжирование «частых собеседников» сторис-ленты (newInterface/09): частота =
// сообщения в личных чатах за 30 дней по локальной истории, при равенстве —
// свежесть последнего сообщения; без ботов, Лизы и авторов сторис; до 15.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/stories/frequent_contacts.dart';

import '../test_client.dart';

final _now = DateTime.utc(2026, 10, 14, 12);

DmActivity _a(String user, int count, {int ts = 0, String? room}) =>
    DmActivity(
      userId: user,
      roomId: room ?? '!$user',
      messageCount: count,
      lastMessageTs: ts,
    );

bool _noBots(String _) => false;

void main() {
  group('countRecentMessages', () {
    late Client client;
    late Room room;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      room = Room(id: '!dm:example.invalid', client: client);
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });

    Event ev(
      String type,
      Duration ago, {
      String? stateKey,
      Map<String, Object?>? unsigned,
    }) => Event(
      eventId: '\$${type.hashCode}-${ago.inMinutes}-$stateKey',
      senderId: '@bob:example.invalid',
      originServerTs: _now.subtract(ago),
      type: type,
      stateKey: stateKey,
      content: const {'msgtype': 'm.text', 'body': 'x'},
      unsigned: unsigned,
      room: room,
    );

    test('считает сообщения/стикеры/зашифрованные внутри 30 дней, '
        'служебные и старые — нет', () {
      // AC:RL-stories-bar-frequent-contacts/2
      final events = [
        ev(EventTypes.Message, const Duration(hours: 1)),
        ev(EventTypes.Sticker, const Duration(days: 2)),
        ev(EventTypes.Encrypted, const Duration(days: 29)),
        ev(EventTypes.Message, const Duration(days: 31)), // старше окна
        ev(EventTypes.Reaction, const Duration(hours: 2)), // не сообщение
        ev(
          EventTypes.RoomMember,
          const Duration(hours: 3),
          stateKey: '@bob:example.invalid',
        ),
        ev(
          EventTypes.Message,
          const Duration(hours: 4),
          unsigned: {
            'redacted_because': {
              'event_id': r'$r',
              'type': 'm.room.redaction',
              'sender': '@bob:example.invalid',
              'origin_server_ts': 0,
              'content': <String, Object?>{},
            },
          },
        ),
      ];
      final (count, lastTs) = countRecentMessages(events, now: _now);
      expect(count, 3);
      expect(
        lastTs,
        _now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
    });

    test('пустой список — ноль', () {
      expect(countRecentMessages(const [], now: _now), (0, 0));
    });
  });

  group('rankFrequentContacts', () {
    test('чаще — левее; при равенстве — свежее последнее сообщение', () {
      // AC:RL-stories-bar-frequent-contacts/1
      final ranked = rankFrequentContacts(
        [
          _a('@carol:x', 2, ts: 50),
          _a('@bob:x', 9, ts: 10),
          _a('@dave:x', 2, ts: 90),
          _a('@erin:x', 5, ts: 1),
        ],
        excludedUserIds: const {},
        isBot: _noBots,
      );
      expect(ranked.map((a) => a.userId), [
        '@bob:x',
        '@erin:x',
        '@dave:x',
        '@carol:x',
      ]);
    });

    test('боты, Лиза, я и авторы сторис исключены; ноль сообщений — нет', () {
      // AC:RL-stories-bar-frequent-contacts/3
      // AC:RL-stories-bar-frequent-contacts/4
      final ranked = rankFrequentContacts(
        [
          _a('@shop:bots.liza.ru', 99),
          _a('@liza:bots.liza.ru', 98),
          _a('@me:x', 97),
          _a('@author:x', 96),
          _a('@aibot:x', 95),
          _a('@silent:x', 0),
          _a('@bob:x', 1),
        ],
        excludedUserIds: const {'@me:x', '@author:x', '@liza:bots.liza.ru'},
        isBot: (id) => isBotLikeMxid(id) || id == '@aibot:x',
      );
      expect(ranked.map((a) => a.userId), ['@bob:x']);
    });

    test('несколько DM с одним человеком суммируются, тап ведёт в свежий', () {
      final ranked = rankFrequentContacts(
        [
          _a('@bob:x', 3, ts: 10, room: '!old'),
          _a('@carol:x', 4, ts: 5),
          _a('@bob:x', 2, ts: 20, room: '!new'),
        ],
        excludedUserIds: const {},
        isBot: _noBots,
      );
      expect(ranked.first.userId, '@bob:x');
      expect(ranked.first.messageCount, 5);
      expect(ranked.first.roomId, '!new');
    });

    test('не больше 15', () {
      // AC:RL-stories-bar-frequent-contacts/5
      final ranked = rankFrequentContacts(
        [for (var i = 0; i < 40; i++) _a('@u$i:x', i + 1)],
        excludedUserIds: const {},
        isBot: _noBots,
      );
      expect(ranked, hasLength(frequentContactsLimit));
      expect(frequentContactsLimit, 15);
      expect(ranked.first.userId, '@u39:x');
    });
  });

  test('isBotLikeMxid: бот-хоумсервер и AI-localpart', () {
    // AC:RL-stories-bar-frequent-contacts/3
    expect(isBotLikeMxid('@shop_bot:bots.liza.ru'), isTrue);
    expect(isBotLikeMxid('@liza:liza.local'), isTrue);
    expect(isBotLikeMxid('@bob:synapse.liza.laba.prodamus.tech'), isFalse);
  });

  group('collectDmActivity (локальная БД, без сети)', () {
    late Client client;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      client.rooms.clear();
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });

    Future<Room> dm(
      String roomId,
      String peer,
      List<Duration> messagesAgo, {
      String peerMembership = 'join',
      bool hidden = false,
    }) async {
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
          originServerTs: _now,
          type: EventTypes.RoomMember,
          stateKey: peer,
          content: {'membership': peerMembership},
          room: room,
        ),
      );
      if (hidden) {
        room.setState(
          Event(
            eventId: '\$t-$roomId',
            senderId: peer,
            originServerTs: _now,
            type: 'com.liza.chat.topology',
            stateKey: '',
            content: {'hidden': true},
            room: room,
          ),
        );
      }
      var i = 0;
      for (final ago in messagesAgo) {
        final e = MatrixEvent(
          eventId: '\$e-$roomId-${i++}',
          senderId: i.isEven ? peer : client.userID!,
          originServerTs: _now.subtract(ago),
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
      return room;
    }

    test('считает DM по локальной истории; группы, скрытые и брошенные — '
        'мимо', () async {
      await dm('!bob', '@bob:x', [
        const Duration(hours: 1),
        const Duration(days: 1),
        const Duration(days: 40),
      ]);
      await dm('!carol', '@carol:x', [const Duration(minutes: 5)]);
      await dm('!left', '@left:x', [
        const Duration(minutes: 1),
      ], peerMembership: 'leave');
      await dm('!hidden', '@hid:x', [const Duration(minutes: 1)], hidden: true);
      // Групповой чат (нет в m.direct) — не кандидат.
      client.rooms.add(Room(id: '!group', client: client));

      final activity = await collectDmActivity(client, now: _now);
      final byUser = {for (final a in activity) a.userId: a.messageCount};
      expect(byUser, {'@bob:x': 2, '@carol:x': 1});
    });

    test('кэш: повторный вызов в пределах TTL не пересчитывает', () async {
      FrequentContactsCache.instance.reset();
      await dm('!bob', '@bob:x', [const Duration(hours: 1)]);
      final first = await FrequentContactsCache.instance.refreshIfStale(
        client,
        now: _now,
      );
      await dm('!carol', '@carol:x', [const Duration(minutes: 1)]);
      final second = await FrequentContactsCache.instance.refreshIfStale(
        client,
        now: _now.add(const Duration(minutes: 5)),
      );
      expect(identical(first, second), isTrue);
      final third = await FrequentContactsCache.instance.refreshIfStale(
        client,
        now: _now.add(const Duration(minutes: 11)),
      );
      expect(third.map((a) => a.userId).toSet(), {'@bob:x', '@carol:x'});
      FrequentContactsCache.instance.reset();
    });
  });
}
