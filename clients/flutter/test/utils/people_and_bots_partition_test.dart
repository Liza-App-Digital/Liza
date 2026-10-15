// ledger:RL-search-people-vs-bots-sections
//
// Чистое разбиение выдачи поиска на «Люди» / «Боты и ИИ» и ожидание ролей
// с таймаутом (задача 12). Классификатор — РЕАЛЬНЫЙ
// `MatrixState.isBotOrAiUser` (роль `ai` ∪ bot-like MXID), каталог ролей
// подменён двойником.
//
// Покрываемые AC (tests/registry/RL-search-people-vs-bots-sections.md):
//   AC-2 человек / федеративный человек → «Люди»; бот liza-bot-api (по домену
//        и по роли ai на чужом домене), ИИ liza/gpt/deepseek (bots.liza.ru и
//        AI-localpart на другом инстансе) → «Боты и ИИ»; Лиза первая.
//   AC-3 (данные) раздел без элементов пуст — экран по нему скрывает заголовок.
//   AC-6 (клиентская часть) разделы не добавляют профилей сверх выдачи
//        сервера — приватный бот, отфильтрованный user_search_guard, не
//        появится ни в одном разделе.
//   AC-4 (механика) роли ждём ≤ 1,5 с; поздний ответ зовёт onLate ровно раз;
//        успевший ответ onLate не зовёт; ошибка ролей поиск не роняет.
//
// Red-proof AC-2: убрать `isBotLikeMxid(userId) ||` из MatrixState.isBotOrAiUser
// → `@shop_bot:bots.liza.ru` и `@gpt:nadezhda.liza.ru` (без роли) уезжают в
// «Люди», тест красный.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/widgets/matrix.dart';

import 'search_sections_stubs.dart';
import 'test_client.dart';

