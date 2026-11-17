import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

/// Хранилище заменяет целый документ: last_collected и pending коммитятся вместе.
abstract interface class PushReportStore {
  Future<String?> read();
  Future<void> write(String value);
}

class FilePushReportStore implements PushReportStore {
  FilePushReportStore({this.file});
  File? file;

  Future<File> _file() async => file ??= File(
    '${(await getApplicationSupportDirectory()).path}/push_report_outbox.json',
  );

  @override
  Future<String?> read() async {
    if (kIsWeb) {
      return (await SharedPreferences.getInstance()).getString(
        'monitoring.push_outbox_v2',
      );
    }
    final target = await _file();
    if (!await target.exists()) return null;
    if (await target.length() > PushReportOutbox.maxBytes) return 'corrupt';
    return target.readAsString();
  }

  @override
  Future<void> write(String value) async {
    if (kIsWeb) {
      // Web backend делает один атомарный localStorage.setItem всего JSON.
      if (!await (await SharedPreferences.getInstance()).setString(
        'monitoring.push_outbox_v2',
        value,
      )) {
        throw const FileSystemException('push outbox storage failed');
      }
      return;
    }
    final target = await _file();
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(target.path);
  }
}

/// Один transport на попытку. close обязан отменять HTTP при timeout.
abstract interface class PushReportTransport {
  Future<String?> send(Map<String, dynamic> report);
  void close();
}

/// Отдельный Dart SentryClient: никакого глобального scope/native cache.
/// Его стандартный HttpTransport возвращает id именно из HTTP-ответа.
class SentryPushReportTransport implements PushReportTransport {
  SentryPushReportTransport({
    required String dsn,
    required String environment,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client() {
    final options = SentryOptions()
      ..dsn = dsn
      ..environment = environment
      ..httpClient = _http
      ..sendDefaultPii = false
      ..sendClientReports = false
      ..maxBreadcrumbs = 0;
    _client = SentryClient(options);
  }

  final http.Client _http;
  late final SentryClient _client;

  @override
  Future<String?> send(Map<String, dynamic> report) async {
    final payload = report['payload'] as Map<String, dynamic>;
    final context = payload['context'] as Map<String, dynamic>;
    final accounts = context['accounts'] as List;
    final id = await _client.captureEvent(
      SentryEvent(
        eventId: SentryId.fromId(report['event_id'] as String),
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          report['created_at'] as int,
          isUtc: true,
        ),
        release: payload['release'] as String?,
        message: SentryMessage(payload['title'] as String),
        level: SentryLevel.info,
        user: accounts.isEmpty
            ? null
            : SentryUser(id: accounts.first['user_id'] as String),
        tags: Map<String, String>.from(payload['tags'] as Map),
        contexts: Contexts()..['push_report'] = context,
      ),
    );
    return id == SentryId.empty() ? null : id.toString();
  }

  @override
  void close() {
    _http.close();
    unawaited(Future<void>.sync(_client.close));
  }
}

enum PushReportDelivery { idle, pending, httpAccepted, failed }

/// Неизменяемое наблюдение; источник входит в ключ дедупликации.
class PushIncidentRecord {
  PushIncidentRecord(Map<String, Object> value, {required this.native})
    : data = Map.unmodifiable(
        jsonDecode(jsonEncode(value)) as Map<String, dynamic>,
      );

  final Map<String, dynamic> data;
  final bool native;
  int get timeMs => data['t'] as int;
  String get key =>
      _hash('${native ? 'native' : 'dart'}:${data['id'] ?? jsonEncode(data)}');
  String? get eventKey {
    final event = data[native ? 'event_hash' : 'e128'];
    if (event is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(event)) {
      return null;
    }
    final account = data[native ? 'account_hash' : 'a128'];
    return _hash('${account ?? '?'}:$event');
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 32);
}

/// Две независимые ограниченные очереди в одном атомарном документе.
/// Seen IDs фиксируются вместе с incident payload, до HTTP; ACK удаляет только
/// конкретный immutable batch. Daily/manual cooldown не касается incidents.
class PushReportOutbox {
  PushReportOutbox({
    required this.store,
    required this.transport,
    this.timeout = const Duration(seconds: 15),
    this.onStatus,
  });

