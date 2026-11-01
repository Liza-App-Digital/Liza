import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
// ignore: depend_on_referenced_packages
import 'package:vodozemac/vodozemac.dart';
import 'package:matrix/encryption/utils/base64_unpadded.dart';
import 'package:liza/utils/foreground_witness.dart';
import 'package:liza/utils/video_flight_recorder.dart';

enum E2eeProxyPhase {
  idle,
  connecting,
  streaming,
  retrying,
  completed,
  failed,
  cancelled,
}

/// Только безопасные данные о текущем lease, без URL и ключей.
class E2eeProxySnapshot {
  final int receivedBytes;
  final int activeRequests;
  final E2eeProxyPhase phase;
  final String? failureReason;

  const E2eeProxySnapshot({
    required this.receivedBytes,
    required this.activeRequests,
    required this.phase,
    this.failureReason,
  });
}

/// Локальный HTTP-прокси для потокового воспроизведения E2EE-вложений.
///
/// Проблема: зашифрованные видео в Matrix требуют полного скачивания и
/// расшифровки перед воспроизведением (24+ МБ в RAM). На мобильных это
/// ненадёжно — download рвётся при уходе в фон, пользователь ждёт 20+ сек.
///
/// Решение: поднимаем локальный HTTP-сервер на 127.0.0.1:0. media_kit (libmpv)
/// шлёт HTTP-запросы (в том числе Range) на localhost. Прокси:
/// 1. Скачивает зашифрованные чанки с Synapse
/// 2. Расшифровывает AES-256-CTR потоково (без загрузки всего файла в RAM)
/// 3. Отдаёт расшифрованные байты плееру
///
/// AES-CTR позволяет расшифровывать произвольный offset: counter = IV + offset/16.
/// Это даёт seek без перечитывания всего файла.
class E2eeMediaProxy {
  HttpServer? _server;
  // Гард идемпотентности: два параллельных ensureStarted() (быстрая смена видео /
  // две страницы карусели) без него оба проходили `_server != null` до завершения
  // первого bind → второй HttpServer перезаписывал _server, первый утекал (fd).
  Future<void>? _starting;
  final _sessions = <String, _ProxySession>{};
  final _random = Random.secure();

  String _newSessionId() => base64Url
      .encode(List.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  /// Журнал upstream-попыток сессии для контекста `[video-*]`-событий.
  VideoFlightRecorder? flight(String sessionId) => _sessions[sessionId]?.flight;

  E2eeProxySnapshot? snapshot(String sessionId) =>
      _sessions[sessionId]?.snapshot;

  /// Один persistent HTTP-клиент на всё время жизни прокси. Раньше
  /// [_serveDecrypted] поднимал `HttpClient()` на КАЖДЫЙ запрос и закрывал в
  /// finally — при moov-в-хвосте libmpv делает серию Range-прыжков к концу
  /// файла, и каждый прыжок = отдельный TLS-handshake к Synapse/MMR. Это и есть
  /// латентность «час по чайной ложке» на LTE. Один клиент переиспользует
  /// keep-alive соединение между Range-запросами (KILLER-2).
  HttpClient? _upstreamClient;

  /// Singleton
  static final E2eeMediaProxy instance = E2eeMediaProxy._();
  E2eeMediaProxy._();

  /// AES-CTR примитив. В проде — vodozemac (`CryptoUtils.aesCtr`). Инъектируется
  /// в тестах: реальный AES живёт в нативной либе vodozemac (в host-`flutter test`
  /// не грузится), поэтому логику стриминга/Range/counter-реконструкции
  /// (`_serveDecrypted`/[_adjustIv]) проверяем детерминированным шифром-заглушкой,
  /// а сам AES — device-flow.
  @visibleForTesting
  static Uint8List Function({
    required Uint8List input,
    required Uint8List key,
    required Uint8List iv,
  })
  aesCtrImpl = CryptoUtils.aesCtr;

  /// Базовый URL прокси (напр. http://127.0.0.1:54321).
  /// null если сервер не запущен.
  String? get baseUrl {
    final s = _server;
    if (s == null) return null;
    return 'http://127.0.0.1:${s.port}';
  }

  /// Запустить прокси-сервер, если ещё не запущен. Идемпотентно и безопасно при
  /// параллельных вызовах: все ждут один и тот же bind (гард `_starting`).
  Future<void> ensureStarted() => _starting ??= _doStart();

  Future<void> _doStart() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _upstreamClient = HttpClient();
    Logs().i('E2eeMediaProxy started on port ${server.port}');
    // _handleRequest — Future<void>, а не `async void`: иначе исключение при
    // request.response.close() (клиент уже отвалился) уходит в необработанные
    // Future-ошибки зоны, минуя логи (M-5 flutter-quality). Ловим через catchError.
    server.listen(
      (req) => unawaited(
        _handleRequest(req).catchError((Object e, StackTrace s) {
          Logs().e('E2eeMediaProxy unhandled', e, s);
        }),
      ),
    );
  }

