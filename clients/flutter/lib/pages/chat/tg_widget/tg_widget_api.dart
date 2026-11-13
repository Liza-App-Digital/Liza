import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

/// Коды `WidgetRequestError` профиля 1 (Telegram, один в один).
abstract final class TgWidgetErrorCode {
  static const notAllowed = 'NOT_ALLOWED';
  static const busy = 'BUSY';
  static const rateLimited = 'RATE_LIMITED';
  static const timeout = 'TIMEOUT';
  static const failed = 'FAILED';
  static const invalidAnswer = 'INVALID_ANSWER';
  static const rejected = 'REJECTED';
  static const badRequest = 'BAD_REQUEST';

  static const all = {
    notAllowed,
    busy,
    rateLimited,
    timeout,
    failed,
    invalidAnswer,
    rejected,
    badRequest,
  };
}

class TgWidgetQueryResult {
  final bool ok;
  final String? result;
  final String? code;

  const TgWidgetQueryResult.success(this.result) : ok = true, code = null;
  const TgWidgetQueryResult.error(String this.code) : ok = false, result = null;
}

class TgSharedWidgetState {
  final String? publicData;
  final int cacheTime;
  final String? etag;
  final bool notModified;

  const TgSharedWidgetState({
    required this.publicData,
    required this.cacheTime,
    required this.etag,
    this.notModified = false,
  });
}

/// OpenID-токен Matrix в форме, которую liza-bot-api уже принимает от push
/// probe (`adapter/push_probe_http.py::_openid_user`).
class TgWidgetOpenId {
  final String accessToken;
  final String matrixServerName;
  final DateTime expiresAt;

  const TgWidgetOpenId({
    required this.accessToken,
    required this.matrixServerName,
    required this.expiresAt,
  });

  Map<String, Object> toJson() => {
    'access_token': accessToken,
    'matrix_server_name': matrixServerName,
  };
}

typedef TgWidgetOpenIdProvider = Future<TgWidgetOpenId> Function();

/// Переиспользование OpenID-токена: фоновые запросы виджета идут раз в 5 с,
/// и запрашивать токен у Synapse на каждый — лишняя нагрузка.
class TgWidgetOpenIdCache {
  TgWidgetOpenIdCache._();
  static final Map<String, TgWidgetOpenId> _cache = {};

  /// Шов для тестов: OpenID без Synapse.
  static TgWidgetOpenIdProvider? debugOverride;

  static TgWidgetOpenIdProvider forClient(Client client) =>
      debugOverride ?? _forClient(client);

  static TgWidgetOpenIdProvider _forClient(Client client) => () async {
    final userId = client.userID;
    if (userId == null) throw StateError('no user');
    final hit = _cache[userId];
    if (hit != null &&
        hit.expiresAt.isAfter(DateTime.now().add(const Duration(minutes: 1)))) {
      return hit;
    }
    final token = await client.requestOpenIdToken(userId, {});
    final fresh = TgWidgetOpenId(
      accessToken: token.accessToken,
      matrixServerName: token.matrixServerName,
      expiresAt: DateTime.now().add(Duration(seconds: token.expiresIn)),
    );
    _cache[userId] = fresh;
    return fresh;
  };

  static void clear() => _cache.clear();
}

/// HTTP-клиент виджетных эндпоинтов liza-bot-api (D13). База — та же, что у
/// остальных `/liza/v1/*` (`AppConfig.lizaBotApiBaseForHomeserver`).
class TgWidgetApi {
  final String base;
  final http.Client _http;
  final DateTime Function() _now;

  TgWidgetApi(this.base, {http.Client? httpClient, DateTime Function()? now})
    : _http = httpClient ?? http.Client(),
      _now = now ?? DateTime.now;

  static final Map<String, TgWidgetApi> _instances = {};

  /// Шов для тестов: подменяет фабрику API для всех баз.
  static TgWidgetApi Function(String base)? debugFactory;

  static TgWidgetApi forBase(String base) {
    final factory = debugFactory;
    if (factory != null) return _instances[base] ??= factory(base);
    return _instances[base] ??= TgWidgetApi(base);
  }

  static void debugReset() => _instances.clear();

  static const Duration keysTtl = Duration(minutes: 10);

  /// Повторно за неизвестным `kid` идём не чаще раза в 30 с: подделка с
  /// мусорным `kid` иначе гоняла бы клиент на сервер на каждый кадр.
  static const Duration unknownKidRefetch = Duration(seconds: 30);
  static const Duration capabilitiesTtl = Duration(minutes: 10);

  /// После ошибки `/widget-keys` не стучимся чаще раза в минуту.
  static const Duration keysErrorBackoff = Duration(seconds: 60);