  static const maxReports = 7;
  static const laneBytes = 256 * 1024;
  static const maxBytes = 576 * 1024;
  static const incidentBatchBytes = 32 * 1024;
  static const seenLimit = 2304;
  static const trackedLimit = 128;
  static const ttl = Duration(days: 7);
  final PushReportStore store;
  final PushReportTransport Function() transport;
  final Duration timeout;
  final void Function(PushReportDelivery)? onStatus;
  Future<void> _tail = Future.value();
  Map<String, dynamic>? _state;
  PushReportDelivery status = PushReportDelivery.idle;

  void _status(PushReportDelivery value) {
    status = value;
    onStatus?.call(value);
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static const _lossKeys = [
    'evicted',
    'expired',
    'corrupt',
    'oversized',
    'incident_evicted',
    'incident_expired',
    'incident_oversized',
    'global_evicted',
    'seen_evicted',
    'tracked_evicted',
  ];

  Map<String, dynamic> _fresh({bool corrupt = false}) => {
    'version': 3,
    'installation_id': SentryId.newId().toString(),
    'reports': <dynamic>[],
    'incidents': <dynamic>[],
    'seen': '',
    'tracked': <String, dynamic>{},
    for (final key in _lossKeys) key: key == 'corrupt' && corrupt ? 1 : 0,
  };

  Future<Map<String, dynamic>> _load() async {
    if (_state != null) return _copy(_state!);
    final raw = await store.read();
    if (raw == null) return _fresh();
    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      final legacy = state['version'] == 2;
      if ((!legacy && state['version'] != 3) ||
          state['installation_id'] is! String ||
          utf8.encode(raw).length > (legacy ? laneBytes : maxBytes)) {
        throw const FormatException();
      }
      // Миграция не изменяет ни один существующий daily payload или ID.
      if (legacy) {
        state['version'] = 3;
        state['incidents'] = <dynamic>[];
        state['seen'] = '';
        state['tracked'] = <String, dynamic>{};
        for (final key in _lossKeys.skip(4)) {
          state[key] = 0;
        }
      }
      if (_lossKeys.any((key) => state[key] is! int || state[key] < 0) ||
          state['seen'] is! String ||
          (state['seen'] as String).length % 22 != 0 ||
          (state['seen'] as String).length > seenLimit * 22 ||
          !RegExp(r'^[A-Za-z0-9_-]*$').hasMatch(state['seen'] as String)) {
        throw const FormatException();
      }
      for (final lane in ['reports', 'incidents']) {
        final reports = state[lane] as List;
        if (reports.length > maxReports || _bytes(reports) > laneBytes) {
          throw const FormatException();
        }
        for (final value in reports) {
          final item = value as Map;
          if (item['event_id'] is! String ||
              item['created_at'] is! int ||
              item['next_attempt'] is! int ||
              item['attempts'] is! int ||
              item['payload'] is! Map) {
            throw const FormatException();
          }
        }
      }
      for (final name in ['tracked']) {
        final map = state[name] as Map;
        if (map.length > (name == 'seen' ? seenLimit : trackedLimit) ||
            map.entries.any(
              (e) =>
                  e.key is! String ||
                  !RegExp(r'^[a-f0-9]{32}$').hasMatch(e.key) ||
                  e.value is! int,
            )) {
          throw const FormatException();
        }
      }
      return state;
    } catch (_) {
      return _fresh(corrupt: true);
    }
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  static int _bytes(Object value) => utf8.encode(jsonEncode(value)).length;
  static void _increment(Map<String, dynamic> state, String key) =>
      state[key] = (state[key] as int) + 1;

  Future<void> _commit(Map<String, dynamic> state) async {
    if (_bytes(state) > maxBytes) {
      throw const FormatException('outbox byte bound');
    }
    await store.write(jsonEncode(state));
    _state = _copy(state);
  }

  void _expire(Map<String, dynamic> state, DateTime now) {
    for (final lane in ['reports', 'incidents']) {
      final reports = state[lane] as List;
      reports.removeWhere((r) {
        final expired =
            now.millisecondsSinceEpoch - (r['created_at'] as int) >=
            ttl.inMilliseconds;
        if (expired) {
          _increment(state, lane == 'reports' ? 'expired' : 'incident_expired');
        }
        return expired;
      });
    }
    // Seen IDs остаются после ACK/TTL: replay не воскрешает утраченные batches.
    (state['tracked'] as Map).removeWhere(
      (_, t) => now.millisecondsSinceEpoch - (t as int) >= ttl.inMilliseconds,
    );
  }

  Map<String, dynamic> _loss(Map<String, dynamic> state) => {
    for (final key in _lossKeys) key: state[key],
    'dedup_window': 'bounded_lru_replay_may_duplicate',
    'scope': 'outbox_persistent',
  };

  Map<String, dynamic> _entry(
    Map<String, dynamic> payload,
    DateTime now,
    Map<String, dynamic> state, {
    bool incident = false,
  }) {
    final id = SentryId.newId().toString();
    final data = _copy(payload);
    final context = data['context'] as Map<String, dynamic>;
    context.addAll({
      'schema_version': 2,
      'report_kind': incident ? 'incident' : 'daily',
      'report_id': id,
      'event_id': id,
      'installation_id': state['installation_id'],
      'created_at': now.toUtc().toIso8601String(),
      'captured_at': now.toUtc().toIso8601String(),
      if (!incident)
        'window_start': now
            .subtract(const Duration(hours: 24))
            .toUtc()
            .toIso8601String(),
      if (!incident) 'window_end': now.toUtc().toIso8601String(),
      'diagnostic_loss': _loss(state),
    });
    return {
      'event_id': id,
      'created_at': now.millisecondsSinceEpoch,
      'next_attempt': now.millisecondsSinceEpoch,
      'attempts': 0,
      'payload': data,
    };
  }

  void _bound(Map<String, dynamic> state, String lane) {
    final reports = state[lane] as List;
    while (reports.length > maxReports || _bytes(reports) > laneBytes) {
      reports.removeAt(0);
      _increment(state, lane == 'reports' ? 'evicted' : 'incident_evicted');
    }
    while (_bytes(state) > maxBytes) {
      final daily = state['reports'] as List;
      final incidents = state['incidents'] as List;
      final removeDaily =
          incidents.isEmpty ||
          (daily.isNotEmpty &&
              daily.first['created_at'] <= incidents.first['created_at']);
      (removeDaily ? daily : incidents).removeAt(0);
      _increment(state, removeDaily ? 'evicted' : 'incident_evicted');
      _increment(state, 'global_evicted');
    }
  }

  void _boundTracked(Map<String, dynamic> state) {
    final map = state['tracked'] as Map<String, dynamic>;
    final ordered = map.entries.toList()
      ..sort((a, b) => (a.value as int).compareTo(b.value as int));
    for (final entry in ordered.take(
      map.length > trackedLimit ? map.length - trackedLimit : 0,
    )) {
      map.remove(entry.key);
      _increment(state, 'tracked_evicted');
    }
  }

  static String _seenToken(String hash) => base64Url
      .encode([
        for (var i = 0; i < hash.length; i += 2)
          int.parse(hash.substring(i, i + 2), radix: 16),
      ])
      .replaceAll('=', '');

  static List<String> _seenKeys(String packed) => [
    for (var i = 0; i < packed.length; i += 22) packed.substring(i, i + 22),
  ];

  Future<bool> isDue(DateTime now, {bool manual = false}) => _serial(() async {
    final state = await _load();
    final last = state[manual ? 'last_manual' : 'last_collected'] as int?;
    return last == null ||
        now.millisecondsSinceEpoch - last >=
            (manual ? const Duration(minutes: 1) : const Duration(hours: 24))
                .inMilliseconds;
  });

  Future<bool> enqueue(
    Map<String, dynamic> payload,
    DateTime now, {
    bool manual = false,
  }) => _serial(() async {
    final state = await _load();
    final key = manual ? 'last_manual' : 'last_collected';
    final last = state[key] as int?;
    final interval = manual
        ? const Duration(minutes: 1)
        : const Duration(hours: 24);
    if (last != null &&
        now.millisecondsSinceEpoch - last < interval.inMilliseconds) {
      return false;
    }
    _expire(state, now);
    final entry = _entry(payload, now, state);
    if (_bytes(entry) > laneBytes - 4096) {
      _increment(state, 'oversized');
      await _commit(state);
      _status(PushReportDelivery.failed);
      return false;
    }
    (state['reports'] as List).add(entry);
    state[key] = now.millisecondsSinceEpoch;
    _bound(state, 'reports');
    entry['payload']['context']['diagnostic_loss'] = _loss(state);
    _bound(state, 'reports');
    await _commit(state);
    _status(PushReportDelivery.pending);
    return true;
  });

  /// Возвращает ключи уже зафиксированных/устаревших наблюдений. Не вошедшие
  /// по размеру остаются у экспортёра; seen записывается только с payload.
  Future<Set<String>> enqueueIncident(
    Map<String, dynamic> payload,
    List<PushIncidentRecord> records,
    DateTime now,
  ) => _serial(() async {
    final state = await _load();
    _expire(state, now);
    final seen = _seenKeys(state['seen'] as String);
    final handled = <String>{};
    final included = <PushIncidentRecord>[];
    var bytes = 0;
    // Capture order, а не hash/time: одинаковая миллисекунда не должна
    // псевдослучайно вытеснять ещё retained записи из LRU.
    for (final record in records) {
      final token = _seenToken(record.key);
      if (seen.remove(token)) {
        seen.add(token); // LRU удерживает весь текущий replay union <=2256.
        handled.add(record.key);
        continue;
      }
      final size = _bytes(record.data) + 1;
      if (bytes + size > incidentBatchBytes) break;
      bytes += size;
      included.add(record);
    }
    if (included.isEmpty) {
      state['seen'] = seen.join();
      await _commit(state);
      return handled;
    }
    final data = _copy(payload);
    final context = data['context'] as Map<String, dynamic>;
    context['journal'] = included
        .where((r) => !r.native)
        .map((r) => jsonEncode(r.data))
        .join('\n');
    context['native_journal'] = included
        .where((r) => r.native)
        .map((r) => r.data)
        .toList();
    final times = included.map((r) => r.timeMs).toList()..sort();
    context['window_start'] = DateTime.fromMillisecondsSinceEpoch(
      times.first,
      isUtc: true,
    ).toIso8601String();
    context['window_end'] = DateTime.fromMillisecondsSinceEpoch(
      times.last,
      isUtc: true,
    ).toIso8601String();
    context['incident_export'] = {
      ...?context['incident_export'] as Map?,
      'candidate_entries': records.length,
      'included_entries': included.length,
      'dedup_scope': 'outbox_persistent',
      'seen_limit': seenLimit,
      'tracked_limit': trackedLimit,
      'legacy_dedup': 'fingerprint_approximate',
    };
    final entry = _entry(data, now, state, incident: true);
    if (_bytes(entry) > laneBytes - 4096) {
      _increment(state, 'incident_oversized');
      await _commit(state);
      _status(PushReportDelivery.failed);
      return handled;
    }
    for (final record in included) {
      seen.add(_seenToken(record.key));
      if (record.eventKey case final key?) {
        (state['tracked'] as Map)[key] = now.millisecondsSinceEpoch;
      }
      handled.add(record.key);
    }
    while (seen.length > seenLimit) {
      seen.removeAt(0);
      _increment(state, 'seen_evicted');
    }
    state['seen'] = seen.join();
    _boundTracked(state);
    (state['incidents'] as List).add(entry);
    _bound(state, 'incidents');
    entry['payload']['context']['diagnostic_loss'] = _loss(state);
    _bound(state, 'incidents');
    await _commit(state);
    _status(PushReportDelivery.pending);
    return handled;
  });

  Future<bool> drain(DateTime now, {bool Function()? canSend}) =>
      _serial(() async {
        final state = await _load();
        _expire(state, now);
        await _commit(state);
        var accepted = false;
        // Incident не ждёт отправки старых суточных снимков.
        for (final lane in ['incidents', 'reports']) {
          final reports = state[lane] as List;
          for (final item in List<Map<String, dynamic>>.from(reports)) {
            if (canSend != null && !canSend()) break;
            if ((item['next_attempt'] as int) > now.millisecondsSinceEpoch) {
              continue;
            }
            PushReportTransport? sender;
            String? ack;
            try {
              sender = transport();
              ack = await sender.send(_copy(item)).timeout(timeout);
            } catch (_) {
              // Любая ошибка оставляет immutable batch в очереди.
            } finally {
              sender?.close();
            }
            if (ack != null && ack.isNotEmpty && ack == item['event_id']) {
              reports.remove(item);
              accepted = true;
            } else {
              final attempts = (item['attempts'] as int) + 1;
              item['attempts'] = attempts;
              final minutes = attempts >= 7 ? 60 : 1 << (attempts - 1);
              item['next_attempt'] = now
                  .add(Duration(minutes: minutes))
                  .millisecondsSinceEpoch;
            }
            await _commit(state);
          }
        }
        final pending =
            (state['reports'] as List).isNotEmpty ||
            (state['incidents'] as List).isNotEmpty;
        _status(
          pending
              ? PushReportDelivery.pending
              : accepted
              ? PushReportDelivery.httpAccepted
              : status == PushReportDelivery.pending
              ? PushReportDelivery.idle
              : status,
        );
        return accepted;
      });

  Future<Map<String, dynamic>> inspect() =>
      _serial(() async => _copy(await _load()));
}
