// Страж задачи 13 (спека 2026-10-14-search-sections-and-company-invite-admin-only):
// в компании приглашают только те, кому разрешено настройкой (по умолчанию —
// админы); кнопка видна всем, без права — плашка «У вас недостаточно прав для
// приглашения пользователей». На общем инстансе (users.liza.ru) и на старом
// сервере без поля `company` — поведение прежнее.
//
// Входы проверяются на РЕАЛЬНЫХ функциях/виджетах: LizaShare.shareInvitePeople
// и shareInviteLink («Пригласить людей», ссылка в Лизу), реальный SpaceView (⋮
// → «Пригласить»), гейт ensureCanInviteToSpace, через который идут оба входа
// деталей пространства (chat_details_view.dart — экран требует полного
// контроллера, поэтому его проводка закреплена source-ассертом ниже).
//
// Red-proof: убрать `if (!ensureCanInviteToLiza(context)) return;` из
// liza_share.dart → падают кейсы «участник компании» обоих входов (плашки нет,
// открывается загрузка); заменить `showInvite` на `canSeeMembers` в
// space_view.dart → падает «участник компании видит Пригласить»; вернуть
// `company` → false в SingleSpaceService → падает разбор поля.
//
// ledger:RL-space-invite-admin-only
// AC:RL-space-invite-admin-only/1 AC:RL-space-invite-admin-only/2
// AC:RL-space-invite-admin-only/3 AC:RL-space-invite-admin-only/4
// AC:RL-space-invite-admin-only/5 AC:RL-space-invite-admin-only/6
// guard.render:real-widget

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/space_view.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/company_invite_gate.dart';
import 'package:liza/utils/knock_requests.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import 'test_client.dart';

const _notAllowed = 'У вас недостаточно прав для приглашения пользователей';

class _FakeSingleSpaceService extends SingleSpaceService {
  _FakeSingleSpaceService(super.client, {required this.company, this.mainId});

  final bool company;
  final String? mainId;

  @override
  Future<({bool exists, String? roomId})> fetch() async =>
      (exists: mainId != null, roomId: mainId);

  @override
  bool get isCompanyInstance => company;

  @override
  String? get mainRootSpaceId => mainId;
}

class _TestMatrixState extends liza_matrix.MatrixState {
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Client client;
  late FakeMatrixApi api;
  late SharedPreferences store;
  var ts = 1000;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = FakeMatrixApi();
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    store = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  String userDomain() => client.userID!.domain!;

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

  /// Пространство, в котором пользователь состоит с уровнем [ownLevel] при
  /// пороге [invite].
  Room addSpace(
    String id, {
    required int ownLevel,
    int? invite,
    List<String> children = const [],
  }) {
    final room = Room(id: id, client: client, membership: Membership.join);
    state(room, EventTypes.RoomCreate, {'type': 'm.space'});
    state(room, EventTypes.RoomName, {'name': 'Компания'});
    state(room, EventTypes.RoomPowerLevels, {
      'users': {client.userID!: ownLevel},
      'users_default': 0,
      if (invite != null) 'invite': invite,
    });
    for (final c in children) {
      state(room, EventTypes.SpaceChild, {
        'via': [userDomain()],
      }, c);
    }
    client.rooms.add(room);
    return room;
  }

  group('умолчание при создании — AC:RL-space-invite-admin-only/1', () {
    test('компания: events_default 100, invite 99', () {
      expect(spacePowerLevelOverride(companyInstance: true), {
        'events_default': 100,
        'invite': adminPowerLevel,
      });
      expect(adminPowerLevel, 99);
    });

    test('общий инстанс: invite не задаётся (preset), events_default 100', () {
      expect(spacePowerLevelOverride(companyInstance: false), {
        'events_default': 100,
      });
    });

    test('модель владельца: нормализация не трогает invite 99, админ вправе '
        'выставить «только админы»', () {
      final normalized = normalizeOwnerModelThresholds({
        ...spacePowerLevelOverride(companyInstance: true),
        'users': {'@o:x': 100},
      });
      expect(normalized['invite'], 99);
      expect(normalized['events_default'], 99);
      for (final own in [adminPowerLevel, ownerPowerLevel]) {
        expect(
          permissionThresholdMaxLevel(key: 'invite', ownPowerLevel: own),
          99,
        );
      }
    });
  });

  test('скилл /liza-company создаёт главное пространство с тем же '
      'override (AC:RL-space-invite-admin-only/1)', () {
    final skill = File(
      '../../.claude/skills/liza-company/SKILL.md',
    ).readAsStringSync();
    final body = skill
        .split('\n')
        .firstWhere((l) => l.contains("'creation_content':{'type':'m.space'}"));
    expect(
      body,
      contains(
        "'power_level_content_override':{'events_default':100,'invite':99}",
      ),
    );
  });

