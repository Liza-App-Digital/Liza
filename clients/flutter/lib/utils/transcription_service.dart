import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/custom_http_client.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';

enum TranscriptionErrorKind {
  network,
  timeout,
  auth,
  server,
  serviceBusy,
  decrypt,
  parse,
}

class TranscriptionException implements Exception {
  final TranscriptionErrorKind kind;
  final String message;
  final int? statusCode;

  const TranscriptionException(this.kind, this.message, {this.statusCode});

  @override
  String toString() => 'TranscriptionException($kind): $message';
}

class TranscriptionService {
  final Client client;
  final Map<String, String> _cache = {};
  final List<String> _cacheOrder = [];
  final Map<String, Future<String>> _pending = {};
  final http.Client _httpClient;

  static const int _maxCacheSize = 200;
  // 300с покрывает worst-case обработки голосового на максимальной
  // разрешённой длине записи (300с, см. maxRecordingDuration в
  // recording_view_model.dart) — по замерам на проде end-to-end время
  // растёт примерно как 0.8×длительность_аудио + 10с.
  static const Duration _requestTimeout = Duration(seconds: 300);

  // Авто-расшифровка в личке с ИИ-ботом (RL-ai-dm-voice-auto-transcript):
  // сервер даёт человеку 10 запросов/мин, автоматика берёт не больше 4 —
  // остальное остаётся ручной 🎤. По одному за раз: при открытии чата с
  // десятком голосовых запросы идут очередью, а не залпом.
  static const int autoPerMinute = 4;
  @visibleForTesting
  Duration autoWindow = const Duration(minutes: 1);
  Future<void> _autoChain = Future.value();
  final List<DateTime> _autoStarts = [];
  final Map<String, Future<String?>> _autoQueued = {};
  // Неудачная авто-попытка не повторяется до конца сессии: иначе каждый
  // перестроенный пузырь (скролл) заново бился бы в 429/недоступный сервис.
  final Set<String> _autoFailed = {};

  /// Подмена сетевой части в тестах (скачивание + POST в transcribe).
  @visibleForTesting
  Future<String> Function(Event event)? debugFetch;

  TranscriptionService(this.client)
      : _httpClient = CustomHttpClient.createHTTPClient();

  static String _keyOf(Event event) => '${event.room.id}:${event.eventId}';

  /// Уже известная расшифровка — синхронно, чтобы пересозданный пузырь
  /// (desktop/Web без keep-alive) показал текст в первом же кадре.
  String? cachedText(Event event) => _cache[_keyOf(event)];

  /// Авто-расшифровка: очередь по одному, не больше [autoPerMinute] в минуту.
  /// Возвращает null, если событие уже проваливалось в этой сессии. Первую
  /// ошибку пробрасывает (вызывающий решает, докладывать ли в мониторинг).
  Future<String?> autoTranscribe(Event event) {
    final key = _keyOf(event);
    final cached = _cache[key];
    if (cached != null) return Future.value(cached);
    if (_autoFailed.contains(key)) return Future.value(null);
    final queued = _autoQueued[key];
    if (queued != null) return queued;

    final completer = Completer<String?>();
    _autoQueued[key] = completer.future;
    _autoChain = _autoChain.then((_) async {
      try {
        if (_cache[key] == null) await _waitAutoSlot();
        completer.complete(await transcribe(event));
      } catch (e, s) {
        _autoFailed.add(key);
        completer.completeError(e, s);
      } finally {
        _autoQueued.remove(key);
      }
    });
    return completer.future;
  }

  Future<void> _waitAutoSlot() async {
    while (true) {
      final now = DateTime.now();
      _autoStarts.removeWhere((t) => now.difference(t) >= autoWindow);
      if (_autoStarts.length < autoPerMinute) {
        _autoStarts.add(now);
        return;
      }
      await Future.delayed(autoWindow - now.difference(_autoStarts.first));
    }
  }

  Future<String> transcribe(Event event) async {
    final cacheKey = _keyOf(event);

    final cached = _cache[cacheKey];
    if (cached != null) return cached;

    final pending = _pending[cacheKey];
    if (pending != null) return pending;

    final fetch = debugFetch;
    final future = fetch == null
        ? _doTranscribe(event, cacheKey)
        : fetch(event).then((text) {
            _addToCache(cacheKey, text);
            return text;
          });
    _pending[cacheKey] = future;
    try {
      return await future;
    } finally {
      _pending.remove(cacheKey);
    }
  }

