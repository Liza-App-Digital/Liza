// Страж выбора «Где создать» на РЕАЛЬНОМ экране «Создать группу» (задача 10
// newInterface). Постановщик (Надежда Розенталь, 14.10): «Им нужно, чтобы
// группу можно было создать именно в конкретной группе (выбрать, где создавать
// в моменте создания группы)».
//
// Ассерты — по виджету NewGroup и по ТЕЛАМ запросов FakeMatrixApi: выбранное
// место обязано попасть в m.space.parent (initial_state) и в PUT m.space.child,
// иначе single_space_guard вложит группу в главное пространство сервера
// создателя.
//
// ledger:RL-new-group-place-picker
// ledger:RL-company-create-rights

// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_group/new_group.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/create_group_in_space.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

const _companyA = '!alpha:example.invalid';
const _companyB = '!beta:example.invalid';
const _subB = '!beta-sub:example.invalid';
const _createdEncoded = '!1234%3AfakeServer.notExisting';

final _picker = find.byKey(const ValueKey('newGroupPlacePicker'));

/// Класс сервера известен: общий (company=false) или компания с главным
/// пространством [mainId].
class _KnownClassService extends SingleSpaceService {
  _KnownClassService(super.client, {required this.company, this.mainId});

  final bool company;
  final String? mainId;

  @override
  Future<({bool exists, String? roomId})> fetch() async =>
      (exists: mainId != null, roomId: mainId);

  @override
  bool get instanceClassKnown => true;

  @override
  bool get isCompanyInstance => company;

  @override
  String? get mainRootSpaceId => mainId;
}

class _TestMatrixState extends MatrixState {
  _TestMatrixState(this._client, this._spaces, this._store);

  final Client _client;
  final SingleSpaceService _spaces;
  final SharedPreferences _store;

  @override
  Client get client => _client;

  @override
  SingleSpaceService get singleSpaceService => _spaces;

  @override
  SharedPreferences get store => _store;
}