  /// Резолвит authenticated-media download-URI зашифрованного вложения [event].
  ///
  /// НЕ через `event.getAttachmentUri()` — тот по дизайну SDK возвращает null для
  /// `isAttachmentEncrypted` («can't url-thumbnail in encrypted rooms»,
  /// `matrix/event.dart`), из-за чего E2EE-прокси-путь раньше ВСЕГДА бросал и падал
  /// в полное скачивание (мёртвый код). `attachmentMxcUrl` для E2EE читает
  /// `content['file']['url']`; `getDownloadUri` строит authenticated
  /// `/_matrix/client/v1/media/download/…` (учитывает MMR-роутинг прод-хоста) —
  /// идентично тому, что SDK делает внутри `downloadAndDecryptAttachment`.
  @visibleForTesting
  static Future<Uri> resolveE2eeDownloadUri(Event event) async {
    final mxcUrl = event.attachmentMxcUrl;
    if (mxcUrl == null) {
      throw VideoProxyException(
        'attachmentMxcUrl is null for ${event.eventId}',
      );
    }
    return mxcUrl.getDownloadUri(event.room.client);
  }

  /// Зарегистрировать E2EE-сессию для воспроизведения.
  /// Возвращает URL вида `http://127.0.0.1:PORT/SESSION_ID`.
  Future<String> registerSession({required Event event}) async {
    await ensureStarted();

    // URL для скачивания зашифрованного вложения (authenticated media).
    final downloadUri = await resolveE2eeDownloadUri(event);

    // Ключ/IV извлекаем через null-safe tryGet — жёсткие касты `as Map` роняли
    // прокси `TypeError`-ом на частичном/битом `content['file']` (частичный sync
    // до завершения E2EE-декрипта), минуя контролируемый VideoProxyException.
    final content = event.content;
    final fileMap = content.tryGetMap<String, Object?>('file');
    if (fileMap == null) {
      throw VideoProxyException('content["file"] missing or not a map');
    }
    final keyMap = fileMap.tryGetMap<String, Object?>('key');
    final k = keyMap?.tryGet<String>('k');
    final iv = fileMap.tryGet<String>('iv');
    if (k == null || iv == null) {
      throw VideoProxyException('E2EE key or iv missing in file map');
    }
    final info = content.tryGetMap<String, dynamic>('info');
    final fileSize = info?.tryGet<int>('size') ?? 0;
    final mimetype = info?.tryGet<String>('mimetype') ?? 'video/mp4';

    // Декодируем ключ и IV из base64url/base64
    final keyBytes = base64decodeUnpadded(base64.normalize(k));
    final ivBytes = base64decodeUnpadded(base64.normalize(iv));

    // Один event может одновременно играть в двух viewer или повторной попытке.
    final sessionId = _newSessionId();
    _sessions[sessionId] = _ProxySession(
      downloadUri: downloadUri,
      accessToken: event.room.client.accessToken,
      keyBytes: keyBytes,
      ivBytes: ivBytes,
      fileSize: fileSize,
      mimetype: mimetype,
      witness: ForegroundWitness.attach(),
      ownsWitness: true,
    );

    final url = '$baseUrl/${Uri.encodeComponent(sessionId)}';
    Logs().i(
      'E2eeMediaProxy session registered (size=$fileSize, mime=$mimetype)',
    );
    return url;
  }

