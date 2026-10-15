// Общие заглушки стражей RL-search-people-vs-bots-sections: экраны поиска
// людей рисуются на РЕАЛЬНЫХ виджетах, а сеть (auth-proxy, федерация,
// каталог ролей) подменена управляемыми двойниками.
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/user_handle_service.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

/// auth-proxy без сети: по нику никого не находим.
class StubHandleService extends UserHandleService {
  StubHandleService()
      : super(
          baseUrl: 'auth.test',
          accessTokenProvider: () => 'token',
          serverNameProvider: () => 'example.invalid',
          httpClient: MockClient((request) async {
            fail('тест не должен ходить в auth-proxy: $request');
          }),
        );

  @override
  Future<List<UserHandleMatch>> searchHandles(String query) async => const [];

  @override
  Future<String?> resolve(String handle) async => null;

  @override
  String? cachedHandleFor(String mxid) => null;
}

class StubFederatedSearch extends FederatedUserSearchService {
  StubFederatedSearch(super.client);

  @override
  Future<List<FederatedUserEntry>> searchUsers(String query) async => const [];
}

/// Каталог ролей под контролем теста: роль `ai` у [serverAi] «приходит» с
/// ответом fetchRoles. При [hold] каждый ответ ждёт, пока тест не отпустит
/// его через [releaseAll] — так моделируется медленный каталог ролей.
class StubRoleService extends UserRoleService {
  StubRoleService(Client client, {this.serverAi = const {}})
      : super(() => client);

  final Set<String> serverAi;
  final _known = <String>{};
  bool hold = false;
  final pending = <Completer<void>>[];
  int calls = 0;

  @override
  Future<void> fetchRoles(Iterable<String> userIds, {Client? client}) async {
    calls++;
    final ids = userIds.toList();
    if (hold) {
      final gate = Completer<void>();
      pending.add(gate);
      await gate.future;
    }
    _known.addAll(ids.where(serverAi.contains));
    rolesVersion.value++;
  }

  void releaseAll() {
    for (final g in pending) {
      if (!g.isCompleted) g.complete();
    }
    pending.clear();
  }

  @override
  bool isAiUser(String userId) => _known.contains(userId);
}

class SearchTestMatrixState extends liza_matrix.MatrixState {
  SearchTestMatrixState(this._client, this._roles);

  final Client _client;
  final UserRoleService _roles;
  final _handles = StubHandleService();

  @override
  Client get client => _client;

  @override
  UserHandleService get userHandleService => _handles;

  @override
  UserRoleService get userRoleService => _roles;

  @override
  FederatedUserSearchService get federatedUserSearchService =>
      StubFederatedSearch(_client);
}

Widget wrapWithMatrix(liza_matrix.MatrixState matrix, Widget child) =>
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: matrix,
        child: child,
      ),
    );

// Client оборачивает httpClient в FixedTimeoutHttpClient — фейк лежит в inner.
FakeMatrixApi fakeApi(Client client) =>
    (client.httpClient as dynamic).inner as FakeMatrixApi;

/// Каталог пользователей сервера: на запрос отдаёт тех из [directory], чьё
/// имя или MXID содержит поисковую строку.
void stubUserDirectory(Client client, Map<String, String> directory) {
  fakeApi(client).api['POST']!['/client/v3/user_directory/search'] = (req) {
    final body = req is String ? jsonDecode(req) as Map<String, Object?> : req;
    final term = (body['search_term'] as String).toLowerCase();
    return {
      'results': [
        for (final e in directory.entries)
          if (e.key.toLowerCase().contains(term) ||
              e.value.toLowerCase().contains(term))
            {'user_id': e.key, 'display_name': e.value},
      ],
      'limited': false,
    };
  };
}

/// Вертикальная координата виджета с текстом [text] — для проверки, что
/// элемент стоит ПОД заголовком своего раздела.
double topOfText(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dy;

double topOf(WidgetTester tester, Finder finder) =>
    tester.getTopLeft(finder).dy;