void main() {
  late Client client;
  late SharedPreferences store;
  late FakeMatrixApi api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeMatrixApi();
    api.api['PUT'] ??= {};
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
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

  void addSpace(
    String id,
    String name, {
    List<String> children = const [],
    int myLevel = 100,
    bool partial = false,
  }) {
    final room = Room(id: id, client: client);
    state(room, EventTypes.RoomCreate, {'type': 'm.space'});
    state(room, EventTypes.RoomName, {'name': name});
    state(room, EventTypes.RoomPowerLevels, {
      'users': {client.userID!: myLevel},
      'users_default': 0,
      'state_default': 50,
    });
    for (final c in children) {
      state(room, EventTypes.SpaceChild, {
        'via': ['example.invalid'],
      }, c);
    }
    // Состояние собрано целиком (как после postLoad): экран не ждёт БД.
    room.partial = partial;
    client.rooms.add(room);
  }

  String childPut(String parentId) =>
      '/client/v3/rooms/${Uri.encodeComponent(parentId)}'
      '/state/m.space.child/$_createdEncoded';

  Future<void> pumpNewGroup(
    WidgetTester tester, [
    CreateGroupType type = CreateGroupType.group,
  ]) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: const [
          L10n.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: L10n.supportedLocales,
        home: Matrix(
          clients: [client],
          store: store,
          child: NewGroup(createGroupType: type),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> teardownScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(_picker);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// Цепочка createRoom → PUT m.space.child идёт через БД клиента (реальный
  /// I/O), который под fake-async виджет-теста не продвигается: чередуем
  /// реальное ожидание и прокрутку фейкового времени (waitForRoomInSync крутит
  /// oneShotSync до 5 с — созданной комнаты в фейковом sync нет).
  Future<void> settleRequests(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(seconds: 1));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
    }
  }

  Future<void> submit(WidgetTester tester, String name) async {
    FakeMatrixApi.calledEndpoints.clear();
    await tester.enterText(find.byType(TextField).first, name);
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await settleRequests(tester);
    // Переход на /invite без GoRouter в обёртке бросает — не предмет теста.
    tester.takeException();
  }

  /// Тела createRoom групп. Виджет Matrix в фоне заводит DM с ботом Лизой
  /// (`is_direct`) — к экрану не относится, отсеиваем.
  List<Map<String, dynamic>> groupCreateBodies() => [
    for (final b
        in FakeMatrixApi.calledEndpoints['/client/v3/createRoom'] ?? const [])
      if (jsonDecode(b as String) case final Map<String, dynamic> body
          when body['is_direct'] != true)
        body,
  ];

  Map<String, dynamic> createRoomBody() {
    final bodies = groupCreateBodies();
    expect(bodies, hasLength(1), reason: 'createRoom должен уйти ровно 1 раз');
    return bodies.single;
  }

  List<Map<String, dynamic>> initialState(Map<String, dynamic> body) =>
      ((body['initial_state'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  group('видимость выбора — AC:RL-new-group-place-picker/1', () {
    testWidgets('baseline фейкового клиента: своих мест нет', (tester) async {
      expect(groupPlaces(client.rooms), isEmpty);
    });

    testWidgets('мест 0 — выбора нет', (tester) async {
      await pumpNewGroup(tester);
      expect(_picker, findsNothing);
      await teardownScreen(tester);
    });

    testWidgets('мест 1 — выбора нет', (tester) async {
      addSpace(_companyA, 'Альфа');
      await pumpNewGroup(tester);
      expect(_picker, findsNothing);
      await teardownScreen(tester);
    });

    testWidgets('мест 2 — выбор виден, по умолчанию «Автоматически»', (
      tester,
    ) async {
      addSpace(_companyA, 'Альфа');
      addSpace(_companyB, 'Бета');
      await pumpNewGroup(tester);
      expect(_picker, findsOneWidget);
      expect(find.text('Где создать'), findsOneWidget);
      expect(find.text('Автоматически'), findsOneWidget);
      await teardownScreen(tester);
    });

    for (final type in [CreateGroupType.channel, CreateGroupType.space]) {
      testWidgets('${type.name}: выбора нет даже при 2 местах', (tester) async {
        addSpace(_companyA, 'Альфа');
        addSpace(_companyB, 'Бета');
        await pumpNewGroup(tester, type);
        expect(_picker, findsNothing);
        await teardownScreen(tester);
      });
    }
  });

  // AC:RL-new-group-place-picker/3 — ∀ выбранное место ∈ {компания,
  // подпространство}.
  for (final (label, placeId) in const [
    ('Бета', _companyB),
    ('Бета › Отдел Беты', _subB),
  ]) {
    testWidgets('выбрано «$label»: m.space.parent и PUT m.space.child — '
        'в выбранное место, invite:50', (tester) async {
      addSpace(_companyA, 'Альфа');
      addSpace(_companyB, 'Бета', children: [_subB]);
      addSpace(_subB, 'Отдел Беты');
      api.api['PUT']![childPut(placeId)] = (_) => {'event_id': '\$child'};

      await pumpNewGroup(tester);
      await choose(tester, label);
      await submit(tester, 'Отдел');

      final body = createRoomBody();
      expect(body['name'], 'Отдел');
      expect(body['preset'], 'private_chat');
      expect(body['visibility'], 'private');
      expect(
        (body['power_level_content_override'] as Map)['invite'],
        moderatorPowerLevel,
      );
      final parents = initialState(
        body,
      ).where((e) => e['type'] == 'm.space.parent').toList();
      expect(parents, hasLength(1));
      expect(parents.single['state_key'], placeId);

      final links = FakeMatrixApi.calledEndpoints.keys
          .where((k) => k.contains('/state/m.space.child/'))
          .toList();
      expect(links, [childPut(placeId)]);
      await teardownScreen(tester);
    });
  }

  testWidgets('выбрано место после «Публичная группа»: свитч скрыт, '
      'тело private_chat без join_rules — AC:RL-new-group-place-picker/4', (
    tester,
  ) async {
    addSpace(_companyA, 'Альфа');
    addSpace(_companyB, 'Бета');
    api.api['PUT']![childPut(_companyB)] = (_) => {'event_id': '\$child'};

    await pumpNewGroup(tester);
    await tester.tap(find.text('Публичная группа'));
    await tester.pumpAndSettle();
    await choose(tester, 'Бета');
    expect(find.text('Публичная группа'), findsNothing);
    await submit(tester, 'Отдел');

    final body = createRoomBody();
    expect(body['preset'], 'private_chat');
    expect(body['visibility'], 'private');
    // LABA-2539: никаких restricted-правил к чужому пространству.
    expect(
      initialState(body).where((e) => e['type'] == 'm.room.join_rules'),
      isEmpty,
    );
    await teardownScreen(tester);
  });

  testWidgets('«Автоматически» — как до фичи: без m.space.parent и без PUT '
      'm.space.child — AC:RL-new-group-place-picker/5', (tester) async {
    addSpace(_companyA, 'Альфа');
    addSpace(_companyB, 'Бета');

    await pumpNewGroup(tester);
    await submit(tester, 'Отдел');

    final body = createRoomBody();
    expect(
      initialState(body).where((e) => e['type'] == 'm.space.parent'),
      isEmpty,
    );
    expect(
      (body['power_level_content_override'] as Map)['invite'],
      moderatorPowerLevel,
    );
    expect(
      FakeMatrixApi.calledEndpoints.keys.where(
        (k) => k.contains('/state/m.space.child/'),
      ),
      isEmpty,
    );
    await teardownScreen(tester);
  });

  testWidgets('двойной тап «Создать» — один createRoom '
      '— AC:RL-new-group-place-picker/6', (tester) async {
    addSpace(_companyA, 'Альфа');
    addSpace(_companyB, 'Бета');
    api.api['PUT']![childPut(_companyB)] = (_) => {'event_id': '\$child'};

    await pumpNewGroup(tester);
    await choose(tester, 'Бета');
    FakeMatrixApi.calledEndpoints.clear();
    await tester.enterText(find.byType(TextField).first, 'Отдел');
    await tester.pump();
    await tester.tap(find.byType(ElevatedButton));
    await tester.tap(find.byType(ElevatedButton));
    await settleRequests(tester);
    tester.takeException();

    expect(groupCreateBodies(), hasLength(1));
    await teardownScreen(tester);
  });

  // AC:RL-company-create-rights/5 — после холодного старта пространства
  // partial: «Создать» и выбор ждут postLoad и после него оживают.
  testWidgets('partial-пространства: «Создать» ждёт postLoad, потом активна', (
    tester,
  ) async {
    addSpace(_companyA, 'Альфа', partial: true);
    addSpace(_companyB, 'Бета', partial: true);
    await pumpNewGroup(tester);
    ElevatedButton button() =>
        tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(button().onPressed, isNull, reason: 'до postLoad права неизвестны');
    for (var i = 0; i < 5 && button().onPressed == null; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(button().onPressed, isNotNull);
    expect(_picker, findsOneWidget);
    await teardownScreen(tester);
  });

  // AC:RL-new-group-place-picker/10 — реальный экран, класс сервера известен.
  group('класс сервера: показ и подпись первого пункта', () {
    Future<void> pumpWithClass(
      WidgetTester tester, {
      required bool company,
      String? mainId,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: const [
            L10n.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: L10n.supportedLocales,
          home: Provider<MatrixState>.value(
            value: _TestMatrixState(
              client,
              _KnownClassService(client, company: company, mainId: mainId),
              store,
            ),
            child: const NewGroup(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    const ownRoot = '!own:fakeServer.notExisting';

    void ownRootEvents(String key, int level) {
      final room = client.getRoomById(ownRoot)!;
      final pl = Map<String, Object?>.from(
        room.getState(EventTypes.RoomPowerLevels)!.content,
      );
      state(room, EventTypes.RoomPowerLevels, {
        ...pl,
        'events': {key: level},
      });
    }

    testWidgets('общий сервер + место в компании: выбор с «Для себя»', (
      tester,
    ) async {
      addSpace(_companyB, 'Бета');
      await pumpWithClass(tester, company: false);
      expect(_picker, findsOneWidget);
      expect(find.text('Для себя (друзья, семья)'), findsOneWidget);
      expect(find.text('Автоматически'), findsNothing);
      await teardownScreen(tester);
    });

    testWidgets('компания, места только свои — выбора нет', (tester) async {
      addSpace(ownRoot, 'Своя', children: [_subB]);
      addSpace(_subB, 'Отдел');
      await pumpWithClass(tester, company: true, mainId: ownRoot);
      expect(_picker, findsNothing);
      await teardownScreen(tester);
    });

    testWidgets('компания + место в чужой: выбор с «В своей компании»', (
      tester,
    ) async {
      addSpace(ownRoot, 'Своя');
      addSpace(_companyB, 'Бета');
      await pumpWithClass(tester, company: true, mainId: ownRoot);
      expect(_picker, findsOneWidget);
      expect(find.text('В своей компании'), findsOneWidget);
      await teardownScreen(tester);
    });

    // AC:RL-company-create-rights/6 — без порога «Создание чатов» своей
    // компании сервер группу туда не вложит: первый пункт «Для себя», корня
    // своей компании среди мест нет; ∀ {место в чужой, своё подпространство}.
    testWidgets('компания без права + место в чужой: «Для себя», '
        'своей компании в списке нет', (tester) async {
      addSpace(ownRoot, 'Своя', myLevel: 0);
      addSpace(_companyB, 'Бета');
      await pumpWithClass(tester, company: true, mainId: ownRoot);
      expect(_picker, findsOneWidget);
      expect(find.text('Для себя (друзья, семья)'), findsOneWidget);
      expect(find.text('В своей компании'), findsNothing);
      await tester.tap(_picker);
      await tester.pumpAndSettle();
      expect(find.text('Своя'), findsNothing);
      expect(find.text('Бета'), findsWidgets);
      await tester.tap(find.text('Для себя (друзья, семья)').last);
      await tester.pumpAndSettle();
      await teardownScreen(tester);
    });

    testWidgets('компания без права + своё подпространство с правом: '
        'выбор с «Для себя»', (tester) async {
      addSpace(ownRoot, 'Своя', myLevel: 0, children: [_subB]);
      addSpace(_subB, 'Отдел');
      await pumpWithClass(tester, company: true, mainId: ownRoot);
      expect(_picker, findsOneWidget);
      expect(find.text('Для себя (друзья, семья)'), findsOneWidget);
      await teardownScreen(tester);
    });

    testWidgets('компания, порог «Создание чатов» открыт рядовым (0): '
        '«В своей компании»', (tester) async {
      addSpace(ownRoot, 'Своя', myLevel: 0, children: [_subB]);
      ownRootEvents(companyCreateChatKey, 0);
      addSpace(_companyB, 'Бета');
      await pumpWithClass(tester, company: true, mainId: ownRoot);
      expect(find.text('В своей компании'), findsOneWidget);
      await teardownScreen(tester);
    });
  });
}