  /// Удалить сессию (при dispose плеера).
  void removeSession(String sessionId) {
    unawaited(cancelSession(sessionId));
  }

  /// Инвалидизация синхронна; ожидание касается только запросов этого lease.
  Future<void> cancelSession(String sessionId) async {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    final operations = session.operations.toList();
    session.cancelled = true;
    for (final operation in operations) {
      operation.cancel();
    }
    await Future.wait(operations.map((operation) => operation.finished.future));
    if (session.ownsWitness) session.witness?.dispose();
  }

  /// Тест-only: зарегистрировать сессию напрямую из явных параметров (в обход
  /// [Event]/`getDownloadUri`), чтобы прогнать AES-CTR стрим-путь
  /// [_serveDecrypted]/[_adjustIv] против фейкового upstream. Возвращает
  /// прокси-URL. Прод-код этот метод не использует.
  @visibleForTesting
  String registerRawSessionForTest({
    required Uri downloadUri,
    required Uint8List keyBytes,
    required Uint8List ivBytes,
    required int fileSize,
    String? accessToken,
    String mimetype = 'video/mp4',
    String? sessionId,
    ForegroundWitness? witness,
    Duration headersTimeout = const Duration(seconds: 30),
    Duration bodyIdleTimeout = const Duration(seconds: 60),
    Duration progressTimeout = const Duration(seconds: 120),
    Duration backoffBase = const Duration(milliseconds: 200),
  }) {
    final id = sessionId ?? _newSessionId();
    if (_sessions.containsKey(id)) {
      throw StateError('Duplicate proxy test lease');
    }
    _sessions[id] = _ProxySession(
      downloadUri: downloadUri,
      accessToken: accessToken,
      keyBytes: keyBytes,
      ivBytes: ivBytes,
      fileSize: fileSize,
      mimetype: mimetype,
      witness: witness,
      headersTimeout: headersTimeout,
      bodyIdleTimeout: bodyIdleTimeout,
      progressTimeout: progressTimeout,
      backoffBase: backoffBase,
    );
    return '$baseUrl/${Uri.encodeComponent(id)}';
  }

  /// Остановить прокси.
  Future<void> stop() async {
    await Future.wait(_sessions.keys.toList().map(cancelSession));
    await _server?.close(force: true);
    _server = null;
    _starting = null; // разрешить повторный ensureStarted после остановки
    _upstreamClient?.close(force: true);
    _upstreamClient = null;
    _sessions.clear();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final id = request.uri.pathSegments.firstOrNull;
    final session = id == null ? null : _sessions[id];
    if (session == null || session.cancelled) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final operation = _ProxyOperation(session, request.response);
    session.latestOperation = operation;
    session.failureReason = null;
    session.operations.add(operation);
    try {
      await _serveDecrypted(request, session, operation);
      operation.completed = true;
      session.completedOnce = true;
      await operation.closeDownstream();
    } on _ProxyCancelled {
      // Seek/закрытие одного downstream — не ошибка остальных запросов lease.
    } catch (e) {
      if (!operation.cancelled) {
        final reason = e is VideoProxyException
            ? e.message
            : 'transport-failed';
        if (identical(session.latestOperation, operation)) {
          session.failureReason = reason;
        }
        Logs().w('E2eeMediaProxy request failed: $reason');
        operation.abortDownstream();
      }
    } finally {
      operation.finish();
      session.operations.remove(operation);
    }
  }

