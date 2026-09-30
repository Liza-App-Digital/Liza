import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/retry.dart' as retry;
import 'package:matrix/matrix.dart';

import 'package:liza/config/isrg_x1.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/update_read_only_http_client.dart';
import 'package:liza/utils/upload_progress_http_client.dart';

/// Custom Client to add an additional certificate. This is for the isrg X1
/// certificate which is needed for LetsEncrypt certificates. It is shipped
/// on Android since OS version 7.1. As long as we support older versions we
/// still have to ship this certificate by ourself.
class CustomHttpClient {
  static HttpClient customHttpClient(String? cert) {
    final context = SecurityContext.defaultContext;

    try {
      if (cert != null) {
        final bytes = utf8.encode(cert);
        context.setTrustedCertificatesBytes(bytes);
      }
    } on TlsException catch (e) {
      if (e.osError != null &&
          e.osError!.message.contains('CERT_ALREADY_IN_HASH_TABLE')) {
      } else {
        rethrow;
      }
    }

    final httpClient = HttpClient(context: context);
    httpClient.connectionTimeout = const Duration(seconds: 15);
    httpClient.idleTimeout = const Duration(seconds: 15);
    return httpClient;
  }

  /// Логирует метаданные отвергнутого сертификата и возвращает `false` —
  /// доверие НЕ меняется (движок и так рвёт хендшейк на невалидном серте),
  /// только снимаем показания (`subject`/`issuer` — публичные метаданные, не
  /// секрет). Диагностика источника TLS-сбоя (MITM-CA vs обрыв/MTU).
  static bool _logBadCert(X509Certificate cert, String host, int port) {
    Logs().w(
      '[HTTP] Bad certificate for $host:$port — '
      'subject=${cert.subject}, issuer=${cert.issuer}, '
      'valid=${cert.startValidity}..${cert.endValidity}',
    );
    return false;
  }

  static http.Client createHTTPClient({int? androidSdkVersion}) {
    final http.Client transport;
    if (PlatformInfos.isAndroid) {
      final httpClient = customHttpClient(ISRG_X1);
      if (androidSdkVersion != null && androidSdkVersion < 25) {
        httpClient.badCertificateCallback = _logBadCert;
      }
      transport = IOClient(httpClient);
    } else if (kIsWeb) {
      transport = http.Client();
    } else {
      // macOS/iOS/Linux/Windows: голый http.Client() не задаёт ни
      // connectionTimeout, ни idleTimeout → мёртвый keep-alive сокет (NAT
      // протух, смена Wi-Fi↔LTE, idle > серверного keepalive_timeout 65s)
      // ловится только ОС-таймаутом TCP (~75s). Всё это время `PUT /send`
      // висит спиннером, прежде чем SDK ретраит. idleTimeout=15s закрывает
      // idle-сокет в пуле раньше, чем он успеет протухнуть. cert=null:
      // на Apple системная цепочка доверия, ISRG X1 добавлять не нужно.
      final httpClient = customHttpClient(null);
      if (PlatformInfos.isIOS || PlatformInfos.isMacOS) {
        // Диагностика бага «под VPN отправка картинки падает
        // tlsConnectionFailed» (2026-08-24): Dart/BoringSSL на Apple НЕ читает
        // user-installed/корп CA из системного keychain, поэтому под VPN с
        // TLS-перехватом хендшейк отвергается, хотя ОС этому CA доверяет.
        // Логируем issuer отвергнутого сертификата — отличить MITM-CA
        // (issuer ≠ публичный корень → корень в trust-store) от обрыва/MTU
        // (сюда вообще не доходит → корень транспортный). `return false` —
        // доверие НЕ меняется (дефолт и так отвергает), только снимаем
        // показания. Спека:
        // docs/superpowers/specs/2026-08-24-vpn-media-upload-tls-trust-diagnosis-design.md
        httpClient.badCertificateCallback = _logBadCert;
      }
      transport = IOClient(httpClient);
    }
    // Порядок обёрток критичен. Счётчик прогресса (`UploadProgressHttpClient`)
    // ставим МЕЖДУ `RetryClient` и транспортом (`IOClient`), а не снаружи:
    // `RetryClient` буферизует тело запроса через `StreamSplitter` (ради
    // возможности повторить запрос) — выкачивает поток в память мгновенно.
    // Будь счётчик НАД `RetryClient`, он считал бы скорость этой
    // буферизации → процент прыгал бы сразу в ~100%. Внизу же, прямо над
    // `IOClient`, счётчик тикает ровно когда байты уходят в сокет
    // (backpressure от `IOSink.addStream`). На Web счётчик не ставим:
    // `BrowserClient` буферизует тело перед XHR (см. UploadProgressHttpClient).
    final counted = kIsWeb ? transport : UploadProgressHttpClient(transport);
    // Режим чтения обязательного обновления — снаружи всей цепочки: отказ
    // собирается локально, ретраи и сеть не нужны.
    return UpdateReadOnlyHttpClient(retry.RetryClient(counted, retries: 2));
  }
}
