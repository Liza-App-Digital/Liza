import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/push_journal.dart';

/// Ф1.1 (спека 2026-11-12-push-sync-industry-alignment): подтверждения с
/// устройства по событию. Отдельная сущность от журнала (`RL-push-report-outbox`
/// AC-7 не размываем), но транспорт тот же — блок `acks` ежедневного
/// push-report. Хэши — sha256-128 hex, как `_push_outcomes.py` в Sygnal и
/// нативные журналы, поэтому сервер стыкует «отправлено — пришло» по
/// `event_hash` + `pushkey_hash` без сырых идентификаторов (AC-10).
String pushAckHash(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 32);

/// Исходы закрытым перечнем: свободного текста в подтверждении нет.
enum PushAckOutcome {
  received,
  shown,
  suppressed,
  skipped,
  duplicate,
  expired,
  error,
  failed,
}

/// Нативная стадия → исход. Неизвестные стадии (token, sweep, loss) — не
/// подтверждения доставки.
PushAckOutcome? nativeAckOutcome(Object? stage) => switch (stage) {
  'nseReceived' || 'fcmReceived' => PushAckOutcome.received,
  'nseCompleted' => PushAckOutcome.shown,
  'nseExpired' => PushAckOutcome.expired,
  'nseError' => PushAckOutcome.error,
  'fcmDuplicate' => PushAckOutcome.duplicate,
  'nseSuppressed' => PushAckOutcome.suppressed,
  _ => null,
};

/// Исход локального показа (баннер из sync). Ранние выходы журнала
/// (`activeRoom`, `tooOld` …) — не доставка пуша, подтверждением не считаются.
PushAckOutcome? localAckOutcome(PushReason reason) => switch (reason) {
  PushReason.shown => PushAckOutcome.shown,
  PushReason.apnsHandled => PushAckOutcome.skipped,
  PushReason.failed => PushAckOutcome.failed,
  _ => null,
};

/// Локальные исходы главного изолята (баннер из sync), персистентное кольцо.
class PushAckLog {
  PushAckLog._();
  static final PushAckLog instance = PushAckLog._();

  static const maxEntries = 200;
  static const _key = 'push.acks_v1';
  final List<Map<String, Object>> _pending = [];
  Future<void> _tail = Future.value();

  void record(String eventId, PushAckOutcome outcome, {DateTime? now}) {
    if (eventId.isEmpty) return;
    _pending.add({
      'e': pushAckHash(eventId),
      'o': outcome.name,
      't': (now ?? DateTime.now()).millisecondsSinceEpoch,
    });
    _tail = _tail.then((_) => _persist()).catchError((Object _) {});
  }

  Future<void> _persist() async {
    if (_pending.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final all = [...decode(prefs.getString(_key)), ..._pending];
    _pending.clear();
    final kept = all.length > maxEntries
        ? all.sublist(all.length - maxEntries)
        : all;
    await prefs.setString(_key, jsonEncode(kept));
  }

  Future<List<Map<String, Object>>> read() async {
    await _tail;
    final prefs = await SharedPreferences.getInstance();
    return decode(prefs.getString(_key));
  }

  /// Терпимый разбор: чужое/битое отбрасываем поштучно.
  static List<Map<String, Object>> decode(String? raw) {
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return [];
      return [
        for (final item in list)
          if (item is Map &&
              item['e'] is String &&
              _hash.hasMatch(item['e'] as String) &&
              PushAckOutcome.values.any((o) => o.name == item['o']) &&
              item['t'] is int)
            {
              'e': item['e'] as String,
              'o': item['o'] as String,
              't': item['t'] as int,
            },
      ];
    } catch (_) {
      return [];
    }
  }

  static final _hash = RegExp(r'^[0-9a-f]{32}$');
}

/// Блок `acks` для push-report: только `event_hash`, исход, источник и время
/// устройства; на уровне блока — `pushkey_hash` и сборка. Новейшие
/// [limit] за окно, остальное — счётчиком `truncated` (AC-10: объём ограничен).
Map<String, Object> buildPushAcks({
  required List<Map<String, Object>> nativeJournal,
  required List<Map<String, Object>> local,
  required String? pushkey,
  required String build,
  required DateTime since,
  int limit = 200,
}) {
  final acks = <Map<String, Object>>[];
  for (final entry in nativeJournal) {
    final outcome = nativeAckOutcome(entry['s']);
    final hash = entry['event_hash'];
    final t = entry['t'];
    if (outcome == null || hash is! String || t is! int) continue;
    if (t < since.millisecondsSinceEpoch) continue;
    final sent = entry['sent'];
    acks.add({
      'e': hash,
      'o': outcome.name,
      'src': 'native',
      't': t,
      if (sent is int && sent > 0) 's': sent,
    });
  }
  for (final entry in local) {
    final t = entry['t'] as int;
    if (t < since.millisecondsSinceEpoch) continue;
    acks.add({...entry, 'src': 'local'});
  }
  acks.sort((a, b) => (b['t'] as int).compareTo(a['t'] as int));
  final truncated = acks.length > limit ? acks.length - limit : 0;
  return {
    'schema': 1,
    'hash_version': 'sha256-128',
    if (pushkey != null && pushkey.isNotEmpty)
      'pushkey_hash': pushAckHash(pushkey),
    'build': build,
    'acks': truncated > 0 ? acks.sublist(0, limit) : acks,
    'truncated': truncated,
  };
}
