import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

/// Стадия пути уведомления, которую журнал фиксирует.
///
/// Имя (`name`) уходит в JSON как есть — серверный разбор
/// (`deploy/scripts/push_fleet_report.py`) матчит `apns` по этому имени.
enum PushStage {
  /// APNs-пуш дошёл до живого процесса (`didReceiveRemoteNotification`).
  apns,

  /// Ответ нативному гейту баннера у активного окна (`NativeBannerGate`).
  gate,

  /// Локальное уведомление из /sync: показано или упало.
  local,

  /// Локальное уведомление НЕ показано — причина в [PushReason].
  localSkip,

  /// Записано число на бейдже (значение — `value`). Это факт записи, а НЕ
  /// факт отрисовки: read-back бейджа на macOS тавтологичен.
  badge,

  /// Сигнал `[push-config]` (уведомления выключены настройками).
  config,

  /// Мак засыпает / просыпается (NSWorkspace) — без этого «пуш опоздал» и
  /// «Мак спал» неотличимы.
  sleep,
  wake,

  /// Решение нативного `willPresent` у активного приложения.
  native,

  /// Между двумя /sync прошло больше [PushJournal.syncGapThreshold] —
  /// процесс стоял (сон, заморозка). `value` — секунды.
  syncGap,
}

/// Закрытый перечень причин. Свободного текста журнал не принимает
/// (инвариант `RL-push-health-report`: в телеметрию нельзя протащить текст
/// сообщения даже по ошибке — у API нет такого параметра).
enum PushReason {
  // Вердикт classifyNativeBanner / outcome handleApnsMessage.
  suppressLocal,
  suppressRead,
  show,
  unknownEvent,
  noEvent,
  duplicate,
  clearing,
  // NativeBannerGate.
  suppress,
  banner,
  silent,
  // Ранние выходы showLocalNotification.
  newsAudience,
  activeRoom,
  hiddenRoom,
  tooOld,
  apnsHandled,
  // Исход показа.
  shown,
  failed,
  // Опции натива.
  bannerSoundList,
  soundList,
  none,
  formatted,
  addFailed,
  // [push-config].
  osDenied,
  defaultRuleDisabled,
  // Сон.
  system,
  screens,
}

/// Одна запись журнала. Поля — только числа, enum и hash8.
@immutable
class PushJournalEntry {
  const PushJournalEntry({
    required this.timeMs,
    required this.stage,
    this.reason,
    this.state,
    this.eventHash,
    this.roomHash,
    this.value,
  });

  final int timeMs;
  final PushStage stage;
  final PushReason? reason;
  final AppLifecycleState? state;
  final String? eventHash;
  final String? roomHash;
  final int? value;

  Map<String, Object> toJson() => {
    't': timeMs,
    's': stage.name,
    if (reason != null) 'r': reason!.name,
    if (state != null) 'st': state!.name,
    if (eventHash != null) 'e': eventHash!,
    if (roomHash != null) 'rm': roomHash!,
    if (value != null) 'v': value!,
  };

  /// Терпимый разбор: битая или чужая строка → null, а не исключение
  /// (журнал дописывается построчно и может оборваться на kill).
  static PushJournalEntry? tryParse(String line) {
    try {
      final raw = jsonDecode(line);
      if (raw is! Map) return null;
      final t = raw['t'];
      final stage = _byName(PushStage.values, raw['s']);
      if (t is! int || stage == null) return null;
      final e = raw['e'];
      final rm = raw['rm'];
      final v = raw['v'];
      return PushJournalEntry(
        timeMs: t,
        stage: stage,
        reason: _byName(PushReason.values, raw['r']),
        state: _byName(AppLifecycleState.values, raw['st']),
        eventHash: e is String && _isHash(e) ? e : null,
        roomHash: rm is String && _isHash(rm) ? rm : null,
        value: v is int ? v : null,
      );
    } catch (_) {
      return null;
    }
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static final _hashRe = RegExp(r'^[0-9a-f]{8}$');
  static bool _isHash(String s) => _hashRe.hasMatch(s);
}

/// Структурный журнал пути уведомлений на устройстве.
///
/// Зачем (спека `2026-10-16-push-telemetry-cohorts-design.md`): разбор
/// «у пользователя не работают пуши» годами упирался в лог, которого нет. Журнал
/// копится сам у всех и раз в сутки уходит хвостом в `[health] push-report`.
/// Сырые `event_id`/`room_id` не пишутся — только [hash8]: сервер хеширует
/// event_id из лога Sygnal так же и сверяет «отправлено — пришло».
///
/// Наблюдатель: ни один метод не бросает и не ждёт IO на вызывающей стороне.
/// В фоновом изоляте (Android FCM) [init] не зовётся — записи остаются в памяти
/// и никуда не пишутся: второй писатель того же файла рвал бы строки.
class PushJournal {
  PushJournal._();

  @visibleForTesting
  PushJournal.forTest();

  static final PushJournal instance = PushJournal._();

