import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/test_push_probe.dart';

/// Р8/M6: API проверки доставки на liza-bot-api хоумсервера аккаунта
/// (`/liza/push/v1`, включается флагом `LIZA_PUSH_PROBE_ENABLED` на сервере —
/// новая сборка для включения не нужна). `LIZA_TEST_PUSH_URL` — явный адрес
/// тестового пуша в обход статуса (локальная отладка).
String pushProbeBase(String? homeserverHost) =>
    '${AppConfig.lizaBotApiBaseForHomeserver(homeserverHost)}/liza/push/v1';

String testPushUrlFor(String? homeserverHost) => testPushEndpoint.isNotEmpty
    ? testPushEndpoint
    : '${pushProbeBase(homeserverHost)}/test';

class PushProbeStatus {
  const PushProbeStatus({required this.test, required this.acks});
  static const off = PushProbeStatus(test: false, acks: false);
  final bool test;
  final bool acks;
}

/// Ошибка, таймаут, старый сервер без маршрута → «выключено».
Future<PushProbeStatus> fetchPushProbeStatus(
  String base, {
  http.Client? httpClient,
}) async {
  final client = httpClient ?? http.Client();
  try {
    final resp = await client
        .get(Uri.parse('$base/status'))
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return PushProbeStatus.off;
    final json = jsonDecode(resp.body);
    if (json is! Map) return PushProbeStatus.off;
    return PushProbeStatus(
      test: json['test'] == true,
      acks: json['acks'] == true,
    );
  } catch (_) {
    return PushProbeStatus.off;
  } finally {
    if (httpClient == null) client.close();
  }
}

/// Тело `POST /acks`: блок `acks` push-report + платформа + OpenID. Тот же
/// блок, что уходит в GlitchTip — сырых pushkey/event_id в нём нет (AC-10).
Map<String, Object> pushAcksUploadBody({
  required Map<String, Object> block,
  required String platform,
  required String openIdToken,
  required String matrixServerName,
}) => {
  ...block,
  'platform': platform,
  'openid': {
    'access_token': openIdToken,
    'matrix_server_name': matrixServerName,
  },
};

/// Подтверждения, ещё не отправленные на сервер: новее курсора последней
/// удачной отправки. Сервер держит дедуп только в памяти пода, а реплик у
/// liza-bot-api несколько — без курсора 24-часовое окно каждого отчёта
/// считалось бы заново. Подтверждения тестового пуша клиент помечает сам
/// (`k: test`): момент отправки помнит лишь под, принявший `/test`.
List<Map<String, Object>> pendingPushAcks(
  List<Object?> acks, {
  required int cursor,
  required Set<String> testHashes,
}) => [
  for (final a in acks)
    if (a is Map<String, Object> && (a['t'] as int? ?? 0) > cursor)
      {...a, if (testHashes.contains(a['e'])) 'k': 'test'},
];

/// Курсор отправленных подтверждений и хэши недавних тестовых пушей.
class PushAckUploadState {
  static const cursorKey = 'push.acks_upload_cursor_v1';
  static const testHashesKey = 'push.test_hashes_v1';
  static const maxTestHashes = 20;

  static Future<int> cursor() async =>
      (await SharedPreferences.getInstance()).getInt(cursorKey) ?? 0;

  static Future<void> setCursor(int value) async =>
      (await SharedPreferences.getInstance()).setInt(cursorKey, value);

  static Future<Set<String>> testHashes() async =>
      ((await SharedPreferences.getInstance()).getStringList(testHashesKey) ??
              const [])
          .toSet();

  /// Хранилище недоступно — тест всё равно идёт (пометка — для метрики).
  static Future<void> rememberTestHash(String hash) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = [...?prefs.getStringList(testHashesKey), hash];
      await prefs.setStringList(
        testHashesKey,
        list.length > maxTestHashes
            ? list.sublist(list.length - maxTestHashes)
            : list,
      );
    } catch (_) {}
  }
}

/// Отправить подтверждения на сервер, если приём включён. Пустой блок не шлём.
/// Любая ошибка — молча false: метрика вторична, доставку пушей не трогает.
Future<bool> uploadPushAcksIfEnabled({
  required Client client,
  required Map<String, Object> block,
  required String platform,
  http.Client? httpClient,
}) async {
  final acks = block['acks'];
  if (acks is! List || acks.isEmpty || client.userID == null) return false;
  final transport = httpClient ?? http.Client();
  try {
    final pending = pendingPushAcks(
      acks,
      cursor: await PushAckUploadState.cursor(),
      testHashes: await PushAckUploadState.testHashes(),
    );
    if (pending.isEmpty) return false;
    final base = pushProbeBase(client.homeserver?.host);
    final status = await fetchPushProbeStatus(base, httpClient: transport);
    if (!status.acks) return false;
    final openId = await client.requestOpenIdToken(client.userID!, {});
    final resp = await transport
        .post(
          Uri.parse('$base/acks'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(
            pushAcksUploadBody(
              block: {...block, 'acks': pending},
              platform: platform,
              openIdToken: openId.accessToken,
              matrixServerName: openId.matrixServerName,
            ),
          ),
        )
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode != 200) return false;
    await PushAckUploadState.setCursor(
      pending.map((a) => a['t'] as int).reduce((a, b) => a > b ? a : b),
    );
    return true;
  } catch (e) {
    Logs().v('[Push] acks upload skipped: $e');
    return false;
  } finally {
    if (httpClient == null) transport.close();
  }
}

/// Синтетическое событие тестового пуша (`TestPushProbe.eventIdFor`): настоящей
/// комнаты нет, рисовать нечего и открывать нечего.
bool isTestPushEvent(String? eventId) =>
    eventId != null && eventId.startsWith(r'$liza-test-');
