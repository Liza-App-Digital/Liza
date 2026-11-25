import 'dart:math';

/// QoE-маяк медиа (спека 2026-11-24-media-qoe-monitoring-design): одна запись
/// на попытку просмотра или отправки видео → `POST /liza/telemetry/v1/media`.
///
/// Модель чистая — без Player, Room и сети: хост (просмотрщик, трекер
/// отправки) сообщает факты, модель копит измерения и РОВНО ОДИН раз отдаёт
/// итог в [MediaQoe.sink]. В запись не попадают ни ключи/iv, ни mxc, ни
/// eventId/roomId, ни URL и имя файла — только числа, enum-ы и короткий host.
abstract interface class MediaQoeSink {
  /// Попытка началась. Запись хранится до [finished]: если приложение убьют
  /// раньше, при следующем старте она уйдёт как `abandoned_unknown`.
  void opened(Map<String, Object> event);

  /// Итог попытки (та же `attempt_id`, что в [opened]).
  void finished(Map<String, Object> event);

  /// Попытка снята без итога (не учитывается вовсе).
  void dropped(String attemptId);
}

abstract final class MediaQoe {
  /// Приёмник событий; null — маяк выключен (тесты, фоновые изоляты).
  static MediaQoeSink? sink;

  /// Тип сети на момент события; обновляет [MediaQoeReporter].
  static String net = 'unknown';

  static final _random = Random.secure();

  static String newAttemptId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static final _mime = RegExp(r'^(video|audio|image)/[a-z0-9.+-]{1,40}$');
  static final _host = RegExp(r'^[a-z0-9.-]{1,64}$');

  static String? safeMime(String? value) {
    final v = value?.toLowerCase().split(';').first.trim();
    return v != null && _mime.hasMatch(v) ? v : null;
  }

  static String? safeHost(String? value) {
    final v = value?.toLowerCase();
    return v != null && _host.hasMatch(v) ? v : null;
  }

  /// Ошибки маяка никогда не доходят до плеера или отправки.
  static void _deliver(void Function(MediaQoeSink s) action) {
    final s = sink;
    if (s == null) return;
    try {
      action(s);
    } catch (_) {}
  }
}

/// Исходы просмотра (имена на проводе — snake_case, закрытый enum сервера).
enum MediaQoeViewOutcome {
  success('success'),
  vsf('vsf'),
  ebvs('ebvs'),
  vpf('vpf'),
  swappedOk('swapped_ok'),
  swappedFailed('swapped_failed'),
  userRetry('user_retry');

  const MediaQoeViewOutcome(this.wire);
  final String wire;
}

/// Одна попытка просмотра: от старта воспроизведения (тап play / автостарт
/// сторис) до итога. Превью в ленте сюда не попадает — только просмотрщик.
class MediaQoeViewSession {
  MediaQoeViewSession({
    required this.surface,
    String? mime,
    int? sizeBytes,
    bool? e2ee,
    String? host,
    int Function()? wallClockMs,
    Stopwatch? clock,
  }) : attemptId = MediaQoe.newAttemptId(),
       _clock = clock ?? (Stopwatch()..start()),
       tsMs = (wallClockMs ?? _wallNow)() {
    _base = {
      'attempt_id': attemptId,
      'kind': 'view',
      'ts_ms': tsMs,
      'surface': surface,
      'mime': ?MediaQoe.safeMime(mime),
      if (sizeBytes != null && sizeBytes >= 0) 'size_bytes': sizeBytes,
      'e2ee': ?e2ee,
      'host': ?MediaQoe.safeHost(host),
    };
    MediaQoe._deliver(
      (s) => s.opened({
        ..._base,
        'outcome': 'abandoned_unknown',
        'net': MediaQoe.net,
      }),
    );
  }

  static int _wallNow() => DateTime.now().millisecondsSinceEpoch;

  final String attemptId;
  final String surface;
  final int tsMs;
  final Stopwatch _clock;
  late final Map<String, Object> _base;

  int? _ttffMs;
  bool? _frameByDeadline;
  bool _swapped = false;
  String? _path;
  int _netSum = 0;
  int _netSamples = 0;

  int _stallCount = 0;
  int _stallMs = 0;
  int? _stallSince;

