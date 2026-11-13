// ledger:RL-push-test-sender-and-acks
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_probe_api.dart';

void main() {
  test('AC:RL-push-test-sender-and-acks/10 статус: только явное true включает; '
      'ошибка, не-200 и мусор — выключено', () async {
    Future<PushProbeStatus> status(http.Response r) => fetchPushProbeStatus(
      'https://bot.example/liza/push/v1',
      httpClient: MockClient((req) async {
        expect(req.url.path, '/liza/push/v1/status');
        return r;
      }),
    );
    final on = await status(http.Response('{"test":true,"acks":true}', 200));
    expect((on.test, on.acks), (true, true));
    final off = await status(http.Response('{"test":"yes"}', 200));
    expect((off.test, off.acks), (false, false));
    expect((await status(http.Response('', 404))).test, isFalse);
    expect((await status(http.Response('<html>', 200))).acks, isFalse);
    final broken = await fetchPushProbeStatus(
      'https://bot.example/liza/push/v1',
      httpClient: MockClient((_) async => throw Exception('offline')),
    );
    expect(broken.test, isFalse);
  });

  test('AC:RL-push-test-sender-and-acks/11 тело POST /acks — блок push-report '
      '+ платформа + OpenID, без сырых идентификаторов', () {
    final block = buildPushAcks(
      nativeJournal: const [],
      local: [
        {'e': pushAckHash(r'$e1'), 'o': 'shown', 't': 1},
      ],
      pushkey: 'raw-pushkey',
      build: '3800',
      since: DateTime.fromMillisecondsSinceEpoch(0),
    );
    final body = pushAcksUploadBody(
      block: block,
      platform: 'android',
      openIdToken: 'oid',
      matrixServerName: 'example.org',
    );
    expect(body['platform'], 'android');
    expect(body['openid'], {
      'access_token': 'oid',
      'matrix_server_name': 'example.org',
    });
    expect(body['acks'], block['acks']);
    final raw = jsonEncode(body);
    expect(raw, isNot(contains('raw-pushkey')));
    expect(raw, isNot(contains(r'$e1')));
  });

  test('AC:RL-push-test-sender-and-acks/12 синтетическое событие теста '
      'распознаётся, настоящее — нет', () {
    expect(isTestPushEvent(r'$liza-test-0123abcd'), isTrue);
    expect(isTestPushEvent(r'$AbCliza-test-'), isFalse);
    expect(isTestPushEvent(null), isFalse);
  });

  test('AC:RL-push-test-sender-and-acks/11 на сервер уходит только новое '
      '(курсор), подтверждение тестового пуша помечено k=test', () {
    final test = pushAckHash(r'$liza-test-ab');
    final acks = <Object?>[
      {'e': pushAckHash(r'$new'), 'o': 'shown', 'src': 'local', 't': 300},
      {'e': test, 'o': 'received', 'src': 'native', 't': 250},
      {'e': pushAckHash(r'$old'), 'o': 'shown', 'src': 'local', 't': 100},
    ];
    final pending = pendingPushAcks(acks, cursor: 200, testHashes: {test});
    expect(pending.map((a) => a['t']), [300, 250]);
    expect(pending.firstWhere((a) => a['e'] == test)['k'], 'test');
    expect(pending.first.containsKey('k'), isFalse);
    expect(pendingPushAcks(acks, cursor: 300, testHashes: const {}), isEmpty);
  });

  test(
    'AC:RL-push-test-sender-and-acks/11 хэши тестовых пушей ограничены',
    () async {
      SharedPreferences.setMockInitialValues({});
      for (var i = 0; i < 25; i++) {
        await PushAckUploadState.rememberTestHash('h$i');
      }
      final hashes = await PushAckUploadState.testHashes();
      expect(hashes, hasLength(PushAckUploadState.maxTestHashes));
      expect(hashes.contains('h24'), isTrue);
      expect(hashes.contains('h0'), isFalse);
    },
  );
}