  Future<String> _doTranscribe(Event event, String cacheKey) async {
    // Стадия 1: скачать и расшифровать вложение
    MatrixFile matrixFile;
    try {
      matrixFile = await event.downloadAndDecryptAttachmentHealed();
    } catch (e) {
      Logs().w('[Transcribe] Ошибка загрузки/расшифровки: $e');
      // Стадия 1 — это СКАЧАТЬ и расшифровать: сетевой обрыв здесь так же
      // штатен, как sha256-mismatch. Раньше оба заворачивались в `decrypt` →
      // алёрт врал `reason=transcription-decrypt`, а пользователь читал «Не
      // удалось расшифровать» при живом файле и моргнувшей сети (инцидент
      // 2026-09-09, issue GlitchTip #111). Классифицируем по ТИПУ ошибки.
      throw TranscriptionException(
        stageOneKindFor(e),
        e.toString(),
      );
    }

    final uri = Uri(
      scheme: 'https',
      host: AppConfig.transcribeHost,
      path: '/v1/transcribe',
    );

    final request = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer ${client.accessToken}'
      ..fields['event_id'] = event.eventId
      ..fields['room_id'] = event.room.id;

    final serverName = _serverName();
    if (serverName != null) {
      request.headers['X-Matrix-Server-Name'] = serverName;
    }
    request.files.add(
      http.MultipartFile.fromBytes(
        'file',
        matrixFile.bytes,
        filename: matrixFile.name,
        contentType: _mediaTypeFromName(matrixFile.name),
      ),
    );

    // Стадия 2: отправить на сервер
    http.Response response;
    try {
      final streamed = await _httpClient.send(request).timeout(
        _requestTimeout,
        onTimeout: () {
          Logs().w('[Transcribe] Таймаут при отправке на $uri');
          throw TranscriptionException(
            TranscriptionErrorKind.timeout,
            'Превышено время ожидания ответа от сервера транскрибации',
          );
        },
      );
      response = await http.Response.fromStream(streamed);
    } on TranscriptionException {
      rethrow;
    } catch (e) {
      Logs().w('[Transcribe] Сетевая ошибка при запросе к $uri: $e');
      throw TranscriptionException(
        TranscriptionErrorKind.network,
        e.toString(),
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      Logs().w(
        '[Transcribe] Ошибка авторизации: ${response.statusCode} — ${response.body.substring(0, response.body.length.clamp(0, 500))}',
      );
      throw TranscriptionException(
        TranscriptionErrorKind.auth,
        'Ошибка авторизации (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode == 503) {
      Logs().w(
        '[Transcribe] Сервис занят: ${response.body.substring(0, response.body.length.clamp(0, 500))}',
      );
      throw TranscriptionException(
        TranscriptionErrorKind.serviceBusy,
        'Сервис транскрибации занят (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    if (response.statusCode != 200) {
      Logs().w(
        '[Transcribe] Сервер вернул ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 500))}',
      );
      throw TranscriptionException(
        TranscriptionErrorKind.server,
        'Сервер вернул ошибку (${response.statusCode})',
        statusCode: response.statusCode,
      );
    }

    // Стадия 3: разобрать ответ
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      // FastAPI HTTPException оборачивает тело в "detail"; прямой JSONResponse — нет
      final payload = body['detail'] is Map<String, dynamic>
          ? body['detail'] as Map<String, dynamic>
          : body;
      if (payload.containsKey('message')) {
        throw TranscriptionException(
          TranscriptionErrorKind.server,
          payload['message'] as String,
        );
      }
      final text = body['text'] as String;
      _addToCache(cacheKey, text);
      return text;
    } on TranscriptionException {
      rethrow;
    } catch (e) {
      Logs().w('[Transcribe] Ошибка разбора ответа: $e — тело: ${response.body.substring(0, response.body.length.clamp(0, 500))}');
      throw TranscriptionException(
        TranscriptionErrorKind.parse,
        e.toString(),
      );
    }
  }

  /// Отображение класса сбоя получения вложения ([mediaFailureKind]) в вид
  /// ошибки транскрибации. Чистая и статическая — страж
  /// `ledger:RL-media-failure-kind` проверяет РЕАЛЬНОЕ правило, а не реплику.
  /// `decrypt` остаётся только за настоящим сбоем расшифровки; всё, что не
  /// опознано (`sdk`/`other`), тоже идёт в `decrypt` — это консервативный
  /// фолбэк прежнего поведения, а не новая ложь про сеть.
  @visibleForTesting
  static TranscriptionErrorKind stageOneKindFor(Object error) {
    switch (mediaFailureKind(error)) {
      case 'network':
      case 'http':
        return TranscriptionErrorKind.network;
      case 'timeout':
        return TranscriptionErrorKind.timeout;
      default:
        return TranscriptionErrorKind.decrypt;
    }
  }

  MediaType _mediaTypeFromName(String? name) {
    if (name == null) return MediaType('application', 'octet-stream');
    final ext = name.split('.').last.toLowerCase();
    switch (ext) {
      case 'm4a':
        return MediaType('audio', 'mp4');
      case 'ogg':
        return MediaType('audio', 'ogg');
      case 'wav':
        return MediaType('audio', 'wav');
      case 'mp3':
        return MediaType('audio', 'mpeg');
      default:
        return MediaType('application', 'octet-stream');
    }
  }

  String? _serverName() {
    final userId = client.userID;
    if (userId == null) return null;
    final colon = userId.indexOf(':');
    if (colon < 0 || colon == userId.length - 1) return null;
    return userId.substring(colon + 1);
  }

  void _addToCache(String key, String value) {
    _cache[key] = value;
    _cacheOrder.add(key);
    while (_cacheOrder.length > _maxCacheSize) {
      final evicted = _cacheOrder.removeAt(0);
      _cache.remove(evicted);
    }
  }

  void clearCache() {
    _cache.clear();
    _cacheOrder.clear();
  }
}
