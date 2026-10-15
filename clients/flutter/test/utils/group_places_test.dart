// Страж списка мест «Где создать» на экране «Создать группу» (задача 10
// newInterface): только пространства, где пользователь состоит и может писать
// m.space.child. Место без права — ловушка: PUT m.space.child упадёт, а
// single_space_guard через parent_grace_seconds вложит группу в главное
// пространство сервера создателя, не туда, куда выбрали.
//
// ledger:RL-new-group-place-picker

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/create_group_in_space.dart';

import 'test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client client;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  var ts = 1000;
  void state(
    Room room,
    String type,
    Map<String, Object?> content, [
    String stateKey = '',
  ]) {
    room.setState(
      Event(
        eventId: '\$${ts++}',
        senderId: '@creator:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
        type: type,
        content: content,
        room: room,
        stateKey: stateKey,
      ),
    );
  }

  Room space(
    String id,
    String name, {
    int myLevel = 100,
    Membership membership = Membership.join,
    List<String> children = const [],
    bool isSpace = true,
  }) {
    final room = Room(id: id, client: client, membership: membership);
    state(room, EventTypes.RoomCreate, {if (isSpace) 'type': 'm.space'});
    state(room, EventTypes.RoomName, {'name': name});
    state(room, EventTypes.RoomPowerLevels, {
      'users': {client.userID!: myLevel},
      'users_default': 0,
      'state_default': 50,
      'events': {EventTypes.SpaceChild: 50},
    });
    for (final c in children) {
      state(room, EventTypes.SpaceChild, {
        'via': ['example.invalid'],
      }, c);
    }
    return room;
  }

  List<String> ids(List<GroupPlace> places) =>
      places.map((p) => p.space.id).toList();

  // AC:RL-new-group-place-picker/2 — ∀ {компания с правом, подпространство с
  // правом, компания без права, пространство без join, обычная комната}.
  test('в списке только пространства с join и правом на m.space.child', () {
    final rooms = [
      space('!b:x', 'Бета', children: ['!b-sub:x']),
      space('!b-sub:x', 'Отдел Беты'),
      space('!a:x', 'Альфа'),
      space('!noright:x', 'Чужая', myLevel: 0),
      space('!invited:x', 'Приглашение', membership: Membership.invite),
      space('!left:x', 'Ушёл', membership: Membership.leave),
      space('!group:x', 'Обычная группа', isSpace: false),
    ];

    final places = groupPlaces(rooms);

    // Компании по имени, подпространство сразу за своей компанией.
    expect(ids(places), ['!a:x', '!b:x', '!b-sub:x']);
    expect(places[0].company, isNull);
    expect(places[1].company, isNull);
    expect(places[2].company?.id, '!b:x');
  });

  test('подпространство с правом в компании без права: остаётся, '
      'подписано компанией', () {
    final rooms = [
      space('!root:x', 'Компания', myLevel: 0, children: ['!sub:x']),
      space('!sub:x', 'Отдел'),
    ];

    final places = groupPlaces(rooms);

    expect(ids(places), ['!sub:x']);
    expect(places.single.company?.id, '!root:x');
  });

  test('вложенность глубже одного уровня — компания-корень в подписи', () {
    final rooms = [
      space('!root:x', 'Компания', children: ['!l1:x']),
      space('!l1:x', 'Уровень 1', children: ['!l2:x']),
      space('!l2:x', 'Уровень 2'),
    ];

    final places = groupPlaces(rooms);

    expect(ids(places), ['!root:x', '!l1:x', '!l2:x']);
    expect(places[2].company?.id, '!root:x');
  });

  test('цикл m.space.child не зацикливает обход и не дублирует места', () {
    final rooms = [
      space('!p:x', 'П', children: ['!q:x']),
      space('!q:x', 'К', children: ['!p:x']),
    ];

    final places = groupPlaces(rooms);

    expect(ids(places)..sort(), ['!p:x', '!q:x']);
  });

  test('мест нет — пустой список', () {
    expect(groupPlaces([space('!g:x', 'Группа', isSpace: false)]), isEmpty);
  });
}