  ({DateTime at, Map<String, String> keys})? _keys;
  Future<Map<String, String>>? _keysInFlight;
  DateTime? _lastKeysFetch;
  DateTime? _keysFailedAt;
  final Map<String, ({DateTime at, Map<String, Object?>? viewer})> _viewers =
      {};
  final Map<String, ({DateTime until, bool verified})> _bots = {};
  final Map<String, Future<bool>> _botsInFlight = {};
  ({DateTime at, Set<String> scopes})? _scopes;
  Future<Set<String>>? _scopesInFlight;

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$base$path').replace(queryParameters: query);

  /// `kid` → публичный ключ (unpadded base64). [needKid] — ключ, которого не
  /// оказалось в кэше: при ротации его стоит перезапросить раньше TTL.
  Future<Map<String, String>> widgetKeys({String? needKid}) async {
    final cached = _keys;
    final now = _now();
    final failed = _keysFailedAt;
    if (failed != null && now.difference(failed) < keysErrorBackoff) {
      return cached?.keys ?? const {};
    }
    final fresh = cached != null && now.difference(cached.at) < keysTtl;
    final missing = needKid != null && cached?.keys[needKid] == null;
    final mayRefetch =
        _lastKeysFetch == null ||
        now.difference(_lastKeysFetch!) >= unknownKidRefetch;
    if (cached != null && fresh && !(missing && mayRefetch)) {
      return cached.keys;
    }
    if (cached != null && !fresh && !mayRefetch) return cached.keys;
    return _keysInFlight ??= _fetchKeys().whenComplete(
      () => _keysInFlight = null,
    );
  }

