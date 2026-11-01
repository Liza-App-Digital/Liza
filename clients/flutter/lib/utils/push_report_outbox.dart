import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
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

/// Ограниченная очередь установки. Все операции, включая чтение/запись и drain,
/// сериализованы; поздний ACK не получает доступа к состоянию очереди.
class PushReportOutbox {
  PushReportOutbox({
    required this.store,
    required this.transport,
    this.timeout = const Duration(seconds: 15),
    this.onStatus,
  });

  static const maxReports = 7;
  static const maxBytes = 256 * 1024;
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

  Map<String, dynamic> _fresh({bool corrupt = false}) => {
    'version': 2,
    'installation_id': SentryId.newId().toString(),
    'reports': <dynamic>[],
    'evicted': 0,
    'expired': 0,
    'corrupt': corrupt ? 1 : 0,
    'oversized': 0,
  };

  Future<Map<String, dynamic>> _load() async {
    if (_state != null) return _copy(_state!);
    final raw = await store.read();
    if (raw == null) return _fresh();
    try {
      final state = jsonDecode(raw) as Map<String, dynamic>;
      if (state['version'] != 2 ||
          state['installation_id'] is! String ||
          [
            'evicted',
            'expired',
            'corrupt',
            'oversized',
          ].any((key) => state[key] is! int || (state[key] as int) < 0) ||
          (state['reports'] as List).length > maxReports ||
          utf8.encode(raw).length > maxBytes) {
        throw const FormatException();
      }
      for (final value in state['reports'] as List) {
        final item = value as Map;
        if (item['event_id'] is! String ||
            item['created_at'] is! int ||
            item['next_attempt'] is! int ||
            item['attempts'] is! int ||
            item['payload'] is! Map) {
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

  Future<void> _commit(Map<String, dynamic> state) async {
    await store.write(jsonEncode(state));
    _state = _copy(state);
  }

  void _expire(Map<String, dynamic> state, DateTime now) {
    final reports = state['reports'] as List;
    final before = reports.length;
    reports.removeWhere(
      (r) =>
          now.millisecondsSinceEpoch - (r['created_at'] as int) >=
          ttl.inMilliseconds,
    );
    state['expired'] = (state['expired'] as int) + before - reports.length;
  }

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
    final id = SentryId.newId().toString();
    final data = _copy(payload);
    final context = data['context'] as Map<String, dynamic>;
    context.addAll({
      'schema_version': 2,
      'report_id': id,
      'event_id': id,
      'installation_id': state['installation_id'],
      'created_at': now.toUtc().toIso8601String(),
      'captured_at': now.toUtc().toIso8601String(),
      'window_start': now
          .subtract(const Duration(hours: 24))
          .toUtc()
          .toIso8601String(),
      'window_end': now.toUtc().toIso8601String(),
      'diagnostic_loss': {
        for (final key in ['evicted', 'expired', 'corrupt', 'oversized'])
          key: state[key],
      },
    });
    final entry = {
      'event_id': id,
      'created_at': now.millisecondsSinceEpoch,
      'next_attempt': now.millisecondsSinceEpoch,
      'attempts': 0,
      'payload': data,
    };
    // Слишком большой снимок отклоняем целиком; JSON не режется по байтам.
    if (utf8.encode(jsonEncode(entry)).length > maxBytes - 4096) {
      state['oversized'] = (state['oversized'] as int) + 1;
      await _commit(state);
      _status(PushReportDelivery.failed);
      return false;
    }
    final reports = state['reports'] as List;
    reports.add(entry);
    state[key] = now.millisecondsSinceEpoch;
    while (reports.length > maxReports ||
        utf8.encode(jsonEncode(state)).length > maxBytes) {
      reports.removeAt(0);
      state['evicted'] = (state['evicted'] as int) + 1;
      (context['diagnostic_loss'] as Map)['evicted'] = state['evicted'];
    }
    await _commit(state);
    _status(PushReportDelivery.pending);
    return true;
  });

  Future<bool> drain(DateTime now, {bool Function()? canSend}) =>
      _serial(() async {
        final state = await _load();
        final expiredBefore = state['expired'];
        _expire(state, now);
        if (_state == null || state['expired'] != expiredBefore) {
          await _commit(state);
        }
        final reports = state['reports'] as List;
        var accepted = false;
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
            // Любая ошибка транспорта оставляет неизменный снимок в очереди.
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
        _status(
          reports.isNotEmpty
              ? PushReportDelivery.pending
              : accepted
              ? PushReportDelivery.httpAccepted
              : status == PushReportDelivery.pending
              ? PushReportDelivery.idle
              : status,
        );
        return accepted;
      });

  /// Копия для диагностики/стражей; вызывающий не может изменить очередь.
  Future<Map<String, dynamic>> inspect() =>
      _serial(() async => _copy(await _load()));
}