  Future<void> _serveDecrypted(
    HttpRequest request,
    _ProxySession session,
    _ProxyOperation operation,
  ) async {
    final fileSize = session.fileSize;
    var rangeStart = 0;
    var rangeEnd = fileSize > 0 ? fileSize - 1 : null;
    var isRange = false;
    final rangeHeader = request.headers.value('range');
    if (rangeHeader != null && fileSize > 0) {
      final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(rangeHeader);
      if (match == null) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        return;
      }
      rangeStart = int.parse(match.group(1)!);
      final end = match.group(2)!;
      if (end.isNotEmpty) rangeEnd = min(int.parse(end), fileSize - 1);
      if (rangeStart >= fileSize || rangeEnd! < rangeStart) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        request.response.headers.set('content-range', 'bytes */$fileSize');
        return;
      }
      isRange = true;
    }
    // MIME приходит из недоверенного Event. ContentType.parse сохраняет CRLF
    // внутри quoted parameter; raw HTTP нельзя собирать до явной проверки.
    if (session.mimetype.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
      throw VideoProxyException('invalid-content-type');
    }
    request.response.headers.contentType = ContentType.parse(session.mimetype);
    final contentType = request.response.headers.value('content-type')!;
    // HttpResponse.done не сообщает FIN, пока upstream молчит. Забираем socket
    // ДО headers: его onDone отменяет только этот Range, даже без новых байтов.
    final socket = await operation.attachDownstream();
    final headers = StringBuffer(
      isRange ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n',
    );
    headers.write('Connection: close\r\nContent-Type: $contentType\r\n');
    if (fileSize > 0) {
      headers.write(
        'Accept-Ranges: bytes\r\nContent-Length: ${rangeEnd! - rangeStart + 1}\r\n',
      );
      if (isRange) {
        headers.write(
          'Content-Range: bytes $rangeStart-$rangeEnd/$fileSize\r\n',
        );
      }
    }
    // Заголовки отправляются вместе с первым прошедшим проверку plaintext.
    var headersSent = false;
    final client = _upstreamClient;
    if (client == null) throw _ProxyCancelled();
    final encrypted = _resumableUpstream(
      client: client,
      session: session,
      operation: operation,
      startOffset: rangeStart - (rangeStart % 16),
      rangeEnd: rangeEnd,
    );
    await for (final chunk in decryptCtrStream(
      encryptedBody: encrypted,
      keyBytes: session.keyBytes,
      baseIv: session.ivBytes,
      rangeStart: rangeStart,
    )) {
      operation.checkCancelled();
      if (!headersSent) {
        if (fileSize == 0 && operation.totalBytes != null) {
          headers.write(
            'Content-Length: ${operation.totalBytes! - rangeStart}\r\n',
          );
        }
        headers.write('\r\n');
        socket.write(headers.toString());
        headersSent = true;
      }
      socket.add(chunk);
      // flush обеспечивает backpressure: upstream не вычитывается целиком в RAM.
      // На yield генератор приостанавливает сетевые deadlines до нового demand.
      try {
        await operation.wait(socket.flush(), includeProgress: false);
      } catch (_) {
        operation.cancel();
        rethrow;
      }
    }
  }

  static const _maxUpstreamRetries = 6;

  Stream<List<int>> _resumableUpstream({
    required HttpClient client,
    required _ProxySession session,
    required _ProxyOperation operation,
    required int startOffset,
    required int? rangeEnd,
  }) async* {
    var pos = startOffset;
    var retries = 0;
    var effectiveEnd = rangeEnd;
    var knownTotal = session.fileSize > 0 ? session.fileSize : null;
    operation.progress.resume();
    try {
      while (effectiveEnd == null || pos <= effectiveEnd) {
        operation.checkCancelled();
        await operation.waitForForeground();
        final attempt = _UpstreamAttempt();
        operation.attempt = attempt;
        final attemptClock = Stopwatch()..start();
        final attemptStart = pos;
        int? status;
        int? ttfbMs;
        var attemptBytes = 0;
        var end = UpstreamEnd.complete;
        StreamIterator<List<int>>? body;
        E2eeProxyDeadline? stage;
        try {
          operation.phase = E2eeProxyPhase.connecting;
          stage = E2eeProxyDeadline(session.headersTimeout, session.witness)
            ..resume();
          final pending = client.getUrl(session.downloadUri).then((req) {
            if (attempt.stopped || operation.cancelled) {
              req.abort();
              throw _ProxyCancelled();
            }
            attempt.request = req;
            return req;
          });
          final req = await operation.wait(pending, stage: stage);
          if (session.accessToken != null) {
            req.headers.set('authorization', 'Bearer ${session.accessToken}');
          }
          req.headers.set('range', 'bytes=$pos-${effectiveEnd ?? ''}');
          final upstream = await operation.wait(req.close(), stage: stage);
          stage.dispose();
          stage = null;
          status = upstream.statusCode;
          ttfbMs = attemptClock.elapsedMilliseconds;
          final (responseEnd, total) = _validateResponse(
            upstream,
            knownTotal,
            pos,
            effectiveEnd,
          );
          knownTotal = total;
          operation.totalBytes = total;
          effectiveEnd ??= total - 1;
          body = StreamIterator(upstream);
          stage = E2eeProxyDeadline(session.bodyIdleTimeout, session.witness)
            ..resume();
          operation.phase = E2eeProxyPhase.streaming;
          while (await operation.wait(body.moveNext(), stage: stage)) {
            final chunk = body.current;
            if (chunk.isEmpty) continue;
            if (pos + chunk.length > responseEnd + 1) {
              throw VideoProxyException('range-body-overflow');
            }
            pos += chunk.length;
            attemptBytes += chunk.length;
            retries = 0;
            session.receivedBytes += chunk.length;
            session.failureReason = null;
            operation.progress.reset();
            stage.reset();
            // Пока downstream не просит следующий chunk (буфер mpv заполнен),
            // отсутствие upstream-байт не является сетевым простоем.
            operation.progress.pause();
            stage.pause();
            yield chunk;
            operation.checkCancelled();
            operation.progress.resume();
            stage.resume();
          }
          if (pos <= responseEnd) {
            throw const _RetryableProxyFailure('short-body');
          }
          if (pos <= effectiveEnd) {
            // Сервер может законно выдать меньший диапазон (remote media).
            continue;
          }
          return;
        } catch (e) {
          end = e is _ProxyCancelled
              ? UpstreamEnd.cancelled
              : operation.progress.expired
              ? UpstreamEnd.progressTimeout
              : e is TimeoutException
              ? UpstreamEnd.timeout
              : e is SocketException
              ? UpstreamEnd.socket
              : e is _RetryableProxyFailure
              ? UpstreamEnd.shortBody
              : e is HttpException || e is VideoProxyException
              ? UpstreamEnd.httpError
              : UpstreamEnd.other;
          attempt.abort();
          operation.checkCancelled();
          if (operation.progress.expired) {
            throw VideoProxyException('progress-timeout');
          }
          final recoverable =
              e is HttpException ||
              e is SocketException ||
              e is _RetryableProxyFailure ||
              e is TimeoutException;
          if (!recoverable) rethrow;
          // Разрыв сразу после сна не расходует попытки; retry ждёт foreground.
          if (!(session.witness?.failureExplainedBySuspension ?? false)) {
            if (++retries > _maxUpstreamRetries) {
              throw VideoProxyException('retries-exhausted');
            }
          }
          operation.phase = E2eeProxyPhase.retrying;
          stage?.dispose();
          stage = null;
          await operation.waitForForeground();
          await operation.wait(
            Future<void>.delayed(session.backoffBase * max(1, retries)),
          );
          await operation.waitForForeground();
        } finally {
          session.flight.recordUpstream(
            rangeStart: attemptStart,
            status: status,
            ttfbMs: ttfbMs,
            bytes: attemptBytes,
            durationMs: attemptClock.elapsedMilliseconds,
            end: end,
          );
          stage?.dispose();
          attempt.abort();
          if (body != null) await body.cancel();
          if (identical(operation.attempt, attempt)) operation.attempt = null;
        }
      }
    } finally {
      operation.progress.pause();
    }
  }

  /// Невалидный HTTP-ответ не попадает ни в decrypt, ни в счётчик прогресса.
  (int, int) _validateResponse(
    HttpClientResponse response,
    int? knownTotal,
    int start,
    int? end,
  ) {
    if (response.statusCode == HttpStatus.ok) {
      if (start != 0 || (end != null && response.contentLength != end + 1)) {
        throw VideoProxyException('invalid-full-response');
      }
      if (response.contentLength < 0) {
        throw VideoProxyException('missing-content-length');
      }
      return (response.contentLength - 1, response.contentLength);
    }
    if (response.statusCode != HttpStatus.partialContent) {
      throw VideoProxyException('http-${response.statusCode}');
    }
    final match = RegExp(
      r'^bytes (\d+)-(\d+)/(\d+)$',
    ).firstMatch(response.headers.value('content-range') ?? '');
    if (match == null) throw VideoProxyException('invalid-content-range');
    final actualStart = int.parse(match.group(1)!);
    final actualEnd = int.parse(match.group(2)!);
    final total = int.parse(match.group(3)!);
    if (actualStart != start ||
        actualEnd < start ||
        actualEnd >= total ||
        (end != null && actualEnd > end) ||
        (knownTotal != null && total != knownTotal) ||
        (response.contentLength >= 0 &&
            response.contentLength != actualEnd - actualStart + 1)) {
      throw VideoProxyException('invalid-content-range');
    }
    return (actualEnd, total);
  }

  /// Потоковая AES-CTR расшифровка [encryptedBody] — ответа upstream,
  /// начинающегося с байта, выровненного вниз до 16-байтной границы от
  /// [rangeStart]. Выдаёт расшифрованные байты, начиная ИМЕННО с [rangeStart]
  /// (обрезая `byteOffset` из первого блока). Вынесена из [_serveDecrypted] и
  /// не зависит от HTTP — тестируется без сети (в host-`flutter test` реальный
  /// HttpClient замокан). Правильность counter/выравнивания критична (R1):
  /// ошибка на один блок = мусор с середины файла.
  @visibleForTesting
  static Stream<List<int>> decryptCtrStream({
    required Stream<List<int>> encryptedBody,
    required Uint8List keyBytes,
    required Uint8List baseIv,
    required int rangeStart,
  }) async* {
    final blockOffset = rangeStart ~/ 16;
    final byteOffset = rangeStart % 16;
    // IV для первого выданного блока: baseIv + blockOffset (позиция в файле).
    final adjustedIv = _adjustIv(baseIv, blockOffset);

    // Счётчик обработанных ЗАШИФРОВАННЫХ байт — для пересчёта counter. Именно
    // encrypted (не output), чтобы counter корректно инкрементировался.
    var encryptedProcessed = 0;
    var pending = <int>[];
    var isFirstChunk = true;

    await for (final chunk in encryptedBody) {
      pending.addAll(chunk);

      final alignedLen = (pending.length ~/ 16) * 16;
      if (alignedLen == 0) continue;

      final toDecrypt = Uint8List.fromList(pending.sublist(0, alignedLen));
      pending = pending.sublist(alignedLen);

      final chunkIv = _adjustIv(adjustedIv, encryptedProcessed ~/ 16);
      final decrypted = aesCtrImpl(
        input: toDecrypt,
        key: keyBytes,
        iv: chunkIv,
      );
      encryptedProcessed += toDecrypt.length;

      yield (isFirstChunk && byteOffset > 0)
          ? decrypted.sublist(byteOffset)
          : decrypted;
      isFirstChunk = false;
    }

    // Последний неполный блок (< 16 байт).
    if (pending.isNotEmpty) {
      final toDecrypt = Uint8List.fromList(pending);
      final chunkIv = _adjustIv(adjustedIv, encryptedProcessed ~/ 16);
      final decrypted = aesCtrImpl(
        input: toDecrypt,
        key: keyBytes,
        iv: chunkIv,
      );
      yield (isFirstChunk && byteOffset > 0)
          ? decrypted.sublist(byteOffset)
          : decrypted;
    }
  }

  /// Вычислить IV с добавленным block offset для AES-CTR.
  ///
  /// Matrix spec: IV — 16 байт = 8 байт random + 8 байт counter (big-endian).
  /// Counter начинает с 0 и увеличивается на 1 для каждого 16-байтного блока.
  /// Для seek на offset N: counter = N / 16.
  @visibleForTesting
  static Uint8List adjustIvForTest(Uint8List baseIv, int blockOffset) =>
      _adjustIv(baseIv, blockOffset);

  static Uint8List _adjustIv(Uint8List baseIv, int blockOffset) {
    if (blockOffset == 0) return baseIv;

    final adjusted = Uint8List.fromList(baseIv);
    // Прибавляем blockOffset к 64-bit counter в байтах 8-15 (big-endian)
    var carry = blockOffset;
    for (var i = 15; i >= 8 && carry > 0; i--) {
      final sum = adjusted[i] + (carry & 0xFF);
      adjusted[i] = sum & 0xFF;
      carry = (carry >> 8) + (sum >> 8);
    }
    return adjusted;
  }
}

