// Экран «Права» главного пространства своей компании: секция «Создание в
// компании» с порогами com.liza.space.create_chat / create_channel (задача 12
// newInterface; Надежда 18.10: «Добавить пункт, кому можно создавать чаты. И
// отдельно каналы и боты»). Умолчание — модератор (держит сервер).
//
// ledger:RL-company-create-rights
// AC:RL-company-create-rights/7

// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:liza/pages/chat_permissions_settings/chat_permissions_settings_view.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

const _roomId = '!company:fakeServer.notExisting';

class _Edit {
  _Edit(this.key, this.current, this.newLevel, this.category);
  final String key;
  final int current;
  final int? newLevel;
  final String? category;
}

class _FakePermsController extends ChatPermissionsSettingsController {
  final edits = <_Edit>[];

  @override
  String? get roomId => _roomId;

  @override
  Stream get onChanged => const Stream.empty();

  @override
  // ignore: must_call_super
  void initState() {}

  @override
  void editPowerLevel(
    BuildContext context,
    String key,
    int currentLevel, {
    int? newLevel,
    String? category,
  }) => edits.add(_Edit(key, currentLevel, newLevel, category));
}

class _MainIdService extends SingleSpaceService {
  _MainIdService(super.client, this.mainId);
  final String? mainId;
  @override
  String? get mainRootSpaceId => mainId;
}

class _FakeMatrixState extends liza_matrix.MatrixState {
  _FakeMatrixState(this._client, this._service);
  final Client _client;
  final SingleSpaceService _service;
  @override
  Client get client => _client;
  @override
  SingleSpaceService get singleSpaceService => _service;
}

void main() {
  late Client client;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  void addRoom({bool isSpace = true, Map<String, Object?> events = const {}}) {
    final room = Room(id: _roomId, client: client, membership: Membership.join);
    room.setState(
      Event(
        eventId: '\$create',
        senderId: client.userID!,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(100),
        type: EventTypes.RoomCreate,
        content: {if (isSpace) 'type': 'm.space'},
        room: room,
        stateKey: '',
      ),
    );
    room.setState(
      Event(
        eventId: '\$pl',
        senderId: client.userID!,
        originServerTs: DateTime.fromMillisecondsSinceEpoch(200),
        type: EventTypes.RoomPowerLevels,
        content: {
          'users': {client.userID!: 100},
          'users_default': 0,
          'events_default': 100,
          'state_default': 50,
          'events': events,
        },
        room: room,
        stateKey: '',
      ),
    );
    client.rooms.add(room);
  }

  Future<_FakePermsController> pump(
    WidgetTester tester, {
    required String? mainId,
  }) async {
    final controller = _FakePermsController();
    // Экран целиком на одном «листе»: без прокрутки все строки в дереве.
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Provider<liza_matrix.MatrixState>.value(
        value: _FakeMatrixState(client, _MainIdService(client, mainId)),
        child: MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(body: ChatPermissionsSettingsView(controller)),
        ),
      ),
    );
    // Делегат L10n грузится асинхронно — до него дерево пустое.
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('главное своей компании: секция, обе строки, без ключа — '
      '«Модератор»', (tester) async {
    addRoom();
    await pump(tester, mainId: _roomId);
    final section = find.text('Создание в компании');
    expect(section, findsOneWidget);
    for (final label in ['Создание чатов', 'Создание каналов']) {
      final row = find.text(label);
      expect(row, findsOneWidget);
      final tile = find.ancestor(of: row, matching: find.byType(Padding)).first;
      expect(
        find.descendant(of: tile, matching: find.text('Модератор')),
        findsOneWidget,
        reason: '$label: ключа нет — умолчание сервера 50',
      );
    }
  });

  testWidgets('«Пользователь» в «Создание чатов» пишет '
      'events[com.liza.space.create_chat] = 0', (tester) async {
    addRoom();
    final controller = await pump(tester, mainId: _roomId);
    final row = find.text('Создание чатов');
    final tile = find.ancestor(of: row, matching: find.byType(Padding)).first;
    await tester.tap(
      find.descendant(of: tile, matching: find.text('Модератор')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Пользователь').last);
    await tester.pumpAndSettle();
    expect(controller.edits, hasLength(1));
    final edit = controller.edits.single;
    expect(edit.key, companyCreateChatKey);
    expect(edit.category, 'events');
    expect(edit.newLevel, 0);
    expect(edit.current, defaultCompanyCreateLevel);
  });

  testWidgets('заданный порог показывается как есть, ключ не дублируется '
      'в общем списке', (tester) async {
    addRoom(events: {companyCreateChannelKey: 99});
    await pump(tester, mainId: _roomId);
    final row = find.text('Создание каналов');
    expect(row, findsOneWidget);
    final tile = find.ancestor(of: row, matching: find.byType(Padding)).first;
    expect(
      find.descendant(of: tile, matching: find.text('Администратор')),
      findsOneWidget,
    );
  });

  // ∀ {чужое пространство, главное ещё не известно, обычная группа} — секции нет.
  for (final (label, mainId, isSpace) in const [
    ('не главное своей компании', '!other:fakeServer.notExisting', true),
    ('mainRootSpaceId ещё null', null, true),
    ('обычная группа', '!other:fakeServer.notExisting', false),
  ]) {
    testWidgets('$label — секции нет', (tester) async {
      addRoom(isSpace: isSpace);
      await pump(tester, mainId: mainId);
      expect(
        find.text('Создание в компании', skipOffstage: false),
        findsNothing,
      );
      expect(find.text('Создание чатов', skipOffstage: false), findsNothing);
    });
  }

  testWidgets('сырых ключей нет: m.space.child / m.space.parent подписаны, '
      'служебные скрыты', (tester) async {
    addRoom(
      events: {
        EventTypes.SpaceChild: 50,
        EventTypes.SpaceParent: 100,
        'com.liza.chat.topology': 50,
        companyCreateChatKey: 0,
      },
    );
    await pump(tester, mainId: _roomId);
    for (final raw in [
      EventTypes.SpaceChild,
      EventTypes.SpaceParent,
      'com.liza.chat.topology',
      companyCreateChatKey,
      companyCreateChannelKey,
    ]) {
      expect(find.text(raw, skipOffstage: false), findsNothing, reason: raw);
    }
    expect(
      find.text('Добавлять и убирать чаты', skipOffstage: false),
      findsOneWidget,
    );
    expect(
      find.text('Указывать родительское пространство', skipOffstage: false),
      findsOneWidget,
    );
  });
}
