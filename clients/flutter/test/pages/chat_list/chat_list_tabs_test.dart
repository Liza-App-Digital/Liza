// ignore_for_file: depend_on_referenced_packages
// ledger:RL-chat-list-agents-people-tabs
//
// Вкладки списка чатов «Агенты и боты» / «Люди» и строка «+ Новый запрос»
// (задание Надежды 18.10, newInterface/2026-10-19/05). Фильтр — РЕАЛЬНЫЙ
// roomMatchesFilter на реальных Room; классификатор — РЕАЛЬНЫЙ
// MatrixState.isBotOrAiUser (каталог ролей подменён StubRoleService).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/new_liza_request_list_tile.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _companyBot = '@cup_bot:liza.cyber-agro.ru';

// L10n грузит языки deferred-импортом: в fake-async теста библиотека «ru»
// не догрузится сама, и MaterialApp не построит дерево. Грузим заранее.
Future<void> _loadRu(WidgetTester tester) =>
    tester.runAsync(() => L10n.delegate.load(const Locale('ru')));

void main() {
  group('roomMatchesFilter: «Агенты и боты» / «Люди»', () {
    late Client client;
    late StubRoleService roles;
    late MatrixState matrix;
    final direct = <String, List<String>>{};

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
      client.rooms.clear();
      direct.clear();
      roles = StubRoleService(client, serverAi: {_companyBot});
      matrix = SearchTestMatrixState(client, roles);
    });

    tearDown(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await client.dispose(closeDatabase: true);
    });

    Room addRoom(
      String id, {
      String? dmWith,
      String? partnerMembership,
      Map<String, Object?>? createContent,
    }) {
      final room = Room(id: id, client: client);
      if (createContent != null) {
        room.setState(
          Event(
            eventId: '\$create-$id',
            senderId: client.userID!,
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
            type: EventTypes.RoomCreate,
            stateKey: '',
            content: createContent,
            room: room,
          ),
        );
      }
      if (dmWith != null) {
        room.setState(
          Event(
            eventId: '\$member-$id',
            senderId: dmWith,
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
            type: EventTypes.RoomMember,
            stateKey: dmWith,
            content: {'membership': partnerMembership ?? 'join'},
            room: room,
          ),
        );
        direct.putIfAbsent(dmWith, () => []).add(id);
        client.accountData['m.direct'] = BasicEvent(
          type: 'm.direct',
          content: direct,
        );
      }
      client.rooms.add(room);
      return room;
    }

    bool agents(Room r) => roomMatchesFilter(
      r,
      ActiveFilter.agents,
      isBotOrAi: matrix.isBotOrAiUser,
    );
    bool people(Room r) => roomMatchesFilter(
      r,
      ActiveFilter.people,
      isBotOrAi: matrix.isBotOrAiUser,
    );

    test('AC-1: ∀ DM с ботом/ИИ — в «Агентах», не в «Людях» '
        '— AC:RL-chat-list-agents-people-tabs/1', () async {
      await roles.fetchRoles([_companyBot]);
      final cases = {
        'Лиза ИИ': addRoom('!liza', dmWith: MatrixState.lizaMxid),
        // «Новый запрос» — второй DM с той же Лизой (forceNew).
        'Новый запрос': addRoom('!liza-req', dmWith: MatrixState.lizaMxid),
        'BotFather': addRoom('!bf', dmWith: '@bot_father:bots.liza.ru'),
        'поддержка': addRoom('!support', dmWith: '@support:bots.liza.ru'),
        'бот пользователя': addRoom('!shop', dmWith: '@shop_bot:bots.liza.ru'),
        'бот компании (роль ai)': addRoom('!cup', dmWith: _companyBot),
        'удалённый бот': addRoom(
          '!gone',
          dmWith: '@old_bot:bots.liza.ru',
          partnerMembership: 'leave',
        ),
      };
      for (final MapEntry(key: name, value: room) in cases.entries) {
        expect(room.isDirectChat, isTrue, reason: '$name — DM');
        expect(agents(room), isTrue, reason: '$name → «Агенты и боты»');
        expect(people(room), isFalse, reason: '$name не в «Людях»');
      }
    });

    test('AC-2: ∀ DM с человеком — в «Людях»; группа/канал/компания — ни в '
        'одной — AC:RL-chat-list-agents-people-tabs/2', () {
      final humans = {
        'свой HS': addRoom('!anna', dmWith: '@anna:example.invalid'),
        'федеративный': addRoom('!ivan', dmWith: '@ivan:nadezhda.liza.ru'),
      };
      for (final MapEntry(key: name, value: room) in humans.entries) {
        expect(people(room), isTrue, reason: '$name → «Люди»');
        expect(agents(room), isFalse, reason: '$name не в «Агентах»');
      }
      final others = {
        'группа': addRoom('!group', createContent: {}),
        'канал': addRoom(
          '!channel',
          createContent: {'com.liza.chat.type': 'channel'},
        ),
        'компания': addRoom('!space', createContent: {'type': 'm.space'}),
      };
      for (final MapEntry(key: name, value: room) in others.entries) {
        expect(agents(room), isFalse, reason: '$name не в «Агентах»');
        expect(people(room), isFalse, reason: '$name не в «Людях»');
      }
      expect(
        roomMatchesFilter(
          others['группа']!,
          ActiveFilter.groups,
          isBotOrAi: matrix.isBotOrAiUser,
        ),
        isTrue,
      );
      expect(
        roomMatchesFilter(
          others['канал']!,
          ActiveFilter.channels,
          isBotOrAi: matrix.isBotOrAiUser,
        ),
        isTrue,
      );
      expect(
        roomMatchesFilter(
          others['компания']!,
          ActiveFilter.spaces,
          isBotOrAi: matrix.isBotOrAiUser,
        ),
        isTrue,
      );
    });

    test('AC-4: роль ai пришла после рендера — DM бота компании переезжает '
        'из «Людей» в «Агенты», rolesVersion бампается '
        '— AC:RL-chat-list-agents-people-tabs/4', () async {
      final room = addRoom('!cup', dmWith: _companyBot);
      expect(people(room), isTrue, reason: 'до роли — среди людей');
      expect(agents(room), isFalse);

      final before = roles.rolesVersion.value;
      await roles.fetchRoles([_companyBot]);

      expect(roles.rolesVersion.value, greaterThan(before));
      expect(agents(room), isTrue, reason: 'после роли — в «Агентах»');
      expect(people(room), isFalse);
    });
  });

  group('ряд чипов', () {
    testWidgets('AC-3: порядок и подписи чипов: Все → Агенты и боты → Люди → '
        'Компании → Группы → Каналы → Новые; «Личные» нет '
        '— AC:RL-chat-list-agents-people-tabs/3', (tester) async {
      await _loadRu(tester);
      late List<String> labels;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Builder(
            builder: (context) {
              labels = [
                for (final f in chatListFilterOrder)
                  f.toLocalizedString(context),
              ];
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(labels, [
        'Все',
        'Агенты и боты',
        'Люди',
        'Компании',
        'Группы',
        'Каналы',
        'Новые',
      ]);
      expect(labels, isNot(contains('Личные')));
      expect(chatListFilterOrder.toSet(), ActiveFilter.values.toSet());
    });
  });

  group('строка «+ Новый запрос»', () {
    test('AC-5: видна ⇔ не поиск ∧ досинкано ∧ чип ∈ {Все, Агенты}; с плашкой '
        'компании не пересекается — AC:RL-chat-list-agents-people-tabs/5', () {
      for (final filter in ActiveFilter.values) {
        for (final isSearchMode in [false, true]) {
          for (final synced in [false, true]) {
            expect(
              shouldShowNewRequestRow(
                filter,
                isSearchMode: isSearchMode,
                synced: synced,
              ),
              !isSearchMode &&
                  synced &&
                  (filter == ActiveFilter.allChats ||
                      filter == ActiveFilter.agents),
              reason: '${filter.name}, поиск=$isSearchMode, sync=$synced',
            );
          }
        }
      }
      expect(
        shouldShowNewRequestRow(
          ActiveFilter.spaces,
          isSearchMode: false,
          synced: true,
        ),
        isFalse,
        reason: 'на «Компаниях» последней идёт плашка «Создать компанию»',
      );
    });

    Widget wrap(Widget child) => MaterialApp(
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      locale: const Locale('ru'),
      home: Scaffold(body: child),
    );

    testWidgets('AC-6: «Новый запрос» по-русски, «+», геометрия ChatListItem '
        '(аватар 44, density −0.5, leading от 16) '
        '— AC:RL-chat-list-agents-people-tabs/6', (tester) async {
      await _loadRu(tester);
      await tester.pumpWidget(wrap(const NewLizaRequestListTile()));
      await tester.pumpAndSettle();

      expect(find.text('Новый запрос'), findsOneWidget);
      expect(find.text('Пригласить людей'), findsNothing);
      expect(find.byIcon(Icons.add), findsOneWidget);

      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.onTap, isNotNull);
      expect(tile.visualDensity, const VisualDensity(vertical: -0.5));
      expect(tile.contentPadding, const EdgeInsets.symmetric(horizontal: 16));

      final icon = find.byKey(const ValueKey('new_liza_request_icon'));
      final avatar = tester.getSize(icon);
      expect(avatar.width, Avatar.defaultSize);
      expect(avatar.height, Avatar.defaultSize);

      final tileLeft = tester.getTopLeft(find.byType(ListTile)).dx;
      final avatarLeft = tester.getTopLeft(icon).dx;
      expect(avatarLeft - tileLeft, moreOrLessEquals(16, epsilon: 0.5));
      // titleStart = 16 + 44 + 16, как у ChatListItem.
      final titleLeft = tester.getTopLeft(find.text('Новый запрос')).dx;
      expect(titleLeft - tileLeft, moreOrLessEquals(76, epsilon: 0.5));
    });
  });
}
