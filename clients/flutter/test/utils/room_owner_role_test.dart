// ledger:RL-room-owner-transfer
//
// Роль «владелец» (механика ВК): владелец 100, админ 99, модератор 50.
// Страж на РЕАЛЬНЫХ предикатах chat_topology и SDK-гейтах User/Room (не
// реплика): матрица «кто кого может понизить/исключить» ∀ сущность ∈ {группа,
// канал, подпространство, компания}, тела ОДНОГО события m.room.power_levels
// при назначении админа и передаче владения.
//
// Red-proof (2026-10-14, временные правки, вместе с member_actions_owner_menu_test):
// - adminPowerLevel = 100 → 15 красных (цель получает 100, админ-99 не админ);
// - убрать нормализацию в _withUsers → 4 красных (AC-3/AC-4: пороги остаются 100);
// - canTransferOwnershipTo от админа (>= 99) → 9 красных (AC-2/AC-6);
// - (ревью 2026-10-14) permissionThresholdMaxLevel без потолка users_default
//   → AC-12 красный; без исключения topology в нормализации → AC-14 красный;
// - меню: maxLevel = ownPowerLevel → AC-5 красный; без пункта «Передать
//   владение» → 4 красных (AC-1/AC-6).
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/member_power_level_actions.dart';

import 'test_client.dart';

const owner = '@owner:example.invalid';
const admin = '@admin:example.invalid';
const admin2 = '@admin2:example.invalid';
const mod = '@mod:example.invalid';
const plain = '@plain:example.invalid';

/// power_levels комнаты после нормализации (новая модель).
Map<String, Object?> ownerModelContent(Map<String, int> users) => {
  'users': users,
  'users_default': 0,
  'events_default': 0,
  'state_default': 50,
  'ban': 50,
  'kick': 50,
  'redact': 50,
  'invite': 50,
  'events': {'m.room.power_levels': 99, 'm.room.history_visibility': 99},
};

/// Шаблон Synapse + канальный override до нормализации (как создаёт клиент).
Map<String, Object?> legacyChannelContent(Map<String, int> users) => {
  'users': users,
  'users_default': 0,
  'events_default': 100,
  'state_default': 50,
  'ban': 50,
  'kick': 50,
  'redact': 50,
  'invite': 50,
  'notifications': {'room': 50},
  'events': {
    ...synapseDefaultEventPowerLevels,
    'm.reaction': 0,
    'm.room.redaction': 0,
  },
};

enum Entity { group, channel, subspace, company }

