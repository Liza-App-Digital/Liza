// ledger:RL-force-update-staged-policy
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/version_gate_service.dart';

VersionGateService _service(
  http.Client client, {
  String? platform = 'android',
  String? bundle,
}) => VersionGateService(
  httpClient: client,
  baseUrl: 'https://vg.test',
  platformKeyOverride: platform,
  currentBuildOverride: 3771,
  packageNameOverride: bundle,
);

void main() {
  test('запрос несёт build и bundle, ответ разбирается', () async {
    late Uri seen;
    final client = MockClient((req) async {
      seen = req.url;
      // Задержка: ответ не мгновенный, как в жизни.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return http.Response(
        jsonEncode({
          'platform': 'ios',
          'build': 3771,
          'stage': 'soft',
          'deadline_at': '2026-11-08T00:00:00Z',
          'server_now': '2026-11-02T12:00:00Z',
          'update_url': 'itms-beta://',
          'max_postpones': 3,
        }),
        200,
      );
    });
    final r = await _service(
      client,
      platform: 'ios',
      bundle: 'ru.prodamus.liza',
    ).fetchPolicy();
    expect(seen.path, '/policy/ios');
    expect(seen.queryParameters, {
      'build': '3771',
      'bundle': 'ru.prodamus.liza',
    });
    expect(r!.build, 3771);
    expect(r.policy!.stage, UpdateStage.soft);
    expect(r.policy!.deadlineAt, DateTime.utc(2026, 11, 8));
  });

  test('android без bundle', () async {
    late Uri seen;
    final client = MockClient((req) async {
      seen = req.url;
      return http.Response(jsonEncode({'stage': 'none'}), 200);
    });
    await _service(client).fetchPolicy();
    expect(seen.queryParameters, {'build': '3771'});
  });

  // AC:RL-force-update-staged-policy/8
  test('ошибка сервера — build известен, политики нет (берём кэш)', () async {
    for (final client in [
      MockClient((_) async => http.Response('err', 500)),
      MockClient((_) async => throw Exception('offline')),
      MockClient((_) async => http.Response('<html>', 200)),
    ]) {
      final r = await _service(client).fetchPolicy();
      expect(r!.build, 3771);
      expect(r.policy, isNull);
    }
  });

  test('неподдерживаемая платформа — проверять нечего', () async {
    var called = false;
    final client = MockClient((_) async {
      called = true;
      return http.Response('{}', 200);
    });
    expect(await _service(client, platform: null).fetchPolicy(), isNull);
    expect(called, isFalse);
  });

  test('404 — ключ неизвестен серверу: этапа нет, кэш не держим', () async {
    final r = await _service(
      MockClient((_) async => http.Response('{"detail":"no"}', 404)),
    ).fetchPolicy();
    expect(r!.policy!.stage, UpdateStage.none);
  });
}
