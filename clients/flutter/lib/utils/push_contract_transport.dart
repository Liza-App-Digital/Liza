import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:liza/config/app_config.dart';

/// Публичные client origins из deploy/well-known/*/matrix/client. Явный
/// дополнительный origin допускает собственный локальный стенд при сборке.
abstract final class PushContractEndpoint {
  static const origins = {
    'https://synapse.liza.laba.prodamus.tech',
    'https://liza.cyber-agro.ru',
    'https://nadezhda.liza.ru',
    'https://bots.liza.ru',
    'https://victoryeng.liza.ru',
    'https://d3n8it.liza.ru',
    'https://pflb.liza.ru',
    'https://skharkov.liza.ru',
    'https://ppetipak.liza.ru',
    'https://hello.liza.ru',
    'https://user.liza.ru',
  };
  static final _additional = const String.fromEnvironment(
    'LIZA_PUSH_CONTRACT_ISSUERS',
  ).split(',').toSet();

  static Uri? forIssuer(Uri? hs, {Set<String>? additional}) {
    if (hs == null ||
        hs.host.isEmpty ||
        hs.userInfo.isNotEmpty ||
        hs.hasQuery ||
        hs.hasFragment ||
        (hs.path.isNotEmpty && hs.path != '/')) {
      return null;
    }
    final loopback = const {
      'localhost',
      '127.0.0.1',
      '[::1]',
      '::1',
    }.contains(hs.host);
    if (hs.scheme != 'https' && !(hs.scheme == 'http' && loopback)) return null;
    if (!origins.contains(hs.origin) &&
        !(additional ?? _additional).contains(hs.origin)) {
      return null;
    }
    return Uri.parse(
      '${AppConfig.lizaBotApiBaseForHomeserver(hs.host)}/liza/push/v1/',
    );
  }
}

/// Каждый запрос имеет отдельный HTTP client, закрываемый при timeout/dispose.
/// Размер ответа ограничен и у chunked transfer без Content-Length.
class PushContractTransport {
  PushContractTransport({http.Client Function()? open})
    : open = open ?? http.Client.new;
  final http.Client Function() open;
  http.Client? _flight;

  void cancel() {
    _flight?.close();
    _flight = null;
  }

  Future<({int status, Map data, int retry})> request(
    Uri url, {
    String? token,
    String? issuer,
    String? body,
    int ageMs = 0,
  }) async {
    final transport = open();
    _flight = transport;
    Future<({int status, Map data, int retry})> send() async {
      final req = http.Request(body == null ? 'GET' : 'POST', url)
        ..followRedirects = false;
      if (body != null) {
        req.headers.addAll({
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'X-Liza-Homeserver': issuer!,
          'X-Liza-Capture-Age-Ms': '$ageMs',
        });
        req.body = body;
      }
      final resp = await transport.send(req);
      final bytes = <int>[];
      await for (final chunk in resp.stream) {
        if (bytes.length + chunk.length > 32768) throw const FormatException();
        bytes.addAll(chunk);
      }
      final result = resp.statusCode == 200
          ? jsonDecode(utf8.decode(bytes))
          : null;
      return (
        status: resp.statusCode,
        data: result is Map ? result : const {},
        retry: int.tryParse(resp.headers['retry-after'] ?? '') ?? 0,
      );
    }

    try {
      return await send().timeout(const Duration(seconds: 12));
    } finally {
      if (identical(transport, _flight)) _flight = null;
      transport.close();
    }
  }
}
