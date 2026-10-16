// Уход единственного владельца канала, группы и пространства: передача
// владения одним событием ДО выхода (Надежда 15.10: «Да. Я бы сделала так же»).
//
// ledger:RL-sole-owner-leave-all-exits

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/owner_leave.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:liza/widgets/matrix.dart';

import 'test_client.dart';

// FakeMatrixApi отвечает на PUT state и /leave только для этой комнаты;
// для любой другой PUT power_levels падает (M_UNRECOGNIZED) — так моделируем
// провал передачи.
const _okRoom = '!1234:fakeServer.notExisting';
const _failRoom = '!fail:fakeServer.notExisting';
const _bob = '@bob:fakeServer.notExisting';

enum _Entity { channel, group, subspace }

/// Лёгкий MatrixState: полный Matrix под runAsync поднимает пуши/бейдж,
/// которых в тестовом окружении нет. Утилите нужен только client.
class _TestMatrixState extends MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

void main() {
  group('leaveOwnershipContent', () {
    // AC:RL-sole-owner-leave-all-exits/2
    test('преемнику 100, меня нет в users, пороги 100 → 99', () {
      final out = leaveOwnershipContent(
        {
          'users': {'@me:x': 100, '@bob:x': 50, '@c:x': 0},
          'state_default': 100,
          'kick': 100,
          'events': {'m.room.name': 100},
        },
        ownerId: '@me:x',
        recipientId: '@bob:x',
      );
      final users = out['users'] as Map;
      expect(users['@bob:x'], ownerPowerLevel);
      expect(users.containsKey('@me:x'), isFalse);
      expect(users['@c:x'], 0);
      expect(out['state_default'], adminPowerLevel);
      expect(out['kick'], adminPowerLevel);
      expect((out['events'] as Map)['m.room.name'], adminPowerLevel);
    });
  });

  group('pickOwnerSuccessor', () {
    // AC:RL-sole-owner-leave-all-exits/2
    test('равный PL — первый по id, независимо от порядка', () {
      for (final order in [
        const [
          OwnerSuccessorCandidate('@zed:x', 99),
          OwnerSuccessorCandidate('@abe:x', 99),
        ],
        const [
          OwnerSuccessorCandidate('@abe:x', 99),
          OwnerSuccessorCandidate('@zed:x', 99),
        ],
      ]) {
        expect(pickOwnerSuccessor(order), '@abe:x');
      }
    });
  });

  group('handleSoleOwnerLeave на реальном виджете', () {
    late Client client;
    OwnerLeaveOutcome? lastOutcome;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      client.backgroundSync = false;
      FakeMatrixApi.calledEndpoints.clear();
    });

    tearDown(() async {
      await client.dispose(closeDatabase: true);
    });

    void ignoreAhemOverflow() {
      final defaultOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exception.toString().contains('A RenderFlex overflowed')) {
          return;
        }
        defaultOnError?.call(details);
      };
      addTearDown(() => FlutterError.onError = defaultOnError);
    }

    Event state(
      Room room,
      String type,
      Map<String, Object?> content, {
      String key = '',
    }) => Event(
      eventId: '\$$type$key',
      senderId: client.userID!,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      type: type,
      content: content,
      room: room,
      stateKey: key,
    );

    /// [members] — mxid → PL; я (client.userID) входит всегда.
    Room buildRoom({
      required _Entity entity,
      String id = _okRoom,
      int myLevel = 100,
      Map<String, int> members = const {_bob: 50},
      String? chatType,
      int extraJoined = 0,
    }) {
      final me = client.userID!;
      final all = {me: myLevel, ...members};
      final room = Room(
        id: id,
        client: client,
        membership: Membership.join,
        summary: RoomSummary.fromJson({
          'm.joined_member_count': all.length + extraJoined,
          'm.invited_member_count': 0,
        }),
      );
      room.setState(
        state(room, EventTypes.RoomCreate, {
          'creator': me,
          if (entity == _Entity.channel) 'com.liza.chat.type': channelChatType,
          if (chatType != null) 'com.liza.chat.type': chatType,
          if (entity == _Entity.subspace) 'type': 'm.space',
        }),
      );
      room.setState(state(room, EventTypes.RoomName, {'name': 'Комната'}));
      room.setState(
        state(room, EventTypes.RoomPowerLevels, {
          'users': all,
          'users_default': 0,
          'state_default': 50,
          'events_default': 0,
        }),
      );
      for (final entry in all.entries) {
        room.setState(
          state(room, EventTypes.RoomMember, {
            'membership': 'join',
            'displayname': entry.key == _bob ? 'Боб' : entry.key,
          }, key: entry.key),
        );
      }
      if (entity == _Entity.subspace) {
        // Подпространство: есть родитель-пространство, иначе это корень
        // своей компании (выход скрыт, передача не нужна).
        final parent = Room(
          id: '!parent:fakeServer.notExisting',
          client: client,
          membership: Membership.join,
        );
        parent.setState(
          state(parent, EventTypes.RoomCreate, {'type': 'm.space'}),
        );
        parent.setState(
          state(parent, EventTypes.SpaceChild, {
            'via': ['fakeServer.notExisting'],
          }, key: id),
        );
        client.rooms.add(parent);
      }
      client.rooms.add(room);
      return room;
    }

    /// HTTP фейкового API отвечает в реальном времени, а pump двигает только
    /// фейковые часы: без runAsync цепочка «PUT → leave» встаёт после первого
    /// запроса. Чередуем оба.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
    }

    Future<OwnerLeaveOutcome?> Function() pumpHost(
      WidgetTester tester,
      Room room,
    ) {
      OwnerLeaveOutcome? outcome;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Provider<MatrixState>.value(
              value: _TestMatrixState(client),
              child: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async => outcome = lastOutcome =
                        await handleSoleOwnerLeave(context, room),
                    child: const Text('go'),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      final app = MaterialApp.router(
        locale: const Locale('ru'),
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10n.supportedLocales,
        routerConfig: router,
      );
      return () async {
        ignoreAhemOverflow();
        await tester.pumpWidget(app);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.tap(find.text('go'));
        await settle(tester);
        return outcome;
      };
    }

    Future<void> confirm(WidgetTester tester, String label) async {
      await tester.tap(find.widgetWithText(AdaptiveDialogAction, label));
      await settle(tester);
    }

    Future<void> teardownTree(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 1));
    }

    List<String> calls() => FakeMatrixApi.calledEndpoints.keys.toList();
    int indexOf(String suffix) => calls().indexWhere((k) => k.endsWith(suffix));

    String labelFor(_Entity e) => switch (e) {
      _Entity.channel => 'Покинуть канал',
      _Entity.group => 'Выйти из чата',
      _Entity.subspace => 'Покинуть',
    };

    // AC:RL-sole-owner-leave-all-exits/3
    testWidgets(
      '∀ {канал, группа, подпространство}: PUT power_levels строго до leave',
      (tester) async {
        for (final entity in _Entity.values) {
          FakeMatrixApi.calledEndpoints.clear();
          client.rooms.clear();
          final room = buildRoom(entity: entity);
          final run = pumpHost(tester, room);
          await run();
          expect(
            find.textContaining('владельцем станет Боб'),
            findsOneWidget,
            reason: '$entity',
          );
          await confirm(tester, labelFor(entity));

          final put = indexOf('/state/m.room.power_levels');
          final leave = indexOf('/leave');
          expect(put, isNonNegative, reason: '$entity: передачи нет');
          expect(leave, greaterThan(put), reason: '$entity: leave до передачи');
          final body =
              jsonDecode(
                    FakeMatrixApi.calledEndpoints[calls()[put]]!.first
                        as String,
                  )
                  as Map<String, Object?>;
          final users = body['users'] as Map;
          expect(users[_bob], ownerPowerLevel, reason: '$entity');
          expect(users.containsKey(client.userID), isFalse, reason: '$entity');
          expect(indexOf('/forget'), -1, reason: '$entity');
          await teardownTree(tester);
        }
      },
    );

    // AC:RL-sole-owner-leave-all-exits/4
    testWidgets('провал передачи → leave НЕ уходит', (tester) async {
      for (final entity in _Entity.values) {
        FakeMatrixApi.calledEndpoints.clear();
        client.rooms.clear();
        final room = buildRoom(entity: entity, id: _failRoom);
        final run = pumpHost(tester, room);
        await run();
        await confirm(tester, labelFor(entity));
        expect(indexOf('/state/m.room.power_levels'), isNonNegative);
        expect(indexOf('/leave'), -1, reason: '$entity');
        await tester.tap(find.byType(AdaptiveDialogAction).last);
        await tester.pump(const Duration(seconds: 1));
        await teardownTree(tester);
      }
    });

    // AC:RL-sole-owner-leave-all-exits/4 — список участников не загрузился:
    // НЕ обычный выход (владелец ушёл бы без передачи).
    testWidgets('участники не загрузились → failed, ни передачи, ни leave', (
      tester,
    ) async {
      FakeMatrixApi.calledEndpoints.clear();
      client.rooms.clear();
      // Счётчик в summary больше известных участников → SDK идёт за /members,
      // а для этой комнаты FakeMatrixApi отвечает ошибкой.
      final room = buildRoom(
        entity: _Entity.group,
        id: _failRoom,
        extraJoined: 3,
      );
      lastOutcome = null;
      final run = pumpHost(tester, room);
      await run();
      expect(indexOf('/members'), isNonNegative);
      // Loading-диалог показал ошибку и ждёт закрытия.
      await tester.tap(find.byType(AdaptiveDialogAction).last);
      await settle(tester);
      expect(lastOutcome, OwnerLeaveOutcome.failed);
      expect(indexOf('/leave'), -1);
      expect(indexOf('/state/m.room.power_levels'), -1);
      await teardownTree(tester);
    });

    // AC:RL-sole-owner-leave-all-exits/1
    testWidgets(
      'не единственный владелец / не владелец / обсуждение → notHandled',
      (tester) async {
        final cases = <String, Room Function()>{
          'я админ-99': () => buildRoom(entity: _Entity.group, myLevel: 99),
          'второй владелец': () =>
              buildRoom(entity: _Entity.group, members: const {_bob: 100}),
          'чат обсуждения': () => buildRoom(
            entity: _Entity.group,
            chatType: channelDiscussionChatType,
          ),
        };
        for (final entry in cases.entries) {
          FakeMatrixApi.calledEndpoints.clear();
          client.rooms.clear();
          final run = pumpHost(tester, entry.value());
          expect(await run(), OwnerLeaveOutcome.notHandled, reason: entry.key);
          expect(indexOf('/leave'), -1, reason: entry.key);
          expect(indexOf('/state/m.room.power_levels'), -1, reason: entry.key);
          await teardownTree(tester);
        }
      },
    );

    // AC:RL-sole-owner-leave-all-exits/5
    testWidgets('нет кандидатов: группа — leave без forget, канал — с forget', (
      tester,
    ) async {
      FakeMatrixApi.calledEndpoints.clear();
      client.rooms.clear();
      var run = pumpHost(
        tester,
        buildRoom(entity: _Entity.group, members: const {}),
      );
      await run();
      expect(find.textContaining('Вы последний участник'), findsOneWidget);
      await confirm(tester, 'Выйти из чата');
      expect(indexOf('/leave'), isNonNegative);
      expect(indexOf('/forget'), -1);
      expect(indexOf('/state/m.room.power_levels'), -1);
      await teardownTree(tester);

      FakeMatrixApi.calledEndpoints.clear();
      client.rooms.clear();
      run = pumpHost(
        tester,
        buildRoom(entity: _Entity.channel, members: const {}),
      );
      await run();
      expect(find.textContaining('канал будет удалён'), findsOneWidget);
      await confirm(tester, 'Покинуть канал');
      expect(indexOf('/leave'), isNonNegative);
      await teardownTree(tester);
    });
  });
}