  group('таблица гейта', () {
    test('плашка только в пространстве компании без права', () {
      expect(companyInviteBlocked(companySpace: true, canInvite: false), true);
      expect(companyInviteBlocked(companySpace: true, canInvite: true), false);
      expect(
        companyInviteBlocked(companySpace: false, canInvite: false),
        false,
      );
      expect(companyInviteBlocked(companySpace: false, canInvite: true), false);
    });

    test('класс — по домену КОРНЯ: подпространство с чужого домена внутри '
        'своей компании — компания; корень на чужом домене — нет', () {
      final root = '!root:${userDomain()}';
      const foreignSub = '!sub:other.invalid';
      addSpace(root, ownLevel: 0, invite: 99, children: [foreignSub]);
      final sub = addSpace(foreignSub, ownLevel: 0, invite: 99);
      final foreignRoot = addSpace('!f:other.invalid', ownLevel: 0);

      expect(companyRootOf(sub).id, root);
      expect(isOwnCompanySpace(sub, companyInstance: true), isTrue);
      expect(isOwnCompanySpace(sub, companyInstance: false), isFalse);
      expect(isOwnCompanySpace(foreignRoot, companyInstance: true), isFalse);
    });

    test('цикл m.space.child не зацикливает поиск корня', () {
      final a = '!a:${userDomain()}';
      final b = '!b:${userDomain()}';
      addSpace(a, ownLevel: 0, children: [b]);
      final rb = addSpace(b, ownLevel: 0, children: [a]);
      expect(companyRootOf(rb).id, anyOf(a, b));
    });
  });

  group('заявки — AC:RL-space-invite-admin-only/6', () {
    test('порог max(50, invite)', () {
      expect(knockReviewThreshold(null), 50);
      expect(knockReviewThreshold(0), 50);
      expect(knockReviewThreshold(50), 50);
      expect(knockReviewThreshold(99), 99);
    });

    test('модератор при invite 99 заявок не видит, админ видит; при invite 0 '
        'модератор видит', () {
      final d = userDomain();
      expect(
        canReviewKnockRequests(addSpace('!m99:$d', ownLevel: 50, invite: 99)),
        isFalse,
      );
      expect(
        canReviewKnockRequests(addSpace('!a99:$d', ownLevel: 99, invite: 99)),
        isTrue,
      );
      expect(
        canReviewKnockRequests(addSpace('!m0:$d', ownLevel: 50, invite: 0)),
        isTrue,
      );
      expect(
        canReviewKnockRequests(addSpace('!u0:$d', ownLevel: 0, invite: 0)),
        isFalse,
      );
    });
  });

  test('SingleSpaceService читает поле company; нет поля → false '
      '(AC:RL-space-invite-admin-only/4)', () async {
    for (final (body, expected) in [
      ('{"exists":true,"room_id":"!r:x","company":true}', true),
      ('{"exists":true,"room_id":"!r:x","company":false}', false),
      ('{"exists":true,"room_id":"!r:x"}', false),
    ]) {
      final service = SingleSpaceService(client);
      await http.runWithClient(
        service.fetch,
        () => MockClient((req) async {
          expect(req.url.path, '/_synapse/client/single_space/v1/root');
          return http.Response(body, 200);
        }),
      );
      expect(service.isCompanyInstance, expected, reason: body);
    }
  });

  // ── входы ──────────────────────────────────────────────────────────────

