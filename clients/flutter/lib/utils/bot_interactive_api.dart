import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/miniapp_room.dart';

/// Приватный HTTP-контур: данные запроса не попадают в ленту/упоминания.
/// Экземпляр привязан к конкретному Matrix-сеансу; смена токена его инвалидирует.
class BotInteractiveApi {
  @visibleForTesting
  static http.Client Function() transportFactory = http.Client.new;
  static final _descriptors = Expando<_DescriptorScope>();
  final Client client;
  final http.Client transport;
  final String? _token;
  final String? _user;
  final Uri? _homeserver;
  bool _disposed = false;

  BotInteractiveApi(this.client, {http.Client? transport})
    : transport = transport ?? transportFactory(),
      _token = client.accessToken,
      _user = client.userID,
      _homeserver = client.homeserver;

  bool get isCurrent =>
      !_disposed &&
      _token != null &&
      client.accessToken == _token &&
      client.userID == _user &&
      client.homeserver == _homeserver;

  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (!isCurrent) throw StateError('Session changed');
    final base = AppConfig.lizaBotApiBaseForHomeserver(_homeserver?.host);
    final uri = Uri.parse('$base$path').replace(queryParameters: query);
    final request = http.Request(method, uri)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $_token',
        'Content-Type': 'application/json',
        if (_homeserver != null) 'X-Liza-Homeserver': _homeserver.toString(),
      });
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await transport.send(request).timeout(const Duration(seconds: 12)),
    ).timeout(const Duration(seconds: 12));
    if (!isCurrent) throw StateError('Session changed');
    if (response.statusCode == 404 && path == '/liza/bots/descriptor') {
      return {'registered': false};
    }
    if (response.statusCode != 200) {
      throw StateError('Interactive API: ${response.statusCode}');
    }
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) throw const FormatException();
    return data;
  }

  Future<RegisteredBot?> resolve({
    String? mxid,
    String? username,
    bool force = false,
  }) async {
    if (!isCurrent) throw StateError('Session changed');
    var scope = _descriptors[client];
    if (scope == null ||
        scope.token != _token ||
        scope.user != _user ||
        scope.homeserver != _homeserver) {
      scope = _DescriptorScope(_token, _user, _homeserver);
      _descriptors[client] = scope;
    }
    final key = mxid != null ? 'mxid:$mxid' : 'username:$username';
    final cached = scope.values[key];
    if (!force && cached != null && DateTime.now().isBefore(cached.$1)) {
      return cached.$2;
    }
    final pending = scope.pending[key];
    if (!force && pending != null) return pending;
    final captured = scope;
    late final Future<RegisteredBot?> future;
    future = _resolve(mxid: mxid, username: username).then((bot) {
      if (isCurrent && identical(captured.pending[key], future)) {
        captured.values[key] = (
          DateTime.now().add(Duration(seconds: bot == null ? 5 : 30)),
          bot,
        );
      }
      return bot;
    });
    captured.pending[key] = future;
    try {
      return await future;
    } finally {
      if (identical(captured.pending[key], future)) {
        captured.pending.remove(key);
      }
    }
  }

  Future<RegisteredBot?> _resolve({String? mxid, String? username}) async {
    final data = await request(
      'GET',
      '/liza/bots/descriptor',
      query: {
        if (mxid != null) 'mxid': mxid,
        if (username != null) 'username': username,
      },
    );
    final bot = RegisteredBot.parse(data);
    if (bot == null || (mxid != null && bot.mxid != mxid)) return null;
    return bot;
  }

  void dispose() {
    _disposed = true;
    transport.close();
  }
}

class RegisteredBot {
  final String mxid;
  final Map<String, dynamic> data;
  const RegisteredBot._(this.mxid, this.data);

  bool get supportsInteractive => data['system'] != true;

  /// Только подсказка при приглашении: ни один флаг не назначает Matrix PL.
  bool requestsAdministratorRights({required bool isChannel}) {
    final defaults = data['default_administrator_rights'];
    if (defaults is! Map) return false;
    final rights = defaults[isChannel ? 'channel' : 'group'];
    return rights is Map && rights.values.any((value) => value == true);
  }

  static RegisteredBot? parse(Map<String, dynamic> data) {
    final mxid = data['mxid'];
    if (data['registered'] != true ||
        mxid is! String ||
        !RegExp(r'^@[^:]+:.+$').hasMatch(mxid)) {
      return null;
    }
    return RegisteredBot._(mxid, data);
  }

  /// URL управляющей кнопки обязан совпасть с опубликованной привязкой реестра.
  MiniAppLaunch? appForUrl(String url) {
    final target = Uri.tryParse(url);
    if (target == null ||
        target.scheme != 'https' ||
        target.host.isEmpty ||
        target.userInfo.isNotEmpty) {
      return null;
    }
    final apps = data['miniapps'];
    if (apps is! List) return null;
    for (final app in apps) {
      if (app is! Map || app['app_id'] is! String) continue;
      if ((app['url'] ?? app['app_url']) != url) continue;
      return MiniAppLaunch(
        appUrl: url,
        botMxid: mxid,
        appId: app['app_id'] as String,
        appName: app['name'] is String ? app['name'] as String : mxid,
        appType: app['app_type'] is String
            ? app['app_type'] as String
            : 'third_party',
      );
    }
    return null;
  }
}

/// Не копирует произвольный Matrix JSON от бота: поддержан только article.
Map<String, dynamic>? safeInlineContent(Object? raw) {
  if (raw is! Map || raw['msgtype'] != 'm.text' || raw['body'] is! String) {
    return null;
  }
  final body = raw['body'] as String;
  if (body.isEmpty || body.length > 16000) return null;
  return {
    'msgtype': 'm.text',
    'body': body,
    if (raw['com.liza.inline_selection'] is String &&
        RegExp(
          r'^[A-Za-z0-9_-]{16,128}$',
        ).hasMatch(raw['com.liza.inline_selection'] as String))
      'com.liza.inline_selection': raw['com.liza.inline_selection'],
    if (raw['format'] == 'org.matrix.custom.html' &&
        raw['formatted_body'] is String &&
        (raw['formatted_body'] as String).length <= 32000) ...{
      'format': 'org.matrix.custom.html',
      'formatted_body': raw['formatted_body'],
    },
  };
}

class _DescriptorScope {
  final String? token;
  final String? user;
  final Uri? homeserver;
  final values = <String, (DateTime, RegisteredBot?)>{};
  final pending = <String, Future<RegisteredBot?>>{};
  _DescriptorScope(this.token, this.user, this.homeserver);
}
