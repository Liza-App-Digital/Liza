// ledger:RL-chat-list-search-empty-and-order
//
// Поиск главного экрана (задание Надежды 18.10, задача 06): пустой запрос
// ничего глобального не показывает и в сеть не ходит; «Пригласить людей» в
// поиске нет; разделы — в порядке вкладок.
//
// Как подменён контроллер: ChatListController целиком в виджет-тесте не
// поднимается (тяжёлый State с Matrix, роутером и хранилищем). Поэтому
//   - проводку гейта (AC-1) проверяет source-assert по chat_list.dart: все три
//     входа — startSearch, _search, setServer — зовут shouldRunGlobalSearch
//     раньше таймера/сетевых вызовов;
//   - разметку (AC-2..AC-5) рисует РЕАЛЬНЫЙ chatListSearchSections — ровно тот
//     вызов, что стоит в блоке `if (controller.isSearchMode)` ChatListViewBody;
//     данные, которые body берёт у контроллера, передаются аргументами.
//
// Red-proof:
//   - убрать `if (!shouldRunGlobalSearch(query)) return const [];` в
//     chatListSearchSections → AC-2 красный (разделы над пустым запросом);
//   - переставить элементы searchSectionOrder → AC-3 красный;
//   - убрать гейт из startSearch → AC-1 «проводка» красный.
// ignore_for_file: depend_on_referenced_packages

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/chat_list_body.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/search_people_bots_sections.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _sectionKeys = {
  SearchSection.agentsAndBots: botsAndAiSectionKey,
  SearchSection.people: peopleSectionKey,
  SearchSection.companies: companiesSectionKey,
  SearchSection.publicRooms: publicRoomsSectionKey,
  SearchSection.publicChannels: publicChannelsSectionKey,
  SearchSection.chats: chatsSectionKey,
};

const _ruTitles = {
  SearchSection.agentsAndBots: 'Агенты и боты',
  SearchSection.people: 'Люди',
  SearchSection.companies: 'Компании',
  SearchSection.publicRooms: 'Публичные чаты',
  SearchSection.publicChannels: 'Публичные каналы',
  SearchSection.chats: 'Чаты',
};

PublishedRoomsChunk _room(String id, String name) => PublishedRoomsChunk(
  roomId: id,
  name: name,
  numJoinedMembers: 3,
  guestCanJoin: false,
  worldReadable: false,
);

