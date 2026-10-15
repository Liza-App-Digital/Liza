// ledger:RL-liza-multi-dm-new-request
// AC:RL-liza-multi-dm-new-request/1 AC:RL-liza-multi-dm-new-request/2
// AC:RL-liza-multi-dm-new-request/3
//
// «+» → «Новый запрос»: несколько DM с одной Лизой на ЖИВОМ Client +
// FakeMatrixApi (считаем реальные POST /createRoom).
//
// Red-proof:
//   RP-1 (AC-1): убрать `skipExistingChat: forceNew` в ensureDirectChat → второй
//     последовательный запрос вернёт первый, createRoom == 1, тест красный.
//   RP-2 (AC-2): убрать `!isLizaRequestRoom` из isLizaAssistantRoom → запрос с
//     очищенным именем станет «ассистентом», тест красный.
//   RP-3 (AC-3): в ensureLizaAssistantDm звать ensureDirectChat без forceNew →
//     SDK вернёт свежий запрос вместо нового основного, тест красный.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'test_client.dart';

const _liza = '@liza:bots.liza.ru';

void main() {
  late Client client;
  late FakeMatrixApi api;
  late List<Map<String, Object?>> createBodies;

  /// Комната «приходит» с теми же state, что ушли в createRoom, а Лиза сразу в
  /// join — как после sync и её вступления.
  void hookCreateRoom() {
    var n = 0;
    api.api['POST']!['/client/v3/createRoom'] = (data) {
      final body = Map<String, Object?>.from(
        (data is String ? jsonDecode(data) : data) as Map,
      );
      createBodies.add(body);
      final roomId = '!created${n++}:example.invalid';
      final room = Room(id: roomId, client: client);
      for (final s in (body['initial_state'] as List? ?? const [])) {
        final st = Map<String, Object?>.from(s as Map);
        _setState(
          room,
          st['type'] as String,
          '',
          Map<String, Object?>.from(st['content'] as Map),
        );
      }
      _setState(room, EventTypes.RoomMember, _liza, {'membership': 'join'});
      client.rooms = [...client.rooms, room];
      return {'room_id': roomId};
    };
  }

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    FakeMatrixApi.client = client;
    api = (client.httpClient as dynamic).inner as FakeMatrixApi;
    createBodies = [];
    hookCreateRoom();
  });

  tearDown(() => client.dispose(closeDatabase: true));

  group('AC-1: каждый «Новый запрос» — новая комната, двойной тап — одна', () {
    test('три последовательных → три createRoom с маркером и именем', () async {
      final ids = <String>[];
      for (var i = 0; i < 3; i++) {
        final (id, joined) = await startLizaRequestChat(
          client,
          _liza,
          title: 'Новый запрос',
        );
        expect(joined, isTrue);
        ids.add(id);
      }
      expect(ids.toSet().length, 3);
      expect(createBodies.length, 3);
      for (final body in createBodies) {
        final state = {
          for (final s in body['initial_state'] as List)
            (s as Map)['type']: s['content'],
        };
        expect(state[lizaRequestStateType], {'placeholder': 'Новый запрос'});
        expect(state[EventTypes.RoomName], {'name': 'Новый запрос'});
        expect(body['is_direct'], isTrue);
      }
      for (final id in ids) {
        expect(isLizaRequestRoom(client.getRoomById(id)!), isTrue);
      }
    });

    test('два параллельных (двойной тап) → один createRoom', () async {
      final results = await Future.wait([
        startLizaRequestChat(client, _liza, title: 'Новый запрос'),
        startLizaRequestChat(client, _liza, title: 'Новый запрос'),
      ]);
      expect(results[0].$1, results[1].$1);
      expect(createBodies.length, 1);
    });

    test(
      'запрос во время создания основного DM не склеивается с ним',
      () async {
        final main = client.ensureDirectChat(_liza);
        final request = startLizaRequestChat(
          client,
          _liza,
          title: 'Новый запрос',
        );
        final ids = await Future.wait([main, request.then((r) => r.$1)]);
        expect(ids[0], isNot(ids[1]));
        expect(createBodies.length, 2);
      },
    );
  });

  test(
    'AC-2: ассистент — ровно основной DM из {основной, запросы, mini App}',
    () async {
      final mainRoom = _dm(client, '!main:x', null);
      final named = _dm(client, '!req1:x', 'Лиза: план отпуска', request: true);
      // Человек стёр имя запроса — ассистентом он стать не должен.
      final cleared = _dm(client, '!req2:x', null, request: true);
      final miniApp = _dm(client, '!app:x', 'Магазин Prodamus');
      client.accountData['m.direct'] = BasicEvent(
        type: 'm.direct',
        content: {
          _liza: [named.id, cleared.id, miniApp.id, mainRoom.id],
        },
      );

      final assistants = client.rooms
          .where((r) => isLizaAssistantRoom(r, _liza))
          .map((r) => r.id)
          .toList();
      expect(assistants, [mainRoom.id]);
      expect(findLizaAssistantDm(client, _liza)?.id, mainRoom.id);
    },
  );

  test('AC-3: есть только запросы → создаётся НОВЫЙ основной DM, а не '
      'возвращается свежий запрос', () async {
    final (requestId, _) = await startLizaRequestChat(
      client,
      _liza,
      title: 'Новый запрос',
    );
    expect(
      client.getDirectChatFromUserId(_liza),
      requestId,
      reason: 'SDK отдал бы запрос — ровно этот случай и закрываем',
    );

    final mainId = await ensureLizaAssistantDm(client, _liza);
    expect(mainId, isNot(requestId));
    expect(createBodies.length, 2);
    final mainState = createBodies.last['initial_state'] as List? ?? const [];
    expect(
      mainState.any((s) => (s as Map)['type'] == lizaRequestStateType),
      isFalse,
    );

    // Основной есть — повторный вызов его возвращает, без новых комнат.
    expect(await ensureLizaAssistantDm(client, _liza), mainId);
    expect(createBodies.length, 2);
  });
}

void _setState(
  Room room,
  String type,
  String stateKey,
  Map<String, Object?> content,
) {
  room.setState(
    Event(
      type: type,
      eventId: '\$${room.id}-$type-$stateKey',
      senderId: '@test:fakeServer.notExisting',
      originServerTs: DateTime.now(),
      room: room,
      content: content,
      stateKey: stateKey,
    ),
  );
}

Room _dm(Client client, String id, String? name, {bool request = false}) {
  final room = Room(id: id, client: client);
  if (name != null) _setState(room, EventTypes.RoomName, '', {'name': name});
  if (request) {
    _setState(room, lizaRequestStateType, '', {'placeholder': 'Новый запрос'});
  }
  _setState(room, EventTypes.RoomMember, _liza, {'membership': 'join'});
  client.rooms.add(room);
  return room;
}