  Widget app(Widget home, {required bool company, String? mainId}) {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, state) => home),
        GoRoute(
          path: '/rooms/:roomId/invite',
          builder: (context, state) => const Scaffold(body: Text('INVITE')),
        ),
        GoRoute(
          path: '/rooms/:roomId',
          builder: (context, state) => const Scaffold(body: Text('ROOM')),
        ),
      ],
    );
    return Provider<liza_matrix.MatrixState>.value(
      value: _TestMatrixState(
        client,
        _FakeSingleSpaceService(client, company: company, mainId: mainId),
        store,
      ),
      child: MaterialApp.router(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        routerConfig: router,
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  // Три роли × два входа в Лизу. Компания-участник — плашка, приглашение не
  // создаётся (нет диалога загрузки createUserInvite); админ и общий
  // инстанс — обычный поток (диалог загрузки).
  const roles = <(String, bool, int, bool)>[
    // (кейс, company, ownLevel, ожидается плашка)
    ('компания, участник PL0', true, 0, true),
    ('компания, модератор PL50', true, 50, true),
    ('компания, админ PL99', true, 99, false),
    ('общий инстанс, участник PL0', false, 0, false),
  ];

  for (final entry in <(String, Future<void> Function(BuildContext))>[
    ('«Пригласить людей»', LizaShare.shareInvitePeople),
    ('ссылка в Лизу', LizaShare.shareInviteLink),
  ]) {
    for (final (label, company, own, blocked) in roles) {
      testWidgets(
        '${entry.$1}: $label → ${blocked ? 'плашка' : 'поток'} '
        '(AC:RL-space-invite-admin-only/${blocked ? 2 : (company ? 3 : 4)})',
        (tester) async {
          final mainId = '!main:${userDomain()}';
          addSpace(mainId, ownLevel: own, invite: 99);
          await tester.pumpWidget(
            app(
              Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => entry.$2(context),
                    child: const Text('GO'),
                  ),
                ),
              ),
              company: company,
              mainId: mainId,
            ),
          );
          await settle(tester);
          await tester.tap(find.text('GO'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));

          expect(
            find.text(_notAllowed),
            blocked ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(Dialog),
            blocked ? findsNothing : findsWidgets,
            reason: 'диалог загрузки = вызван createUserInvite',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          await settle(tester);
        },
      );
    }
  }

  // Реальный SpaceView: ⋮ → «Пригласить».
  const spaceRoles = <(String, bool, int, bool, String)>[
    // (кейс, company, ownLevel, пункт виден, результат тапа)
    ('компания, участник PL0', true, 0, true, _notAllowed),
    ('компания, админ PL99', true, 99, true, 'INVITE'),
    ('общий инстанс, участник PL0', false, 0, false, ''),
    ('общий инстанс, модератор PL50', false, 50, true, 'INVITE'),
  ];
  for (final (label, company, own, visible, outcome) in spaceRoles) {
    testWidgets('⋮ пространства: $label', (tester) async {
      // Ширина PopupMenu ограничена, а тестовый шрифт Ahem шире реального —
      // переполнение строк меню к гейту отношения не имеет.
      final onError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (details.exceptionAsString().contains('RenderFlex overflowed')) {
          return;
        }
        onError?.call(details);
      };
      addTearDown(() => FlutterError.onError = onError);
      final spaceId = '!space:${userDomain()}';
      addSpace(spaceId, ownLevel: own, invite: company ? 99 : 0);
      // Иначе ошибка /hierarchy встанет снэкбаром в очередь перед плашкой.
      api.api['GET']!['/client/v1/rooms/${Uri.encodeComponent(spaceId)}'
          '/hierarchy?suggested_only=false&max_depth=2'] = (_) => {
        'rooms': [],
      };
      await tester.pumpWidget(
        app(
          SpaceView(
            spaceId: spaceId,
            onBack: () {},
            onChatTab: (_) {},
            activeChat: null,
          ),
          company: company,
          mainId: spaceId,
        ),
      );
      await settle(tester);
      await tester.tap(find.byType(PopupMenuButton<SpaceActions>));
      await settle(tester);
      final item = find.text('Пригласить');
      expect(item, visible ? findsOneWidget : findsNothing);
      if (visible) {
        await tester.tap(item);
        await settle(tester);
        expect(find.text(outcome), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settle(tester);
    });
  }

  // Детали пространства: оба входа идут через тот же гейт, что проверен выше.
  testWidgets('ensureCanInviteToSpace: компания без права — плашка и false; '
      'с правом / не компания — true без плашки', (tester) async {
    final d = userDomain();
    final member = addSpace('!cm:$d', ownLevel: 0, invite: 99);
    final admin = addSpace('!ca:$d', ownLevel: 99, invite: 99);
    late BuildContext ctx;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) {
            ctx = context;
            return const Scaffold(body: SizedBox());
          },
        ),
        company: true,
        mainId: '!cm:$d',
      ),
    );
    await settle(tester);
    expect(ensureCanInviteToSpace(ctx, admin), isTrue);
    await tester.pump();
    expect(find.text(_notAllowed), findsNothing);
    expect(ensureCanInviteToSpace(ctx, member), isFalse);
    await tester.pump();
    expect(find.text(_notAllowed), findsOneWidget);
  });

  test('детали пространства: оба входа видны в компании и гейтятся '
      'ensureCanInviteToSpace (source)', () {
    final src = File(
      'lib/pages/chat_details/chat_details_view.dart',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
    expect(src, contains('(room.canInvite || companySpace)'));
    expect(src, contains('(canManageInviteLink || companySpace)'));
    expect(
      RegExp(r'ensureCanInviteToSpace\(context, room\)').allMatches(src).length,
      2,
    );
  });

  test(
    'поиск людей не зависит от права приглашать — рядовой участник '
    'компании видит раздел «Люди» (source, AC:RL-space-invite-admin-only/5)',
    () {
      final src = File(
        'lib/pages/chat_list/chat_list_body.dart',
      ).readAsStringSync();
      expect(src, isNot(contains('canBrowseUserDirectory')));
      expect(src, isNot(contains('.canInvite')));
      expect(src, contains('SearchUsersHorizontalList('));
    },
  );
}
