// ledger:RL-search-people-vs-bots-sections
//
// Экран «Новый личный чат» на РЕАЛЬНОМ виджете (NewPrivateChat →
// NewPrivateChatView): выдача поиска разбита на «Люди» / «Агенты и боты».
// Сеть подменена: каталог пользователей — FakeMatrixApi, роли — управляемый
// двойник (может «тормозить»), ник и федерация — пустые.
//
// Покрываемые AC (tests/registry/RL-search-people-vs-bots-sections.md):
//   AC-1 два раздела в одном списке на этом экране.
//   AC-2 человек / федеративный человек — под «Люди»; бот liza-bot-api,
//        бот по роли ai, ИИ liza/gpt — под «Агенты и боты», Лиза первая.
//   AC-3 только люди → заголовка «Агенты и боты» нет.
//   AC-4 роли пришли позже 1,5 с → бот переезжает в «Агенты и боты»; ответ
//        ролей устаревшего запроса выдачу нового не затирает.
//   AC-5 заголовки — из L10n, в ru «Люди» и «Агенты и боты».
//
// Red-proof AC-4 (устаревший запрос): убрать `seq != _searchSeq` из onLate в
// new_private_chat.dart → поздние роли старого запроса возвращают на экран
// «Анна kot», тест «устаревший запрос» красный.
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/pages/new_private_chat/new_private_chat.dart';
import 'package:liza/widgets/search_people_bots_sections.dart';

import '../../utils/search_sections_stubs.dart';
import '../../utils/test_client.dart';

