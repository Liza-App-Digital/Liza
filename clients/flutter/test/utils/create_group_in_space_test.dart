// Страж рецидива invite:0: группа, созданная кнопкой «+» → «Новая группа» на
// экране компании, обязана нести тот же порог приглашения invite:50, что и
// группа из меню «+» (`new_group.dart` `_createGroup`). Фикс 25.08 покрыл
// только путь меню — путь `space_view` создавал группу без override, preset
// private_chat давал invite:0, и любой участник приглашал посторонних.
//
// Ассерты — по ТЕЛАМ запросов FakeMatrixApi.calledEndpoints: проверка чистой
// функции groupPowerLevelOverride() была зелёной и при живом баге.
//
// Задача 04: та же группа рождается с ровно одним родителем — местом создания
// (m.space.parent в initial_state + один m.space.child от родителя), иначе
// single_space_guard вкладывал её ещё и в главное пространство.
//
// ledger:RL-group-permissions-enforcement
// ledger:RL-company-group-single-parent

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/create_group_in_space.dart';

import 'test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client client;
  late FakeMatrixApi api;

  // Ответ стаба FakeMatrixApi на POST /createRoom.
  const createdId = '!1234:fakeServer.notExisting';
  const encodedCreated = '!1234%3AfakeServer.notExisting';
  const spaceId = '!company:example.invalid';
  const subspaceId = '!sub:example.invalid';
  late String userDomain;

  String childPutPath([String parentId = spaceId]) =>
      '/client/v3/rooms/${Uri.encodeComponent(parentId)}'
      '/state/m.space.child/$encodedCreated';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeMatrixApi();
    api.api['PUT'] ??= {};
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    userDomain = client.userID!.domain!;
    FakeMatrixApi.calledEndpoints.clear();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Room space([String id = spaceId]) {
    final room = Room(id: id, client: client);
    room.setState(
      Event(
        eventId: '\$create-company',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomCreate,
        content: {'type': 'm.space'},
        room: room,
        stateKey: '',
      ),
    );
    return room;
  }

  Map<String, dynamic> createRoomBody() {
    final bodies = FakeMatrixApi.calledEndpoints['/client/v3/createRoom'];
    expect(bodies, isNotNull, reason: 'createRoom не вызван');
    expect(bodies, hasLength(1), reason: 'createRoom должен быть вызван 1 раз');
    return jsonDecode(bodies!.single as String) as Map<String, dynamic>;
  }

  void stubLinks([String parentId = spaceId]) {
    api.api['PUT']![childPutPath(parentId)] = (_) => {'event_id': '\$child'};
  }

  test('тело createRoom: invite:50, private_chat, private, имя', () async {
    stubLinks();

    final roomId = await createGroupInSpace(
      space: space(),
      name: 'Отдел продаж',
    );
    expect(roomId, createdId);

    final body = createRoomBody();
    final override = body['power_level_content_override'] as Map;

    // AC:RL-group-permissions-enforcement/6 — без явного порога preset
    // private_chat отдал бы invite:0.
    expect(override['invite'], moderatorPowerLevel);
    expect(body['preset'], 'private_chat');
    expect(body['visibility'], 'private');
    expect(body['name'], 'Отдел продаж');

    // AC:RL-group-permissions-enforcement/7 — ни events (shallow-merge стёр
    // бы шаблонные пороги → модератор переписал бы m.room.power_levels), ни
    // events_default (в группе пишут все).
    expect(override.containsKey('events'), isFalse);
    expect(override.containsKey('events_default'), isFalse);
  });

  // AC:RL-company-group-single-parent/3 — квантор ∀ по месту создания: корень
  // компании и подпространство.
  for (final parentId in const [spaceId, subspaceId]) {
    test('родитель $parentId: один m.space.parent в initial_state, '
        'один PUT m.space.child, без PUT m.space.parent', () async {
      stubLinks(parentId);

      await createGroupInSpace(space: space(parentId), name: 'Отдел');

      final body = createRoomBody();
      expect(
        (body['power_level_content_override'] as Map)['invite'],
        moderatorPowerLevel,
      );
      final parents = (body['initial_state'] as List)
          .cast<Map<String, dynamic>>()
          .where((e) => e['type'] == 'm.space.parent')
          .toList();
      expect(parents, hasLength(1));
      expect(parents.single['state_key'], parentId);
      expect(parents.single['content'], {
        'via': [userDomain],
      });
      // Шифрование группе компании не включаем (как было до фикса).
      expect(
        (body['initial_state'] as List).cast<Map>().where(
          (e) => e['type'] == 'm.room.encryption',
        ),
        isEmpty,
      );

      // AC:RL-company-group-single-parent/4 и
      // AC:RL-group-permissions-enforcement/8 — связь со стороны родителя
      // ОДНИМ m.space.child с непустым via, строго после createRoom;
      // m.space.parent вторым PUT не переписывается.
      final links = FakeMatrixApi.calledEndpoints.keys
          .where(
            (k) =>
                k.contains('/state/m.space.child/') ||
                k.contains('/state/m.space.parent/'),
          )
          .toList();
      expect(links, [childPutPath(parentId)]);
      final childBody =
          jsonDecode(
                FakeMatrixApi.calledEndpoints[childPutPath(parentId)]!.single
                    as String,
              )
              as Map<String, dynamic>;
      expect(childBody['via'], [userDomain]);
      final order = FakeMatrixApi.calledEndpoints.keys.toList();
      expect(
        order.indexOf('/client/v3/createRoom'),
        lessThan(order.indexOf(childPutPath(parentId))),
      );
    });
  }

  test('провал привязки: группа покидается и забывается, '
      'исходная ошибка пробрасывается', () async {
    // PUT не зарегистрирован → FakeMatrixApi отвечает ошибкой → SDK бросает.
    api.api['POST']!['/client/v3/rooms/$encodedCreated/forget'] = (_) => {};

    // AC:RL-company-group-single-parent/4 — с родителем в initial_state
    // сервер группу в компанию не вложит: без компенсации осталась бы сирота.
    await expectLater(
      createGroupInSpace(space: space(), name: 'Отдел'),
      throwsA(isA<MatrixException>()),
    );
    final calls = FakeMatrixApi.calledEndpoints.keys.toList();
    expect(calls, contains('/client/v3/rooms/$encodedCreated/leave'));
    expect(calls, contains('/client/v3/rooms/$encodedCreated/forget'));
    expect(
      calls.indexOf(childPutPath()),
      lessThan(calls.indexOf('/client/v3/rooms/$encodedCreated/leave')),
    );
  });

  // AC:RL-company-group-single-parent/8 — кнопка «Создать чат» и пункт
  // «Новое подпространство» видны ⇔ право писать m.space.child.
  group('canCreateChatInSpace', () {
    Room spaceWithLevel(int myLevel) {
      final room = space();
      room.setState(
        Event(
          eventId: '\$pl',
          senderId: '@creator:example.invalid',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          type: EventTypes.RoomPowerLevels,
          content: {
            'users': {client.userID!: myLevel},
            'users_default': 0,
            'state_default': 50,
            'events': {EventTypes.SpaceChild: 50},
          },
          room: room,
          stateKey: '',
        ),
      );
      return room;
    }

    test('участник (0) — нет', () {
      expect(canCreateChatInSpace(spaceWithLevel(0)), isFalse);
    });
    test('модератор (50) — да', () {
      expect(canCreateChatInSpace(spaceWithLevel(50)), isTrue);
    });
    test('админ (100) — да', () {
      expect(canCreateChatInSpace(spaceWithLevel(100)), isTrue);
    });
    test('пространства нет — нет', () {
      expect(canCreateChatInSpace(null), isFalse);
    });
  });
}
