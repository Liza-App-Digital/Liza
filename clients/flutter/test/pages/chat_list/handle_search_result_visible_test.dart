// Страж доставки находок по @-нику до выдачи ГЛАВНОГО экрана.
// ledger:RL-user-handles
//
// Жалоба пользователя была именно про главный экран: «поиск по никнеймам не
// работает». Резолва в контроллере для этого мало — важно, что найденный по
// нику человек доезжает до КАРУСЕЛИ людей. В chat_list.dart результаты
// публикуются не через возвращаемое значение mergeSearchResults, а МУТАЦИЕЙ
// userSearchResult.results (..clear() ..addAll(merged)), из него считаются разделы; стоит кому-то
// разорвать эту цепочку — находка по нику молча пропадёт из интерфейса,
// оставаясь «успешно отрезолвленной» в контроллере.
//
// Как ИМЕННО карусель подписывает такую находку (имя из профиля → @ник →
// никогда localpart) — отдельный страж на реальном виджете:
// search_users_carousel_hydration_test.dart (RL-search-handle-profile-hydration).
// Прежний второй тест этого файла рисовал РЕПЛИКУ карусели и закреплял показ
// localpart — удалён после LABA-2552.
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/federated_user_search_service.dart';

void main() {
  group('находка по @-нику доезжает до выдачи главного экрана', () {
    // AC:RL-user-handles/33
    test('mergeSearchResults + мутация results публикуют находку по нику', () {
      // Ровно та форма, в которой _search() складывает источники: directory
      // отдал одного человека, поиск по нику — ДРУГОГО (его в directory нет).
      final userSearchResult = SearchUserDirectoryResponse(
        results: [Profile(userId: '@known:prod', displayName: 'Из directory')],
        limited: false,
      );

      final merged = mergeSearchResults(
        local: userSearchResult.results,
        federated: [
          // находка по нику приходит голым userId
          FederatedUserEntry.fromJson({'user_id': '@byhandle:prod'}),
        ],
      );
      // Публикация — мутацией, как в chat_list.dart::_search().
      userSearchResult.results
        ..clear()
        ..addAll(merged);
      // Карусели рисуют разделы, посчитанные из userSearchResult.results
      // (RL-search-people-vs-bots-sections) — ровно как _partitionUserSearch.
      final sections = partitionPeopleAndBots(
        userSearchResult.results,
        isBotOrAi: (_) => false,
      );

      // Если находка по нику не попала в раздел «Люди», на экране её не будет.
      expect(
        sections.people.map((p) => p.userId),
        containsAll(<String>['@known:prod', '@byhandle:prod']),
        reason: 'человек, найденный по нику, обязан быть в выдаче экрана',
      );
    });
  });
}
