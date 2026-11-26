import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';

/// msgtype служебного события СТАРОГО пути (клиенты ≤ 2.4.0): ключ ехал в чат.
///
/// Новые клиенты отправляют ключ через [XlApi] (HTTPS, без сообщения в
/// переписке). Константа нужна, чтобы исторические события не показывались в
/// таймлайне как обычные сообщения.
const String xlCredentialsMsgtype = 'com.liza.xl.credentials';

/// Старый способ доставки ключа (клиенты ≤ 2.4.0): служебное событие в чат.
///
/// Новый клиент его не отправляет — ключ идёт через [XlApi]. Оставлено для
/// совместимости формата и тестов фильтра таймлайна.
abstract final class XlCredentials {
  /// Служебное событие с ключом для Лизы.
  static Map<String, Object?> buildEvent(String apiKey) => {
    'msgtype': xlCredentialsMsgtype,
    'body': 'Подключение интеграции XL',
    'xl_api_key': apiKey.trim(),
  };
}

/// Серверный статус XL из ответа Bot API (после проверки ключа).
///
/// * [connected] — ключ сохранён и проверен `initialize` + `tools/list`;
/// * [keySaved] — ключ лежит в PG, даже если проверить не удалось (XL недоступен);
/// * [error] — `''`, `invalid_key` или `unavailable`.
class XlStatusInfo {
  const XlStatusInfo({
    required this.connected,
    required this.keySaved,
    required this.error,
  });

  final bool connected;
  final bool keySaved;
  final String error;

  /// Отключённое состояние (ключа нет / сервер не подтверждал).
  static const XlStatusInfo disconnected = XlStatusInfo(
    connected: false,
    keySaved: false,
    error: '',
  );

  factory XlStatusInfo.fromContent(Map<String, dynamic> content) =>
      XlStatusInfo(
        connected: content['connected'] == true,
        keySaved: content['key_saved'] == true,
        error: content['error'] is String ? content['error'] as String : '',
      );
}

/// Клиентские эндпоинты XL в Liza Bot API.
///
/// Ключ больше не едет сообщением в переписку и не хранится в account_data:
/// `POST /liza/v1/xl/connect` кладёт его в PG Лизы (шифротекст) и возвращает
/// серверный статус; `GET /liza/v1/xl/status` читает его при открытии карточки.
/// Аутентификация — Matrix access-token пользователя (whoami на его homeserver),
/// как у `/liza/mybots`.
abstract final class XlApi {
  static const Duration _connectTimeout = Duration(seconds: 60);
  static const Duration _statusTimeout = Duration(seconds: 10);

  /// Сохранить/удалить ключ. `null` — сеть/сервер не ответил (статус не трогаем).
  static Future<XlStatusInfo?> connect(Client client, String key) async {
    final data = await _request(
      client,
      'POST',
      '/liza/v1/xl/connect',
      body: {'key': key},
      timeout: _connectTimeout,
    );
    return data == null ? null : XlStatusInfo.fromContent(data);
  }

  /// Серверный статус карточки. `null` — сеть/сервер не ответил.
  static Future<XlStatusInfo?> status(Client client) async {
    final data = await _request(
      client,
      'GET',
      '/liza/v1/xl/status',
      timeout: _statusTimeout,
    );
    return data == null ? null : XlStatusInfo.fromContent(data);
  }

  static Future<Map<String, dynamic>?> _request(
    Client client,
    String method,
    String path, {
    Map<String, dynamic>? body,
    required Duration timeout,
  }) async {
    final token = client.accessToken;
    if (token == null || token.isEmpty) return null;
    final base = AppConfig.lizaBotApiBaseForHomeserver(client.homeserver?.host);
    final uri = Uri.parse('$base$path');
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
      if (client.homeserver != null)
        'X-Liza-Homeserver': client.homeserver.toString(),
    };
    try {
      final response = method == 'POST'
          ? await http
                .post(uri, headers: headers, body: jsonEncode(body ?? {}))
                .timeout(timeout)
          : await http.get(uri, headers: headers).timeout(timeout);
      if (response.statusCode != 200) {
        Logs().w('XL: $path → ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e) {
      Logs().w('XL: $path failed: $e');
      return null;
    }
  }
}