  int _bgMs = 0;
  int? _bgSince;

  bool _finished = false;
  bool get finished => _finished;
  bool get frameShown => _ttffMs != null;

  int get _now => _clock.elapsedMilliseconds;

  /// Первый кадр — только из гейта первого кадра просмотрщика.
  void markFirstFrame({required bool byDeadline}) {
    if (_finished || _ttffMs != null) return;
    _ttffMs = _now;
    _frameByDeadline = byDeadline;
  }

  /// Источник переключён на полностью скачанный локальный файл.
  void markSwapped() {
    if (!_finished) _swapped = true;
  }

  /// `proxy` (E2EE-прокси) | `stream` (HTTP) | `download` (локальный файл).
  void setPath(String path) {
    if (!_finished && const {'proxy', 'stream', 'download'}.contains(path)) {
      _path = path;
    }
  }

  /// Сэмпл скорости входа плеера (mpv `cache-speed`, байт/с); в итог идёт
  /// среднее по ненулевым сэмплам — нули значат «буфер полон», а не «сети нет».
  void addNetSample(int? bytesPerSecond) {
    if (_finished || bytesPerSecond == null || bytesPerSecond <= 0) return;
    _netSum += bytesPerSecond;
    _netSamples++;
  }

  /// Переход «пауза за буфером» по сэмплам монитора. До первого кадра это
  /// ожидание старта, а не подвисание, — не считаем.
  void stallChanged(bool paused) {
    if (_finished) return;
    if (paused && _stallSince == null && _ttffMs != null) {
      _stallSince = _now;
      _stallCount++;
    } else if (!paused && _stallSince != null) {
      _stallMs += _now - _stallSince!;
      _stallSince = null;
    }
  }

  /// Приложение ушло в фон / вернулось. Время в фоне — отдельным полем,
  /// сервер исключает такие попытки из правила «медленный старт».
  void backgroundChanged(bool suspended) {
    if (_finished) return;
    if (suspended && _bgSince == null) {
      _bgSince = _now;
    } else if (!suspended && _bgSince != null) {
      _bgMs += _now - _bgSince!;
      _bgSince = null;
    }
  }

  /// Провал (error-overlay): до кадра — VSF, после — VPF, после свапа —
  /// swapped_failed.
  void finishError() => _finish(
    _swapped
        ? MediaQoeViewOutcome.swappedFailed
        : (frameShown ? MediaQoeViewOutcome.vpf : MediaQoeViewOutcome.vsf),
  );

  /// Пользователь ушёл (закрыл просмотрщик, свайпнул карусель, сменил
  /// событие): до кадра без ошибки — EBVS, иначе успех.
  void finishExit() => _finish(
    !frameShown
        ? MediaQoeViewOutcome.ebvs
        : (_swapped
              ? MediaQoeViewOutcome.swappedOk
              : MediaQoeViewOutcome.success),
  );

  /// Попытку перезапустили до итога (повтор, смена источника).
  void finishRetry() => _finish(
    !frameShown
        ? MediaQoeViewOutcome.userRetry
        : (_swapped
              ? MediaQoeViewOutcome.swappedOk
              : MediaQoeViewOutcome.success),
  );

  /// Итог, собранный без отправки (для тестов и [MediaQoe.sink]).
  Map<String, Object> _event(MediaQoeViewOutcome outcome) {
    final now = _now;
    final stallMs = _stallMs + (_stallSince == null ? 0 : now - _stallSince!);
    final bgMs = _bgMs + (_bgSince == null ? 0 : now - _bgSince!);
    return {
      ..._base,
      'outcome': outcome.wire,
      'net': MediaQoe.net,
      'watch_ms': now,
      'ttff_ms': ?_ttffMs,
      'frame_by_deadline': ?_frameByDeadline,
      if (outcome == MediaQoeViewOutcome.ebvs) 'exit_before_frame_ms': now,
      'stall_count': _stallCount,
      'stall_ms': stallMs,
      'bg_ms': bgMs,
      'path': ?_path,
      if (_netSamples > 0) 'net_bytes_per_s': _netSum ~/ _netSamples,
    };
  }

