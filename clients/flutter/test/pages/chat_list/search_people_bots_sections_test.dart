// ledger:RL-search-people-vs-bots-sections
//
// Разделы поиска ГЛАВНОГО экрана на РЕАЛЬНЫХ виджетах: ровно тот вызов, что
// стоит в chat_list_body.dart (chatListSearchSections → botsSearchSection /
// peopleSearchSection → SearchTitle + SearchUsersHorizontalList →
// SearchCarouselItem). Разделы считает контроллер
// (ChatListController.userSearchSections) тем же partitionPeopleAndBots, что
// и здесь.
//
// Покрываемые AC (tests/registry/RL-search-people-vs-bots-sections.md):
//   AC-1a на главном экране два раздела в одном списке, «Агенты и боты» выше
//         «Люди» (порядок вкладок, задача 06 от 18.10).
//   AC-3 пустой раздел скрыт вместе с заголовком; оба пусты — ничего.
//   AC-4 элемент, переехавший между разделами после поздних ролей, рисуется
//        в новом разделе (ключ ValueKey(userId), чужое состояние не
//        переиспользуется).
//   AC-5 заголовки — из L10n: ru «Люди» / «Агенты и боты», en «People» /
//        «Agents & bots».
//
// Red-proof AC-3: в botsSearchSection убрать условие
// `sections.botsAndAi.isEmpty` → заголовок «Агенты и боты» появляется
// над пустым разделом, тест «пустой раздел скрыт» красный.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list_body.dart';
import 'package:liza/pages/chat_list/search_carousel_item.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/pages/chat_list/search_users_horizontal_list.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/search_people_bots_sections.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _anna = '@anna:example.com';
const _cup = '@cup_bot:liza.cyber-agro.ru';
const _liza = '@liza:bots.liza.ru';

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await client.dispose();
  });

  Widget body(
    liza_matrix.MatrixState matrix,
    PeopleAndBots? sections, {
    Locale locale = const Locale('ru'),
    void Function(String userId)? onTap,
  }) =>
      MaterialApp(
        locale: locale,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: matrix,
          child: Scaffold(
            body: Builder(
              builder: (context) => ListView(
                children: [
                  // Ровно как в chat_list_body.dart; прочие разделы пусты.
                  ...chatListSearchSections(
                    context,
                    query: 'а',
                    people: sections,
                    companies: const [],
                    publicRooms: null,
                    publicChannels: null,
                    hasChats: false,
                    onUserTap: onTap ?? (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Finder carouselOf(String userId) => find.ancestor(
        of: find.byKey(ValueKey(userId)),
        matching: find.byType(SearchUsersHorizontalList),
      );

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/1
      // AC:RL-search-people-vs-bots-sections/5
      'главный экран: «Агенты и боты» выше «Люди» — две карусели под своими заголовками',
      (tester) async {
    final matrix = SearchTestMatrixState(client, StubRoleService(client));
    final sections = partitionPeopleAndBots(
      [
        Profile(userId: _anna, displayName: 'Анна'),
        Profile(userId: _liza, displayName: 'Лиза'),
      ],
      isBotOrAi: matrix.isBotOrAiUser,
    );
    String? tapped;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        body(matrix, sections, onTap: (id) => tapped = id),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Агенты и боты'), findsOneWidget);
    expect(find.byType(SearchUsersHorizontalList), findsNWidgets(2));
    final peopleY = topOf(tester, find.byKey(peopleSectionKey));
    final botsY = topOf(tester, find.byKey(botsAndAiSectionKey));
    expect(botsY, lessThan(peopleY));
    expect(topOfText(tester, 'Лиза'), inExclusiveRange(botsY, peopleY));
    expect(topOfText(tester, 'Анна'), greaterThan(peopleY));
    expect(find.byKey(const ValueKey(_anna)), findsOneWidget);
    expect(
      tester.widget<SearchCarouselItem>(find.byKey(const ValueKey(_liza))).userId,
      _liza,
    );

    await tester.tap(find.text('Лиза'));
    expect(tapped, _liza, reason: 'тап по элементу раздела открывает его DM');

    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/3
      'главный экран: пустой раздел скрыт вместе с заголовком', (tester) async {
    final matrix = SearchTestMatrixState(client, StubRoleService(client));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        body(
          matrix,
          PeopleAndBots(people: [Profile(userId: _anna, displayName: 'Анна')]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Агенты и боты'), findsNothing);
    expect(find.byType(SearchUsersHorizontalList), findsOneWidget);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        body(
          matrix,
          PeopleAndBots(botsAndAi: [Profile(userId: _liza, displayName: 'Лиза')]),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
    expect(find.text('Люди'), findsNothing);
    expect(find.text('Агенты и боты'), findsOneWidget);

    for (final empty in [const PeopleAndBots(), null]) {
      await tester.runAsync(() async {
        await tester.pumpWidget(body(matrix, empty));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        await tester.pump();
      });
      expect(find.byType(SearchTitle), findsNothing);
      expect(find.byType(SearchUsersHorizontalList), findsNothing);
    }
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/4
      'главный экран: бот после поздних ролей рисуется в «Агенты и боты»',
      (tester) async {
    final roles = StubRoleService(client, serverAi: {_cup});
    final matrix = SearchTestMatrixState(client, roles);
    final published = [
      Profile(userId: _anna, displayName: 'Анна'),
      Profile(userId: _cup, displayName: 'Кубок'),
    ];
    PeopleAndBots partition() =>
        partitionPeopleAndBots(published, isBotOrAi: matrix.isBotOrAiUser);

    await tester.runAsync(() async {
      await tester.pumpWidget(body(matrix, partition()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
    expect(
      carouselOf(_cup),
      findsOneWidget,
    );
    expect(find.text('Агенты и боты'), findsNothing,
        reason: 'до ролей бот на чужом домене неотличим от человека');

    // Поздние роли — контроллер переразбивает ту же выдачу.
    await tester.runAsync(() async {
      await roles.fetchRoles([_anna, _cup]);
      await tester.pumpWidget(body(matrix, partition()));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
    final botsY = topOf(tester, find.byKey(botsAndAiSectionKey));
    final peopleY = topOf(tester, find.byKey(peopleSectionKey));
    expect(topOfText(tester, 'Кубок'), inExclusiveRange(botsY, peopleY));
    expect(topOfText(tester, 'Анна'), greaterThan(peopleY));
    expect(find.byKey(const ValueKey(_cup)), findsOneWidget);
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/5
      'en: заголовки «People» / «Agents & bots»', (tester) async {
    final matrix = SearchTestMatrixState(client, StubRoleService(client));
    await tester.runAsync(() async {
      await tester.pumpWidget(
        body(
          matrix,
          PeopleAndBots(
            people: [Profile(userId: _anna, displayName: 'Anna')],
            botsAndAi: [Profile(userId: _liza, displayName: 'Liza')],
          ),
          locale: const Locale('en'),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });
    expect(find.text('People'), findsOneWidget);
    expect(find.text('Agents & bots'), findsOneWidget);
  });
}
