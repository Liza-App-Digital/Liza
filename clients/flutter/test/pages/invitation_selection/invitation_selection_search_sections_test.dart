// ledger:RL-search-people-vs-bots-sections
//
// Экран «Пригласить в группу» на РЕАЛЬНОМ виджете (InvitationSelection →
// InvitationSelectionView): выдача поиска разбита на «Люди» / «Боты и ИИ».
//
// Покрываемые AC (tests/registry/RL-search-people-vs-bots-sections.md):
//   AC-1 два раздела в одном списке на этом экране.
//   AC-2 человек / федеративный человек — «Люди»; бот по роли ai, бот
//        liza-bot-api по домену, ИИ — «Боты и ИИ».
//   AC-3 только люди → заголовка «Боты и ИИ» нет.
//   AC-4 роли пришли позже 1,5 с → бот переезжает в «Боты и ИИ».
//
// Red-proof AC-4: убрать `onLate?.call()` в waitForRolesBounded → «Кубок»
// остаётся среди людей, тест «роли пришли позже» красный.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/invitation_selection/invitation_selection.dart';
import 'package:liza/widgets/search_people_bots_sections.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _roomId = '!726s6s6q:example.com';

const _directory = {
  '@anna:example.com': 'Анна kot',
  '@ivan:nadezhda.liza.ru': 'Иван kot',
  '@shop_bot:bots.liza.ru': 'Магазин kot',
  '@cup_bot:liza.cyber-agro.ru': 'Кубок kot',
  '@zed:example.com': 'Зед zed',
};

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    stubUserDirectory(client, _directory);
  });

  tearDown(() async {
    await client.dispose();
  });

  Future<void> settle(WidgetTester tester, int ms) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  Future<void> search(
    WidgetTester tester,
    StubRoleService roles,
    String text, {
    int waitMs = 1000,
  }) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapWithMatrix(
        SearchTestMatrixState(client, roles),
        const InvitationSelection(roomId: _roomId),
      ),
    );
    await settle(tester, 100);
    await tester.enterText(find.byType(TextField), text);
    await settle(tester, waitMs);
  }

  double y(WidgetTester tester, String text) => topOfText(tester, text);
  double header(WidgetTester tester, Key key) =>
      topOf(tester, find.byKey(key));

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/1
      // AC:RL-search-people-vs-bots-sections/2
      'приглашение: люди под «Люди», боты и ИИ под «Боты и ИИ»',
      (tester) async {
    final roles = StubRoleService(
      client,
      serverAi: {'@cup_bot:liza.cyber-agro.ru'},
    );
    await tester.runAsync(() => search(tester, roles, 'kot'));

    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Боты и ИИ'), findsOneWidget);
    final bots = header(tester, botsAndAiSectionKey);
    final people = header(tester, peopleSectionKey);
    for (final human in ['Анна kot', 'Иван kot']) {
      expect(y(tester, human), inExclusiveRange(people, bots), reason: human);
    }
    for (final bot in ['Магазин kot', 'Кубок kot']) {
      expect(y(tester, bot), greaterThan(bots), reason: bot);
    }
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/3
      'приглашение: только люди → раздела «Боты и ИИ» нет',
      (tester) async {
    final roles = StubRoleService(client);
    await tester.runAsync(() => search(tester, roles, 'zed'));

    expect(find.text('Зед zed'), findsOneWidget);
    expect(find.byKey(peopleSectionKey), findsOneWidget);
    expect(find.byKey(botsAndAiSectionKey), findsNothing);
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/4
      'приглашение: роли пришли позже таймаута → бот переезжает к ботам',
      (tester) async {
    final roles = StubRoleService(
      client,
      serverAi: {'@cup_bot:liza.cyber-agro.ru'},
    )..hold = true;
    await tester.runAsync(() => search(tester, roles, 'kot', waitMs: 2400));

    // Выдача показана по таймауту, роль ещё в пути — бот пока среди людей.
    expect(
      y(tester, 'Кубок kot'),
      lessThan(header(tester, botsAndAiSectionKey)),
    );

    await tester.runAsync(() async {
      roles.releaseAll();
      await settle(tester, 100);
    });

    expect(
      y(tester, 'Кубок kot'),
      greaterThan(header(tester, botsAndAiSectionKey)),
    );
    expect(find.text('Кубок kot'), findsOneWidget);
  });
}
