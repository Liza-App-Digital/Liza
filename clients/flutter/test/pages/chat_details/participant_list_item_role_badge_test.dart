// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/participant_list_item.dart';
import 'package:liza/utils/access_admin_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

// Тот же трюк, что в access_admin_panel_test.dart: Avatar безусловно читает
// Matrix.of(context).client, поэтому подменяем геттер client. ParticipantListItem
// дополнительно читает Matrix.of(context).store (StoriesSeenStore) — подменяем
// и его, иначе State.widget падает на несмонтированном виджете.
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._store);

  final Client _client;
  final SharedPreferences _store;

  @override
  Client get client => _client;

  @override
  SharedPreferences get store => _store;
}

Widget _wrap(Widget child, Client client, SharedPreferences store) =>
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client, store),
        child: Scaffold(body: child),
      ),
    );

void main() {
  late Client client;
  late Room room;
  late SharedPreferences store;

  setUp(() async {
    client = await prepareTestClient();
    room = Room(id: '!space:srv', client: client);
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  // powerLevel читается из room-state m.room.power_levels, а не из
  // content самого User-события — прописываем через users-карту комнаты.
  void setPowerLevel(int level) {
    room.setState(
      Event(
        eventId: '\$pl',
        senderId: '@creator:srv',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
        type: EventTypes.RoomPowerLevels,
        content: {
          'users_default': 0,
          'users': {'@bob:srv': level},
        },
        room: room,
        stateKey: '',
      ),
    );
  }

  User user({int powerLevel = 0}) {
    setPowerLevel(powerLevel);
    return User('@bob:srv', membership: 'join', displayName: 'Bob', room: room);
  }

  testWidgets('без spaceMember бейдж роли не рисуется', (tester) async {
    await tester.pumpWidget(_wrap(ParticipantListItem(user()), client, store));
    await tester.pumpAndSettle();
    expect(find.text('Админ компании'), findsNothing);
    expect(find.text('Только в дочерних чатах'), findsNothing);
  });

  testWidgets('членство в компании + PL 99 -> "Админ компании"', (
    tester,
  ) async {
    final member = const SpaceMember(
      userId: '@bob:srv',
      membershipInSpace: 'join',
      maxPowerLevel: 99,
      elevatedRooms: [],
    );
    await tester.pumpWidget(
      _wrap(
        ParticipantListItem(
          user(powerLevel: 99),
          spaceMember: member,
          isCompanyRoom: true,
        ),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Админ компании'), findsOneWidget);
  });

  testWidgets('членство в суб-пространстве + PL 99 -> "Админ пространства"', (
    tester,
  ) async {
    final member = const SpaceMember(
      userId: '@bob:srv',
      membershipInSpace: 'join',
      maxPowerLevel: 99,
      elevatedRooms: [],
    );
    await tester.pumpWidget(
      _wrap(
        ParticipantListItem(
          user(powerLevel: 99),
          spaceMember: member,
          isCompanyRoom: false,
        ),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Админ пространства'), findsOneWidget);
  });

  testWidgets('членство в компании + PL>=50 -> "Модератор компании"', (
    tester,
  ) async {
    final member = const SpaceMember(
      userId: '@bob:srv',
      membershipInSpace: 'join',
      maxPowerLevel: 50,
      elevatedRooms: [],
    );
    await tester.pumpWidget(
      _wrap(
        ParticipantListItem(
          user(powerLevel: 50),
          spaceMember: member,
          isCompanyRoom: true,
        ),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Модератор компании'), findsOneWidget);
  });

  testWidgets(
    'нет членства в пространстве, есть admin в 2 дочерних сущностях -> plural few',
    (tester) async {
      final member = const SpaceMember(
        userId: '@bob:srv',
        membershipInSpace: null,
        maxPowerLevel: 0,
        elevatedRooms: [
          ElevatedRoom(
            roomId: '!a:srv',
            name: 'A',
            powerLevel: 100,
            group: 'chat',
          ),
          ElevatedRoom(
            roomId: '!b:srv',
            name: 'B',
            powerLevel: 100,
            group: 'channel',
          ),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          ParticipantListItem(user(), spaceMember: member, isCompanyRoom: true),
          client,
          store,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Админ в 2 сущностях'), findsOneWidget);
      expect(find.text('Только в дочерних чатах'), findsOneWidget);
    },
  );

  testWidgets('одна дочерняя сущность с PL модератора -> plural one', (
    tester,
  ) async {
    final member = const SpaceMember(
      userId: '@bob:srv',
      membershipInSpace: null,
      maxPowerLevel: 0,
      elevatedRooms: [
        ElevatedRoom(
          roomId: '!a:srv',
          name: 'A',
          powerLevel: 50,
          group: 'chat',
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(
        ParticipantListItem(user(), spaceMember: member, isCompanyRoom: true),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Модератор в 1 сущности'), findsOneWidget);
  });

  testWidgets('обычный участник без elevated ролей -> подписи нет', (
    tester,
  ) async {
    final member = const SpaceMember(
      userId: '@bob:srv',
      membershipInSpace: 'join',
      maxPowerLevel: 0,
      elevatedRooms: [],
    );
    await tester.pumpWidget(
      _wrap(
        ParticipantListItem(user(), spaceMember: member, isCompanyRoom: true),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Админ компании'), findsNothing);
    expect(find.text('Модератор компании'), findsNothing);
    expect(find.text('Только в дочерних чатах'), findsNothing);
  });
  // ledger:RL-room-owner-transfer — AC-15: PL 100 подписан «Владелец компании/пространства», а не
  // «Админ компании/пространства» ∀ {компания, подпространство}.
  for (final isCompany in [true, false]) {
    testWidgets(
      'AC:RL-room-owner-transfer/15 PL 100 в '
      '${isCompany ? 'компании' : 'подпространстве'} -> "Владелец компании/пространства"',
      (tester) async {
        final member = const SpaceMember(
          userId: '@bob:srv',
          membershipInSpace: 'join',
          maxPowerLevel: 100,
          elevatedRooms: [],
        );
        await tester.pumpWidget(
          _wrap(
            ParticipantListItem(
              user(powerLevel: 100),
              spaceMember: member,
              isCompanyRoom: isCompany,
            ),
            client,
            store,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Владелец'), findsOneWidget);
        expect(find.text('Админ компании'), findsNothing);
        expect(find.text('Админ пространства'), findsNothing);
      },
    );
  }
}