class _ProxySession {
  final Uri downloadUri;
  final String? accessToken;
  final Uint8List keyBytes;
  final Uint8List ivBytes;
  final int fileSize;
  final String mimetype;
  final ForegroundWitness? witness;
  final bool ownsWitness;
  final Duration headersTimeout;
  final Duration bodyIdleTimeout;
  final Duration progressTimeout;
  final Duration backoffBase;
  final operations = <_ProxyOperation>{};
  _ProxyOperation? latestOperation;
  int receivedBytes = 0;
  bool cancelled = false;
  bool completedOnce = false;
  String? failureReason;
  final flight = VideoFlightRecorder();

  _ProxySession({
    required this.downloadUri,
    required this.accessToken,
    required this.keyBytes,
    required this.ivBytes,
    required this.fileSize,
    required this.mimetype,
    this.witness,
    this.ownsWitness = false,
    this.headersTimeout = const Duration(seconds: 30),
    this.bodyIdleTimeout = const Duration(seconds: 60),
    this.progressTimeout = const Duration(seconds: 120),
    this.backoffBase = const Duration(milliseconds: 200),
  });

  E2eeProxySnapshot get snapshot {
    final active = operations
        .where((op) => !op.cancelled && !op.completed)
        .toList();
    final phase = cancelled
        ? E2eeProxyPhase.cancelled
        : active.isNotEmpty
        ? active.last.phase
        : failureReason != null
        ? E2eeProxyPhase.failed
        : completedOnce
        ? E2eeProxyPhase.completed
        : E2eeProxyPhase.idle;
    return E2eeProxySnapshot(
      receivedBytes: receivedBytes,
      activeRequests: active.length,
      phase: phase,
      failureReason: phase == E2eeProxyPhase.failed ? failureReason : null,
    );
  }
}

