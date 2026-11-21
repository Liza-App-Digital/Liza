// ignore_for_file: depend_on_referenced_packages
// ledger:RL-invite-contacts-dedup-dm
//
// «Пригласить контакт» при пустом поиске: одна строка на собеседника, сколько бы
// личных комнат с ним ни было (каждый «Новый запрос» к Лизе — отдельный DM).
// РЕАЛЬНЫЙ InvitationSelection на реальных Room; каталог ролей подменён.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/invitation_selection/invitation_selection.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _roomId = '!726s6s6q:example.com';
const _botAi = '@helper:bots.liza.ru';

void main() {
  late Client client;
  final direct = <String, List<String>>{};
  final lizaMxid = MatrixState.lizaMxid;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    direct.clear();
    FrequentContactsCache.instance.reset();
  });

  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await client.dispose(closeDatabase: true);
  });

  Room addDm(
    String id,
    String peer,
    String name, {
    String peerMembership = 'join',
    int lastTs = 1000,
    bool request = false,
    Map<String, Object?>? createContent,
    Membership membership = Membership.join,
  }) {
    final room = Room(id: id, client: client, membership: membership);
    void put(String type, String key, String sender, Map<String, Object?> c) =>
        room.setState(
          Event(
            eventId: '\$$type-$id',
            senderId: sender,
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
            type: type,
            stateKey: key,
            content: c,
            room: room,
          ),
        );
    if (createContent != null) {
      put(EventTypes.RoomCreate, '', client.userID!, createContent);
    }
    if (request) put(lizaRequestStateType, '', client.userID!, const {});
    put(EventTypes.RoomMember, peer, peer, {
      'membership': peerMembership,
      'displayname': name,
    });
    direct.putIfAbsent(peer, () => []).add(id);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: direct,
    );
    room.lastEvent = Event(
      eventId: '\$last-$id',
      senderId: peer,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(lastTs),
      type: EventTypes.Message,
      content: const {'msgtype': 'm.text', 'body': 'привет'},
      room: room,
    );
    client.rooms.add(room);
    return room;
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final roles = StubRoleService(client, serverAi: {lizaMxid, _botAi});
    await tester.runAsync(() async {
      await roles.fetchRoles([lizaMxid, _botAi]);
      await tester.pumpWidget(
        wrapWithMatrix(
          SearchTestMatrixState(client, roles),
          const InvitationSelection(roomId: _roomId),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
    });
  }

  double y(WidgetTester tester, String text) => topOfText(tester, text);

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/1
    // AC:RL-invite-contacts-dedup-dm/5
    'десять DM с Лизой и два с человеком — по одной строке',
    (tester) async {
      for (var i = 0; i < 10; i++) {
        addDm('!liza$i:example.com', lizaMxid, 'Liza', lastTs: 100 + i);
      }
      addDm('!a1:example.com', '@yana:example.com', 'Яна');
      addDm('!a2:example.com', '@yana:example.com', 'Яна', lastTs: 2000);
      addDm('!ai:example.com', _botAi, 'Хелпер');
      addDm('!b:example.com', '@boris:example.com', 'Борис');
      await open(tester);

      expect(find.text('Liza'), findsOneWidget);
      expect(find.text('Яна'), findsOneWidget);
      expect(find.text('Хелпер'), findsOneWidget);
    },
  );

  List<double> ys(WidgetTester tester, List<String> names) =>
      names.map((t) => y(tester, t)).toList();

  void expectOrder(WidgetTester tester, List<String> names) {
    final order = ys(tester, names);
    expect(order, orderedEquals([...order]..sort()), reason: '$names');
  }

  void seedActivity(Map<String, int> counts) =>
      FrequentContactsCache.instance.seed(client.userID!, [
        for (final e in counts.entries)
          DmActivity(
            userId: e.key,
            roomId: '!x',
            messageCount: e.value,
            lastMessageTs: 1,
          ),
      ]);

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/6
    'люди раньше Лизы, ИИ и ботов при любых счётчиках; хвост Лиза → ИИ → бот',
    (tester) async {
      addDm('!liza:example.com', lizaMxid, 'Liza', lastTs: 9000);
      addDm('!ai:example.com', _botAi, 'Хелпер', lastTs: 9000);
      addDm('!bot:example.com', '@bot:bots.liza.ru', 'Бот', lastTs: 9000);
      addDm('!b:example.com', '@boris:example.com', 'Борис', lastTs: 1);
      addDm('!y:example.com', '@yana:example.com', 'Яна', lastTs: 2);
      // У ботов «активность» огромная — людей это не обгоняет.
      seedActivity({lizaMxid: 500, _botAi: 400, '@bot:bots.liza.ru': 300});
      await open(tester);

      expectOrder(tester, ['Яна', 'Борис', 'Liza', 'Хелпер', 'Бот']);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/9
    'люди по убыванию числа сообщений (вопреки алфавиту), без активности — после',
    (tester) async {
      addDm('!a:example.com', '@anna:example.com', 'Анна', lastTs: 5000);
      addDm('!b:example.com', '@boris:example.com', 'Борис', lastTs: 1);
      addDm('!v:example.com', '@vera:example.com', 'Вера', lastTs: 3000);
      addDm('!g:example.com', '@gleb:example.com', 'Глеб', lastTs: 4000);
      seedActivity({'@vera:example.com': 40, '@boris:example.com': 7});
      await open(tester);

      // Вера(40) → Борис(7) → без активности по свежести: Анна(5000) → Глеб(4000)
      expectOrder(tester, ['Вера', 'Борис', 'Анна', 'Глеб']);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/10
    'пустой кэш — люди по свежести, при равной свежести по имени',
    (tester) async {
      addDm('!a:example.com', '@anna:example.com', 'Анна', lastTs: 100);
      addDm('!b:example.com', '@boris:example.com', 'Борис', lastTs: 300);
      addDm('!v:example.com', '@vera:example.com', 'Вера', lastTs: 100);
      await open(tester);

      expectOrder(tester, ['Борис', 'Анна', 'Вера']);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/11
    'равные счётчики — свежее выше, потом имя',
    (tester) async {
      addDm('!a:example.com', '@anna:example.com', 'Анна', lastTs: 100);
      addDm('!b:example.com', '@boris:example.com', 'Борис', lastTs: 200);
      addDm('!v:example.com', '@vera:example.com', 'Вера', lastTs: 200);
      seedActivity({
        '@anna:example.com': 5,
        '@boris:example.com': 5,
        '@vera:example.com': 5,
      });
      await open(tester);

      expectOrder(tester, ['Борис', 'Вера', 'Анна']);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/3
    'только запросы к Лизе — Лиза остаётся одной строкой; у человека запрос не виден',
    (tester) async {
      for (var i = 0; i < 4; i++) {
        addDm('!req$i:example.com', lizaMxid, 'Liza', request: true);
      }
      await open(tester);

      expect(find.text('Liza'), findsOneWidget);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/4
    'ушедший бот и забаненный человек скрыты, ушедший человек виден',
    (tester) async {
      addDm('!deadbot:example.com', _botAi, 'Хелпер', peerMembership: 'leave');
      addDm(
        '!banned:example.com',
        '@zed:example.com',
        'Зед',
        peerMembership: 'ban',
      );
      addDm(
        '!left:example.com',
        '@yana:example.com',
        'Яна',
        peerMembership: 'leave',
      );
      await open(tester);

      expect(find.text('Хелпер'), findsNothing);
      expect(find.text('Зед'), findsNothing);
      expect(find.text('Яна'), findsOneWidget);
    },
  );

  testWidgets(
    // AC:RL-invite-contacts-dedup-dm/7
    'invite-комната, сторис-комната и комната-канал строк не дают',
    (tester) async {
      addDm(
        '!inv:example.com',
        '@invitee:example.com',
        'Приглашённый',
        membership: Membership.invite,
      );
      addDm(
        '!story:example.com',
        '@story:example.com',
        'Сторис',
        createContent: {'type': 'com.liza.stories'},
      );
      addDm('!ok:example.com', '@ok:example.com', 'Нормальный');
      await open(tester);

      expect(find.text('Приглашённый'), findsNothing);
      expect(find.text('Нормальный'), findsOneWidget);
    },
  );
}