  Future<Map<String, String>> _fetchKeys() async {
    _lastKeysFetch = _now();
    try {
      final resp = await _http
          .get(_uri('/liza/v1/widget-keys'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        _keysFailedAt = _now();
        return _keys?.keys ?? const {};
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      final keys = <String, String>{};
      final list = json is Map ? json['keys'] : null;
      if (list is List) {
        for (final k in list) {
          if (k is Map &&
              k['alg'] == 'ed25519' &&
              k['kid'] is String &&
              k['public_key'] is String) {
            keys[k['kid'] as String] = k['public_key'] as String;
          }
        }
      }
      _keys = (at: _now(), keys: keys);
      _keysFailedAt = null;
      return keys;
    } catch (e) {
      Logs().w('[TgWidget] widget-keys недоступны: ${e.runtimeType}');
      _keysFailedAt = _now();
      return _keys?.keys ?? const {};
    }
  }

  /// Проверенный ли бот (D11). Ошибка сети = «не проверен»: худший исход —
  /// лишняя кнопка «Запустить», а не исполнение чужого кода без спроса.
  Future<bool> botVerified(String mxid) {
    final hit = _bots[mxid];
    if (hit != null && _now().isBefore(hit.until)) {
      return Future.value(hit.verified);
    }
    // Тело-блок обязателен: `remove` вернул бы этот же future, и
    // `whenComplete` ждал бы сам себя.
    return _botsInFlight[mxid] ??= _fetchBot(mxid).whenComplete(() {
      _botsInFlight.remove(mxid);
    });
  }

  Future<bool> _fetchBot(String mxid) async {
    try {
      final resp = await _http
          .get(_uri('/liza/v1/widget-bot', {'mxid': mxid}))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return false;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map) return false;
      final verified = json['verified'] == true;
      final cacheTime = json['cache_time'];
      final ttl = cacheTime is int && cacheTime > 0 ? cacheTime : 300;
      _bots[mxid] = (
        until: _now().add(Duration(seconds: ttl)),
        verified: verified,
      );
      return verified;
    } catch (e) {
      Logs().w('[TgWidget] widget-bot недоступен: ${e.runtimeType}');
      return false;
    }
  }

  static const Duration viewerTtl = Duration(minutes: 10);

  /// `TelegramWidget.viewer` (D13, `POST /liza/v1/widget-viewer`): тот же
  /// пользователь, что бот видит в `from`. Ошибка → `null`, виджет всё равно
  /// грузится. Кэш — по (аккаунт, комната или widget_id).
  Future<Map<String, Object?>?> viewer({
    required String accountId,
    required TgWidgetOpenIdProvider openId,
    required String widgetId,
    String? roomId,
    String? eventId,
  }) async {
    final key = '$accountId|${roomId ?? 'w:$widgetId'}';
    final hit = _viewers[key];
    if (hit != null && _now().difference(hit.at) < viewerTtl) return hit.viewer;
    Map<String, Object?>? viewer;
    try {
      final token = await openId();
      final resp = await _http
          .post(
            _uri('/liza/v1/widget-viewer'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'openid': token.toJson(),
              'room_id': ?roomId,
              'event_id': ?eventId,
              'widget_id': widgetId,
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      viewer = json is Map ? parseTgWidgetViewer(json['viewer']) : null;
    } catch (e) {
      Logs().v('[TgWidget] widget-viewer: ${e.runtimeType}');
      return null;
    }
    _viewers[key] = (at: _now(), viewer: viewer);
    return viewer;
  }

  /// `widgets.scopes` из `/liza/v1/capabilities`. `null` — ещё неизвестно.
  Set<String>? scopesCached() => _scopes?.scopes;

  Future<Set<String>> scopes() async {
    final cached = _scopes;
    if (cached != null && _now().difference(cached.at) < capabilitiesTtl) {
      return cached.scopes;
    }
    return _scopesInFlight ??= _fetchScopes().whenComplete(
      () => _scopesInFlight = null,
    );
  }

  Future<Set<String>> _fetchScopes() async {
    try {
      final resp = await _http
          .get(_uri('/liza/v1/capabilities'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return _scopes?.scopes ?? const {};
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      final widgets = json is Map ? json['widgets'] : null;
      final list = widgets is Map ? widgets['scopes'] : null;
      final scopes = <String>{
        if (list is List)
          for (final s in list)
            if (s is String) s,
      };
      _scopes = (at: _now(), scopes: scopes);
      return scopes;
    } catch (e) {
      Logs().w('[TgWidget] capabilities недоступны: ${e.runtimeType}');
      return _scopes?.scopes ?? const {};
    }
  }

  /// `public_data` общего виджета. `null` — виджета нет (404) или сеть.
  Future<TgSharedWidgetState?> sharedWidget(
    String widgetId, {
    String? etag,
  }) async {
    try {
      final resp = await _http
          .get(
            _uri('/liza/v1/widgets/${Uri.encodeComponent(widgetId)}'),
            headers: {if (etag != null) 'If-None-Match': etag},
          )
          .timeout(const Duration(seconds: 10));
      final cacheTime = _maxAge(resp.headers['cache-control']);
      if (resp.statusCode == 304) {
        return TgSharedWidgetState(
          publicData: null,
          cacheTime: cacheTime ?? 30,
          etag: etag,
          notModified: true,
        );
      }
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map) return null;
      final data = json['public_data'];
      final bodyCache = json['cache_time'];
      return TgSharedWidgetState(
        publicData: data is String && data.isNotEmpty ? data : null,
        cacheTime: bodyCache is int ? bodyCache : (cacheTime ?? 30),
        etag: resp.headers['etag'],
      );
    } catch (e) {
      Logs().v('[TgWidget] shared widget poll: ${e.runtimeType}');
      return null;
    }
  }

  static int? _maxAge(String? header) {
    if (header == null) return null;
    final m = RegExp(r'max-age=(\d+)').firstMatch(header);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// `POST /liza/v1/widget-query`. Сервер держит запрос до ответа бота или
  /// 15 с; клиентский таймаут чуть больше, чтобы `TIMEOUT` пришёл от сервера.
  Future<TgWidgetQueryResult> query({
    required TgWidgetOpenIdProvider openId,
    required String widgetId,
    required String data,
    required bool background,
    required String instanceId,
    String? roomId,
    String? eventId,
  }) async {
    final TgWidgetOpenId token;
    try {
      token = await openId();
    } catch (e) {
      Logs().w('[TgWidget] OpenID не получен: ${e.runtimeType}');
      return const TgWidgetQueryResult.error(TgWidgetErrorCode.failed);
    }
    try {
      final resp = await _http
          .post(
            _uri('/liza/v1/widget-query'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'openid': token.toJson(),
              'room_id': ?roomId,
              'event_id': ?eventId,
              'widget_id': widgetId,
              'data': data,
              'background': background,
              'instance_id': instanceId,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        return const TgWidgetQueryResult.error(TgWidgetErrorCode.failed);
      }
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map) {
        return const TgWidgetQueryResult.error(TgWidgetErrorCode.failed);
      }
      if (json['ok'] == true) {
        final result = json['result'];
        return TgWidgetQueryResult.success(result is String ? result : null);
      }
      final code = json['code'];
      return TgWidgetQueryResult.error(
        code is String && TgWidgetErrorCode.all.contains(code)
            ? code
            : TgWidgetErrorCode.failed,
      );
    } on TimeoutException {
      return const TgWidgetQueryResult.error(TgWidgetErrorCode.timeout);
    } catch (e) {
      Logs().w('[TgWidget] widget-query: ${e.runtimeType}');
      return const TgWidgetQueryResult.error(TgWidgetErrorCode.failed);
    }
  }
}

/// `WidgetViewer` Telegram: `id` обязателен, остальное — только валидное.
Map<String, Object?>? parseTgWidgetViewer(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  if (id is! int) return null;
  String? str(String k) {
    final v = raw[k];
    return v is String && v.isNotEmpty && v.length <= 256 ? v : null;
  }

  return {
    'id': id,
    'first_name': ?str('first_name'),
    'last_name': ?str('last_name'),
    'username': ?str('username'),
    if (raw['is_premium'] is bool) 'is_premium': raw['is_premium'],
  };
}
