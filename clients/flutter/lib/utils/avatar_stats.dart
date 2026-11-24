import 'package:liza/utils/reader_profile_resolver.dart';

/// Счётчики исходов догрузки профилей читателей за жизнь процесса — сырьё
/// золотого стандарта GS-A («буква там, где фото должно быть», спека
/// `docs/superpowers/specs/2026-11-23-reader-avatars-and-avatar-monitoring-design.md`).
///
/// Знаменатель считаем на устройстве: GlitchTip считает события, а не доли,
/// поэтому отчёт уходит одним событием с готовыми числами (`Monitoring`).
/// Без MXID и текстов ошибок — только счётчики закрытого перечисления.
/// Счётчики монтирований читательских аватарок (знаменатель GS-A). Считаем
/// МОНТИРОВАНИЯ State, а не уникальные аватарки: при скролле State
/// пересоздаётся. Доля имеет смысл только внутри одного репортёра.
enum AvatarEvent {
  /// Читательская аватарка смонтирована.
  mounted,

  /// Миниатюра известного фото не загрузилась → показана буква.
  letterKnownPhoto,

  /// Сверка после сбоя миниатюры нашла другой avatar_url.
  thumbRecheckChanged,
}

class AvatarStats {
  static final AvatarStats instance = AvatarStats();

  /// Сколько сбоев сервера (`error`) в сессии при их преобладании над
  /// успехами считается «всплеском» → алёрт `[media-avatar-miss]`.
  static const int burstThreshold = 5;

  final Map<ReaderProfileOutcome, int> _counts = {};
  final Map<AvatarEvent, int> _events = {};

  /// Назначается `Monitoring` при активном мониторинге; вызывается один раз на
  /// пересечение порога. Аргумент — закрытая метка причины.
  void Function(String reason)? onBurst;
  var _burstFired = false;

  void record(ReaderProfileOutcome outcome) {
    _counts.update(outcome, (n) => n + 1, ifAbsent: () => 1);
    if (_burstFired || outcome != ReaderProfileOutcome.error) return;
    final errors = _counts[ReaderProfileOutcome.error] ?? 0;
    final ok = _counts[ReaderProfileOutcome.resolved] ?? 0;
    if (errors >= burstThreshold && errors > ok) {
      _burstFired = true;
      onBurst?.call('profile-error');
    }
  }

  void recordEvent(AvatarEvent event) =>
      _events.update(event, (n) => n + 1, ifAbsent: () => 1);

  int eventCount(AvatarEvent event) => _events[event] ?? 0;

  int count(ReaderProfileOutcome outcome) => _counts[outcome] ?? 0;

  bool get isEmpty => _counts.isEmpty && _events.isEmpty;

  /// Снимок для суточного отчёта; счётчики обнуляются, чтобы следующий отчёт
  /// не удваивал уже отправленное.
  Map<String, int> takeSnapshot() {
    final snapshot = {
      for (final e in _counts.entries) e.key.name: e.value,
      for (final e in _events.entries) 'ev_${e.key.name}': e.value,
    };
    _counts.clear();
    _events.clear();
    return snapshot;
  }
}