void main() {
  group('partitionPeopleAndBots + MatrixState.isBotOrAiUser', () {
    late Client client;

    setUp(() async {
      client = await prepareTestClient(loggedIn: true);
    });

    tearDown(() async {
      await client.dispose();
    });

    // AC:RL-search-people-vs-bots-sections/2
    test('∀ кейс AC-2 попадает в свой раздел, Лиза первая в «Боты и ИИ»',
        () async {
      final roles = StubRoleService(
        client,
        // Бот liza-bot-api на домене компании — узнаём только по роли ai.
        serverAi: {'@cup_bot:liza.cyber-agro.ru'},
      );
      final matrix = SearchTestMatrixState(client, roles);
      await roles.fetchRoles(['@cup_bot:liza.cyber-agro.ru']);

      final profiles = [
        Profile(userId: '@anna:synapse.liza.laba.prodamus.tech'), // человек
        Profile(userId: '@shop_bot:bots.liza.ru'), // бот liza-bot-api
        Profile(userId: '@ivan:nadezhda.liza.ru'), // федеративный человек
        Profile(userId: '@gpt:bots.liza.ru'), // ИИ
        Profile(userId: '@cup_bot:liza.cyber-agro.ru'), // бот по роли ai
        Profile(userId: '@deepseek:bots.liza.ru'), // ИИ
        Profile(userId: '@gpt:nadezhda.liza.ru'), // ИИ на другом инстансе
        Profile(userId: MatrixState.lizaMxid), // Лиза — в середине выдачи
      ];

      final sections = partitionPeopleAndBots(
        profiles,
        isBotOrAi: matrix.isBotOrAiUser,
        lizaMxid: MatrixState.lizaMxid,
      );

      expect(sections.people.map((p) => p.userId).toList(), [
        '@anna:synapse.liza.laba.prodamus.tech',
        '@ivan:nadezhda.liza.ru',
      ]);
      expect(sections.botsAndAi.map((p) => p.userId).toList(), [
        MatrixState.lizaMxid,
        '@shop_bot:bots.liza.ru',
        '@gpt:bots.liza.ru',
        '@cup_bot:liza.cyber-agro.ru',
        '@deepseek:bots.liza.ru',
        '@gpt:nadezhda.liza.ru',
      ]);
    });

    // AC:RL-search-people-vs-bots-sections/2
    test('без роли ai бот на чужом домене остаётся среди людей до её прихода',
        () async {
      final roles = StubRoleService(
        client,
        serverAi: {'@cup_bot:liza.cyber-agro.ru'},
      );
      final matrix = SearchTestMatrixState(client, roles);
      final profiles = [Profile(userId: '@cup_bot:liza.cyber-agro.ru')];

      final before =
          partitionPeopleAndBots(profiles, isBotOrAi: matrix.isBotOrAiUser);
      expect(before.people, hasLength(1));
      expect(before.botsAndAi, isEmpty);

      await roles.fetchRoles(['@cup_bot:liza.cyber-agro.ru']);
      final after =
          partitionPeopleAndBots(profiles, isBotOrAi: matrix.isBotOrAiUser);
      expect(after.people, isEmpty);
      expect(after.botsAndAi.single.userId, '@cup_bot:liza.cyber-agro.ru');
    });

    // AC:RL-search-people-vs-bots-sections/3
    test('только люди → «Боты и ИИ» пуст; только боты → «Люди» пуст', () {
      final matrix = SearchTestMatrixState(client, StubRoleService(client));

      final humans = partitionPeopleAndBots(
        [Profile(userId: '@anna:prod'), Profile(userId: '@ivan:prod')],
        isBotOrAi: matrix.isBotOrAiUser,
      );
      expect(humans.botsAndAi, isEmpty);
      expect(humans.people, hasLength(2));

      final bots = partitionPeopleAndBots(
        [Profile(userId: '@gpt:bots.liza.ru')],
        isBotOrAi: matrix.isBotOrAiUser,
      );
      expect(bots.people, isEmpty);
      expect(bots.isNotEmpty, isTrue);

      expect(
        partitionPeopleAndBots(const [], isBotOrAi: (_) => true).isEmpty,
        isTrue,
      );
    });
  });

  // AC:RL-search-people-vs-bots-sections/6
  test('разбиение не добавляет профилей: в разделах ровно выдача сервера', () {
    // Приватного бота user_search_guard не отдаёт постороннему; клиентская
    // часть инварианта — разделы не подмешивают никого сверх выдачи (ни
    // фолбэк-ботов, ни Лизу, если её нет в ответе).
    final profiles = [
      Profile(userId: '@anna:prod'),
      Profile(userId: '@shop_bot:bots.liza.ru'),
    ];
    final sections = partitionPeopleAndBots(
      profiles,
      isBotOrAi: (id) => id.endsWith(':bots.liza.ru'),
      lizaMxid: '@liza:bots.liza.ru',
    );
    expect(
      [...sections.people, ...sections.botsAndAi].map((p) => p.userId).toSet(),
      profiles.map((p) => p.userId).toSet(),
    );
    expect(sections.people.length + sections.botsAndAi.length, 2);
  });

  group('waitForRolesBounded', () {
    // AC:RL-search-people-vs-bots-sections/4
    test('роли успели → ждём их, onLate не зовётся', () {
      fakeAsync((async) {
        final roles = Completer<void>();
        var done = false;
        var late = 0;
        waitForRolesBounded(roles.future, onLate: () => late++)
            .then((_) => done = true);

        async.elapse(const Duration(milliseconds: 400));
        expect(done, isFalse, reason: 'до ответа ролей выдачу не публикуем');
        roles.complete();
        async.flushMicrotasks();
        expect(done, isTrue);
        async.elapse(const Duration(seconds: 3));
        expect(late, 0);
      });
    });

    // AC:RL-search-people-vs-bots-sections/4
    test('роли опоздали → публикация ровно по таймауту 1,5 с, потом onLate',
        () {
      fakeAsync((async) {
        final roles = Completer<void>();
        var done = false;
        var late = 0;
        waitForRolesBounded(roles.future, onLate: () => late++)
            .then((_) => done = true);

        async.elapse(const Duration(milliseconds: 1499));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 1));
        expect(done, isTrue, reason: 'выдачу не держим дольше 1,5 с');
        expect(late, 0);

        roles.complete();
        async.flushMicrotasks();
        expect(late, 1, reason: 'поздние роли переразбивают выдачу');
      });
    });

    // AC:RL-search-people-vs-bots-sections/4
    test('ошибка загрузки ролей не роняет поиск и не зовёт onLate', () {
      fakeAsync((async) {
        final roles = Completer<void>();
        var done = false;
        var late = 0;
        waitForRolesBounded(roles.future, onLate: () => late++)
            .then((_) => done = true);

        roles.completeError(Exception('roles 500'));
        async.flushMicrotasks();
        expect(done, isTrue);
        async.elapse(const Duration(seconds: 3));
        expect(late, 0);
      });
    });
  });
}