  static const int maxEntries = 2000;
  static const int _maxFileBytes = 512 * 1024;
  static const String _fileName = 'push_journal.jsonl';
  static const Duration syncGapThreshold = Duration(minutes: 2);

  /// Первые 8 hex sha256 — общий вектор с `push_fleet_report.py` (AC-13).
  static String hash8(String value) =>
      sha256.convert(utf8.encode(value)).toString().substring(0, 8);

  final List<PushJournalEntry> _entries = [];
  final List<String> _pending = [];
  File? _file;
  int? _lastSyncMs;

  List<PushJournalEntry> get entries => List.unmodifiable(_entries);

  /// Подключить файл и подтянуть прошлые записи. Вызывается один раз из
  /// главного изолята после `FileLogger.init`.
  Future<void> init() async {
    if (kIsWeb || _file != null) return;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/$_fileName');
      // Записанное до готовности файла (init идёт не блокируя старт; холодный
      // старт от пуша пишет первым) — тоже на диск, и на первом старте, когда
      // файла ещё нет.
      final early = _entries.map((e) => jsonEncode(e.toJson())).toList();
      if (await file.exists()) {
        final lines = await file.readAsLines();
        final start = lines.length > maxEntries ? lines.length - maxEntries : 0;
        final loaded = <PushJournalEntry>[];
        for (final line in lines.skip(start)) {
          final e = PushJournalEntry.tryParse(line);
          if (e != null) loaded.add(e);
        }
        _entries.insertAll(0, loaded);
        _trim();
        if (await file.length() > _maxFileBytes) {
          await file.writeAsString(_serialize(_entries), flush: true);
        }
      }
      _pending.addAll(early);
      _file = file;
      Timer.periodic(const Duration(seconds: 5), (_) => flush());
    } catch (e) {
      debugPrint('PushJournal init failed: $e');
    }
  }

  void record(
    PushStage stage, {
    PushReason? reason,
    AppLifecycleState? state,
    String? eventId,
    String? roomId,
    int? value,
    DateTime? now,
  }) {
    try {
      final entry = PushJournalEntry(
        timeMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
        stage: stage,
        reason: reason,
        state: state,
        eventHash: eventId == null || eventId.isEmpty ? null : hash8(eventId),
        roomHash: roomId == null || roomId.isEmpty ? null : hash8(roomId),
        value: value,
      );
      _entries.add(entry);
      _trim();
      if (_file != null) _pending.add(jsonEncode(entry.toJson()));
    } catch (_) {
      // Наблюдатель: сбой записи не должен трогать путь уведомления.
    }
  }

  /// Запись от нативного кода (macOS `MacApnsPushPlugin.journal`). Всё, что не
  /// из закрытых перечней, отбрасывается.
  void recordNative(Object? args) {
    if (args is! Map) return;
    final stage = PushJournalEntry._byName(PushStage.values, args['stage']);
    if (stage == null) return;
    final value = args['value'];
    final eventId = args['eventId'];
    // Время — натива: событие сна Dart получает уже после пробуждения.
    final timeMs = args['timeMs'];
    record(
      stage,
      reason: PushJournalEntry._byName(PushReason.values, args['reason']),
      eventId: eventId is String ? eventId : null,
      value: value is int ? value : null,
      now: timeMs is int ? DateTime.fromMillisecondsSinceEpoch(timeMs) : null,
    );
  }

  /// Отметка очередного /sync. Пропасть больше порога = процесс стоял.
  void noteSync({DateTime? now}) {
    final ms = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final last = _lastSyncMs;
    _lastSyncMs = ms;
    if (last == null) return;
    final gap = ms - last;
    if (gap >= syncGapThreshold.inMilliseconds) {
      record(
        PushStage.syncGap,
        value: gap ~/ 1000,
        now: DateTime.fromMillisecondsSinceEpoch(ms),
      );
    }
  }

  void flush() {
    final file = _file;
    if (file == null || _pending.isEmpty) return;
    try {
      final data = '${_pending.join('\n')}\n';
      _pending.clear();
      // Без fsync: журнал диагностический, потеря хвоста при kill допустима, а
      // fsync на UI-изоляте раз в 5 с — это микрофризы на медленном диске.
      if (file.existsSync() && file.lengthSync() > _maxFileBytes) {
        file.writeAsStringSync(_serialize(_entries));
      } else {
        file.writeAsStringSync(data, mode: FileMode.append);
      }
    } catch (e) {
      debugPrint('PushJournal flush failed: $e');
    }
  }

  void _trim() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  static String _serialize(List<PushJournalEntry> entries) =>
      '${entries.map((e) => jsonEncode(e.toJson())).join('\n')}\n';

  /// Хвост журнала (новейшие записи) JSONL-строкой не длиннее [maxBytes].
  static String tail(List<PushJournalEntry> entries, int maxBytes) {
    final lines = <String>[];
    var bytes = 0;
    for (final e in entries.reversed) {
      final line = jsonEncode(e.toJson());
      final size = utf8.encode(line).length + 1;
      if (bytes + size > maxBytes) break;
      bytes += size;
      lines.add(line);
    }
    return lines.reversed.join('\n');
  }