  void _finish(MediaQoeViewOutcome outcome) {
    if (_finished) return;
    _finished = true;
    final event = _event(outcome);
    MediaQoe._deliver((s) => s.finished(event));
  }
}

class _SendAttempt {
  _SendAttempt(this.base) : clock = Stopwatch()..start();
  final Map<String, Object> base;
  final Stopwatch clock;
  final phaseMs = <String, int>{};
  String? phase;
  int phaseSince = 0;

  void enter(String next) {
    final now = clock.elapsedMilliseconds;
    final current = phase;
    if (current != null) {
      phaseMs[current] = (phaseMs[current] ?? 0) + now - phaseSince;
    }
    phase = next;
    phaseSince = now;
  }
}

/// Попытки отправки по txid. Ключ — (txid, attempt): после итога/снятия
/// повтор того же txid — новая попытка с новым `attempt_id`.
class MediaQoeSendTracker {
  MediaQoeSendTracker({int Function()? wallClockMs})
    : _wall = wallClockMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _wall;
  final _open = <String, _SendAttempt>{};

  static const _phaseFields = {
    'preparing': 'prepare_ms',
    'compressing': 'compress_ms',
    'uploading': 'upload_ms',
    'waitingNetwork': 'wait_network_ms',
  };

  bool isOpen(String txid) => _open.containsKey(txid);

  /// Начало попытки. Повторный вызов на открытой попытке (retry на 429
  /// внутри SDK) — та же попытка.
  void begin(
    String txid, {
    String? mime,
    int? sizeBytes,
    bool? e2ee,
    bool? album,
  }) {
    if (_open.containsKey(txid)) return;
    final safeMime = MediaQoe.safeMime(mime);
    if (safeMime == null || safeMime.startsWith('audio/')) return;
    final attempt = _SendAttempt({
      'attempt_id': MediaQoe.newAttemptId(),
      'kind': 'send',
      'ts_ms': _wall(),
      'mime': safeMime,
      if (sizeBytes != null && sizeBytes >= 0) 'size_bytes': sizeBytes,
      'e2ee': ?e2ee,
      'album': ?album,
    })..enter('preparing');
    _open[txid] = attempt;
    MediaQoe._deliver(
      (s) => s.opened({
        ...attempt.base,
        'outcome': 'abandoned_unknown',
        'net': MediaQoe.net,
      }),
    );
  }

  /// Смена этапа: `UploadPhase.name`.
  void phase(String txid, String phase) {
    final attempt = _open[txid];
    if (attempt == null || !_phaseFields.containsKey(phase)) return;
    if (attempt.phase != phase) attempt.enter(phase);
  }

  void sent(String txid) => _finish(txid, 'sent');

  void failed(String txid, {String? errorKind}) =>
      _finish(txid, 'failed_terminal', errorKind: errorKind);

  void canceled(String txid) => _finish(txid, 'canceled');

  /// Снятие без итога (unregister без статуса) — не учитываем.
  void drop(String txid) {
    final attempt = _open.remove(txid);
    if (attempt == null) return;
    final id = attempt.base['attempt_id'] as String;
    MediaQoe._deliver((s) => s.dropped(id));
  }

  void _finish(String txid, String outcome, {String? errorKind}) {
    final attempt = _open.remove(txid);
    if (attempt == null) return;
    attempt.enter('done');
    final total = attempt.clock.elapsedMilliseconds;
    final uploadMs = attempt.phaseMs['uploading'];
    final size = attempt.base['size_bytes'] as int?;
    final kind = errorKind?.toLowerCase();
    final event = <String, Object>{
      ...attempt.base,
      'outcome': outcome,
      'net': MediaQoe.net,
      'duration_ms': total,
      for (final e in _phaseFields.entries)
        if (attempt.phaseMs[e.key] case final int ms) e.value: ms,
      if (outcome == 'sent' && size != null) 'bytes': size,
      if (outcome == 'sent' && size != null && uploadMs != null && uploadMs > 0)
        'net_bytes_per_s': size * 1000 ~/ uploadMs,
      if (kind != null && RegExp(r'^[a-z_]{1,32}$').hasMatch(kind))
        'error_kind': kind,
    };
    MediaQoe._deliver((s) => s.finished(event));
  }
}
