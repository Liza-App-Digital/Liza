// ignore_for_file: depend_on_referenced_packages

// Стражи «ожидаемый исход пуш-контура ≠ error в GlitchTip» (2026-10-13):
// - #508: resume после выхода последнего аккаунта — `clients.first` на пустом
//   списке (StateError) из updateBadgeCount;
// - #2100: postPusher → M_UNKNOWN_TOKEN (сессию отозвали) уходил error-issue;
// - #2040: 502 nginx на рестарте Synapse — сырой HTML error-issue после 3
//   ретраев, уложившихся в простой;
// - #185/#271/#90: таймаут/5xx при фоновом пуше — error-issue на каждый пуш.
// Мост Logs().e → Monitoring.captureSdkError, поэтому «не ушло в мониторинг»
// проверяем как «нет записи уровня error» в Logs().outputEvents.
// Реальные ошибки (4xx-reject pusher, не сетевые типы) — по-прежнему error.
//
// ledger:RL-push-monitoring-expected-outcomes

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/background_push.dart';
import 'package:liza/utils/push_helper.dart';

import 'test_client.dart';

const _gateway = 'https://push.tech.liza.ru/_matrix/push/v1/notify';
const _token = 'apns-token-of-this-device';

const _nginx502 = '<html>\r\n<head><title>502 Bad Gateway</title></head>\r\n'
    '<body>\r\n<center><h1>502 Bad Gateway</h1></center>\r\n'
    '<hr><center>nginx/1.29.0</center>\r\n</body>\r\n</html>';

/// Сервер, отвечающий на `POST /pushers/set` заданным статусом и телом.
class _PusherSetFailingApi extends FakeMatrixApi {
  _PusherSetFailingApi(this.status, this.body);

  final int status;
  final String body;
  int posts = 0;

  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    final path = request.url.path;
    if (path.endsWith('/client/v3/pushers') && request.method == 'GET') {
      return http.Response(jsonEncode({'pushers': []}), 200);
    }
    if (path.endsWith('/client/v3/pushers/set') && request.method == 'POST') {
      posts++;
      return http.Response(body, status);
    }
    return super.mockIntercept(request);
  }
}

List<LogEvent> _errorsSince(int from) => Logs()
    .outputEvents
    .skip(from)
    .where((e) => e.level == Level.error || e.level == Level.wtf)
    .toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Без хранилища настроек setupPusher пишет в лог error «Unable to fetch …»
  // — шум, неотличимый от проверяемого.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('isTransientServerOrNetworkError', () {
    // AC:RL-push-monitoring-expected-outcomes/1
    test('сеть, таймаут и 5xx SDK — транзиентны', () {
      for (final e in <Object>[
        Exception(_nginx502), // #2040: MatrixApi.request на 5xx
        Exception('http error response'), // #90: сгенерированный API
        Exception('{"errcode":"M_UNKNOWN","error":"Internal server error"}'),
        Exception(''),
        TimeoutException('x', const Duration(seconds: 8)), // #185/#271
        const SocketException('down'),
        http.ClientException('reset'),
      ]) {
        expect(isTransientServerOrNetworkError(e), isTrue, reason: '$e');
      }
    });

    // AC:RL-push-monitoring-expected-outcomes/2
    test('ошибки кода и ответы сервера по существу — НЕ транзиентны', () {
      for (final e in <Object>[
        StateError('No element'),
        const FormatException('bad json'),
        Exception('Unable to find event for this push notification!'),
        ArgumentError('x'),
        MatrixException.fromJson({'errcode': 'M_FORBIDDEN', 'error': 'no'}),
      ]) {
        expect(isTransientServerOrNetworkError(e), isFalse, reason: '$e');
      }
    });
  });

  // AC:RL-push-monitoring-expected-outcomes/3
  test('#508: updateBadgeCount без клиентов (все вышли) не бросает', () async {
    await expectLater(BackgroundPush.forTest([]).updateBadgeCount(), completes);
  });

  group('setupPusher: что уходит в мониторинг', () {
    late List<Duration> savedDelays;
    setUp(() {
      savedDelays = BackgroundPush.postPusherRetryDelays;
      BackgroundPush.postPusherRetryDelays = const [
        Duration.zero,
        Duration.zero,
        Duration.zero,
      ];
    });
    tearDown(() => BackgroundPush.postPusherRetryDelays = savedDelays);

    Future<(_PusherSetFailingApi, Client)> setup(int status, String body) async {
      final api = _PusherSetFailingApi(status, body);
      final client = await prepareTestClient(loggedIn: true, httpClient: api);
      return (api, client);
    }

    Future<void> register(Client client) => BackgroundPush.forTest([client])
        .setupPusher(client: client, gatewayUrl: _gateway, token: _token);

    // AC:RL-push-monitoring-expected-outcomes/4
    test('#2100: M_UNKNOWN_TOKEN — без error и без повторов', () async {
      final (api, client) = await setup(
        401,
        jsonEncode({
          'errcode': 'M_UNKNOWN_TOKEN',
          'error': 'Invalid access token passed.',
        }),
      );
      final from = Logs().outputEvents.length;
      await register(client);
      expect(_errorsSince(from), isEmpty);
      expect(api.posts, 1);
      await client.dispose();
    });

    // AC:RL-push-monitoring-expected-outcomes/5
    test('#2040: 502 nginx — ретраи по всем паузам, без error-issue', () async {
      final (api, client) = await setup(502, _nginx502);
      final from = Logs().outputEvents.length;
      await register(client);
      expect(api.posts, BackgroundPush.postPusherRetryDelays.length + 1);
      expect(_errorsSince(from), isEmpty);
      await client.dispose();
    });

    // AC:RL-push-monitoring-expected-outcomes/6
    test('паузы ретраев переживают рестарт прод-Synapse (≥45 с суммарно)', () {
      final total = savedDelays.fold(Duration.zero, (a, b) => a + b);
      expect(total, greaterThanOrEqualTo(const Duration(seconds: 45)));
    });

    // AC:RL-push-monitoring-expected-outcomes/7
    test('4xx-отказ (не токен) по-прежнему уходит error', () async {
      final (_, client) = await setup(
        400,
        jsonEncode({'errcode': 'M_INVALID_PARAM', 'error': 'bad pusher'}),
      );
      final from = Logs().outputEvents.length;
      await register(client);
      expect(_errorsSince(from), isNotEmpty);
      await client.dispose();
    });
  });
}