void main() {
  group('чистые функции', () {
    test('AC:RL-room-owner-transfer/5 assignableRoleMaxLevel: владелец → '
        'админ, админ → модератор', () {
      expect(assignableRoleMaxLevel(100), adminPowerLevel);
      expect(assignableRoleMaxLevel(99), moderatorPowerLevel);
      expect(assignableRoleMaxLevel(50), moderatorPowerLevel);
      expect(assignableRoleMaxLevel(0), 0);
      expect(ownerPowerLevel, 100);
      expect(adminPowerLevel, 99);
    });

    test('AC:RL-room-owner-transfer/4 назначение админа: цели 99, пороги '
        '100 → 99, прочие пороги и users не тронуты', () {
      final before = legacyChannelContent({owner: 100, mod: 50});
      final after = promoteToAdminContent(before, mod);
      expect(after['users'], {owner: 100, mod: 99});
      expect(after['events_default'], 99);
      final events = after['events'] as Map;
      expect(events['m.room.power_levels'], 99);
      expect(events['m.room.history_visibility'], 99);
      expect(events['m.room.tombstone'], 99);
      expect(events['m.room.encryption'], 99);
      expect(events['m.room.server_acl'], 99);
      expect(events['m.room.name'], 50);
      expect(events['m.reaction'], 0);
      expect(events['m.room.redaction'], 0);
      expect(after['invite'], 50);
      expect(after['kick'], 50);
      expect(after['notifications'], {'room': 50});
      // Исходный content не мутирован.
      expect(before['events_default'], 100);
      expect((before['users'] as Map)[mod], 50);
    });

    test('AC:RL-room-owner-transfer/3 передача владения: получателю 100, '
        'себе 99, остальные users не тронуты', () {
      final before = legacyChannelContent({owner: 100, admin: 99, plain: 0});
      final after = transferOwnershipContent(
        before,
        ownerId: owner,
        recipientId: admin,
      );
      expect(after['users'], {owner: 99, admin: 100, plain: 0});
      expect(after['events_default'], 99);
      expect((after['events'] as Map)['m.room.power_levels'], 99);
    });

    test('нормализация не трогает значения > 100 и уже-99', () {
      final after = normalizeOwnerModelThresholds({
        'events_default': 150,
        'state_default': 99,
        'events': {'x': 150, 'y': 100},
      });
      expect(after['events_default'], 150);
      expect(after['state_default'], 99);
      expect(after['events'], {'x': 150, 'y': 99});
    });

    test('AC:RL-room-owner-transfer/14 порог com.liza.chat.topology '
        'остаётся 100 при назначении админа и передаче владения', () {
      final before = legacyChannelContent({owner: 100, mod: 50});
      (before['events'] as Map)['com.liza.chat.topology'] = 100;
      for (final after in [
        promoteToAdminContent(before, mod),
        transferOwnershipContent(before, ownerId: owner, recipientId: mod),
        normalizeOwnerModelThresholds(before),
      ]) {
        final events = after['events'] as Map;
        expect(events['com.liza.chat.topology'], 100);
        expect(events['m.room.power_levels'], 99, reason: 'прочие — 99');
      }
    });

    test('AC:RL-room-owner-transfer/12 потолок экрана «Права»: '
        'users_default ≤ модератор ∀ роль; прочие пороги ≤ min(свой, 99)', () {
      for (final own in [100, 99]) {
        expect(
          permissionThresholdMaxLevel(key: 'users_default', ownPowerLevel: own),
          moderatorPowerLevel,
          reason: 'own=$own: users_default=99 сделал бы админами всех',
        );
        for (final (key, category) in [
          ('events_default', null),
          ('kick', null),
          ('m.room.name', 'events'),
          ('rooms', 'notifications'),
        ]) {
          expect(
            permissionThresholdMaxLevel(
              key: key,
              category: category,
              ownPowerLevel: own,
            ),
            adminPowerLevel,
            reason: '$category/$key own=$own',
          );
        }
      }
      expect(
        permissionThresholdMaxLevel(key: 'users_default', ownPowerLevel: 30),
        30,
      );
      expect(permissionThresholdMaxLevel(key: 'kick', ownPowerLevel: 50), 50);
      // `users_default` внутри events — обычный тип события, не роль.
      expect(
        permissionThresholdMaxLevel(
          key: 'users_default',
          category: 'events',
          ownPowerLevel: 99,
        ),
        adminPowerLevel,
      );
    });

    test('AC:RL-room-owner-transfer/6 «Передать владение» — только '
        'владельцу, на чужом участнике в join, не боту, не владельцу', () {
      bool can({
        int own = 100,
        String caller = owner,
        String target = admin,
        int targetPl = 99,
        bool joined = true,
        bool dm = false,
      }) => canTransferOwnershipTo(
        ownPowerLevel: own,
        callerId: caller,
        targetId: target,
        targetPowerLevel: targetPl,
        targetJoined: joined,
        isDirectChat: dm,
      );
      expect(can(), isTrue);
      expect(can(target: plain, targetPl: 0), isTrue);
      expect(can(own: 99), isFalse, reason: 'админ не передаёт владение');
      expect(can(target: owner), isFalse, reason: 'не себе');
      expect(can(targetPl: 100), isFalse, reason: 'уже владелец');
      expect(can(joined: false), isFalse, reason: 'приглашённый/вышедший');
      expect(can(target: '@liza:example.invalid', targetPl: 0), isFalse);
      expect(can(target: '@support:example.invalid', targetPl: 0), isFalse);
      expect(can(dm: true), isFalse, reason: 'в личке ролей нет');
    });
  });

  group('матрица прав на реальном Room ∀ сущность', () {
    late Client client;
    late String me;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      me = client.userID!;
    });

    tearDown(() async {
      await client.dispose(closeDatabase: true);
    });

    Room makeRoom(Entity entity, Map<String, Object?> powerLevels) {
      final room = Room(id: '!${entity.name}:example.invalid', client: client);
      room.setState(
        Event(
          eventId: '\$create',
          senderId: owner,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          type: EventTypes.RoomCreate,
          content: {
            if (entity == Entity.channel) 'com.liza.chat.type': 'channel',
            if (entity == Entity.subspace || entity == Entity.company)
              'type': 'm.space',
          },
          room: room,
          stateKey: '',
        ),
      );
      room.setState(
        Event(
          eventId: '\$pl',
          senderId: owner,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1001),
          type: EventTypes.RoomPowerLevels,
          content: powerLevels,
          room: room,
          stateKey: '',
        ),
      );
      return room;
    }

    ({bool role, bool kick, bool ban, bool transfer}) gates(
      Room room,
      String target,
    ) {
      final user = User(target, membership: 'join', room: room);
      return (
        role: canChangeMemberPowerLevel(
          callerId: me,
          targetId: target,
          sdkAllows: room.canChangePowerLevel && user.canChangeUserPowerLevel,
        ),
        kick: user.canKick,
        ban: user.canBan,
        transfer: canTransferOwnershipTo(
          ownPowerLevel: room.ownPowerLevel,
          callerId: me,
          targetId: target,
          targetPowerLevel: user.powerLevel,
          targetJoined: true,
          isDirectChat: room.isDirectChat,
        ),
      );
    }

    for (final entity in Entity.values) {
      test('AC:RL-room-owner-transfer/1 [$entity] владелец понижает, '
          'исключает и блокирует админа, передаёт ему владение', () {
        final room = makeRoom(
          entity,
          ownerModelContent({me: 100, admin: 99, mod: 50}),
        );
        for (final target in [admin, mod, plain]) {
          final g = gates(room, target);
          expect(g.role, isTrue, reason: '$entity: права над $target');
          expect(g.kick, isTrue, reason: '$entity: исключить $target');
          expect(g.ban, isTrue, reason: '$entity: заблокировать $target');
          expect(g.transfer, isTrue, reason: '$entity: владение $target');
        }
        final self = gates(room, me);
        expect(self.role || self.kick || self.transfer, isFalse);
      });

      test('AC:RL-room-owner-transfer/2 [$entity] админ НЕ трогает владельца '
          'и другого админа, но управляет модератором', () {
        final room = makeRoom(
          entity,
          ownerModelContent({owner: 100, me: 99, admin2: 99, mod: 50}),
        );
        for (final target in [owner, admin2]) {
          final g = gates(room, target);
          expect(g.role, isFalse, reason: '$entity: права над $target');
          expect(g.kick, isFalse, reason: '$entity: исключить $target');
          expect(g.ban, isFalse, reason: '$entity: заблокировать $target');
          expect(g.transfer, isFalse, reason: '$entity: владение $target');
        }
        final m = gates(room, mod);
        expect(m.role && m.kick && m.ban, isTrue, reason: '$entity: модератор');
        expect(m.transfer, isFalse, reason: 'админ не передаёт владение');
        // Админ-99 — админ для всех клиентских гейтов.
        expect(room.ownPowerLevel >= adminPowerLevel, isTrue);
        expect(room.canHideMembers, isTrue);
      });
    }

    test('AC:RL-room-owner-transfer/10 старая комната: два владельца 100 '
        'равны и друг друга не трогают (как раньше)', () {
      final room = makeRoom(
        Entity.channel,
        legacyChannelContent({me: 100, owner: 100, mod: 50}),
      );
      final g = gates(room, owner);
      expect(g.role || g.kick || g.ban || g.transfer, isFalse);
      final m = gates(room, mod);
      expect(m.role && m.kick && m.transfer, isTrue);
    });
  });

  group('ОДНО событие m.room.power_levels на сервер', () {
    late Client client;
    late FakeMatrixApi api;
    late String me;
    const roomId = '!chan:example.invalid';
    final putPath =
        '/client/v3/rooms/${Uri.encodeComponent(roomId)}/state/m.room.power_levels';

    setUp(() async {
      api = FakeMatrixApi();
      api.api['PUT'] ??= {};
      api.api['PUT']![putPath] = (_) => {'event_id': '\$pl2'};
      client = await prepareTestClient(loggedIn: true, httpClient: api);
      client.backgroundSync = false;
      me = client.userID!;
      FakeMatrixApi.calledEndpoints.clear();
    });

    tearDown(() async {
      await client.dispose(closeDatabase: true);
    });

    Room channel({bool withPowerLevels = true}) {
      final room = Room(id: roomId, client: client);
      if (withPowerLevels) {
        room.setState(
          Event(
            eventId: '\$pl',
            senderId: me,
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
            type: EventTypes.RoomPowerLevels,
            content: legacyChannelContent({me: 100, admin: 99, plain: 0}),
            room: room,
            stateKey: '',
          ),
        );
      }
      return room;
    }

    List<Map<String, dynamic>> putBodies() =>
        (FakeMatrixApi.calledEndpoints[putPath] ?? const [])
            .map((b) => jsonDecode(b as String) as Map<String, dynamic>)
            .toList();

    test('AC:RL-room-owner-transfer/3 transferRoomOwnership: один PUT, '
        'получателю 100, себе 99', () async {
      await transferRoomOwnership(channel(), admin);
      final bodies = putBodies();
      expect(bodies, hasLength(1));
      expect(bodies.single['users'], {me: 99, admin: 100, plain: 0});
      expect(bodies.single['events_default'], 99);
      expect(bodies.single['events']['m.room.power_levels'], 99);
    });

    test('AC:RL-room-owner-transfer/4 promoteMemberToAdmin: один PUT, '
        'цели 99 + нормализация', () async {
      await promoteMemberToAdmin(channel(), plain);
      final bodies = putBodies();
      expect(bodies, hasLength(1));
      expect(bodies.single['users'], {me: 100, admin: 99, plain: 99});
      expect(bodies.single['events']['m.room.history_visibility'], 99);
    });

    test('без загруженного power_levels ничего не шлём (пустой content '
        'стёр бы пороги)', () async {
      await expectLater(
        transferRoomOwnership(channel(withPowerLevels: false), admin),
        throwsStateError,
      );
      expect(putBodies(), isEmpty);
    });
  });

  test('AC:RL-room-owner-transfer/8 в lib/ нет предиката «админ» по '
      'литералу 100', () {
    final bad = RegExp(
      r'(owerLevel|getPowerLevelByUserId\([^)]*\))\s*(>=|<)\s*100\b',
    );
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (bad.hasMatch(lines[i])) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'используй adminPowerLevel/ownerPowerLevel',
    );
  });
}