/// Тело метода из исходника: от сигнатуры до парной закрывающей скобки.
String _methodBody(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'в chat_list.dart нет «$signature»');
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) return source.substring(open, i + 1);
  }
  fail('не нашли конец «$signature»');
}

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await client.dispose();
  });

  /// Полная выдача: каждый раздел непуст, кроме перечисленных в [empty].
  Future<void> pumpSections(
    WidgetTester tester, {
    required String query,
    Set<SearchSection> empty = const {},
  }) async {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final matrix = SearchTestMatrixState(client, StubRoleService(client));
    final people = PeopleAndBots(
      people: [
        if (!empty.contains(SearchSection.people))
          Profile(userId: '@anna:example.com', displayName: 'Анна'),
      ],
      botsAndAi: [
        if (!empty.contains(SearchSection.agentsAndBots))
          Profile(userId: '@liza:bots.liza.ru', displayName: 'Лиза'),
      ],
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: matrix,
            child: Scaffold(
              body: Builder(
                builder: (context) => ListView(
                  children: chatListSearchSections(
                    context,
                    query: query,
                    people: people,
                    companies: [
                      if (!empty.contains(SearchSection.companies))
                        const CompanyEntry(
                          roomId: '!co:example.com',
                          name: 'Школа шахмат',
                        ),
                    ],
                    publicRooms: [
                      if (!empty.contains(SearchSection.publicRooms))
                        _room('!pr:example.com', 'Шахматный клуб'),
                    ],
                    publicChannels: [
                      if (!empty.contains(SearchSection.publicChannels))
                        _room('!pc:example.com', 'Шахматный канал'),
                    ],
                    hasChats: !empty.contains(SearchSection.chats),
                    onUserTap: (_) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
  }

  group('AC-1 пустой запрос не запускает глобальный поиск', () {
    // AC:RL-chat-list-search-empty-and-order/1
    test('shouldRunGlobalSearch: пустой и пробельный ввод — нет', () {
      for (final text in ['', ' ', '\t', '  \n ']) {
        expect(shouldRunGlobalSearch(text), isFalse, reason: '«$text»');
      }
      for (final text in ['ш', ' ш ', '+79990000000']) {
        expect(shouldRunGlobalSearch(text), isTrue, reason: '«$text»');
      }
    });

    // AC:RL-chat-list-search-empty-and-order/1
    test('проводка: startSearch, _search, setServer гейтятся до сети', () {
      final source = File('lib/pages/chat_list/chat_list.dart').readAsStringSync();
      for (final signature in ['void startSearch()', 'void setServer() async']) {
        final body = _methodBody(source, signature);
        final gate = body.indexOf('shouldRunGlobalSearch(searchController.text)');
        expect(gate, isNonNegative, reason: '$signature без гейта');
        expect(
          gate,
          lessThan(body.indexOf('Timer(')),
          reason: '$signature ставит таймер поиска до гейта',
        );
      }
      final search = _methodBody(source, 'void _search() async');
      final gate = search.indexOf('shouldRunGlobalSearch(searchController.text)');
      expect(gate, isNonNegative, reason: '_search без гейта');
      for (final call in [
        'fetchCompanies(',
        'queryPublicRooms(',
        'searchUserDirectory(',
      ]) {
        final at = search.indexOf(call);
        expect(at, isNonNegative, reason: 'в _search нет $call');
        expect(gate, lessThan(at), reason: '$call раньше гейта');
      }
    });
  });

  testWidgets(
    // AC:RL-chat-list-search-empty-and-order/2
    // AC:RL-chat-list-search-empty-and-order/5
    'AC-2 пустой запрос: ни одного раздела и нет «Пригласить людей»',
    (tester) async {
      for (final query in ['', ' ', '\t']) {
        await pumpSections(tester, query: query);
        expect(find.byType(SearchTitle), findsNothing, reason: '«$query»');
        for (final title in _ruTitles.values) {
          expect(find.text(title), findsNothing, reason: '«$query»: $title');
        }
        expect(find.text('Пригласить людей'), findsNothing);
      }
      await unmount(tester);
    },
  );

  testWidgets(
    // AC:RL-chat-list-search-empty-and-order/3
    'AC-3 порядок: Агенты и боты → Люди → Компании → Публичные чаты → '
    'Публичные каналы → Чаты',
    (tester) async {
      // Требование Надежды — сам порядок, а не «какой-то»: литерал здесь
      // и есть критерий приёмки.
      expect(searchSectionOrder(), const [
        SearchSection.agentsAndBots,
        SearchSection.people,
        SearchSection.companies,
        SearchSection.publicRooms,
        SearchSection.publicChannels,
        SearchSection.chats,
      ]);

      await pumpSections(tester, query: 'ш');
      final ys = [
        for (final section in searchSectionOrder())
          topOf(tester, find.byKey(_sectionKeys[section]!)),
      ];
      for (var i = 1; i < ys.length; i++) {
        expect(
          ys[i],
          greaterThan(ys[i - 1]),
          reason:
              '${searchSectionOrder()[i]} обязан быть ниже '
              '${searchSectionOrder()[i - 1]}',
        );
      }
      for (final entry in _ruTitles.entries) {
        expect(
          find.descendant(
            of: find.byKey(_sectionKeys[entry.key]!),
            matching: find.text(entry.value),
          ),
          findsOneWidget,
          reason: 'заголовок ${entry.key}',
        );
      }
      await unmount(tester);
    },
  );

  testWidgets(
    // AC:RL-chat-list-search-empty-and-order/4
    'AC-4 пустой раздел скрыт вместе с заголовком — каждый раздел',
    (tester) async {
      for (final section in SearchSection.values) {
        await pumpSections(tester, query: 'ш', empty: {section});
        expect(
          find.byKey(_sectionKeys[section]!),
          findsNothing,
          reason: '$section пуст — заголовка нет',
        );
        expect(find.text(_ruTitles[section]!), findsNothing);
        for (final other in SearchSection.values.where((s) => s != section)) {
          expect(
            find.byKey(_sectionKeys[other]!),
            findsOneWidget,
            reason: '$other непуст — заголовок есть',
          );
        }
      }
      await pumpSections(
        tester,
        query: 'ш',
        empty: SearchSection.values.toSet(),
      );
      expect(find.byType(SearchTitle), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    // AC:RL-chat-list-search-empty-and-order/5
    'AC-5 «Пригласить людей» нет в поиске при любом запросе',
    (tester) async {
      // Полный телефон без матча: прежде здесь всплывало приглашение.
      for (final query in ['ш', '+79990000000']) {
        await pumpSections(
          tester,
          query: query,
          empty: SearchSection.values.toSet(),
        );
        expect(find.text('Пригласить людей'), findsNothing, reason: query);
      }
      await unmount(tester);

      final body = File(
        'lib/pages/chat_list/chat_list_body.dart',
      ).readAsStringSync();
      expect(body, isNot(contains('InvitePeopleListTile')));
      expect(body, isNot(contains('invite_people_row_search')));
    },
  );
}