class _ProxyCancelled implements Exception {}

class _RetryableProxyFailure implements Exception {
  final String reason;
  const _RetryableProxyFailure(this.reason);
}

class _UpstreamAttempt {
  HttpClientRequest? request;
  bool stopped = false;
  void abort() {
    stopped = true;
    request?.abort();
  }
}

/// Дедлайн активного ожидания. Пауза downstream замораживает остаток,
/// возвращение приложения в foreground начинает полный срок заново.
class E2eeProxyDeadline {
  final Duration duration;
  final ForegroundWitness? witness;
  final _expiry = Completer<void>();
  final Stopwatch _elapsed;
  late Duration _remaining;
  Timer? _timer;
  StreamSubscription<void>? _resume;
  bool _running = false;
  bool _disposed = false;

  E2eeProxyDeadline(this.duration, this.witness, {Stopwatch? stopwatch})
    : _elapsed = stopwatch ?? Stopwatch() {
    _remaining = duration;
    _resume = witness?.onResume.listen((_) {
      reset(extra: witness!.resumeGrace);
    });
  }

  bool get expired => _expiry.isCompleted;
  Future<void> get expiry => _expiry.future;

  void reset({Duration extra = Duration.zero}) {
    if (_disposed || expired) return;
    _timer?.cancel();
    _elapsed.reset();
    _remaining = duration + extra;
    if (_running) _arm();
  }

