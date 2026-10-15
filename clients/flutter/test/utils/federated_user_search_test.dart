import 'package:flutter_test/flutter_test.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:matrix/matrix.dart';

void main() {
  group('FederatedUserEntry.fromJson', () {
    test('парсит ответ Synapse', () {
      final entry = FederatedUserEntry.fromJson({
        'user_id': '@ivan:nadezhda.liza.ru',
        'display_name': 'Иван',
        'avatar_url': 'mxc://s/abc',
        'homeserver': 'nadezhda.liza.ru',
      });

      expect(entry.userId, '@ivan:nadezhda.liza.ru');
      expect(entry.displayName, 'Иван');
      expect(entry.avatarUrl, 'mxc://s/abc');
      expect(entry.homeserver, 'nadezhda.liza.ru');
    });

    test('терпит отсутствие необязательных полей', () {
      final entry = FederatedUserEntry.fromJson({'user_id': '@u:s'});

      expect(entry.userId, '@u:s');
      expect(entry.displayName, isNull);
      expect(entry.avatarUrl, isNull);
    });
  });

  group('mergeSearchResults', () {
    test('локальные идут первыми, федеративные следом', () {
      final merged = mergeSearchResults(
        local: [Profile(userId: '@local:prod', displayName: 'Локальный')],
        federated: [
          FederatedUserEntry.fromJson({
            'user_id': '@remote:nadezhda.liza.ru',
            'display_name': 'Удалённый',
          }),
        ],
      );

      expect(merged.map((p) => p.userId).toList(),
          ['@local:prod', '@remote:nadezhda.liza.ru']);
    });

    // Ровно та форма, в которой все три экрана поиска передают находки по
    // @-нику: UserHandleMatch -> FederatedUserEntry(userId) в общий список
    // federated. Дедуп здесь — единственное, что не даёт человеку,
    // найденному И по нику, И в directory, показаться дважды.
    // ledger:RL-user-handles AC:RL-user-handles/33
    test('человек, найденный и по нику, и в directory, показан один раз', () {
      final merged = mergeSearchResults(
        local: [Profile(userId: '@ivan:prod', displayName: 'Иван')],
        federated: [
          // находка по @-нику приходит голым userId — профиль у неё беднее
          FederatedUserEntry.fromJson({'user_id': '@ivan:prod'}),
          FederatedUserEntry.fromJson({'user_id': '@anna:prod'}),
        ],
      );

      expect(merged.map((p) => p.userId).toList(), ['@ivan:prod', '@anna:prod']);
      // Побеждает более полный профиль из directory, а не голый MXID.
      expect(merged.first.displayName, 'Иван');
    });

    test('дубли между источниками схлопываются, локальный выигрывает', () {
      final merged = mergeSearchResults(
        local: [Profile(userId: '@u:prod', displayName: 'Из directory')],
        federated: [
          FederatedUserEntry.fromJson({
            'user_id': '@u:prod',
            'display_name': 'Из федерации',
          }),
        ],
      );

      expect(merged.length, 1);
      expect(merged.first.displayName, 'Из directory');
    });

    test('пустые источники дают пустой результат', () {
      expect(
        mergeSearchResults(local: const [], federated: const []),
        isEmpty,
      );
    });

    test('добавление полного MXID не затирает найденные результаты', () {
      final merged = mergeSearchResults(
        local: [Profile(userId: '@найденный:prod', displayName: 'Найденный')],
        federated: const [],
      );

      const typed = '@другой:nadezhda.liza.ru';
      if (!merged.any((p) => p.userId == typed)) {
        merged.add(Profile(userId: typed));
      }

      expect(merged.map((p) => p.userId).toList(),
          ['@найденный:prod', '@другой:nadezhda.liza.ru']);
    });
  });

  // Прежний pinAiProfilesFirst превращён в разбиение на разделы
  // (RL-search-people-vs-bots-sections); кейсы классификатора — в
  // people_and_bots_partition_test.dart.
  group('partitionPeopleAndBots', () {
    test('боты/ИИ уходят в свой раздел, порядок внутри разделов сохраняется',
        () {
      final profiles = [
        Profile(userId: '@human1:prod', displayName: 'Человек 1'),
        Profile(userId: '@ai:prod', displayName: 'AI-помощник'),
        Profile(userId: '@human2:prod', displayName: 'Человек 2'),
      ];

      final sections = partitionPeopleAndBots(
        profiles,
        isBotOrAi: (id) => id == '@ai:prod',
      );

      expect(sections.people.map((p) => p.userId).toList(),
          ['@human1:prod', '@human2:prod']);
      expect(sections.botsAndAi.map((p) => p.userId).toList(), ['@ai:prod']);
    });

    test('Лиза идёт первой в «Боты и ИИ»', () {
      final profiles = [
        Profile(userId: '@human:prod'),
        Profile(userId: '@gpt:bots.liza.ru'),
        Profile(userId: '@liza:bots.liza.ru'),
      ];

      final sections = partitionPeopleAndBots(
        profiles,
        isBotOrAi: (id) => id.endsWith(':bots.liza.ru'),
        lizaMxid: '@liza:bots.liza.ru',
      );

      expect(sections.botsAndAi.map((p) => p.userId).toList(),
          ['@liza:bots.liza.ru', '@gpt:bots.liza.ru']);
      expect(sections.people.map((p) => p.userId).toList(), ['@human:prod']);
    });

    test('без lizaMxid порядок внутри «Боты и ИИ» не меняется', () {
      final profiles = [
        Profile(userId: '@gpt:bots.liza.ru'),
        Profile(userId: '@liza:bots.liza.ru'),
      ];

      final sections = partitionPeopleAndBots(
        profiles,
        isBotOrAi: (_) => true,
      );

      expect(sections.botsAndAi.map((p) => p.userId).toList(),
          ['@gpt:bots.liza.ru', '@liza:bots.liza.ru']);
      expect(sections.people, isEmpty);
    });
  });
}
