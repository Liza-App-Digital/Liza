// ledger:RL-room-owner-transfer
//
// Меню действий участника на РЕАЛЬНОМ виджете (showMemberActionsPopupMenu) +
// выбор роли (showPermissionChooser) + бейдж роли в строке участника.
// Кейсы ∀ сущность ∈ {группа, канал, подпространство, компания}.
//
// Red-proof: вернуть `maxLevel: user.room.ownPowerLevel` в меню → AC-5
// (админ видит «Администратор») краснеет; убрать пункт transferOwnership → AC-6.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/participant_list_item.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/member_actions_popup_menu_button.dart';
import 'package:liza/widgets/permission_slider_dialog.dart';

import '../utils/test_client.dart';

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
      // Тестовый шрифт Ahem рисует каждый глиф квадратом во весь кегль:
      // «Заблокировать в пространстве» не влезает в 280px меню. Мельче кегль —
      // проверяем состав пунктов, а не вёрстку.
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: const TextScaler.linear(0.4)),
        child: child!,
      ),
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client, store),
        child: Scaffold(body: Center(child: child)),
      ),
    );

enum Entity { group, channel, subspace, company }

const owner = '@owner:example.invalid';
const admin2 = '@admin2:example.invalid';
const mod = '@mod:example.invalid';
const parentId = '!parent:example.invalid';