  void _arm() {
    if (_disposed || expired || !_running) return;
    if (witness?.suspended ?? false) {
      _elapsed.stop();
      return; // onResume перевзведёт полный срок.
    }
    _elapsed.start();
    _timer = Timer(_remaining, () {
      _elapsed.stop();
      if (_disposed || expired) return;
      if (witness?.suspended ?? false) {
        _remaining = duration;
        _elapsed.reset();
        return;
      }
      _expiry.complete();
    });
  }

  void pause() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _elapsed.stop();
    _remaining -= _elapsed.elapsed;
    if (_remaining.isNegative) _remaining = Duration.zero;
    _elapsed.reset();
  }

  void resume() {
    if (_running || _disposed) return;
    _running = true;
    _arm();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _elapsed.stop();
    unawaited(_resume?.cancel());
  }
}

class _ProxyOperation {
  final _ProxySession session;
  final HttpResponse downstream;
  final _cancelled = Completer<void>();
  final finished = Completer<void>();
  late final E2eeProxyDeadline progress;
  _UpstreamAttempt? attempt;
  E2eeProxyPhase phase = E2eeProxyPhase.connecting;
  bool completed = false;
  int? totalBytes;
  bool _downstreamClosed = false;
  Socket? _socket;
  StreamSubscription<Uint8List>? _socketEvents;

