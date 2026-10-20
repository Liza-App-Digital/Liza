// Право создавать чаты/каналы в компании (задача 12 newInterface, Надежда
// 18.10: «по умолчанию это должно быть запрещено»; «Почему-то я могу создать
// [группу в] компанию Розенталь, хотя я не являюсь администратором»).
//
// Корень бага В3 — клиентский: m.room.power_levels нет в importantStateEvents,
// у partial-пространства после холодного старта getState(PowerLevels) == null,
// SDK считал порог m.space.child = 0, и место «было» у всех.
//
// ledger:RL-company-create-rights

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/chat_topology.dart';
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
  Event stateEvent(
    Room room,
    String type,
    Map<String, Object?> content, [
    String stateKey = '',
  ]) => Event(
    eventId: '\$${ts++}',
    senderId: '@creator:example.invalid',
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: type,
    content: content,
    room: room,
    stateKey: stateKey,
  );

  Map<String, Object?> powerLevels(
    int myLevel, {
    Map<String, int> events = const {},
  }) => {
    'users': {client.userID!: myLevel},
    'users_default': 0,
    'state_default': 50,
    'events': {EventTypes.SpaceChild: 50, ...events},
  };

  /// Пространство; [myLevel] == null — power_levels не загружен (partial).
  Room space(
    String id, {
    int? myLevel = 100,
    Map<String, int> events = const {},
    List<String> children = const [],
  }) {
    final room = Room(id: id, client: client, membership: Membership.join);
    room.setState(stateEvent(room, EventTypes.RoomCreate, {'type': 'm.space'}));
    room.setState(stateEvent(room, EventTypes.RoomName, {'name': id}));
    if (myLevel != null) {
      room.setState(
        stateEvent(
          room,
          EventTypes.RoomPowerLevels,
          powerLevels(myLevel, events: events),
        ),
      );
    }
    for (final c in children) {
      room.setState(
        stateEvent(room, EventTypes.SpaceChild, {
          'via': ['example.invalid'],
        }, c),
      );
    }
    return room;
  }

  // Точное зеркало серверного may_create_in_company: кейсы читают оба теста.
  group('паритет с single_space_guard', () {
    final file = File(
      '../../servers/synapse/modules/single_space_guard/tests/'
      'create_rights_cases.json',
    );
    final cases = (jsonDecode(file.readAsStringSync()) as Map)['cases'] as List;
    for (final c in cases.cast<Map<String, dynamic>>()) {
      test(c['name'], () {
        expect(
          mayCreateInCompany(
            (c['power_levels'] as Map).cast<String, Object?>(),
            c['user'] as String,
            c['kind'] == 'channel'
                ? CompanyCreateKind.channel
                : CompanyCreateKind.chat,
            creators: ((c['creators'] as List?) ?? const []).cast<String>(),
          ),
          c['allowed'],
        );
      });
    }
  });

  // AC:RL-company-create-rights/5 — ∀ {корень компании, подпространство,
  // чужая компания}: без загруженного power_levels и с PL 0 < 50 места нет.
  group('groupPlaces: места только с загруженным правом', () {
    for (final (label, build) in <(String, List<Room> Function(int?))>[
      ('корень компании', (lvl) => [space('!root:x', myLevel: lvl)]),
      (
        'подпространство',
        (lvl) => [
          space('!root:x', myLevel: 0, children: ['!sub:x']),
          space('!sub:x', myLevel: lvl),
        ],
      ),
      ('чужая компания', (lvl) => [space('!foreign:other', myLevel: lvl)]),
    ]) {
      test('$label: power_levels не загружен — места нет', () {
        expect(groupPlaces(build(null)), isEmpty);
      });
      test('$label: PL 0 — места нет', () {
        expect(groupPlaces(build(0)), isEmpty);
      });
      test('$label: PL 50 — место есть', () {
        expect(groupPlaces(build(50)), hasLength(1));
      });
    }

    test('корень своей компании: m.space.child есть, порог «Создание '
        'чатов» 99 — места нет; без ключа модератору — есть', () {
      final strict = space(
        '!own:x',
        myLevel: 50,
        events: {companyCreateChatKey: 99},
      );
      expect(groupPlaces([strict], ownCompanyRootId: '!own:x'), isEmpty);
      expect(groupPlaces([strict]), hasLength(1));
      final byDefault = space('!own2:x', myLevel: 50);
      expect(
        groupPlaces([byDefault], ownCompanyRootId: '!own2:x'),
        hasLength(1),
      );
    });
  });

  group('canCreateChatInSpace', () {
    test('power_levels не загружен — нет даже владельцу', () {
      expect(canCreateChatInSpace(space('!s:x', myLevel: null)), isFalse);
    });

    test('порог «Создание чатов» действует только в корне своей компании', () {
      final room = space(
        '!s:x',
        myLevel: 50,
        events: {companyCreateChatKey: 99},
      );
      expect(canCreateChatInSpace(room), isTrue);
      expect(canCreateChatInSpace(room, ownCompanyRootId: '!other:x'), isTrue);
      expect(canCreateChatInSpace(room, ownCompanyRootId: '!s:x'), isFalse);
    });
  });

  // AC:RL-company-create-rights/8 — владелец после холодного старта: power_levels
  // лежит в БД (не в importantStateEvents), пространство partial → кнопок нет;
  // postLoad() (SpaceView.initState) поднимает их владельцу, рядовому — нет.
  group('холодный старт: postLoad возвращает право', () {
    Future<Room> coldSpace(String id, int myLevel) async {
      final room = space(id, myLevel: null);
      client.rooms.add(room);
      await client.database.storeEventUpdate(
        id,
        stateEvent(room, EventTypes.RoomPowerLevels, powerLevels(myLevel)),
        EventUpdateType.state,
        client,
      );
      // storeEventUpdate мог положить состояние и в память — сбрасываем, как
      // после холодного старта (в памяти только importantStateEvents).
      room.states.remove(EventTypes.RoomPowerLevels);
      room.partial = true;
      return room;
    }

    test('владелец: до postLoad нет, после — есть', () async {
      final room = await coldSpace('!cold:x', 100);
      expect(canCreateChatInSpace(room), isFalse);
      await room.postLoad();
      expect(canCreateChatInSpace(room), isTrue);
      expect(canCreateChatInSpace(room, ownCompanyRootId: '!cold:x'), isTrue);
    });

    test('рядовой: и после postLoad нет', () async {
      final room = await coldSpace('!cold2:x', 0);
      await room.postLoad();
      expect(room.getState(EventTypes.RoomPowerLevels), isNotNull);
      expect(canCreateChatInSpace(room), isFalse);
    });
  });
}
