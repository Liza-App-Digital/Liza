import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/network_recovery_trigger.dart';

/// Свидетель заморозки мобильного процесса на время одной сетевой операции.
///
/// iOS/Android усыпляют приложение с загрузкой в полёте, а Dart-таймеры,
/// просроченные во сне, выстреливают при первом же пробуждении — в том числе
/// фоновом. Инцидент GlitchTip #2064 (2026-09-24, сборка 3767): видео 63 МБ
/// качалось, в 19:12:30 приложение ушло в фон, и в 19:30:44 (фоновое
/// пробуждение, `in_foreground=false`) idle-таймер загрузки выстрелил
/// `media stream idle > 60s` → `[video-fail] swap-failed`, хотя канал был ни
/// при чём: MMR честно отдавал файл, пока процесс не заморозили.
///
/// Отвечает на два вопроса: «процесс сейчас заморожен?» ([suspended]) и
/// «объясняется ли сбой сном?» ([failureExplainedBySuspension]: в фоне или в
/// первые [resumeGrace] после возврата — сокет, переживший сон, рвётся сразу).
/// [onResume] — сигнал «перезапусти отсчёт»: сон не должен съедать срок.
///
/// Аудио держит свою копию этой логики (`_ForegroundDeadline` в
/// `audio_autoplay_service.dart`) — там она сплетена с дедлайном подготовки.
class ForegroundWitness {
  /// Без подписки на жизненный цикл: состояние подаёт [onStateChange]
  /// (host-тесты, где биндинга нет или он не шлёт переходы).
  @visibleForTesting
  ForegroundWitness.manual({
    AppLifecycleState? initial,
    this.resumeGrace = const Duration(seconds: 5),
  }) : _suspended = _startsSuspended(initial);

  /// Подписан на жизненный цикл приложения через [AppLifecycleListener].
  ForegroundWitness.attach({this.resumeGrace = const Duration(seconds: 5)})
    : _suspended = _startsSuspended(WidgetsBinding.instance.lifecycleState) {
    _listener = AppLifecycleListener(onStateChange: onStateChange);
  }

  /// Неизвестное состояние (движок ещё не прислал первое) считаем заморозкой:
  /// процесс мог стартовать в фоне от пуша — как в `ResumeHttpRefreshGate`.
  /// Первое же `resumed` снимает флаг, так что на глазах терминал не теряется.
  static bool _startsSuspended(AppLifecycleState? initial) =>
      initial == null || isSuspendingLifecycleState(initial);

  final Duration resumeGrace;
  AppLifecycleListener? _listener;
  bool _suspended;
  bool _justResumed = false;
  Timer? _grace;
  final StreamController<void> _resumed = StreamController<void>.broadcast();
  final List<Completer<void>> _waiters = [];

  bool get suspended => _suspended;

  bool get failureExplainedBySuspension => _suspended || _justResumed;

  Stream<void> get onResume => _resumed.stream;

  /// Ждёт возврата в foreground (сразу, если процесс не заморожен).
  /// [dispose] до возврата тоже отпускает ожидающих — без `StateError`, который
  /// дал бы `.first` на закрытом контроллере.
  Future<void> untilForeground() {
    if (!_suspended) return Future<void>.value();
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _releaseWaiters() {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  @visibleForTesting
  void onStateChange(AppLifecycleState state) {
    final suspended = isSuspendingLifecycleState(state);
    if (suspended == _suspended) return;
    _suspended = suspended;
    _grace?.cancel();
    _justResumed = !suspended;
    if (suspended) return;
    _grace = Timer(resumeGrace, () => _justResumed = false);
    _releaseWaiters();
    _resumed.add(null);
  }

  void dispose() {
    _listener?.dispose();
    _grace?.cancel();
    _releaseWaiters();
    unawaited(_resumed.close());
  }
}

/// [attempt] с РОВНО одним тихим повтором, если транспортный сбой (таймаут /
/// сеть) объясняется заморозкой процесса ([ForegroundWitness.failureExplainedBySuspension]).
/// Повтор стартует, когда приложение снова открыто — в фоне он замёрз бы так же.
///
/// HTTP-коды и декрипт так не повторяются: это не сон, а ответ сервера/данные
/// ([[RL-media-http-error-gate]] — «ошибка = стоп, без retry-шторма»). Второй
/// сбой уходит вызывающему как есть — он и есть честный терминал.
/// [abandoned] — потребитель ушёл (плеер закрыт): повтор не нужен.
Future<T> retryOnceAfterSuspension<T>(
  Future<T> Function() attempt,
  ForegroundWitness? witness, {
  bool Function()? abandoned,
  void Function(Object error)? onRetry,
}) async {
  try {
    return await attempt();
  } catch (e) {
    final transport = const {'timeout', 'network'}.contains(
      mediaFailureKind(e),
    );
    if (witness == null ||
        !transport ||
        !witness.failureExplainedBySuspension ||
        (abandoned?.call() ?? false)) {
      rethrow;
    }
    await witness.untilForeground();
    if (abandoned?.call() ?? false) rethrow;
    onRetry?.call(e);
    return await attempt();
  }
}

/// Сколько раз один виджет может «не засчитать» сбой, объяснённый сном процесса.
/// Конечный потолок: без него мёртвая сеть, совпавшая с серией
/// пробуждений, крутила бы ретраи вечно.
const int maxSuspensionPasses = 2;

/// true — транспортный сбой ([mediaFailureKind] timeout/network) объясняется
/// заморозкой процесса и бюджет пропусков [passesUsed] не исчерпан: ретрай не
/// должен сгорать. Цикл ретраев `MxcImage` (2+4+8+16+30 с) во сне не живёт:
/// просроченные таймеры выстреливают скопом при пробуждении, сокеты мёртвые,
/// все 5 попыток падают за секунды → `[media-stuck] give-up kind=network`
/// (GlitchTip #2166, iOS 3789: `resumed` в 09:42:04, give-up в 09:42:11, при
/// том что сервер/MMR в окне чисты).
bool holdRetryForSuspension(
  Object error,
  ForegroundWitness? witness,
  int passesUsed,
) {
  if (witness == null || passesUsed >= maxSuspensionPasses) return false;
  if (!witness.failureExplainedBySuspension) return false;
  return const {'timeout', 'network'}.contains(mediaFailureKind(error));
}