void main() {
  late Client client;
  late SharedPreferences store;
  late String me;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    me = client.userID!;
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  Room makeRoom(Entity entity, Map<String, int> users) {
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
        content: {
          'users': users,
          'users_default': 0,
          'events': {'m.room.power_levels': 99},
        },
        room: room,
        stateKey: '',
      ),
    );
    if (entity == Entity.subspace) {
      // Подпространство = дочернее у другого пространства (isCompanySpace).
      final parent = Room(id: parentId, client: client);
      parent.setState(
        Event(
          eventId: '\$pcreate',
          senderId: owner,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
          type: EventTypes.RoomCreate,
          content: {'type': 'm.space'},
          room: parent,
          stateKey: '',
        ),
      );
      parent.setState(
        Event(
          eventId: '\$child',
          senderId: owner,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1002),
          type: EventTypes.SpaceChild,
          content: {
            'via': ['example.invalid'],
          },
          room: parent,
          stateKey: room.id,
        ),
      );
      client.rooms.add(parent);
    }
    return room;
  }

  Future<void> openMenu(WidgetTester tester, User user) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showMemberActionsPopupMenu(context: context, user: user),
            child: const Text('open'),
          ),
        ),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  // Меню рисует Avatar с presence — его таймер обязан истечь до конца теста.
  Future<void> closeAll(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  String kickLabel(Entity e) => switch (e) {
    Entity.group => 'Исключить из чата',
    Entity.channel => 'Исключить из канала',
    Entity.company => 'Исключить из компании',
    Entity.subspace => 'Исключить из пространства',
  };

  // Тип пункта — PopupMenuItem<_MemberActions> (приватный enum), поэтому
  // ищем предка иконки пункта «Права» по предикату.
  bool roleItemEnabled(WidgetTester tester) {
    final item = tester.widget(
      find.ancestor(
        of: find.byIcon(Icons.admin_panel_settings_outlined),
        matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
      ),
    );
    return (item as PopupMenuItem).enabled;
  }

  for (final entity in Entity.values) {
    testWidgets('AC:RL-room-owner-transfer/1 AC:RL-room-owner-transfer/6 '
        '[$entity] владелец на админе: «Права» активны, «Исключить» и '
        '«Передать владение» есть', (tester) async {
      final room = makeRoom(entity, {me: 100, admin2: 99});
      await openMenu(tester, User(admin2, membership: 'join', room: room));
      expect(find.text('Передать владение'), findsOneWidget);
      expect(find.text(kickLabel(entity)), findsOneWidget);
      expect(roleItemEnabled(tester), isTrue);
      // Подзаголовок роли цели.
      expect(find.text('Администратор'), findsOneWidget);
      await closeAll(tester);
    });

    testWidgets('AC:RL-room-owner-transfer/2 [$entity] админ на владельце '
        'и на другом админе: «Права» неактивны, нет «Исключить» и '
        '«Передать владение»', (tester) async {
      final room = makeRoom(entity, {owner: 100, me: 99, admin2: 99});
      for (final target in [owner, admin2]) {
        await openMenu(tester, User(target, membership: 'join', room: room));
        expect(find.text('Передать владение'), findsNothing, reason: target);
        expect(find.text(kickLabel(entity)), findsNothing, reason: target);
        expect(roleItemEnabled(tester), isFalse, reason: target);
        // закрыть меню
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
      }
      await closeAll(tester);
    });
  }

  testWidgets('AC:RL-room-owner-transfer/7 подзаголовок «Владелец» у PL 100', (
    tester,
  ) async {
    final room = makeRoom(Entity.group, {owner: 100, me: 99});
    await openMenu(tester, User(owner, membership: 'join', room: room));
    expect(find.text('Владелец'), findsOneWidget);
    await closeAll(tester);
  });

  // Проводка меню → выбор роли: maxLevel меню = assignableRoleMaxLevel.
  for (final (own, expectAdmin) in const [(99, false), (100, true)]) {
    testWidgets('AC:RL-room-owner-transfer/5 меню «Права» (PL $own) → '
        '«Администратор» ${expectAdmin ? "есть" : "нет"}', (tester) async {
      final room = makeRoom(Entity.group, {owner: 100, me: own, mod: 50});
      await openMenu(tester, User(mod, membership: 'join', room: room));
      await tester.tap(find.text('Права в чате'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Администратор'),
        ),
        expectAdmin ? findsOneWidget : findsNothing,
      );
      // Выбор не делаем: setPower ушёл бы в сеть. Дерево снимает closeAll.
      await closeAll(tester);
    });
  }

  group('AC:RL-room-owner-transfer/5 выбор роли', () {
    Future<List<String>> chooserLabels(
      WidgetTester tester, {
      required int own,
      int current = 0,
    }) async {
      int? picked;
      await tester.pumpWidget(
        _wrap(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showPermissionChooser(
                context,
                currentLevel: current,
                maxLevel: assignableRoleMaxLevel(own),
              ),
              child: const Text('open'),
            ),
          ),
          client,
          store,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final labels = [
        for (final l in ['Администратор', 'Модератор', 'Пользователь'])
          if (find.text(l).evaluate().isNotEmpty) l,
      ];
      if (labels.contains('Администратор')) {
        await tester.tap(find.text('Администратор'));
        await tester.pumpAndSettle();
        expect(picked, adminPowerLevel, reason: '«Администратор» = 99');
      } else {
        await tester.tap(find.text(labels.first));
        await tester.pumpAndSettle();
      }
      expect(find.byType(Dialog), findsNothing);
      return labels;
    }

    // Текущий уровень цели в списке не показывается: цель-пользователь (0)
    // и цель-модератор (50) — оба кейса.
    testWidgets('владелец: Администратор + Модератор/Пользователь', (
      tester,
    ) async {
      expect(await chooserLabels(tester, own: 100), [
        'Администратор',
        'Модератор',
      ]);
      expect(await chooserLabels(tester, own: 100, current: 50), [
        'Администратор',
        'Пользователь',
      ]);
    });

    testWidgets('админ: без «Администратор»', (tester) async {
      expect(await chooserLabels(tester, own: 99), ['Модератор']);
      expect(await chooserLabels(tester, own: 99, current: 50), [
        'Пользователь',
      ]);
    });
  });

  testWidgets('AC:RL-room-owner-transfer/7 бейдж роли: Владелец/'
      'Администратор/Модератор', (tester) async {
    late L10n l10n;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) {
            l10n = L10n.of(context);
            return const SizedBox();
          },
        ),
        client,
        store,
      ),
    );
    await tester.pumpAndSettle();
    expect(memberRoleLabel(l10n, 100), 'Владелец');
    expect(memberRoleLabel(l10n, 99), 'Администратор');
    expect(memberRoleLabel(l10n, 50), 'Модератор');
    expect(memberRoleLabel(l10n, 0), '');
  });
}
