import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:path_provider/path_provider.dart';

import 'package:liza/utils/media_qoe_session.dart';
import 'package:liza/utils/push_report_outbox.dart';

/// Web: только память — между перезагрузками вкладки маяк не копит.
class MemoryMediaQoeStore implements PushReportStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
}

/// Нативные платформы: свой файл рядом с push-outbox, атомарная запись
/// (tmp + rename) — та же реализация [FilePushReportStore].
PushReportStore mediaQoeDefaultStore() {
  if (kIsWeb) return MemoryMediaQoeStore();
  return _LazyFileStore();
}

class _LazyFileStore implements PushReportStore {
  FilePushReportStore? _inner;
  Future<FilePushReportStore> _store() async => _inner ??= FilePushReportStore(
    file: File(
      '${(await getApplicationSupportDirectory()).path}/media_qoe_outbox.json',
    ),
  );
  @override
  Future<String?> read() async => (await _store()).read();
  @override
  Future<void> write(String value) async => (await _store()).write(value);
}

/// Результат одной HTTP-попытки отправки батча.
typedef MediaQoeSend =
    Future<int> Function(Map<String, Object> client, List<Map> events);

/// Ограниченная очередь итогов попыток (спека QoE, задача 2.6).
///
/// Запись `open` — начатая попытка; при следующем старте ([load]) такие
/// записи становятся `abandoned_unknown` (приложение убили до итога).
/// Отправляются только `done`. Лимиты: [maxRecords] записей и [maxBytes]
/// документа — старые вытесняются.
class MediaQoeOutbox implements MediaQoeSink {
  MediaQoeOutbox({required this.store, int Function()? clock})
    : _now = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const maxRecords = 200;
  static const maxBytes = 256 * 1024;
  static const batchEvents = 50;
  static const batchBytes = 30 * 1024;
  static const minBackoffMs = 30 * 1000;
  static const maxBackoffMs = 60 * 60 * 1000;

  final PushReportStore store;
  final int Function() _now;
  final List<Map<String, Object?>> _records = [];
  Future<void> _tail = Future.value();
  bool _loaded = false;

  /// 401/403/404 — флаг на сервере выключен или чужой эмитент: до рестарта
  /// приложения не шлём.
  bool disabled = false;
  int _backoffMs = 0;
  int _notBefore = 0;

  @visibleForTesting
  List<Map<String, Object?>> get records => List.unmodifiable(_records);

  int get pending => _records.where((r) => r['s'] == 'done').length;

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> load() => _serial(_loadNow);

  // Мутация до load() иначе перезаписала бы файл одной новой записью и
  // потеряла записи прошлого запуска — поэтому каждая операция дочитывает файл.
  Future<void> _loadNow() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await store.read();
      final doc = raw == null ? null : jsonDecode(raw);
      final list = doc is Map ? doc['records'] : null;
      if (list is List) {
        for (final r in list) {
          if (r is! Map || r['e'] is! Map) continue;
          final event = Map<String, Object?>.from(r['e'] as Map);
          // Итог неизвестен: процесс умер между стартом попытки и итогом.
          if (r['s'] == 'open') event['outcome'] = 'abandoned_unknown';
          _records.add({'s': 'done', 'e': event});
        }
      }
    } catch (_) {
      _records.clear();
    }
    _trim();
    await _persist();
  }

  @override
  void opened(Map<String, Object> event) =>
      unawaited(_mutate(() => _records.add({'s': 'open', 'e': event})));

  @override
  void finished(Map<String, Object> event) => unawaited(
    _mutate(() {
      _records.removeWhere((r) => _id(r) == event['attempt_id']);
      _records.add({'s': 'done', 'e': event});
    }),
  );

  @override
  void dropped(String attemptId) => unawaited(
    _mutate(() => _records.removeWhere((r) => _id(r) == attemptId)),
  );

  static Object? _id(Map<String, Object?> r) => (r['e'] as Map)['attempt_id'];

  Future<void> _mutate(void Function() change) => _serial(() async {
    await _loadNow();
    change();
    _trim();
    await _persist();
  });

  void _trim() {
    while (_records.length > maxRecords) {
      _records.removeAt(0);
    }
    while (_records.isNotEmpty && _encode().length > maxBytes) {
      _records.removeAt(0);
    }
  }

  String _encode() => jsonEncode({'version': 1, 'records': _records});

  Future<void> _persist() async {
    try {
      await store.write(_encode());
    } catch (_) {}
  }

  /// Отправить накопленное. [canSend] проверяется перед каждым батчем
  /// (передний план). Возвращает число принятых сервером событий.
  Future<int> drain(
    Map<String, Object> client,
    MediaQoeSend send, {
    bool Function()? canSend,
  }) => _serial(() async {
    await _loadNow();
    var accepted = 0;
    while (!disabled && _now() >= _notBefore && (canSend?.call() ?? true)) {
      final batch = _nextBatch(client);
      if (batch.isEmpty) break;
      int status;
      try {
        status = await send(client, batch.map((r) => r['e'] as Map).toList());
      } catch (_) {
        status = -1;
      }
      if (status == 200 || status == 400 || status == 413) {
        // 400/413 — батч невалиден для сервера; повтор не поможет.
        final ids = batch.map(_id).toSet();
        _records.removeWhere((r) => ids.contains(_id(r)));
        if (status == 200) accepted += batch.length;
        _backoffMs = 0;
        await _persist();
        continue;
      }
      if (status == 401 || status == 403 || status == 404) {
        disabled = true;
        break;
      }
      _backoffMs = _backoffMs == 0
          ? minBackoffMs
          : (_backoffMs * 2).clamp(minBackoffMs, maxBackoffMs);
      _notBefore = _now() + _backoffMs;
      break;
    }
    return accepted;
  });

  List<Map<String, Object?>> _nextBatch(Map<String, Object> client) {
    final batch = <Map<String, Object?>>[];
    var size = jsonEncode({'schema': 1, 'client': client, 'events': []}).length;
    for (final r in _records) {
      if (r['s'] != 'done') continue;
      final bytes = jsonEncode(r['e']).length + 1;
      if (batch.length >= batchEvents || size + bytes > batchBytes) {
        // Одна запись больше батча не уйдёт никогда — не держим ею очередь.
        if (batch.isEmpty) batch.add(r);
        break;
      }
      batch.add(r);
      size += bytes;
    }
    return batch;
  }
}
