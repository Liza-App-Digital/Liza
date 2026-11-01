import 'dart:convert';

/// Закрытый список причин завершения upstream-попытки: строки исключений в
/// контекст не попадают (в тексте HttpException бывают URL).
enum UpstreamEnd {
  complete,
  httpError,
  socket,
  timeout,
  shortBody,
  progressTimeout,
  cancelled,
  other,
}

/// Закрытый список событий жизненного цикла плеера.
enum FlightEvent {
  opened,
  firstFrame,
  paused,
  resumed,
  backgrounded,
  foregrounded,
  stalled,
  swapToLocal,
  failed,
}

/// «Чёрный ящик» одной видеосессии: кольцевые журналы фиксированного размера,
/// которые прикладываются к `[video-*]`-событию GlitchTip как контекст
/// `video_flight`. Только числа и значения закрытых enum — без URL, ключей,
/// идентификаторов событий и текстов исключений (`RL-mediadiag-no-secret`).
class VideoFlightRecorder {
  static const maxUpstream = 32;
  static const maxSamples = 120;
  static const maxEvents = 20;
  static const maxContextBytes = 8 * 1024;

  final Stopwatch _clock;
  final _upstream = <Map<String, Object>>[];
  final _samples = <List<int>>[];
  final _events = <List<Object>>[];
  var _dropped = 0;

  VideoFlightRecorder({Stopwatch? clock})
    : _clock = clock ?? (Stopwatch()..start());

  int get elapsedMs => _clock.elapsedMilliseconds;

  /// Одна upstream-попытка прокси. Range-старт округляется до 8 МБ-бакета.
  void recordUpstream({
    required int rangeStart,
    required int? status,
    required int? ttfbMs,
    required int bytes,
    required int durationMs,
    required UpstreamEnd end,
  }) {
    _push(_upstream, {
      't': elapsedMs,
      'r': rangeStart ~/ (8 * 1024 * 1024) * 8,
      if (status != null) 's': status,
      if (ttfbMs != null) 'ttfb': ttfbMs,
      'kb': bytes ~/ 1024,
      'ms': durationMs,
      'end': end.name,
    }, maxUpstream);
  }

  /// Сэмпл монитора: [cacheSec] — глубина буфера демуксера, [speedKBs] —
  /// скорость кэша, [proxyKb] — принято прокси.
  void sample({
    required double cacheSec,
    required bool pausedForCache,
    required int speedKBs,
    required int proxyKb,
  }) {
    _push(_samples, [
      elapsedMs ~/ 1000,
      cacheSec.round(),
      pausedForCache ? 1 : 0,
      speedKBs,
      proxyKb,
    ], maxSamples);
  }

  void event(FlightEvent e) =>
      _push(_events, [elapsedMs ~/ 1000, e.name], maxEvents);

  void _push<T>(List<T> list, T item, int cap) {
    if (list.length >= cap) {
      list.removeAt(0);
      _dropped++;
    }
    list.add(item);
  }

  /// Компактный контекст ≤ [maxContextBytes]. При превышении сначала режутся
  /// самые старые сэмплы, потом upstream; флаг `truncated` это фиксирует.
  /// [upstreamFrom] — рекордер прокси сессии: его upstream-журнал берётся вместо
  /// собственного (`t` в нём — от старта прокси-сессии).
  Map<String, Object> toContext({
    Map<String, Object> extra = const {},
    VideoFlightRecorder? upstreamFrom,
  }) {
    var samples = List<List<int>>.of(_samples);
    var upstream = List<Map<String, Object>>.of(
      (upstreamFrom ?? this)._upstream,
    );
    var truncated = _dropped > 0;
    Map<String, Object> build() => {
      ...extra,
      'elapsed_s': elapsedMs ~/ 1000,
      'fields': 'samples=[t_s,cache_s,paused_for_cache,speed_kbs,proxy_kb]',
      'upstream': upstream,
      'samples': samples,
      'events': _events,
      'truncated': truncated,
    };
    var ctx = build();
    while (utf8.encode(jsonEncode(ctx)).length > maxContextBytes &&
        (samples.isNotEmpty || upstream.length > 4)) {
      truncated = true;
      if (samples.isNotEmpty) {
        samples = samples.sublist((samples.length / 4).ceil());
      } else {
        upstream = upstream.sublist(1);
      }
      ctx = build();
    }
    return ctx;
  }
}