const _directory = {
  '@anna:example.com': 'Анна kot',
  '@ivan:nadezhda.liza.ru': 'Иван kot',
  '@shop_bot:bots.liza.ru': 'Магазин kot',
  '@cup_bot:liza.cyber-agro.ru': 'Кубок kot',
  '@gpt:bots.liza.ru': 'GPT kot',
  '@liza:bots.liza.ru': 'Лиза kot',
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

  Future<void> pumpScreen(WidgetTester tester, StubRoleService roles) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrapWithMatrix(
        SearchTestMatrixState(client, roles),
        const NewPrivateChat(),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }

  Future<void> settle(WidgetTester tester, int ms) async {
    await Future<void>.delayed(Duration(milliseconds: ms));
    // Колбэк FutureBuilder регистрируется в кадре, срабатывает в следующем,
    // перерисовка — ещё через кадр.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  /// Элемент [name] стоит в разделе [section]: ниже его заголовка и, если
  /// раздел «Люди», выше заголовка «Агенты и боты».
  void expectInSection(WidgetTester tester, String name, Key section) {
    final y = topOfText(tester, name);
    expect(y, greaterThan(topOf(tester, find.byKey(section))),
        reason: '«$name» должен стоять под заголовком своего раздела');
    final bots = find.byKey(botsAndAiSectionKey);
    if (section == peopleSectionKey && bots.evaluate().isNotEmpty) {
      expect(y, lessThan(topOf(tester, bots)),
          reason: '«$name» — человек, он выше раздела «Агенты и боты»');
    }
  }

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/1
      // AC:RL-search-people-vs-bots-sections/2
      // AC:RL-search-people-vs-bots-sections/5
      'выдача разбита на «Люди» и «Агенты и боты», Лиза первая среди ботов',
      (tester) async {
    final roles = StubRoleService(
      client,
      serverAi: {'@cup_bot:liza.cyber-agro.ru'},
    );
    await tester.runAsync(() async {
      await pumpScreen(tester, roles);
      await tester.enterText(find.byType(TextField), 'kot');
      await settle(tester, 800);
      await settle(tester, 300);
    });

    expect(find.text('Люди'), findsOneWidget);
    expect(find.text('Агенты и боты'), findsOneWidget);
    expect(
      topOf(tester, find.byKey(peopleSectionKey)),
      lessThan(topOf(tester, find.byKey(botsAndAiSectionKey))),
      reason: '«Люди» — первым разделом',
    );
    for (final human in ['Анна kot', 'Иван kot']) {
      expectInSection(tester, human, peopleSectionKey);
    }
    for (final bot in ['Лиза kot', 'Магазин kot', 'Кубок kot', 'GPT kot']) {
      expectInSection(tester, bot, botsAndAiSectionKey);
    }
    final lizaY = topOfText(tester, 'Лиза kot');
    for (final bot in ['Магазин kot', 'Кубок kot', 'GPT kot']) {
      expect(lizaY, lessThan(topOfText(tester, bot)),
          reason: 'Лиза — первая в «Агенты и боты»');
    }
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/3
      'только люди → раздела «Агенты и боты» нет вместе с заголовком',
      (tester) async {
    final roles = StubRoleService(client);
    await tester.runAsync(() async {
      await pumpScreen(tester, roles);
      await tester.enterText(find.byType(TextField), 'zed');
      await settle(tester, 800);
      await settle(tester, 300);
    });

    expect(find.text('Зед zed'), findsOneWidget);
    expect(find.byKey(peopleSectionKey), findsOneWidget);
    expect(find.byKey(botsAndAiSectionKey), findsNothing);
    expect(find.text('Агенты и боты'), findsNothing);
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/4
      'роли пришли позже таймаута → бот переезжает в «Агенты и боты»',
      (tester) async {
    final roles = StubRoleService(
      client,
      serverAi: {'@cup_bot:liza.cyber-agro.ru'},
    )..hold = true;
    await tester.runAsync(() async {
      await pumpScreen(tester, roles);
      await tester.enterText(find.byType(TextField), 'kot');
      // дебаунс 500 мс + таймаут ролей 1,5 с
      await settle(tester, 800);
      await settle(tester, 1700);
    });

    // Роль ещё не пришла: бот на чужом домене временно среди людей, но
    // выдача уже показана — поиск не висит на медленном каталоге ролей.
    expect(find.text('Кубок kot'), findsOneWidget);
    expectInSection(tester, 'Кубок kot', peopleSectionKey);

    await tester.runAsync(() async {
      roles.releaseAll();
      await settle(tester, 100);
    });

    expectInSection(tester, 'Кубок kot', botsAndAiSectionKey);
    expect(find.text('Кубок kot'), findsOneWidget);
  });

  testWidgets(
      // AC:RL-search-people-vs-bots-sections/4
      'поздние роли устаревшего запроса не возвращают его выдачу',
      (tester) async {
    final roles = StubRoleService(
      client,
      serverAi: {'@cup_bot:liza.cyber-agro.ru'},
    )..hold = true;
    await tester.runAsync(() async {
      await pumpScreen(tester, roles);
      await tester.enterText(find.byType(TextField), 'kot');
      await settle(tester, 800);
      await settle(tester, 1700);
      expect(find.text('Анна kot'), findsOneWidget);

      // Новый запрос, пока роли старого всё ещё в пути.
      await tester.enterText(find.byType(TextField), 'zed');
      await settle(tester, 800);
      await settle(tester, 1700);
      expect(find.text('Зед zed'), findsOneWidget);

      // Приходят роли СТАРОГО запроса (первый вызов каталога), новый ещё
      // ждёт — поздний ответ старого обязан быть отброшен.
      roles.pending.first.complete();
      await settle(tester, 100);
      await settle(tester, 100);
    });

    expect(find.text('Зед zed'), findsOneWidget);
    expect(find.text('Анна kot'), findsNothing,
        reason: 'ответ ролей устаревшего запроса не показывается');
    expect(find.text('Кубок kot'), findsNothing);

    await tester.runAsync(() async {
      roles.releaseAll();
      await settle(tester, 100);
    });
    expect(find.text('Зед zed'), findsOneWidget);
    expect(find.text('Анна kot'), findsNothing);
  });
}
