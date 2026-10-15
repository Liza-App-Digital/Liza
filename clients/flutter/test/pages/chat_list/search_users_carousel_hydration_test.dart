// ledger:RL-search-handle-profile-hydration
//
// Страж карусели людей в поиске главного экрана на РЕАЛЬНОМ виджете
// (SearchUsersHorizontalList → SearchCarouselItem → Avatar/UserRoleBadge) и
// диалога UserDialog по long-press. Жалоба LABA-2552: находка по @-нику
// показывалась как `user_f86a7e57` с буквой «u».
//
// Покрываемые AC (tests/registry/RL-search-handle-profile-hydration.md):
//   AC-1 профиль доступен → после стадии 2 карточка «Саша» + Avatar.mxContent;
//        плашки admin/moderator в карточке скрыты (call-site hideRoleCodes).
//   AC-2 профиль недоступен, ник в кэше → «@alexxandrines», буква «a»,
//        localpart в дереве отсутствует; UserDialog — тот же заголовок.
//   AC-4 стадия 1 рисуется до гидратации, стадия 2 — после (тот же список,
//        замена по индексу, перерисовка через setState).
//   AC-5 отрисовка карусели не делает ни одного запроса /profile/ (сеть — только
//        в контроллере, RL-user-handles AC-3).
//
// Red-proof: вернуть в SearchUsersHorizontalList формулу
// `displayName ?? userId.localpart` → AC-2 краснеет (`user_f86a7e57` найден).
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/search_users_horizontal_list.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/user_handle_service.dart';
import 'package:liza/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/user_role_badge.dart';
import 'package:liza/utils/user_role_service.dart';

import '../../utils/test_client.dart';

const _sasha = '@user_f86a7e57:user.liza.ru';
const _sashaRoute = '/client/v3/profile/%40user_f86a7e57%3Auser.liza.ru';
const _sashaAvatar = 'mxc://user.liza.ru/DwhWXyeYYcOGIkfKrRrjENnw';

/// Кэш ников без сети и без SharedPreferences: то, что положил бы туда
/// searchHandles → rememberHandle (RL-user-handles AC-31).
class _StubHandleService extends UserHandleService {
  _StubHandleService(this._byMxid)
      : super(
          baseUrl: 'auth.test',
          accessTokenProvider: () => 'token',
          serverNameProvider: () => 'example.invalid',
          httpClient: MockClient((request) async {
            fail('карусель не должна ходить в auth-proxy: $request');
          }),
        );

  final Map<String, String> _byMxid;

  @override
  String? cachedHandleFor(String mxid) => _byMxid[mxid];
}

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client, this._handles);

  final Client _client;
  final UserHandleService _handles;

  @override
  Client get client => _client;

  @override
  UserHandleService get userHandleService => _handles;
}

Widget _wrap(Client client, UserHandleService handles, Widget child) =>
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client, handles),
        child: Scaffold(body: child),
      ),
    );

// Client оборачивает httpClient в FixedTimeoutHttpClient — фейк лежит в inner.
FakeMatrixApi _api(Client client) =>
    (client.httpClient as dynamic).inner as FakeMatrixApi;

void main() {
  late Client client;

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
  });

  tearDown(() async {
    await client.dispose();
  });

  testWidgets(
      // AC:RL-search-handle-profile-hydration/1
      // AC:RL-search-handle-profile-hydration/4
      'стадия 1 показывает @ник, стадия 2 — «Саша» с аватаром из профиля;'
      ' плашки admin/moderator скрыты', (tester) async {
    _api(client).api['GET']![_sashaRoute] = (_) => {
          'displayname': 'Саша',
          'avatar_url': _sashaAvatar,
        };
    final handles = _StubHandleService({_sasha: 'alexxandrines'});
    // Ровно та форма, что публикует chat_list.dart::_search() стадией 1.
    final published = SearchUserDirectoryResponse(
      results: [Profile(userId: _sasha)],
      limited: false,
    );
    late StateSetter rebuild;

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(
          client,
          handles,
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return SearchUsersHorizontalList(
                profiles: published.results,
                onItemTap: (_) {},
              );
            },
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
    });

    // Стадия 1: находка видна сразу по нику, не по localpart.
    expect(find.text('@alexxandrines'), findsOneWidget);
    expect(find.text('user_f86a7e57'), findsNothing);
    expect(find.text('Саша'), findsNothing);

    // Стадия 2 — как в chat_list.dart::_hydrateUserSearchResult, над тем же
    // опубликованным списком.
    await tester.runAsync(() async {
      final hydrated =
          await hydrateProfilesWithoutDisplayName(client, published.results);
      expect(applyHydratedProfiles(published.results, hydrated), isTrue);
      rebuild(() {});
      await tester.pump();
    });

    expect(find.text('Саша'), findsOneWidget);
    expect(find.text('@alexxandrines'), findsNothing);
    expect(find.text('user_f86a7e57'), findsNothing);
    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.mxContent, Uri.parse(_sashaAvatar));
    expect(avatar.name, 'Саша');
    // Call-site плашки роли (RL-search-hide-admin-moderator-badge) не потерян
    // при извлечении карусели из chat_list_body.dart.
    final badge = tester.widget<UserRoleBadge>(find.byType(UserRoleBadge));
    expect(
      badge.hideRoleCodes,
      containsAll([UserRoleService.adminRole, UserRoleService.moderatorRole]),
    );

    // Снимаем виджеты внутри runAsync, чтобы загрузка аватара MxcImage не
    // оставила таймеров ретрая в fake-async зоне.
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
    });
  });

  testWidgets(
      // AC:RL-search-handle-profile-hydration/2
      // AC:RL-search-handle-profile-hydration/5
      'профиль недоступен → «@alexxandrines», буква «a», localpart отсутствует;'
      ' отрисовка не ходит за профилем', (tester) async {
    var profileCalls = 0;
    _api(client).api['GET']![_sashaRoute] = (_) {
      profileCalls++;
      return {'displayname': 'Саша'};
    };
    final handles = _StubHandleService({_sasha: 'alexxandrines'});
    final published = SearchUserDirectoryResponse(
      results: [Profile(userId: _sasha)],
      limited: false,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(
          client,
          handles,
          SearchUsersHorizontalList(
            profiles: published.results,
            onItemTap: (_) {},
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('@alexxandrines'), findsOneWidget);
    expect(find.text('user_f86a7e57'), findsNothing);
    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.name, 'alexxandrines',
        reason: 'буква аватара — «a», не «@»');
    expect(avatar.mxContent, isNull);
    expect(profileCalls, 0,
        reason: 'build() карусели не делает запросов /profile/ — сеть только'
            ' в контроллере (RL-user-handles AC-3)');
  });

  testWidgets(
      // AC:RL-search-handle-profile-hydration/2
      'UserDialog по long-press до гидратации: заголовок @ник, не localpart',
      (tester) async {
    final handles = _StubHandleService({_sasha: 'alexxandrines'});

    await tester.runAsync(() async {
      await tester.pumpWidget(
        _wrap(client, handles, UserDialog(Profile(userId: _sasha))),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await tester.pump();
      await tester.pump();
    });

    expect(find.text('@alexxandrines'), findsWidgets);
    expect(find.text('user_f86a7e57'), findsNothing);
  });
}