  @visibleForTesting
  void resetForTest() {
    _entries.clear();
    _pending.clear();
    _lastSyncMs = null;
  }
}

/// Счётчики журнала за окно — плоские числа для `extra` push-report.
///
/// Только факты, которые устройство проверяет само. «Пуш потерян» отсюда НЕ
/// выводится: read-grace, mute и сон делают такой вывод ложным на клиенте —
/// доставку считает сервер по хвосту журнала (`push_fleet_report.py`).
abstract final class PushJournalStats {
  static Map<String, num> compute(
    List<PushJournalEntry> entries, {
    required DateTime since,
  }) {
    final sinceMs = since.millisecondsSinceEpoch;
    // Нативные записи (сон) приходят в Dart уже после пробуждения — порядок в
    // списке не хронологический, пары sleep→wake ищем по времени.
    final window = entries.where((e) => e.timeMs >= sinceMs).toList()
      ..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    final out = <String, num>{
      'journal_entries': window.length,
      'apns_received': 0,
      'local_shown': 0,
      'local_failed': 0,
      'badge_writes': 0,
      'sleep_count': 0,
      'sleep_minutes': 0,
      'sync_gap_count': 0,
      'sync_gap_max_s': 0,
    };
    final latencies = <int>[];
    int? sleptAt;
    for (final e in window) {
      switch (e.stage) {
        case PushStage.apns:
          // Сверяется с отправками Sygnal (alert-пуши с event_id) — clearing и
          // повтор того же пуша туда не входят.
          if (e.eventHash != null &&
              e.reason != PushReason.clearing &&
              e.reason != PushReason.duplicate) {
            out['apns_received'] = out['apns_received']! + 1;
          }
          if (e.value != null) latencies.add(e.value!);
        case PushStage.local:
          final key = e.reason == PushReason.failed
              ? 'local_failed'
              : 'local_shown';
          out[key] = out[key]! + 1;
        case PushStage.badge:
          out['badge_writes'] = out['badge_writes']! + 1;
          if (e.value != null) out['badge_last'] = e.value!;
        // Сон дисплея — отдельный счётчик: процесс при нём живёт, а сон
        // системы останавливает всё, включая доставку APNs в процесс.
        case PushStage.sleep when e.reason == PushReason.screens:
          out['screen_sleep_count'] = (out['screen_sleep_count'] ?? 0) + 1;
        case PushStage.wake when e.reason == PushReason.screens:
          break;
        case PushStage.sleep:
          out['sleep_count'] = out['sleep_count']! + 1;
          sleptAt = e.timeMs;
        case PushStage.wake:
          if (sleptAt != null) {
            out['sleep_minutes'] =
                out['sleep_minutes']! + (e.timeMs - sleptAt) ~/ 60000;
            sleptAt = null;
          }
        case PushStage.syncGap:
          out['sync_gap_count'] = out['sync_gap_count']! + 1;
          final v = e.value ?? 0;
          if (v > out['sync_gap_max_s']!) out['sync_gap_max_s'] = v;
        case PushStage.gate:
        case PushStage.localSkip:
        case PushStage.config:
        case PushStage.native:
          break;
      }
      if (e.reason != null &&
          (e.stage == PushStage.gate ||
              e.stage == PushStage.localSkip ||
              e.stage == PushStage.native ||
              e.stage == PushStage.apns)) {
        final key = '${_snake(e.stage.name)}.${_snake(e.reason!.name)}';
        out[key] = (out[key] ?? 0) + 1;
      }
    }
    if (latencies.isNotEmpty) {
      latencies.sort();
      out['apns_latency_p50_s'] = _pct(latencies, 0.5);
      out['apns_latency_p90_s'] = _pct(latencies, 0.9);
      out['apns_latency_max_s'] = latencies.last;
      out['apns_late_2m'] = latencies.where((l) => l >= 120).length;
    }
    return out;
  }

  static int _pct(List<int> sorted, double p) =>
      sorted[((sorted.length - 1) * p).round()];

  static String _snake(String camel) =>
      camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');
}

/// Версия ОС «major.minor» из `Platform.operatingSystemVersion` для тега
/// когорты: на macOS строка вида `Version 13.7.8 (Build 22H730)`.
String osMajorMinor(String raw) {
  final m = RegExp(r'(\d+)\.(\d+)').firstMatch(raw);
  if (m != null) return '${m[1]}.${m[2]}';
  final major = RegExp(r'\d+').firstMatch(raw);
  return major?[0] ?? 'unknown';
}

/// Платформа для title push-report — низкая кардинальность.
String pushReportPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isIOS) return 'ios';
  if (Platform.isAndroid) return 'android';
  if (Platform.isWindows) return 'windows';
  return 'linux';
}
