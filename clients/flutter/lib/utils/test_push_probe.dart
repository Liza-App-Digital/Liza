import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'package:liza/utils/notification_health.dart';
import 'package:liza/utils/push_acks.dart';
import 'package:liza/utils/push_probe_api.dart';

/// Р8: тестовый пуш на СВОЙ pushkey — единственная проверка всей цепочки
/// Sygnal → APNs/FCM → устройство. Отправитель — эндпоинт рядом с приёмником
/// подтверждений (открытый вопрос 1 спеки); пока он не развёрнут, адрес пуст
/// и кнопка скрыта. Получение видим по `event_hash` в нативном журнале
/// (NSE / FCM-сервис) или в кольце [PushAckLog] — тем же ключом, что Ф1.1.
const testPushEndpoint = String.fromEnvironment('LIZA_TEST_PUSH_URL');

enum TestPushStatus { delivered, timedOut, rejected }

class TestPushResult {
  const TestPushResult(this.status, [this.elapsed]);
  final TestPushStatus status;
  final Duration? elapsed;
}

class TestPushProbe {
  TestPushProbe({
    required this.endpoint,
    required this.pushkey,
    required this.appId,
    required this.openIdToken,
    required this.matrixServerName,
    http.Client? httpClient,
    Future<Set<String>> Function()? receivedHashes,
    this.timeout = const Duration(seconds: 60),
    this.pollInterval = const Duration(seconds: 1),
    String Function()? nonce,
  }) : _http = httpClient ?? http.Client(),
       _receivedHashes = receivedHashes ?? defaultReceivedHashes,
       _nonce = nonce ?? _randomNonce;

  final String endpoint;
  final String pushkey;
  final String appId;
  final String openIdToken;
  final String matrixServerName;
  final Duration timeout;
  final Duration pollInterval;
  final http.Client _http;
  final Future<Set<String>> Function() _receivedHashes;
  final String Function() _nonce;

  static String _randomNonce() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  /// Синтетический event_id: настоящих событий тест не создаёт и других
  /// устройств пользователя не будит (пуш идёт только на этот pushkey).
  static String eventIdFor(String nonce) => '\$liza-test-$nonce';

  static Future<Set<String>> defaultReceivedHashes() async {
    final native = await NativePushDiagnostics.readJournal();
    final local = await PushAckLog.instance.read();
    return {
      for (final e in native)
        if (e['event_hash'] case final String h) h,
      for (final e in local)
        if (e['e'] case final String h) h,
    };
  }

  Future<TestPushResult> run() async {
    final nonce = _nonce();
    final hash = pushAckHash(eventIdFor(nonce));
    // Подтверждение этого пуша уйдёт на сервер с пометкой «тест» (M6).
    await PushAckUploadState.rememberTestHash(hash);
    final watch = Stopwatch()..start();
    final resp = await _http
        .post(
          Uri.parse(endpoint),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'nonce': nonce,
            'event_id': eventIdFor(nonce),
            'pushkey': pushkey,
            'app_id': appId,
            'openid': {
              'access_token': openIdToken,
              'matrix_server_name': matrixServerName,
            },
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return const TestPushResult(TestPushStatus.rejected);
    }
    while (watch.elapsed < timeout) {
      if ((await _receivedHashes()).contains(hash)) {
        return TestPushResult(TestPushStatus.delivered, watch.elapsed);
      }
      await Future<void>.delayed(pollInterval);
    }
    return const TestPushResult(TestPushStatus.timedOut);
  }
}
