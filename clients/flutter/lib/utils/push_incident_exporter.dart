import 'dart:async';
import 'dart:convert';

import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/push_report_outbox.dart';

class _IncidentPayload {
  _IncidentPayload(this.key)
    : value = jsonDecode(key) as Map<String, dynamic>,
      bytes = utf8.encode(key).length;
  final String key;
  final Map<String, dynamic> value;
  final int bytes;
  int references = 0;
}

class _CapturedIncident {
  _CapturedIncident(this.record, this.snapshot)
    : bytes = utf8.encode(jsonEncode(record.data)).length;
  final PushIncidentRecord record;
  final _IncidentPayload snapshot;
  final int bytes;
  Map<String, dynamic> get payload => snapshot.value;
  String get identity => snapshot.key;
}

/// Наблюдатель уведомлений: capture + critical journal flush синхронны.
/// Сеть выполняется только после coalescing, вне callback уведомления.
class PushIncidentExporter {
  PushIncidentExporter({
    required this.journal,
    required this.outbox,
    required this.payload,
    required this.readNative,
    this.nativeStatus,
    this.canSend,
    DateTime Function()? clock,
    this.coalesce = const Duration(milliseconds: 250),
  }) : clock = clock ?? DateTime.now;

  final PushJournal journal;
  final PushReportOutbox outbox;
  final Map<String, dynamic> Function() payload;
  final Future<List<Map<String, Object>>> Function() readNative;
  final String Function()? nativeStatus;
  final bool Function()? canSend;
  final DateTime Function() clock;
  final Duration coalesce;
  // Полный retained union: Dart <=512 КиБ + native <=128 КиБ, общий
  // immutable account snapshot <=32 КиБ. Переполнение остаётся явным.
  static const maxBuffered = 2304;
  static const maxBufferBytes = 768 * 1024;
  final Map<String, _CapturedIncident> _pending = {};
  final Set<String> _tracked = {};
  final Map<String, _IncidentPayload> _payloads = {};
  int _bufferBytes = 0;
  int _bufferEvictions = 0;
  int _sourceErrors = 0;
  int _trackedEvictions = 0;
  int _nativeLoss = 0;
  String _nativeReadStatus = 'unknown';
  DateTime? _nativeReadAt;
  Timer? _coalescer;
  Timer? _retry;
  Future<void>? _flight;
  Future<void>? _replayFlight;
  bool _started = false;
  bool _disposed = false;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    journal.addObserver(_onRecord);
    // startup/resume/tick не зависят от daily/manual eligibility.
    _retry = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(replay()),
    );
    unawaited(replay());
  }

  static bool _trigger(PushIncidentRecord record) {
    final d = record.data;
    final media = d[record.native ? 'media' : 'kind'];
    final event = d[record.native ? 'event_hash' : 'e128'] ?? d['e'];
    // noEvent у non-mac callback означает отсутствие macOS-вердикта,
    // поэтому наличие события определяем по hash, а не имени причины.
    if (event is! String || event.isEmpty || d['r'] == 'clearing') {
      return false;
    }
    if (media == 'voice' || media == 'audio') return true;
    if (media != null && media != 'unknown' && media != 'encrypted') {
      return false;
    }
    return record.native
        ? const {'received', 'nseReceived', 'fcmReceived'}.contains(d['s']) &&
              d['source'] != 'local'
        : d['s'] == 'apns';
  }

  bool _eligible(PushIncidentRecord record) =>
      record.data['r'] != 'clearing' &&
      (_trigger(record) ||
          (record.eventKey != null && _tracked.contains(record.eventKey)));

  void _onRecord(PushJournalEntry entry) {
    try {
      final record = PushIncidentRecord(entry.toJson(), native: false);
      if (!_eligible(record)) return;
      // Копия record и account snapshot ДО любого await/timer/сетевого drain.
      _capture(record);
      journal.flush();
      _schedule();
    } catch (_) {
      _sourceErrors++;
    }
  }

  void _capture(PushIncidentRecord record) {
    if (_disposed || _pending.containsKey(record.key)) return;
    if (record.eventKey case final key?) {
      _track(key);
    }
    final encoded = jsonEncode(payload());
    final snapshot = _payloads.putIfAbsent(
      encoded,
      () => _IncidentPayload(encoded),
    );
    if (snapshot.references++ == 0) _bufferBytes += snapshot.bytes;
    final captured = _CapturedIncident(record, snapshot);
    _pending[record.key] = captured;
    _bufferBytes += captured.bytes;
    while (_pending.length > maxBuffered || _bufferBytes > maxBufferBytes) {
      _remove(_pending.keys.first);
      _bufferEvictions++;
    }
  }

  void _remove(String key) {
    final removed = _pending.remove(key);
    if (removed == null) return;
    _bufferBytes -= removed.bytes;
    if (--removed.snapshot.references == 0) {
      _payloads.remove(removed.snapshot.key);
      _bufferBytes -= removed.snapshot.bytes;
    }
  }

  void _track(String key) {
    _tracked.remove(key);
    _tracked.add(key);
    while (_tracked.length > PushReportOutbox.trackedLimit) {
      _tracked.remove(_tracked.first);
      _trackedEvictions++;
    }
  }

  void _captureSnapshot(List<PushIncidentRecord> records) {
    for (final record in records) {
      if (record.native &&
          record.data['s'] == 'diagnosticLoss' &&
          record.data['value'] is int &&
          record.data['value'] > _nativeLoss) {
        _nativeLoss = record.data['value'] as int;
      }
    }
    // Сначала узнаём интересующие события, затем сохраняем их более ранние
    // стадии из того же полного retained снимка, даже без metadata.
    for (final record in records.where(_trigger)) {
      if (record.eventKey case final key?) _track(key);
    }
    for (final record in records) {
      if (_eligible(record)) _capture(record);
    }
  }

  void _schedule() {
    if (_disposed || _coalescer != null || _flight != null) return;
    _coalescer = Timer(coalesce, () {
      _coalescer = null;
      unawaited(flush());
    });
  }

  Future<void> replay() {
    if (_disposed) return Future.value();
    // Первый снимок закреплён до чтения outbox/native. Локальная ошибка
    // одного источника не запрещает сбор и экспорт остальных.
    _captureSnapshot(
      journal.entries
          .map((e) => PushIncidentRecord(e.toJson(), native: false))
          .toList(),
    );
    journal.flush();
    return _replayFlight ??= _replay().whenComplete(() => _replayFlight = null);
  }

  Future<void> _replay() async {
    try {
      final state = await outbox.inspect();
      for (final key in (state['tracked'] as Map).keys.cast<String>()) {
        _track(key);
      }
    } catch (_) {
      _sourceErrors++;
    }
    try {
      await journal.init();
      _captureSnapshot(
        journal.entries
            .map((e) => PushIncidentRecord(e.toJson(), native: false))
            .toList(),
      );
      journal.flush();
    } catch (_) {
      _sourceErrors++;
    }
    try {
      final native = await readNative();
      _nativeReadAt = clock();
      _nativeReadStatus = nativeStatus?.call() ?? 'available';
      if (_nativeReadStatus == 'unknown') _sourceErrors++;
      _captureSnapshot(
        native.map((e) => PushIncidentRecord(e, native: true)).toList(),
      );
    } catch (_) {
      _nativeReadAt = clock();
      _nativeReadStatus = 'unknown';
      _sourceErrors++;
    }
    await flush();
  }

  Future<void> flush() {
    if (_disposed) return Future.value();
    _coalescer?.cancel();
    _coalescer = null;
    return _flight ??= _flush().whenComplete(() => _flight = null);
  }

  Future<void> _flush() async {
    try {
      while (_pending.isNotEmpty && !_disposed) {
        final all = _pending.values.toList();
        final first = all.first;
        final records = all
            .where((c) => c.identity == first.identity)
            .map((c) => c.record)
            .toList();
        final data =
            jsonDecode(jsonEncode(first.payload)) as Map<String, dynamic>;
        data['context']['incident_export'] = {
          'buffer_evictions_since_start': _bufferEvictions,
          'source_errors_since_start': _sourceErrors,
          'tracked_evictions_since_start': _trackedEvictions,
          'buffer_bytes': _bufferBytes,
          'buffer_limit_bytes': maxBufferBytes,
          'capture_counter_scope': 'process_lifetime',
        };
        data['context']['native_loss'] = _nativeLoss;
        final storage = journal.exportCoverage(const [], 0);
        final dartCoverage =
            data['context']['coverage']['dart_journal'] as Map<String, dynamic>;
        for (final key in const [
          'ring_evictions_since_start',
          'pending_evictions_since_start',
          'disk_evictions_since_start',
          'persistence_failures_since_start',
        ]) {
          dartCoverage[key] = storage[key];
        }
        dartCoverage['critical_flush'] = 'best_effort_no_fsync';
        (data['context']['coverage'] as Map<String, dynamic>).addAll({
          'native_journal': _nativeLoss > 0 ? 'partial' : _nativeReadStatus,
          'native_read_status': _nativeReadStatus,
          if (_nativeReadAt != null)
            'native_read_observed_at': _nativeReadAt!.toUtc().toIso8601String(),
          'native_loss_semantics': 'cumulative_unknown_window',
          'native_window': 'unknown',
          'native_persistence': 'best_effort',
          'native_crash_tail': 'async_pending_unknown_after_process_exit',
        });
        final handled = await outbox.enqueueIncident(data, records, clock());
        if (handled.isEmpty) {
          return; // storage/oversize: минутный retry, без spin.
        }
        for (final key in handled) {
          _remove(key);
        }
      }
      await outbox.drain(clock(), canSend: canSend);
    } catch (_) {
      // Журнал и captured queue сохраняются; retry по минуте/resume.
      _sourceErrors++;
    } finally {
      // Записи, пришедшие во время HTTP, остаются закреплены до следующего
      // coalesced batch. Ошибки IO не создают горячий бесконечный retry.
      if (!_disposed && _pending.isNotEmpty) {
        _coalescer ??= Timer(const Duration(minutes: 1), () {
          _coalescer = null;
          unawaited(flush());
        });
      }
    }
  }

  void dispose() {
    _disposed = true;
    journal.removeObserver(_onRecord);
    _coalescer?.cancel();
    _retry?.cancel();
  }
}