  _ProxyOperation(this.session, this.downstream) {
    progress = E2eeProxyDeadline(session.progressTimeout, session.witness);
  }

  bool get cancelled => _cancelled.isCompleted || session.cancelled;

  void checkCancelled() {
    if (cancelled) throw _ProxyCancelled();
  }

  Future<T> wait<T>(
    Future<T> future, {
    E2eeProxyDeadline? stage,
    bool includeProgress = true,
  }) async {
    checkCancelled();
    try {
      return await Future.any([
        future,
        _cancelled.future.then<T>((_) => throw _ProxyCancelled()),
        if (stage != null)
          stage.expiry.then<T>((_) => throw TimeoutException('request-idle')),
        if (includeProgress)
          progress.expiry.then<T>(
            (_) => throw VideoProxyException('progress-timeout'),
          ),
      ]);
    } on TimeoutException {
      attempt?.abort();
      rethrow;
    }
  }

  Future<void> waitForForeground() async {
    final witness = session.witness;
    if (witness == null) return;
    await wait(witness.untilForeground(), includeProgress: false);
  }

  Future<Socket> attachDownstream() async {
    final pending = downstream.detachSocket(writeHeaders: false).then((socket) {
      if (cancelled) {
        socket.destroy();
        throw _ProxyCancelled();
      }
      _socket = socket;
      _socketEvents = socket.listen(
        (_) {},
        onDone: () {
          if (!completed) cancel();
        },
        onError: (Object _) {
          if (!completed) cancel();
        },
      );
      return socket;
    });
    return wait(pending, includeProgress: false);
  }

  Future<void> closeDownstream() async {
    final socket = _socket;
    if (socket == null) {
      await downstream.close();
    } else {
      await socket.flush();
      await socket.close();
    }
  }

  void abortDownstream() {
    if (_downstreamClosed) return;
    _downstreamClosed = true;
    final socket = _socket;
    if (socket != null) {
      socket.destroy();
    } else {
      downstream.deadline = Duration.zero;
    }
  }

  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    attempt?.abort();
    progress.dispose();
    abortDownstream();
  }

  void finish() {
    completed = true;
    unawaited(_socketEvents?.cancel());
    _socket?.destroy();
    attempt?.abort();
    progress.dispose();
    if (!finished.isCompleted) finished.complete();
  }
}

class VideoProxyException implements Exception {
  final String message;
  VideoProxyException(this.message);
  @override
  String toString() => 'VideoProxyException: $message';
}
