import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:universal_html/html.dart' as html;

import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bandwidth_estimator.dart';
import 'package:liza/utils/e2ee_media_proxy.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/foreground_witness.dart';
import 'package:liza/utils/idle_timeout_stream.dart';
import 'package:liza/utils/mp4_faststart.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/video_prefetch_cache.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/mpv_property.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/video_poster_cache.dart';
import 'package:liza/widgets/blur_hash.dart';
import '../../widgets/mxc_image.dart';
import '../../utils/video_flight_recorder.dart';
import 'carousel_video_controls.dart';
import 'video_first_frame_gate.dart';

/// Обёртка для ошибок воспроизведения видео.
///
/// Не наследует IOException/ClientException, поэтому не попадает под фильтр
/// `_ignoredTypes` в [Monitoring] — гарантирует доставку в GlitchTip.
class VideoPlaybackException implements Exception {
  final String message;
  final Object? cause;

  /// Класс причины провала (`watchdog-no-progress`/`libmpv-fatal`/`io-error`/
  /// `unable-to-play`) и хост пользователя — уходят в `toString` (= title
  /// Sentry-issue), чтобы notifier роутил видео-провал по маркеру `[video-fail]`
  /// и дедупил инциденты по reason+host. eventId СЮДА НЕ кладём: это локатор
  /// контента (пин `RL-mediadiag-no-secret`, вердикт комиссии) — в мониторинг
  /// не уходит.
  final String? reason;
  final String? host;

  VideoPlaybackException(this.message, {this.cause, this.reason, this.host});

  /// ⚠️ Первыми идут МАРКЕР, `reason` и КОРОТКИЙ host — и никакого повтора имени
  /// класса. GlitchTip режет `issue.title` на 100 символов, а для исключения сам
  /// добавляет спереди `VideoPlaybackException: ` (24 символа) — прежняя форма
  /// `VideoPlaybackException(VideoPlaybackException([video-fail] …` съедала 44
  /// символа на дубль имени и обрывалась ПОСРЕДИ host'а (проверено на прод-БД
  /// 2026-09-10: 4 issue ровно на 100). Хвост (`message`/`cause`) обрезается —
  /// это ОК: он остаётся целым в теле события, куда ведёт ссылка «Открыть issue».
  @override
  String toString() {
    final head =
        '[video-fail] reason=${reason ?? 'unknown'} '
        'host=${Monitoring.shortHost(host)}';
    return '$head — $message${cause != null ? ' | cause: $cause' : ''}';
  }
}

/// Полноэкранный просмотрщик видео-сообщений из ленты чата.
///
/// Для **non-E2EE** комнат и не-Web платформ открывает видео по прямой
/// authenticated-media ссылке (`/_matrix/client/v1/media/download/...`) и
/// передаёт `Authorization: Bearer ...` в httpHeaders. Внутри `media_kit`
/// сидит libmpv. Видео начинает играть, как только подтянулся первый чанк,
/// без полной загрузки. Поддерживает MP4/MOV/MKV/WebM/AVI/FLV/HEVC/AV1.
///
/// Seek-режим: после MMR-cutover (2026-08-12) клиентское медиа прод-хоста
/// обслуживает matrix-media-repo с нативным Range из S3 (`get_object(Range=…)`,
/// дальний seek ≈0.05с — `howItWoks/s3.md`). libmpv тянет Range-запросы сам,
/// seek работает нативно, `seekable=0` на MMR-хосте НЕ форсим (см.
/// [buildStreamLavfOpts]). RAM-буфер умеренный: `demuxer-max-bytes=32 MiB`,
/// `cache-secs=30`, `demuxer-readahead-secs=15` — достаточно для плавного
/// воспроизведения, но не жадная буферизация всего файла (на мобильной сети
/// вызывала многосекундные зависания). Хосты без MMR (`liza.cyber-agro.ru`,
/// `nadezhda.liza.ru`) отдают медиа своим Synapse → там `seekable=0` сохранён.
///
/// Для **E2EE** — потоковый локальный AES-CTR proxy. Web и начальный
/// fallback используют полное скачивание с расшифровкой.
///
/// **Стриминг и фоллбэк.**
/// Для non-E2EE non-Web сразу открываем HTTP-URL в libmpv — он сам тянет
/// Range-запросы. Отдельную HEAD-пробу Range не делаем (лишний запрос к
/// media-эндпоинту). Реально-фатальные ошибки libmpv (`Cannot seek in this
/// stream`, `Failed to recognize file format`, 4xx) ловятся через
/// `Player.stream.error` и через `_maybeSwapOnFatalLog` — обе ветки идут
/// в `_handlePlaybackError` → `_swapToLocal` (полное скачивание +
/// проигрывание из файла).
///
/// **Что ИГНОРИРУЕМ.** libmpv пишет в stream.log/stream.error много
/// recoverable info-уровневой шумовой ошибки: `lavf: Failed to create
/// file cache` (media_kit ставит `cache-on-disk=yes` по дефолту, в
/// sandbox не пишется — но играть это не мешает), `Cannot seek backward
/// in linear streams!` (попытка отмотать назад вне cache), `partial
/// file` (chunk-level отчёт), `tls: mbedtls_ssl_read returned -0x0`
/// (TLS-hiccup, reconnect). Эти фильтруются через
/// `_fatalSwapTextPatterns` — иначе плеер рубил живой стрим.
/// Сессионный детектор устойчивого ребуферинга видео: даёт сигнал в мониторинг
/// ОДИН раз за жизнь плеера, когда ≥[threshold] буфер-андерранов уложились в
/// окно [window]. Чистый и `@visibleForTesting` (инъекция `now`, состояние
/// держит сам, эмит — через возвращаемое значение, без зависимости от Sentry/
/// виджета) — по образцу `BadgeDriftAggregator`. Порог/окно совпадают с
/// UI-баннером «Медленное соединение» (≥3 за 30с), но состояние отдельное:
/// баннер — про UX, этот агрегатор — про телеметрию (один сигнал, не поток).
@visibleForTesting
class VideoRebufferAggregator {
  VideoRebufferAggregator({
    this.threshold = 3,
    this.window = const Duration(seconds: 30),
  });

  final int threshold;
  final Duration window;
  final List<DateTime> _events = [];
  bool _reported = false;

  /// Сколько буфер-андерранов в текущем окне (для теста/диагностики).
  @visibleForTesting
  int get pendingCount => _events.length;

  /// Зарегистрировать буфер-андерран в момент [now]. Возвращает `true` РОВНО
  /// ОДИН раз — на первом пересечении порога в скользящем окне (дальше `false`:
  /// сигнал за сессию уже ушёл, чат не спамим). События старше окна выбрасываем,
  /// поэтому «3 растянутых на >30с» порога не дают.
  bool observe(DateTime now) {
    if (_reported) return false;
    _events.add(now);
    _events.removeWhere((t) => now.difference(t) > window);
    if (_events.length >= threshold) {
      _reported = true;
      return true;
    }
    return false;
  }

  /// Сброс при повторной попытке воспроизведения (`_retryPlayback`).
  void reset() {
    _events.clear();
    _reported = false;
  }
}

/// Дедлайн отсутствия ПОЛЕЗНОГО прогресса. Позиция декодера stream-pos
/// намеренно не участвует: она стоит, пока mpv продолжает наполнять кэш.
@visibleForTesting
class StalledReconnectDetector {
  Duration? _lastProgress;
  int? _bytes;
  double? _cache;
  Duration? _position;
  bool _reported = false;
  bool progressed = false;

  bool observe({
    required Duration now,
    required Duration budget,
    required bool active,
    int? receivedBytes,
    double? cacheDuration,
    double? cacheSpeed,
    required Duration position,
  }) {
    if (!active) {
      reset();
      return false;
    }
    final progress =
        (cacheSpeed != null && cacheSpeed > 0) ||
        (receivedBytes != null && _bytes != null && receivedBytes > _bytes!) ||
        (cacheDuration != null && _cache != null && cacheDuration > _cache!) ||
        (_position != null && position > _position!);
    progressed = progress;
    _bytes = receivedBytes;
    _cache = cacheDuration;
    _position = position;
    if (_lastProgress == null || progress) {
      _lastProgress = now;
      _reported = false;
    }
    if (!_reported && now - _lastProgress! >= budget) {
      _reported = true;
      return true;
    }
    return false;
  }

  void reset() {
    progressed = false;
    _lastProgress = null;
    _bytes = null;
    _cache = null;
    _position = null;
    _reported = false;
  }
}

/// Ресурсы строго одной попытки. Native-события не содержат generation:
/// отдельный Player обеспечивает реальную изоляцию после retry/fallback.
class _VideoAttempt {
  _VideoAttempt(this.player);
  final Player player;
  VideoController? controller;
  final List<StreamSubscription<dynamic>> subscriptions = [];
  final StalledReconnectDetector progress = StalledReconnectDetector();
  final Stopwatch clock = Stopwatch()..start();
  bool active = true;
  bool opened = false;
  bool manuallyPaused = false;
  bool requestingPlay = false;
  bool storyEnded = false;
  bool monitorBusy = false;
  bool propertiesPending = false;
  int propertyEpoch = 0;
  bool tuningPending = false;
  String bufferPolicy = 'normal';
  Future<void>? opening;
  Future<void>? playingCommand;
  Future<void>? cleanup;
  http.Client? downloadClient;
  String? proxySessionId;

  /// Держим ссылку: сессию прокси удаляют при retire, а контекст нужен и после.
  VideoFlightRecorder? proxyFlight;
  Timer? monitor;
  Timer? recoveryProbe;
  String? blobUrl;
}

/// Низкокардинальный бакет размера файла для тега/контекста видео-сигнала
/// (сырой size высок по кардинальности → расклеил бы GlitchTip-issue).
@visibleForTesting
String videoSizeBucket(int? bytes) {
  if (bytes == null) return 'unknown';
  final mb = bytes / (1024 * 1024);
  if (mb < 10) return '<10MB';
  if (mb < 50) return '10-50MB';
  if (mb < 150) return '50-150MB';
  return '>150MB';
}

/// Битрейт, который считаем «нужным» видео, когда у события нет size/duration
/// (~8 Мбит/с — верх обычного телефонного 1080p).
const int _fallbackVideoBytesPerSec = 1024 * 1024;

/// Причина устойчивого ребуферинга — по ЗАМЕРУ, а не по допущению. Раньше
/// reason всегда был `slow-network`, и #2146 (2026-10-26) пришёл с ним, хотя
/// Traefik отдал устройству весь 10-МБ файл за 2 с (~40 Мбит/с): разбор ушёл
/// не в ту сторону. [inputBytesPerSec] — mpv `cache-speed` в момент паузы за
/// буфером (скорость поступления байт в кэш плеера; у E2EE это выход
/// локального прокси). Байты идут медленнее битрейта файла → `slow-network`;
/// идут не медленнее, а плеер всё равно стоит → `local-stall` (декод/прокси/
/// главный изолят). Замера нет → `rate-unknown`, а не догадка.
@visibleForTesting
String videoRebufferReason({
  int? inputBytesPerSec,
  int? sizeBytes,
  int? durationMs,
  bool encrypted = false,
}) {
  if (encrypted) return 'rate-unknown';
  if (inputBytesPerSec == null || inputBytesPerSec < 0) return 'rate-unknown';
  final needed = (sizeBytes != null && durationMs != null && durationMs > 0)
      ? sizeBytes * 1000 ~/ durationMs
      : _fallbackVideoBytesPerSec;
  return inputBytesPerSec < needed ? 'slow-network' : 'local-stall';
}

/// Хост для видео-алёрта: ORIGIN медиа приоритетен над хоумсервером читателя.
/// Выделено чистой функцией (страж RL-video-playback-monitoring-signal): раньше
/// в алёрт уходил хоумсервер читателя → федеративное видео с ОДНОГО origin
/// расклеивалось по читателям, дедуп notifier `room|title` терял смысл. `origin`
/// пуст (не-медиа/битый mxc) → фолбэк на homeserver (лучше, чем null).
@visibleForTesting
String? alertHostFor(String? originHost, String? homeserverHost) =>
    originHost ?? homeserverHost;

/// Сколько ждать НОВЫХ БАЙТ при скачивании видео, прежде чем признать загрузку
/// мёртвой. Это межчанковый порог, а не бюджет всей загрузки: 161-МБ файл на
/// слабом канале качается минутами и рубиться не должен. Чтобы чанк не пришёл
/// за минуту, канал должен упасть ниже ~9 кбит/с.
///
/// Значение согласовано с `kAudioPrepareNetworkTimeout` (аудио) и
/// `MxcImage._networkTimeout`. Streaming recovery отдельно получает 120 с
/// активного времени; полный download ограничен только idle между чанками.
const Duration _downloadIdleTimeout = Duration(seconds: 60);

class EventVideoPlayer extends StatefulWidget {
  final Event event;

  /// `false` — страница карусели увела на другое медиа. Триггерит паузу,
  /// чтобы звук не продолжался с невидимого видео (media-v-format.md §8.9).
  final bool isActive;

  /// Story-режим: авто-старт без кнопки play, без seek-контролов карусели,
  /// со звуком и mute-toggle в углу. Используется в просмотрщике сторис.
  final bool storyMode;

  /// Колбэк завершения видео (для авто-перехода к следующему сегменту сторис).
  final VoidCallback? onStoryEnded;

  /// Сообщает фактическую длительность видео, когда libmpv её узнает
  /// (для прогресс-полоски сторис).
  final ValueChanged<Duration>? onDurationKnown;

  /// Как вписывать видео в отведённый бокс. В сторис-режиме — BoxFit.cover
  /// (кадр 9:16 без полей, как фото). По умолчанию contain.
  final BoxFit fit;

  /// Story-режим: играть только СРЕЗ `[startPositionMs..endPositionMs]`. Нужно
  /// для видео-сториса на desktop/web, где физической обрезки нет — окно отрезка
  /// приезжает метаданными (`com.liza.story.media.trim`), и вьюер проигрывает
  /// выбранный автором фрагмент (seek к старту + авто-переход по концу окна).
  /// null — играть с начала до конца файла (mobile: файл уже физически обрезан).
  final int? startPositionMs;
  final int? endPositionMs;

  /// Story-режим: общий на весь сеанс просмотра переключатель «звук выкл»
  /// (владелец — [StoryViewerController]). Дефолт — приглушено. Плеер только
  /// ЧИТАЕТ и применяет громкость; сам mute-состояние НЕ хранит, иначе оно
  /// сбрасывалось бы при пересоздании плеера по `ValueKey` на каждом сегменте
  /// (баг ③ — «звук не распространяется на остальные истории»).
  final ValueNotifier<bool>? mutedNotifier;

  /// Узкие seams: State владеет созданным Player и уничтожает его.
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(BuildContext, Player)? videoSurfaceBuilder;
  @visibleForTesting
  final Future<String?> Function(Player, String)? propertyReader;
  @visibleForTesting
  final Future<void> Function(Player, String, String)? propertyWriter;
  @visibleForTesting
  final Duration Function()? elapsed;
  @visibleForTesting
  final E2eeProxySnapshot? Function(String)? snapshotReader;
  @visibleForTesting
  final http.Client Function()? downloadClientFactory;

  const EventVideoPlayer(
    this.event, {
    this.isActive = true,
    this.storyMode = false,
    this.onStoryEnded,
    this.onDurationKnown,
    this.fit = BoxFit.contain,
    this.startPositionMs,
    this.endPositionMs,
    this.mutedNotifier,
    this.playerFactory,
    this.videoSurfaceBuilder,
    this.propertyReader,
    this.propertyWriter,
    this.elapsed,
    this.snapshotReader,
    this.downloadClientFactory,
    super.key,
  });

  @override
  EventVideoPlayerState createState() => EventVideoPlayerState();
}

class EventVideoPlayerState extends State<EventVideoPlayer> {
  /// libmpv info-prefix-ы, которые пропускаем в Logs().i. Остальные info-
  /// строки (cache, demux-перепрыжки на каждый чанк) уходят в Logs().v
  /// и не засоряют /logs. Список держим узким — только то, что реально
  /// нужно при разборе «не воспроизводится».
  static const _loudMpvPrefixes = {
    'cplayer',
    'demux',
    'ffmpeg',
    'file',
    'stream',
    'vd',
    'vo',
    'hwdec',
  };

  // На debug-сборке info: нужно видеть «почему .mov/HEVC отвалился»
  // (демуксер, hwdec, track-selection). На release — warn: на info libmpv
  // пишет каждую cache-stat и selection строку, локальный liza.log
  // раздувается, а в Sentry (ветка liza-monitoring) это уйдёт как шум.
  late _VideoAttempt _attempt;
  Player get _player => _attempt.player;
  ForegroundWitness? _foreground;
  AppLifecycleListener? _lifecycle;
  bool _backgroundPaused = false;
  bool _wasSuspended = false;
  bool _restartForChangedEvent = false;
  Future<void>? _retrying;

  bool _current(_VideoAttempt a) =>
      mounted && !_disposed && identical(_attempt, a) && a.active;
  bool _foregroundActive(_VideoAttempt a) =>
      _current(a) && widget.isActive && !(_foreground?.suspended ?? false);
  bool _canPlay(_VideoAttempt a) =>
      _foregroundActive(a) && !_pausedByViewer && !a.manuallyPaused;
  Duration _now(_VideoAttempt a) => widget.elapsed?.call() ?? a.clock.elapsed;

  Future<String?> _readProperty(_VideoAttempt a, String name) async {
    if (!_current(a)) return null;
    return (widget.propertyReader ?? getMpvProperty)(a.player, name);
  }

  Future<void> _writeProperty(
    _VideoAttempt a,
    String name,
    String value,
  ) async {
    if (!_current(a)) return;
    await (widget.propertyWriter ?? setMpvProperty)(
      a.player,
      name,
      value,
    ).timeout(const Duration(seconds: 2));
  }

  Future<void> _playIfAllowed(_VideoAttempt a) {
    if (!_canPlay(a) || !a.opened) return Future<void>.value();
    if (a.requestingPlay) return a.playingCommand ?? Future<void>.value();
    a.requestingPlay = true;
    a.playingCommand = () async {
      try {
        await a.player.play();
        // Даже отложенная native-команда не оставляет звук за скрытой страницей.
        if (!_canPlay(a)) await a.player.pause();
      } catch (e, stack) {
        if (_current(a)) unawaited(_handlePlaybackError(e, stack));
      } finally {
        a.requestingPlay = false;
      }
    }();
    return a.playingCommand!;
  }

  Widget _videoSurface(BoxFit fit) {
    final builder = widget.videoSurfaceBuilder;
    if (builder != null) return builder(context, _player);
    return Video(
      key: ObjectKey(_player),
      controller: _attempt.controller ??= VideoController(_player),
      fit: fit,
      controls: NoVideoControls,
    );
  }

  // Story-режим со срезом (desktop-trim): seek к старту выполнен единожды.

  // Story-режим: mute-состояние живёт во внешнем ValueNotifier
  // (StoryViewerController.storyMuted), общем на весь сеанс просмотра —
  // переживает пересоздание плеера по ValueKey. Дефолт (нет notifier'а или
  // его значение) — приглушено (требование ②: у зрителей звук по умолчанию
  // выключен). Плеер только читает и применяет громкость.
  bool get _muted => widget.mutedNotifier?.value ?? true;

  // Реакция на смену общего mute-переключателя из шапки вьюера.
  void _onMutedChanged() {
    final a = _attempt;
    if (_current(a)) unawaited(a.player.setVolume(_muted ? 0 : 100));
  }

  double? _downloadProgress;
  // Троттлинг setState прогресса скачивания: на 161 МБ прилетают тысячи
  // мелких HTTP-чанков, setState на каждый = джанк. Обновляем UI не чаще
  // раза в 250 мс (≈4 fps прогресса — визуально плавно).
  DateTime _lastProgressUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _ready = false;
  bool _showErrorFallback = false;
  bool _awaitingUpload = false;
  // Отправка копии уже провалилась (`EventStatus.error`): «ещё отправляется»
  // было бы неправдой навсегда — файл сам не дойдёт.
  bool _uploadFailed = false;

  // ID сессии E2EE прокси — для cleanup в dispose.

  // Флаг dispose: проверяем перед обращением к _player после async-операций
  // (downloadAndDecryptAttachment длится 20+ сек, пользователь может закрыть
  // плеер — логи подтверждают: "Player has been disposed" после download done).
  bool _disposed = false;

  // Видео не запускается само: пользователь сначала видит постер с кнопкой
  // play. Скачивание/стриминг (а на prod это полное скачивание файла —
  // см. media-v-format.md §8.1) стартует только по тапу. До тапа страница
  // видео в карусели — статичный постер, не перехватывает свайпы PageView.
  bool _started = false;

  // Постер из VideoPosterCache (первый кадр, извлечённый inline-bubble-ом
  // в ленте). Если есть — показываем мгновенно, без серверного thumbnail.
  File? _cachedPoster;

  // Источник переключён на полностью скачанный локальный файл — поток-стриминг
  // больше не используется, дальше всё через filesystem.
  bool _useLocalFile = false;

  // Идёт фоновое скачивание ради swap-а на локальный файл; повторно не
  // запускаем, чтобы не дёргать downloadAndDecryptAttachment параллельно.
  bool _swappingToLocal = false;

  // Только для логов / разработки. Никогда не показываем пользователю —
  // mpv-сообщения вроде "force it with --force-seekable=yes" бесполезны
  // и пугают.
  String? _lastErrorDetails;

  // --- Адаптивный монитор буферизации (Фаза 1 video-streaming-optimization) ---
  // Пауза-за-буфером сейчас: честный индикатор «Буферизация…» поверх видео
  // (пришло на смену баннеру «Скачать полностью?», убранному 2026-08-31).
  bool _pausedForCache = false;

  // Гейт первого кадра (заявка №52): между `open` и первым кадром держим
  // постер + индикатор загрузки, а не чёрный `Video` с «паузой» и 0:00/0:00.
  // Ждём кадр только ПОСЛЕ `await open` — события прошлого открытия до этого
  // игнорируются (см. [_openWatchingFirstFrame]).
  bool _frameShown = false;
  final _flight = VideoFlightRecorder();
  bool _awaitingFirstFrame = false;
  bool _firstFrameDeadlinePassed = false;
  bool _pausedByViewer = false;
  Timer? _firstFrameDeadlineTimer;

  // --- Телеметрия видео-проблем (комната «Liza · Видео») ---
  // Сессионные защёлки: один сигнал на жизнь плеера, чтобы не спамить чат.
  bool _swapReported = false;
  final VideoRebufferAggregator _rebufferAggregator = VideoRebufferAggregator();

  @visibleForTesting
  int get rebufferEpisodes => _rebufferAggregator.pendingCount;
  @visibleForTesting
  bool get rebufferReported => _rebufferAggregator._reported;

  // `Failed to open` (терминальный провал открытия, напр. HTTP 500 от MMR на пустом
  // источнике 556МБ) фатален ТОЛЬКО со 2-го раза: mpv `reconnect_on_network_error`
  // может переоткрыть транзиентную ошибку сам — рубить по первой = рецидив «резали
  // живой стрим» (mediaContent §5).
  int _failedToOpenCount = 0;

  // Сохраняем ScaffoldMessenger через didChangeDependencies, чтобы в dispose()
  // вызвать clearSnackBars() — context в dispose уже нельзя использовать для
  // ScaffoldMessenger.of (зависимости больше не отслеживаются).
  ScaffoldMessengerState? _scaffoldMessenger;

  /// Единственный вход в состояние ошибки: провал ЛЮБОЙ природы
  /// (`unable-to-play`, `stalled-reconnect`, `libmpv-fatal`, `swap-failed`,
  /// `io-error`) показывает РОВНО ОДНУ поверхность — центральный error-overlay.
  ///
  /// `clearSnackBars()` здесь не косметика, а гарантия инварианта КОДОМ: до
  /// 2026-09-04 рядом с оверлеем всплывал ещё и SnackBar «Ой, что-то пошло не
  /// так…», и на экране висели два сообщения с двумя одинаковыми кнопками
  /// «Повторить» (регресс с 1dbabb74). Чистим очередь на входе, чтобы чужая
  /// плашка (например, от соседней страницы карусели) не дожила поверх оверлея.
  void _enterErrorState([String? details]) {
    if (!_current(_attempt)) return;
    _lastErrorDetails = details ?? _lastErrorDetails;
    _retire(_attempt);
    _scaffoldMessenger?.clearSnackBars();
    setState(() {
      _showErrorFallback = true;
      _ready = false;
      _pausedForCache = false;
    });
  }

  /// Инвалидизация синхронна; Future — барьер для следующей попытки.
  Future<void> _retire(_VideoAttempt a) {
    if (a.cleanup != null) return a.cleanup!;
    a.active = false;
    a.monitor?.cancel();
    a.recoveryProbe?.cancel();
    a.downloadClient?.close();
    final sid = a.proxySessionId;
    final proxyCleanup = sid == null
        ? Future<void>.value()
        : E2eeMediaProxy.instance.cancelSession(sid);
    if (identical(a, _attempt)) {
      _firstFrameDeadlineTimer?.cancel();
      _awaitingFirstFrame = false;
    }
    final cancellations = a.subscriptions.map((s) => s.cancel()).toList();
    a.cleanup = () async {
      // stop вызывается сразу, а повтор после late open закрывает его эффект.
      try {
        await a.player.stop();
      } catch (_) {}
      try {
        await a.opening;
      } catch (_) {}
      try {
        await a.playingCommand;
      } catch (_) {}
      try {
        await a.player.stop();
      } catch (_) {}
      await Future.wait(cancellations);
      try {
        await proxyCleanup;
      } catch (_) {}
      try {
        await a.player.dispose();
      } catch (_) {}
      if (a.blobUrl != null) html.Url.revokeObjectUrl(a.blobUrl!);
    }();
    return a.cleanup!;
  }

  _VideoAttempt _createAttempt() {
    final a = _VideoAttempt(
      widget.playerFactory?.call() ??
          Player(
            configuration: PlayerConfiguration(
              logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.warn,
            ),
          ),
    );
    a.subscriptions.addAll([
      a.player.stream.error.listen((e) {
        if (_current(a)) _onPlayerError(e);
      }),
      a.player.stream.width.listen((_) {
        if (_current(a)) _evaluateFirstFrameGate();
      }),
      a.player.stream.position.listen((_) {
        if (_current(a)) _evaluateFirstFrameGate();
      }),
      a.player.stream.playing.listen((playing) {
        if (!_current(a) || !a.opened || a.requestingPlay) return;
        // Native EOF: playing=false приходит ПЕРЕД completed=true event.
        // Это завершение, а не ручная пауза, story обязана перейти дальше.
        if (a.player.state.completed) return;
        if (!playing && _foregroundActive(a)) {
          a.manuallyPaused = true;
          a.progress.reset();
          a.recoveryProbe?.cancel();
          a.recoveryProbe = null;
        } else if (playing && _foregroundActive(a)) {
          a.manuallyPaused = false;
          _pausedByViewer = false;
        }
      }),
      a.player.stream.log.listen((event) {
        if (!_current(a)) return;
        final tag = 'mpv [${event.level}] ${event.prefix}: ${event.text}';
        switch (event.level) {
          case 'fatal' || 'error':
            Logs().w(tag);
            _maybeSwapOnFatalLog(event);
          case 'warn':
            Logs().w(tag);
          case 'info' when _loudMpvPrefixes.contains(event.prefix):
            Logs().i(tag);
          default:
            Logs().v(tag);
        }
      }),
    ]);
    if (widget.storyMode) {
      a.subscriptions.addAll([
        a.player.stream.duration.listen((d) {
          if (!_foregroundActive(a) || d <= Duration.zero) return;
          final start = widget.startPositionMs;
          final end = widget.endPositionMs;
          widget.onDurationKnown?.call(
            start != null && end != null && end > start
                ? Duration(milliseconds: end - start)
                : d,
          );
        }),
        a.player.stream.completed.listen((done) {
          if (done) _endStory(a);
        }),
        a.player.stream.position.listen((pos) {
          if (!_foregroundActive(a)) return;
          final end = widget.endPositionMs;
          if (end != null && pos.inMilliseconds >= end) _endStory(a);
        }),
      ]);
    }
    return a;
  }

  void _endStory(_VideoAttempt a) {
    if (!_canPlay(a) || a.storyEnded || !a.opened) return;
    a.storyEnded = true;
    widget.onStoryEnded?.call();
  }

  @override
  void initState() {
    super.initState();
    _foreground = ForegroundWitness.attach();
    _wasSuspended = _foreground!.suspended;
    _attempt = _createAttempt();
    _lifecycle = AppLifecycleListener(
      onStateChange: (_) {
        final suspended = _foreground!.suspended;
        if (suspended == _wasSuspended) return;
        _wasSuspended = suspended;
        _flight.event(
          suspended ? FlightEvent.backgrounded : FlightEvent.foregrounded,
        );
        final a = _attempt;
        a.progress.reset();
        a.recoveryProbe?.cancel();
        a.recoveryProbe = null;
        if (!_current(a)) return;
        if (suspended) {
          // Намерение Play сохраняется и пока open/download ещё не завершился.
          _backgroundPaused =
              _started &&
              !_pausedByViewer &&
              !a.manuallyPaused &&
              !a.player.state.completed;
          unawaited(a.player.pause());
        } else if (_backgroundPaused) {
          _backgroundPaused = false;
          unawaited(_playIfAllowed(a));
        }
      },
    );
    VideoPosterCache.instance.getCached(widget.event).then((file) {
      if (file != null && mounted) setState(() => _cachedPoster = file);
    });
    if (widget.storyMode) {
      widget.mutedNotifier?.addListener(_onMutedChanged);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_started) _onPlayPressed();
      });
    }
  }

  /// Один реальный batch. Истёкший Future не отменяется платформой, поэтому
  /// до его завершения новые reads не запускаются; idle всё равно ограничен.
  Future<List<String?>?> _properties(_VideoAttempt a) async {
    if (a.propertiesPending) return null;
    a.propertiesPending = true;
    final epoch = ++a.propertyEpoch;
    final batch = Future.wait([
      _readProperty(a, 'demuxer-cache-duration'),
      _readProperty(a, 'paused-for-cache'),
      _readProperty(a, 'cache-speed'),
    ]);
    // Обработчик освобождает только собственный batch; timeout не даёт ему
    // права применить устаревший результат.
    unawaited(
      batch.then(
        (_) {
          if (a.propertyEpoch == epoch) a.propertiesPending = false;
        },
        onError: (Object _, StackTrace _) {
          if (a.propertyEpoch == epoch) a.propertiesPending = false;
        },
      ),
    );
    try {
      return await batch.timeout(const Duration(seconds: 2));
    } catch (_) {
      return null;
    }
  }

  /// Существующая адаптация буфера, отдельно от обязательного liveness poll.
  /// Гистерезис исключает повтор настройки на каждом тике; timeout ожидания
  /// НЕ освобождает single-flight, пока реальная native-команда не завершится.
  void _adaptBuffer(_VideoAttempt a, double? cache) {
    if (!_current(a) || _useLocalFile || cache == null || a.tuningPending) {
      return;
    }
    final policy = cache >= 0 && cache < 2
        ? 'slow'
        : cache > 15
        ? 'normal'
        : null;
    if (policy == null || policy == a.bufferPolicy) return;
    a.bufferPolicy = policy;
    a.tuningPending = true;
    final writer = widget.propertyWriter ?? setMpvProperty;
    final batch = () async {
      await writer(a.player, 'cache-secs', policy == 'slow' ? '120' : '30');
      if (!_current(a)) return;
      await writer(a.player, 'cache-pause-wait', policy == 'slow' ? '5' : '2');
    }();
    unawaited(
      batch.then<void>(
        (_) {
          a.tuningPending = false;
        },
        onError: (Object _, StackTrace _) {
          a.tuningPending = false;
        },
      ),
    );
    unawaited(() async {
      try {
        await batch.timeout(const Duration(seconds: 2));
      } catch (_) {
        if (_current(a)) Logs().w('Video buffer tuning unavailable');
      }
    }());
  }

  void _startAdaptiveMonitor(_VideoAttempt a) {
    a.monitor?.cancel();
    // Baseline до первого poll: бюджет не удлиняется на время open.
    a.progress.observe(
      now: _now(a),
      budget: const Duration(seconds: 120),
      active: _canPlay(a),
      position: a.player.state.position,
    );
    a.monitor = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_current(a) || a.monitorBusy) return;
      unawaited(_monitor(a));
    });
  }

  Future<void> _monitor(_VideoAttempt a) async {
    a.monitorBusy = true;
    try {
      final active = _canPlay(a) && !a.player.state.completed;
      if (!active) {
        a.progress.reset();
        a.recoveryProbe?.cancel();
        a.recoveryProbe = null;
        return;
      }
      final properties = await _properties(a);
      if (!_current(a)) return;
      if (!_canPlay(a)) {
        a.progress.reset();
        return;
      }
      final cache = double.tryParse(properties?[0] ?? '');
      final paused = properties?[1] == 'yes';
      final speed = double.tryParse(properties?[2] ?? '');
      if (properties != null) {
        _flight.sample(
          cacheSec: cache ?? 0,
          pausedForCache: paused,
          speedKBs: ((speed ?? 0) / 1024).round(),
          proxyKb: ((_proxyReceived(a)) ~/ 1024),
        );
        if (paused && !_pausedForCache) _flight.event(FlightEvent.stalled);
        final entered = paused && !_pausedForCache;
        if (paused != _pausedForCache) setState(() => _pausedForCache = paused);
        if (entered &&
            _frameShown &&
            _rebufferAggregator.observe(DateTime.now())) {
          _reportVideoRebuffer(inputBytesPerSec: speed?.round());
        }
      }
      final sid = a.proxySessionId;
      final snapshot = sid == null
          ? null
          : (widget.snapshotReader ?? E2eeMediaProxy.instance.snapshot)(sid);
      final recovering =
          snapshot != null &&
          snapshot.phase != E2eeProxyPhase.completed &&
          snapshot.phase != E2eeProxyPhase.idle;
      final budget = recovering
          ? const Duration(seconds: 120)
          : const Duration(seconds: 60);
      final position = a.player.state.position;
      final exhausted = a.progress.observe(
        now: _now(a),
        budget: budget,
        active: true,
        receivedBytes: snapshot?.receivedBytes,
        cacheDuration: cache,
        cacheSpeed: speed,
        position: position,
      );
      // Failed — завершённый transport, но уже набранный кэш ещё может играть.
      final failed = snapshot?.phase == E2eeProxyPhase.failed;
      if ((failed && !a.progress.progressed) || exhausted) {
        if (recovering) {
          await _handlePlaybackError(
            'Video upstream unavailable; ${_videoFailureDiag('stalled-reconnect')}',
            StackTrace.current,
            reason: 'stalled-reconnect',
          );
        } else if (a.recoveryProbe == null) {
          // Одна bounded проверка (без второго зависшего native batch).
          final baseline = position;
          a.recoveryProbe = Timer(const Duration(seconds: 5), () {
            if (!_canPlay(a) || a.player.state.position > baseline) return;
            unawaited(
              _handlePlaybackError(
                'Video playback unresponsive (rate-unknown)',
                StackTrace.current,
                reason: 'playback-unresponsive',
              ),
            );
          });
        }
      } else if (a.progress.progressed) {
        a.recoveryProbe?.cancel();
        a.recoveryProbe = null;
      }
      _adaptBuffer(a, cache);
    } finally {
      a.monitorBusy = false;
    }
  }

  /// Структурная строка диагностики провала видео для GlitchTip. Принимает
  /// ТОЛЬКО безопасные примитивы — key/iv/accessToken/URL-с-токеном сюда
  /// структурно не попадают (пин `RL-mediadiag-no-secret`; образец
  /// `buildMediaDiagLine`). Ошибка на границе (случайно передать ключ) —
  /// невозможна по сигнатуре, а не «мы стараемся не логировать».
  @visibleForTesting
  static String buildVideoFailureDiag({
    required String reason,
    required bool e2ee,
    required bool onWeb,
    required bool local,
    String? mimetype,
    int? size,
    String? host,
  }) =>
      'video-fail reason=$reason e2ee=$e2ee web=$onWeb local=$local '
      'mime=$mimetype size=$size host=$host';

  /// Инстанс-обёртка: извлекает безопасные поля из события и зовёт
  /// [buildVideoFailureDiag]. Ключ/iv из `content["file"]` не трогаем.
  String _videoFailureDiag(String reason) {
    final event = widget.event;
    final info = event.content.tryGetMap<String, dynamic>('info');
    return buildVideoFailureDiag(
      reason: reason,
      e2ee: event.isAttachmentEncrypted,
      onWeb: kIsWeb,
      local: _useLocalFile,
      mimetype: info?.tryGet<String>('mimetype'),
      size: info?.tryGet<int>('size'),
      host: event.room.client.homeserver?.host,
    );
  }

  /// Низкокардинальный контекст видео для телеметрии (e2ee/mime/size-бакет).
  /// Только безопасные примитивы — секретов/eventId нет (пин `RL-mediadiag-no-secret`).
  VideoFlightRecorder? _lastProxyFlight;

  int _proxyReceived(_VideoAttempt a) {
    final sid = a.proxySessionId;
    if (sid == null) return 0;
    return (widget.snapshotReader ?? E2eeMediaProxy.instance.snapshot)(
          sid,
        )?.receivedBytes ??
        0;
  }

  /// Контекст `video_flight` для события GlitchTip: журналы сессии + upstream
  /// прокси. Читается только через API (в чат не едет).
  Map<String, Object> _flightContext() {
    return _flight.toContext(
      upstreamFrom: _lastProxyFlight,
      extra: {
        'from_open_s': _attempt.clock.elapsed.inSeconds,
        'frame_shown': _frameShown,
        'attempt_swapped': _useLocalFile,
      },
    );
  }

  Map<String, String> _videoContext() {
    final info = widget.event.content.tryGetMap<String, dynamic>('info');
    final mime = info?.tryGet<String>('mimetype');
    return {
      'e2ee': '${widget.event.isAttachmentEncrypted}',
      if (mime != null) 'mime': mime,
      'size': videoSizeBucket(info?.tryGet<int>('size')),
      // Низкокардинальные PII-safe координаты для разбора: платформа читателя
      // (~6 значений) и MMR-origin ли медиа (2). Различают классы инцидентов,
      // дедуп notifier по title выдерживает. Без build/eventId/mxc (кардинальность/PII).
      'platform': _platformName,
      'mmr': '${isMmrBackedHost(_mediaOriginHost)}',
    };
  }

  /// Платформа читателя для контекста алёрта. Web-safe (`Platform.isX` из
  /// dart:io падает на web) — через `defaultTargetPlatform`/`kIsWeb`.
  String get _platformName {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.macOS:
        return 'macos';
      case TargetPlatform.windows:
        return 'windows';
      case TargetPlatform.linux:
        return 'linux';
      case TargetPlatform.fuchsia:
        return 'fuchsia';
    }
  }

  /// Хост хоумсервера пользователя (для дедупа инцидента в notifier). Публичный,
  /// не PII.
  String? get _videoHost => widget.event.room.client.homeserver?.host;

  /// Origin (server_name) медиа = хост mxc (`mxc://<origin>/<id>` → `<origin>`).
  /// Именно origin, а НЕ хоумсервер читателя, определяет транспорт: MMR отдаёт
  /// нативный Range только для СВОЕГО local_media (S3); чужое (федеративное)
  /// медиа лежит в MMR как remote_media на диске и режет ОТКРЫТЫЙ Range до
  /// `defaultRangeChunkSizeBytes` (10 МБ) → ffmpeg зацикливается на reconnect.
  /// Поэтому seekable-гейт считаем по origin (см. [_start], спека
  /// 2026-09-01-federated-video-mmr-open-range-and-web-upload-zero-byte).
  String? get _mediaOriginHost => widget.event.attachmentMxcUrl?.host;

  /// Хост для алёрта = ORIGIN медиа (mxc-host) с фолбэком на хоумсервер читателя.
  /// Origin приоритетен: иначе федеративное видео с ОДНОГО origin (напр.
  /// `user.liza.ru`) расклеивается в notifier по хоумсерверам РАЗНЫХ читателей —
  /// дедуп `room|title` теряет смысл, а инцидент origin-а не виден как один. mxc
  /// пуст (не-медиа/битый) → homeserver читателя (лучше, чем ничего).
  String? get _alertHost => alertHostFor(_mediaOriginHost, _videoHost);

  /// Свап на полное скачивание = стриминг не пошёл. Сигналим ТОЛЬКО когда медиа
  /// с MMR-origin (там нативный Range должен был сработать → свап аномалия). Для
  /// не-MMR origin (`cyber-agro`/`nadezhda`/федеративное `user.liza.ru`) свап —
  /// штатное полное скачивание by design (`seekable=0`), это не инцидент. Гейт по
  /// origin медиа, не по хоумсерверу читателя. Один сигнал на сессию.
  ///
  /// [trigger] — ЧТО сорвало стрим (`stalled-reconnect`/`watchdog-no-progress`/
  /// фатальный reason libmpv), в title вместо прежнего константного
  /// `swap-to-local`: префикс `[video-swap]` и так говорит «свап». Без триггера
  /// #2063 (2026-09-24) не разбирался: при живой, но медленной отдаче (Traefik:
  /// 206 по ~5 МБ за ~10 с) нельзя было понять, какой детектор решил свапать.
  void _reportVideoSwap(String trigger) {
    if (_swapReported) return;
    if (!isMmrBackedHost(_mediaOriginHost)) return;
    _swapReported = true;
    Monitoring.reportVideoIssue(
      prefix: Monitoring.videoSwapPrefix,
      reason: trigger,
      host: _alertHost,
      context: _videoContext(),
      videoFlight: _flightContext(),
    );
  }

  /// Устойчивый ребуферинг («медленно, но играет»). Сигнал low, один раз за
  /// сессию (агрегатор). Контекст (size-бакет/mime) — чтобы отличить тяжёлый
  /// файл (аргумент за транскодер) от слабой сети пользователя; reason — по
  /// замеру входной скорости, см. [videoRebufferReason].
  void _reportVideoRebuffer({int? inputBytesPerSec}) {
    final info = widget.event.content.tryGetMap<String, dynamic>('info');
    Monitoring.reportVideoIssue(
      prefix: Monitoring.videoRebufferPrefix,
      reason: videoRebufferReason(
        inputBytesPerSec: inputBytesPerSec,
        sizeBytes: info?.tryGet<int>('size'),
        durationMs: info?.tryGet<int>('duration'),
        encrypted: widget.event.isAttachmentEncrypted,
      ),
      host: _alertHost,
      context: _videoContext(),
      videoFlight: _flightContext(),
    );
  }

  /// Запуск воспроизведения по тапу на кнопку play. До этого момента
  /// показывается только постер (см. media-v-format.md §8.2).
  void _onPlayPressed() {
    if (_started) return;
    setState(() => _started = true);
    unawaited(_start(_attempt));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  @override
  void didUpdateWidget(EventVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mutedNotifier != widget.mutedNotifier) {
      oldWidget.mutedNotifier?.removeListener(_onMutedChanged);
      widget.mutedNotifier?.addListener(_onMutedChanged);
      _onMutedChanged();
    }
    if (oldWidget.event.eventId != widget.event.eventId ||
        oldWidget.event.attachmentMxcUrl != widget.event.attachmentMxcUrl) {
      _retire(_attempt);
      if (_retrying != null) {
        _restartForChangedEvent = true;
      } else {
        unawaited(_restart(autoStart: widget.storyMode || _started));
      }
      return;
    }
    final a = _attempt;
    if (oldWidget.isActive != widget.isActive) {
      a.progress.reset();
      a.recoveryProbe?.cancel();
      a.recoveryProbe = null;
    }
    if (oldWidget.isActive && !widget.isActive && _started) {
      _pausedByViewer = true;
      if (_current(a)) unawaited(a.player.pause());
      _evaluateFirstFrameGate();
    }
    if (!oldWidget.isActive &&
        widget.isActive &&
        _started &&
        widget.storyMode) {
      _pausedByViewer = false;
      if (_current(a)) unawaited(_playIfAllowed(a));
    }
  }

  /// Общие libmpv-настройки декода — нужны и для HTTP-стриминга, и для
  /// проигрывания локального файла после swap-а или E2EE-download.
  ///
  ///   * `hwdec=auto-safe` — HW-декод H.264/HEVC через VideoToolbox (macOS),
  ///     MediaCodec (Android), D3D11 (Win), VA-API (Linux). `auto-safe`
  ///     включает только проверенные комбинации codec/profile/output,
  ///     SW-fallback на edge-codecs. Без этого `.mov` с HEVC от iPhone
  ///     может играть рывками или фейлить декодер.
  ///   * `hr-seek=yes` — точный seek по PTS, а не по ближайшему keyframe.
  ///
  /// `vd-lavc-fast=yes` НЕ ставим — он допускает non-spec оптимизации
  /// (упрощённое dequantization, пропуск проверок битстрима) и ломал
  /// макосёвые screen-recording-mov с низким fps: libmpv детектил h264-
  /// track, но потом «No video or audio streams selected» из-за
  /// невалидной для fast-режима последовательности фреймов.
  Future<void> _tuneMpvCommon(_VideoAttempt a) async {
    await _writeProperty(a, 'hwdec', 'auto-safe');
    await _writeProperty(a, 'hr-seek', 'yes');
  }

  /// libmpv-настройки специально для HTTP-стриминга.
  ///
  ///   * `cache-on-disk=no` — media_kit по дефолту ставит `yes`, но в
  ///     sandbox-сборках (iOS + macOS App Sandbox) libmpv не может создать
  ///     temp-файл в своей cache-dir и пишет `mpv [error] lavf: Failed to
  ///     create file cache.` Сам поток после этого играет нормально из
  ///     RAM-cache, но строка прилетает как error в `Player.stream.log` и
  ///     раньше ложно триггерила swap-to-local;
  ///   * `cache=yes` + умеренные `cache-secs` / `demuxer-max-bytes` — храним
  ///     прочитанные байты в RAM, seek **внутри буфера** работает без сети.
  ///     Раньше было 600s/512MiB — libmpv пытался буферизировать всё видео
  ///     целиком, что на мобильной сети вызывало многосекундные зависания
  ///     до начала воспроизведения;
  ///   * `cache-pause-initial=yes` + `cache-pause-wait=2` — libmpv при
  ///     открытии потока ставит паузу, пока не наберёт 2 с буфера. Без
  ///     этого на сетях медленнее битрейта видео получается stutter loop
  ///     (play 0.5 с → пауза → play 0.5 с). Те же 2 с применяются при
  ///     rebuffering (buffer underrun во время воспроизведения);
  ///   * `demuxer-readahead-secs=15` — ограничивает опережающее чтение:
  ///     libmpv не тянет дальше 15 с вперёд от текущей позиции, даже если
  ///     `demuxer-max-bytes` позволяет. Без этого свойства libmpv жадно
  ///     читает пока не упрётся в лимит байтов или cache-secs;
  ///   * `demuxer-max-back-bytes` — лимит на «назад», иначе при отмотке
  ///     всё равно полезет в сеть;
  ///   * `network-timeout=30` — дефолт media_kit/libmpv 5 сек, мало для
  ///     LTE с TLS-handshake на первый чанк; на 5s libmpv ронял стрим до
  ///     прихода первого пакета.
  /// Хоумсерверы, чьё клиентское медиа обслуживает matrix-media-repo (MMR) —
  /// нативный Range из S3 (`get_object(Range=…)`, дальний seek ≈0.05с, замер
  /// `howItWoks/s3.md` после cutover 2026-08-12). На них `seekable=0` НЕ нужен
  /// и вреден: он запрещает Range-seek к `moov` → для файлов с moov-в-хвосте
  /// (iPhone-оригинал «Файлом»; faststart-ремукс — только desktop-отправка) mpv
  /// читает файл целиком до хвоста перед стартом = «сначала полностью грузится».
  /// Инстансы без MMR-роутера (`liza.cyber-agro.ru`, `nadezhda.liza.ru`, и др.
  /// standalone-Synapse) отдают клиентское медиа своим Synapse → там `seekable=0`
  /// сохраняем (fail-safe). Инвертировать на «всё кроме этих = MMR» НЕЛЬЗЯ: на
  /// сегодня MMR-роутер только у прода, а standalone-инстансов ~10 (комиссия
  /// 2026-08-31) → инверсия сломала бы им seekable=0.
  ///
  /// ⚠️ Хардкод против молчаливой деградации новых MMR-инстансов: список
  /// РАСШИРЯЕМ сборкой через `--dart-define=MMR_HOSTS=host1,host2` — новый
  /// MMR-хост добавляется БЕЗ правки кода (только пересборка). Долгосрочно —
  /// рантайм-проба Accept-Ranges/capability (follow-up).
  static const String _mmrHostsFromEnv = String.fromEnvironment(
    'MMR_HOSTS',
    defaultValue: '',
  );
  static final Set<String> _mmrBackedHomeservers = {
    'synapse.liza.laba.prodamus.tech',
    ..._mmrHostsFromEnv
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty),
  };

  /// Тест-override: `--dart-define=E2E_FORCE_MMR=1` заставляет [isMmrBackedHost]
  /// возвращать true для ЛЮБОГО хоста. Нужен device-flow'у: локальный стек
  /// (`localhost:8008`) не в [_mmrBackedHomeservers] → без override гонялась бы
  /// НЕ-MMR-ветка (`seekable=0`), а не та, что у пользователя на проде → ложно-
  /// зелёный (класс рецидивов, CLAUDE.local.md «device-flow обязан…»). В проде
  /// дефолт false — поведение не меняется.
  static const bool _forceMmrForTest = bool.fromEnvironment(
    'E2E_FORCE_MMR',
    defaultValue: false,
  );

  /// Обслуживает ли [host] медиа через MMR с нативным Range из S3. Передаём
  /// ORIGIN медиа (mxc-host), а НЕ хоумсервер читателя: MMR отдаёт полный Range
  /// только для СВОЕГО local_media (S3); чужой origin приезжает как remote_media
  /// (диск, обрез открытого Range 10 МБ). Неизвестный/новый/федеративный origin →
  /// `false` (консервативно: seekable=0 → один последовательный GET, петли нет).
  @visibleForTesting
  static bool isMmrBackedHost(String? host) =>
      _forceMmrForTest ||
      (host != null && _mmrBackedHomeservers.contains(host));

  /// Собирает значение mpv-свойства `stream-lavf-o` для HTTP-стриминга.
  ///
  /// `seekable=0` (ffmpeg читает ОДНИМ последовательным GET без Range)
  /// добавляется ТОЛЬКО когда медиа с НЕ-MMR-origin: голый Synapse
  /// `s3_storage_provider` (дальний Range виснет — рестрим с нуля) ЛИБО
  /// федеративное медиа (в прод-MMR лежит как remote_media на диске и режет
  /// ОТКРЫТЫЙ Range `bytes=N-` до `defaultRangeChunkSizeBytes` = 10 МБ → ffmpeg
  /// `reconnect_streamed` видит «Stream ends prematurely» и зацикливается, видео
  /// не стартует — инцидент 2026-09-01). Условие: не-E2EE видео с origin без MMR.
  /// Для MMR-origin (свой local_media, нативный Range из S3) и E2EE-пути
  /// (локальный AES-CTR прокси, данные не из S3) `seekable` НЕ форсим → libmpv
  /// Range-прыгает к `moov` и стримит частично, с догрузкой в процессе.
  /// `reconnect*` — переживать обрыв на длинном чтении (LTE) — сохраняются
  /// всегда. Минус `seekable=0` (там где он остаётся): timeline-seek дальше
  /// RAM-кэша недоступен.
  @visibleForTesting
  static String buildStreamLavfOpts({
    required bool encrypted,
    required bool mediaOriginOnMmr,
  }) {
    final forceSequential = !encrypted && !mediaOriginOnMmr;
    return [
      if (forceSequential) 'seekable=0',
      // Где seekable=0 НЕ ставим (MMR-Range или E2EE-прокси) — явно помечаем поток
      // seekable, чтобы ffmpeg при reconnect после mid-stream reset переоткрывал
      // с Range от места разрыва, а не начинал с 0 (M-2 flutter-quality: без этого
      // resume-точность reconnect_streamed зависит от версии libavformat).
      if (!forceSequential) 'force-seekable=yes',
      'reconnect=1',
      'reconnect_streamed=1',
      'reconnect_on_network_error=1',
      'reconnect_delay_max=5',
    ].join(',');
  }

  /// [encrypted] — E2EE-путь (через локальный AES-CTR прокси); [mediaOriginOnMmr]
  /// — лежит ли ORIGIN медиа (не хоумсервер читателя) на MMR как local_media.
  /// Вместе задают, форсить ли `seekable=0` (см. [buildStreamLavfOpts]).
  Future<void> _tuneMpvForStreaming(
    _VideoAttempt a, {
    required bool encrypted,
    required bool mediaOriginOnMmr,
  }) async {
    await _writeProperty(a, 'cache-on-disk', 'no');
    await _writeProperty(a, 'cache', 'yes');
    await _writeProperty(a, 'cache-secs', '30');
    await _writeProperty(a, 'cache-pause-initial', 'yes');
    await _writeProperty(a, 'cache-pause-wait', '2');
    await _writeProperty(a, 'demuxer-max-bytes', '33554432'); // 32 MiB
    await _writeProperty(a, 'demuxer-max-back-bytes', '16777216'); // 16 MiB
    await _writeProperty(a, 'demuxer-readahead-secs', '15');
    await _writeProperty(a, 'network-timeout', '30');
    final lavfOpts = buildStreamLavfOpts(
      encrypted: encrypted,
      mediaOriginOnMmr: mediaOriginOnMmr,
    );
    await _writeProperty(a, 'stream-lavf-o', lavfOpts);
    // seek в пределах RAM-кэша (внутри cache-secs) стабильнее принудительно.
    await _writeProperty(a, 'demuxer-seekable-cache', 'yes');
  }

  /// Выбрать оптимальный URL для видео по bandwidth и доступным вариантам.
  ///
  /// Если в комнате есть state event `com.liza.media_variants` с
  /// state_key=eventId — выбираем вариант (720p/480p) или оригинал.
  /// Если вариантов нет — оригинальный URL.
  Uri? _resolveVideoVariant(Event event, Uri originalUrl) {
    try {
      final room = event.room;
      final stateEvent = room.getState(
        'com.liza.media_variants',
        event.eventId,
      );
      if (stateEvent == null) return originalUrl;

      final content = stateEvent.content;
      final variants = content.tryGetList('variants');
      if (variants == null || variants.isEmpty) return originalUrl;

      final bandwidth = BandwidthEstimator.instance.estimatedBps;

      // Если bandwidth достаточен для оригинала — оригинал
      final info = event.content.tryGetMap<String, dynamic>('info');
      final fileSize = info?.tryGet<int>('size');
      final durationMs = info?.tryGet<int>('duration');
      if (fileSize != null && durationMs != null && durationMs > 0) {
        final originalBitrate = fileSize * 8 / (durationMs / 1000);
        if (bandwidth > originalBitrate * 1.5) return originalUrl;
      }

      // Выбрать лучший вариант, который уложится в bandwidth
      for (final v in variants) {
        if (v is! Map) continue;
        final targetBitrate = v['bitrate_bps'];
        if (targetBitrate is int && bandwidth > targetBitrate * 1.5) {
          final mxc = v['mxc'];
          if (mxc is String && mxc.startsWith('mxc://')) {
            // Конвертировать mxc -> authenticated media URL
            final mxcUri = Uri.parse(mxc);
            final server = mxcUri.host;
            final mediaId = mxcUri.pathSegments.last;
            final scheme = originalUrl.scheme;
            final host = originalUrl.host;
            final port = originalUrl.port;
            final quality = v['quality'] ?? '?';
            Logs().i(
              'Video variant selected: $quality '
              '(bw=${(bandwidth / 1e6).toStringAsFixed(1)} Mbps, '
              'target=${(targetBitrate / 1e6).toStringAsFixed(1)} Mbps)',
            );
            return Uri(
              scheme: scheme,
              host: host,
              port: port == 443 || port == 0 ? null : port,
              path: '/_matrix/client/v1/media/download/$server/$mediaId',
            );
          }
        }
      }

      // Самый лёгкий вариант (последний в списке)
      final last = variants.last;
      if (last is Map) {
        final mxc = last['mxc'];
        if (mxc is String && mxc.startsWith('mxc://')) {
          final mxcUri = Uri.parse(mxc);
          final server = mxcUri.host;
          final mediaId = mxcUri.pathSegments.last;
          final quality = last['quality'] ?? '?';
          Logs().i('Video variant fallback to lightest: $quality');
          return Uri(
            scheme: originalUrl.scheme,
            host: originalUrl.host,
            port: originalUrl.port == 443 || originalUrl.port == 0
                ? null
                : originalUrl.port,
            path: '/_matrix/client/v1/media/download/$server/$mediaId',
          );
        }
      }
    } catch (e) {
      Logs().w('Video variant resolution failed: $e');
    }
    return originalUrl;
  }

  Future<void> _start(_VideoAttempt a) async {
    if (!_current(a)) return;
    final event = widget.event;
    if (event.isPendingMediaWithoutBytes) {
      setState(() {
        _awaitingUpload = true;
        _uploadFailed = event.status.isError;
      });
      return;
    }
    try {
      await _tuneMpvCommon(a);
      if (!_current(a)) return;
      if (widget.storyMode) {
        await a.player.setVolume(_muted ? 0 : 100);
        if (!_current(a)) return;
      }
      if (!kIsWeb) {
        final cached = await VideoPrefetchCache.instance.getCached(event);
        if (!_current(a)) return;
        if (cached != null) {
          final exists = await cached.exists();
          if (!_current(a)) return;
          if (exists) {
            _useLocalFile = true;
            await _writeProperty(a, 'cache', 'no');
            if (!_current(a)) return;
            await _openWatchingFirstFrame(a, Media(cached.path));
            if (_current(a)) setState(() => _ready = true);
            return;
          }
        }
      }
      if (!event.isAttachmentEncrypted && !kIsWeb) {
        final original = await event.getAttachmentUri();
        if (!_current(a)) return;
        if (original != null) {
          final url = _resolveVideoVariant(event, original);
          final token = event.room.client.accessToken;
          await _tuneMpvForStreaming(
            a,
            encrypted: false,
            mediaOriginOnMmr: isMmrBackedHost(_mediaOriginHost),
          );
          if (!_current(a)) return;
          await _openWatchingFirstFrame(
            a,
            Media(
              url.toString(),
              httpHeaders: {
                if (token != null) 'Authorization': 'Bearer $token',
              },
            ),
          );
          if (_current(a)) setState(() => _ready = true);
          return;
        }
      }
      if (event.isAttachmentEncrypted && !kIsWeb) {
        try {
          final url = await E2eeMediaProxy.instance.registerSession(
            event: event,
          );
          final sid = Uri.parse(url).pathSegments.first;
          if (!_current(a)) {
            await E2eeMediaProxy.instance.cancelSession(sid);
            return;
          }
          a.proxySessionId = sid;
          a.proxyFlight = E2eeMediaProxy.instance.flight(sid);
          _lastProxyFlight = a.proxyFlight;
          await _tuneMpvForStreaming(
            a,
            encrypted: true,
            mediaOriginOnMmr: isMmrBackedHost(_mediaOriginHost),
          );
          if (!_current(a)) return;
          await _openWatchingFirstFrame(a, Media(url));
          if (_current(a)) setState(() => _ready = true);
          return;
        } catch (e) {
          if (!_current(a)) return;
          Logs().w('E2EE proxy initial open failed; local fallback');
          // Начальный fallback сохраняется, но получает собственный engine:
          // поздний stream.error старого open не завершит новый локальный файл.
          await _replaceWithLocal(a);
          return;
        }
      }
      await _downloadAndPlay(a);
    } on IOException catch (e, stack) {
      if (!_current(a)) return;
      _reportVideoFailure('io-error', cause: e, stack: stack);
      _enterErrorState(e.toString());
    } catch (e, stack) {
      if (!_current(a)) return;
      await _handlePlaybackError(e, stack);
    }
  }

  Future<void> _downloadAndPlay(_VideoAttempt a) async {
    await _downloadAndOpenLocal(a);
    if (_current(a)) setState(() => _ready = true);
  }

  void _maybeUpdateDownloadProgress(_VideoAttempt a, int received, int? total) {
    if (!_current(a)) return;
    final now = DateTime.now();
    if (now.difference(_lastProgressUpdate).inMilliseconds < 250) return;
    _lastProgressUpdate = now;
    final p = total != null && total > 0 ? received / total : null;
    setState(() => _downloadProgress = p != null && p < 1 ? p : null);
  }

  Future<void> _downloadAndOpenLocal(
    _VideoAttempt a, {
    Duration? seekTo,
  }) async {
    if (!_current(a)) return;
    final event = widget.event;
    final fileSize = event.content
        .tryGetMap<String, dynamic>('info')
        ?.tryGet<int>('size');
    final stopwatch = Stopwatch()..start();
    final client = widget.downloadClientFactory?.call() ?? http.Client();
    a.downloadClient = client;
    final token = event.room.client.accessToken;
    final witness = PlatformInfos.isMobile ? ForegroundWitness.attach() : null;
    try {
      Future<MatrixFile> download() {
        if (!_current(a)) throw StateError('Video attempt retired');
        return event.downloadAndDecryptAttachmentHealed(
          downloadCallback: (url) async {
            if (!_current(a)) throw StateError('Video attempt retired');
            final request = http.Request('GET', url);
            if (token != null) {
              request.headers['authorization'] = 'Bearer $token';
            }
            final response = await client
                .send(request)
                .timeout(_downloadIdleTimeout);
            if (!_current(a)) throw StateError('Video attempt retired');
            return readBytesWithIdleTimeout(
              response.stream,
              idleTimeout: _downloadIdleTimeout,
              witness: witness,
              onChunk: (received) =>
                  _maybeUpdateDownloadProgress(a, received, fileSize),
            );
          },
        );
      }

      final videoFile = await retryOnceAfterSuspension(
        download,
        witness,
        abandoned: () => !_current(a),
        onRetry: (_) {
          if (_current(a)) setState(() => _downloadProgress = 0);
        },
      );
      if (!_current(a)) return;
      stopwatch.stop();
      BandwidthEstimator.instance.addTimedSample(
        videoFile.bytes.length,
        stopwatch.elapsed,
      );
      _useLocalFile = true;
      await _writeProperty(a, 'cache', 'no');
      if (!_current(a)) return;
      final relocated = Mp4Faststart.process(videoFile.bytes);
      final bytes = relocated ?? videoFile.bytes;
      if (kIsWeb) {
        final url = html.Url.createObjectUrlFromBlob(html.Blob([bytes]));
        a.blobUrl = url;
        await _openWatchingFirstFrame(a, Media(url), seekTo: seekTo);
      } else {
        final directory = await getTemporaryDirectory();
        if (!_current(a)) return;
        final segment =
            event.attachmentOrThumbnailMxcUrl()?.pathSegments.last ??
            'video_${event.eventId.hashCode.toUnsigned(32).toRadixString(16)}';
        final extension = _safeExtensionFor(videoFile.name);
        final name = relocated != null
            ? '${segment}_fs$extension'
            : '$segment$extension';
        final file = File('${directory.path}/$name');
        final exists = await file.exists();
        if (!_current(a)) return;
        if (!exists) {
          await file.writeAsBytes(bytes);
          if (!_current(a)) return;
        }
        await _openWatchingFirstFrame(a, Media(file.path), seekTo: seekTo);
      }
      if (_current(a)) setState(() => _downloadProgress = null);
    } finally {
      witness?.dispose();
      client.close();
      if (identical(a.downloadClient, client)) a.downloadClient = null;
    }
  }

  /// Единственная точка `open` просмотрщика: перед открытием гейт первого
  /// кадра взводится заново (свап, «Повторить», каждая ветка `_start`), после —
  /// начинаем ждать кадр и запускаем дедлайн.
  Future<void> _openWatchingFirstFrame(
    _VideoAttempt a,
    Media media, {
    Duration? seekTo,
  }) async {
    if (!_current(a)) return;
    _firstFrameDeadlineTimer?.cancel();
    _awaitingFirstFrame = false;
    _firstFrameDeadlinePassed = false;
    setState(() => _frameShown = false);
    _startAdaptiveMonitor(a);
    // autoplay запрещён даже у незавершённого open: поздний успех не даёт звук.
    a.opening = a.player.open(media, play: false);
    await a.opening;
    if (!_current(a)) return;
    a.opened = true;
    final trim = widget.storyMode ? widget.startPositionMs : null;
    final target =
        seekTo ?? (trim != null ? Duration(milliseconds: trim) : null);
    if (target != null && target > Duration.zero) {
      await _seekWhenReady(a, target);
      if (!_current(a)) return;
    }
    _awaitingFirstFrame = true;
    _firstFrameDeadlineTimer = Timer(firstFrameGateDeadline, () {
      if (!_current(a) || !_awaitingFirstFrame) return;
      _firstFrameDeadlinePassed = true;
      _evaluateFirstFrameGate();
    });
    _evaluateFirstFrameGate();
    await _playIfAllowed(a);
  }

  void _evaluateFirstFrameGate() {
    if (!_awaitingFirstFrame || !_current(_attempt)) return;
    final state = _player.state;
    if (!firstFrameGateOpen(
      width: state.width,
      position: state.position,
      pausedByViewer: _pausedByViewer,
      deadlinePassed: _firstFrameDeadlinePassed,
    )) {
      return;
    }
    _awaitingFirstFrame = false;
    _firstFrameDeadlineTimer?.cancel();
    _flight.event(FlightEvent.firstFrame);
    setState(() => _frameShown = true);
  }

  Future<void> _seekWhenReady(_VideoAttempt a, Duration target) async {
    final deadline = _now(a) + const Duration(seconds: 10);
    while (_current(a) && _now(a) < deadline) {
      if (a.player.state.duration > Duration.zero) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (_current(a)) await a.player.seek(target);
  }

  Future<_VideoAttempt?> _freshAfter(_VideoAttempt previous) async {
    await _retire(previous);
    if (!mounted || _disposed || !identical(_attempt, previous)) return null;
    final next = _createAttempt();
    setState(() {
      _attempt = next;
      _ready = false;
      _frameShown = false;
    });
    // NativeVideoController должен попасть в дерево ДО mpv.open (macOS).
    await WidgetsBinding.instance.endOfFrame;
    return _current(next) ? next : null;
  }

  Future<void> _replaceWithLocal(
    _VideoAttempt previous, {
    Duration? seekTo,
  }) async {
    final next = await _freshAfter(previous);
    if (next == null) return;
    try {
      await _tuneMpvCommon(next);
      if (!_current(next)) return;
      if (widget.storyMode) {
        await next.player.setVolume(_muted ? 0 : 100);
        if (!_current(next)) return;
      }
      await _downloadAndOpenLocal(next, seekTo: seekTo);
      if (_current(next)) setState(() => _ready = true);
    } catch (e, stack) {
      if (!_current(next)) return;
      _reportVideoFailure('initial-fallback-failed', cause: e, stack: stack);
      _enterErrorState(e.toString());
    }
  }

  /// Существующий non-E2EE swap сохраняется, старый engine завершается.
  Future<void> _swapToLocal({required String trigger, Duration? seekTo}) async {
    if (!_current(_attempt) || _swappingToLocal || _useLocalFile) return;
    _reportVideoSwap(trigger);
    setState(() {
      _swappingToLocal = true;
      _downloadProgress = 0;
    });
    // identity нового engine сохраняем для guards catch/finally.
    final previous = _attempt;
    _VideoAttempt? local;
    try {
      local = await _freshAfter(previous);
      if (local == null) return;
      await _tuneMpvCommon(local);
      if (!_current(local)) return;
      if (widget.storyMode) {
        await local.player.setVolume(_muted ? 0 : 100);
        if (!_current(local)) return;
      }
      await _downloadAndOpenLocal(local, seekTo: seekTo);
      if (_current(local)) setState(() => _ready = true);
    } catch (e, stack) {
      if (local == null || !_current(local)) return;
      _reportVideoFailure('swap-failed', cause: e, stack: stack);
      _enterErrorState(e.toString());
    } finally {
      if (local != null && _current(local)) {
        setState(() {
          _swappingToLocal = false;
          _pausedForCache = false;
        });
      }
    }
  }

  /// `Player.stream.error` — это **все** error-level логи libmpv после
  /// маппинга в media_kit, среди них recoverable: `Cannot seek backward
  /// in linear streams!` (попытка mpv отмотать в non-seekable стриме —
  /// stream остаётся живым), `error reading packet: Invalid data...`
  /// (chunk-corruption, libmpv пропускает кадр и читает дальше) и т.п.
  /// Если свапать на любое сообщение из этого потока — рубим работающий
  /// плеер.
  ///
  /// Реально-фатальные строки: mpv не может открыть стрим / не понял
  /// контейнер / получил 4xx от сервера. Список держим в синхроне
  /// с [_fatalSwapTextPatterns] — тут просто whitelist по тексту.
  void _onPlayerError(String message) {
    if (!_current(_attempt)) return;
    Logs().e('media_kit player error: $message');
    _lastErrorDetails = message;
    // `Failed to open …` — терминальный провал открытия (напр. HTTP 500 от MMR на
    // пустом источнике 556МБ, инцидент 2026-09-01). Фатально ТОЛЬКО со 2-го раза:
    // mpv `reconnect_on_network_error` мог бы переоткрыть транзиент сам; рубить по
    // первой = рецидив «резали живой стрим». В `_fatalSwapTextPatterns` не кладём
    // (там безусловный whitelist) — отдельный порог здесь.
    if (message.contains('Failed to open')) {
      _failedToOpenCount++;
      if (_failedToOpenCount < 2) {
        if (Monitoring.isActive) {
          Sentry.addBreadcrumb(
            Breadcrumb(
              message: 'mpv transient open error (1st): $message',
              category: 'media_kit',
              level: SentryLevel.warning,
            ),
          );
        }
        return;
      }
      _handlePlaybackError(message, StackTrace.current, reason: 'open-failed');
      return;
    }
    if (!_fatalSwapTextPatterns.any((re) => re.hasMatch(message))) {
      // Не-фатальные ошибки не свапают, но добавляем breadcrumb в Sentry —
      // при последующем capture они приедут в контексте события.
      if (Monitoring.isActive) {
        Sentry.addBreadcrumb(
          Breadcrumb(
            message: 'mpv recoverable error: $message',
            category: 'media_kit',
            level: SentryLevel.warning,
          ),
        );
      }
      return;
    }
    _handlePlaybackError(message, StackTrace.current);
  }

  /// Возвращает безопасное расширение (`.mov`, `.mp4`, ...) для подстановки
  /// в локальный путь. Если в имени файла нет точки или расширение слишком
  /// длинное / не-ASCII — возвращаем пустую строку (libmpv определит по
  /// magic bytes), но НЕ копируем в путь сам не-ASCII текст.
  static String _safeExtensionFor(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    final ext = fileName.substring(dot);
    if (ext.length > 8) return '';
    // только латинские буквы/цифры после точки
    final ok = RegExp(r'^\.[A-Za-z0-9]+$').hasMatch(ext);
    return ok ? ext.toLowerCase() : '';
  }

  /// Fail-safe: media_kit `stream.error` мапит только cplayer/ffmpeg/vd/ad/
  /// stream × level=error. `lavf`/`demux_lavf` сюда **не** попадают, поэтому
  /// нужен бэкап через `stream.log` — иначе при реальном fatal из libavformat
  /// (бит-стрим невалиден, файл-формат не распознан) пользователь сидит
  /// на вечном BlurHash, потому что swap не стартует.
  ///
  /// Раньше тут был whitelist префиксов (`lavf`, `ffmpeg`, `demux`...),
  /// который рубил **живой** стрим из-за нефатальных info-логов:
  ///   * `lavf: Failed to create file cache.` — media_kit по дефолту
  ///     включает `cache-on-disk=yes` без `cache-dir`. В sandbox-сборках
  ///     mpv не может создать temp-файл, пишет error, но дальше играет
  ///     из RAM-cache как ни в чём не бывало (см. `mpv/demux/cache.c` —
  ///     fallback на NULL cache, без abort);
  ///   * `ffmpeg: Cannot seek backward in linear streams!` — recoverable
  ///     при попытке отмотать назад без Range;
  ///   * `ffmpeg/demuxer: partial file`, `lavf: error reading packet:
  ///     Invalid data` — recoverable chunk-уровневые отчёты;
  ///   * `ffmpeg: tls: mbedtls_ssl_read returned -0x0` — TLS hiccup,
  ///     libmpv reconnect'ит сам.
  ///
  /// Сейчас матчим по **тексту**: только то, после чего mpv действительно
  /// не оживёт (`Cannot seek in this stream`, `Failed to recognize`, и т.п.).
  /// Guard в [_swapToLocal] всё равно защищает от повторов.
  static final List<RegExp> _fatalSwapTextPatterns = [
    RegExp(r'Cannot seek in this stream'),
    RegExp(r'Failed to recognize file format'),
    RegExp(r'Could not open codec'),
    RegExp(r'No video or audio streams selected'),
    RegExp(r'aborting demuxing of'),
    RegExp(r'Server returned 4\d\d'),
    RegExp(r'HTTP error 4\d\d'),
    // 5xx тоже терминален: HTTP 500 отдаёт локальный E2EE-прокси, когда
    // upstream оборвался и resume исчерпан (carrier-RST) — без этого паттерна
    // libmpv висел с чёрным экраном без свапа/сигнала (тихий провал, комиссия
    // 2026-08-31). Свапать некуда на E2EE (уже прокси) → error-overlay+сигнал.
    RegExp(r'Server returned 5\d\d'),
    RegExp(r'HTTP error 5\d\d'),
  ];

  /// Классифицирует фатальный текст libmpv в reason для мониторинга. HTTP-код
  /// вытягиваем в reason (`http-5xx`/`http-4xx`), чтобы notifier видел СЕРВЕРНЫЙ
  /// класс отдельно от декодерных провалов: HTTP 5xx = сервер (в т.ч. фантом
  /// `media_length=0` → EOF; после серверного 404-фикса — «media недоступно»),
  /// 4xx = не найдено/нет доступа (инцидент 2026-09-01). eventId/секретов нет.
  static String _fatalReasonFor(String text) {
    if (RegExp(r'(HTTP error|Server returned) 5\d\d').hasMatch(text)) {
      return 'http-5xx';
    }
    if (RegExp(r'(HTTP error|Server returned) 4\d\d').hasMatch(text)) {
      return 'http-4xx';
    }
    return 'libmpv-fatal';
  }

  void _maybeSwapOnFatalLog(PlayerLog event) {
    if (!_current(_attempt)) return;
    final text = event.text;
    if (!_fatalSwapTextPatterns.any((re) => re.hasMatch(text))) return;
    final fatalReason = _fatalReasonFor(text);
    // E2EE/Web: swap-to-local бессмысленен (уже играем из файла), но
    // ошибку НЕ глотаем — показываем error fallback + отправляем в
    // мониторинг. Раньше тут был `return`, из-за которого пользователь
    // видел чёрный экран навсегда без какого-либо сообщения (Дыра 1).
    final msg = 'libmpv ${event.prefix}: $text';
    if (widget.event.isAttachmentEncrypted || kIsWeb) {
      Logs().e('Fatal libmpv error on E2EE/Web video: $msg');
      Monitoring.capture(
        VideoPlaybackException(
          '$msg; ${_videoFailureDiag(fatalReason)}',
          reason: fatalReason,
          host: _alertHost,
        ),
        StackTrace.current,
      );
      if (!mounted) return;
      _enterErrorState(msg);
      return;
    }
    Logs().i(
      'Triggering swap-to-local from log-stream fatal: '
      '[${event.level}] ${event.prefix}: $text',
    );
    _handlePlaybackError(msg, StackTrace.current, reason: fatalReason);
  }

  /// Терминальный провал видео → сигнал `[video-fail]` в мониторинг.
  /// VideoPlaybackException обходит фильтр `_ignoredTypes` (IOException/
  /// ClientException туда не попадут). eventId в сигнал НЕ уходит (см. класс).
  void _reportVideoFailure(String reason, {Object? cause, StackTrace? stack}) {
    Monitoring.capture(
      VideoPlaybackException(
        'Unable to play video',
        cause: cause,
        reason: reason,
        host: _alertHost,
      ),
      stack ?? StackTrace.current,
      videoFlight: _flightContext(),
    );
  }

  Future<void> _handlePlaybackError(
    Object e,
    StackTrace s, {
    String reason = 'unable-to-play',
  }) async {
    if (!_current(_attempt)) return;
    // Старые native events изолированы retired Player; fatal нового локального
    // engine нельзя глушить даже во время его open/play.
    // Уровень warn, а не error: `Logs().e` с объектом-ошибкой уходит мостом
    // `captureSdkError` в GlitchTip отдельным error-issue (`String: libmpv
    // cplayer: …`, #2044) — дублем `[video-swap]`/`[video-fail]`, которые шлют
    // сами ветки ниже, и без медиа-маркера, т.е. в ОБЩУЮ комнату алёртов как
    // «падение». Текст libmpv в терминальном случае едет в `cause` сигнала.
    Logs().w('Unable to play video: $e');
    _lastErrorDetails ??= e.toString();

    if (!mounted) return;

    final event = widget.event;
    // Уже на локальном файле → повторный свап невозможен (иначе цикл) → терминал.
    final canSwap =
        !event.isAttachmentEncrypted &&
        !kIsWeb &&
        !_useLocalFile &&
        !_swappingToLocal;

    if (canSwap) {
      // Стриминг сорвался, но восстановимо: свап на полное скачивание сам шлёт
      // `[video-swap]` (не терминальный провал — видео обычно проигрывается
      // после докачки, это «медленно», а не «сломано»). Терминальный
      // `[video-fail]` — ТОЛЬКО если и свап упал.
      final pos = _ready ? _player.state.position : null;
      Logs().i(
        'Video playback error, swapping to local file '
        '(ready=$_ready, pos=$pos)',
      );
      // Свап сам терминален при провале (`catch` внутри `_swapToLocal` шлёт
      // `swap-failed` и ставит error-overlay), поэтому дублирующего catch тут
      // больше нет: две версии одной логики расходятся — так и родился
      // исходный дефект LABA-2557.
      await _swapToLocal(trigger: reason, seekTo: pos);
      return;
    } else {
      // E2EE/Web: свапать некуда — это терминальный провал.
      _reportVideoFailure(reason, cause: e, stack: s);
    }

    _enterErrorState();
  }

  @override
  void dispose() {
    _disposed = true;
    widget.mutedNotifier?.removeListener(_onMutedChanged);
    _lifecycle?.dispose();
    _foreground?.dispose();
    _scaffoldMessenger?.clearSnackBars();
    unawaited(_retire(_attempt));
    super.dispose();
  }

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  /// Постер видео до запуска: первый кадр из [VideoPosterCache] (если
  /// inline-bubble уже извлёк) → серверный thumbnail → BlurHash.
  Widget _buildPoster(double width, double height, String blurHash) {
    final cached = _cachedPoster;
    final Widget child;
    if (cached != null) {
      child = Image.file(
        cached,
        width: width,
        height: height,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => BlurHash(
          blurhash: blurHash,
          width: width,
          height: height,
          fit: BoxFit.cover,
        ),
      );
    } else if (widget.event.hasThumbnail) {
      child = MxcImage(
        event: widget.event,
        isThumbnail: true,
        width: width,
        height: height,
        fit: BoxFit.cover,
        placeholder: (context) => BlurHash(
          blurhash: blurHash,
          width: width,
          height: height,
          fit: BoxFit.cover,
        ),
      );
    } else {
      child = BlurHash(blurhash: blurHash, width: width, height: height);
    }
    return Center(
      child: Hero(tag: widget.event.eventId, child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final blurHash =
        (widget.event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final infoMap = widget.event.content.tryGetMap<String, Object?>('info');
    final videoWidth = infoMap?.tryGet<int>('w') ?? 400;
    final videoHeight = infoMap?.tryGet<int>('h') ?? 300;
    final height = MediaQuery.sizeOf(context).height - 52;
    final width = videoHeight == 0
        ? MediaQuery.sizeOf(context).width
        : videoWidth * (height / videoHeight);

    if (_awaitingUpload) {
      return _buildAwaitingUploadOverlay(width, height, blurHash);
    }
    if (_showErrorFallback) {
      return _buildErrorOverlay(width, height, blurHash);
    }

    if (widget.storyMode) {
      // Story-ветка: авто-play без контролов карусели, кнопки play и
      // download-overlay. Только Video + постер до готовности.
      // Video растягивается на весь бокс кадра (Positioned.fromRect +
      // ClipRect задают кадр 9:16 в просмотрщике), widget.fit = cover —
      // заполнение без полей (alignment center внутри media_kit).
      // Кнопка mute (грамофон) живёт НЕ здесь, а в структурной шапке
      // story_viewer_view (рядом с крестиком) — так она выравнивается
      // layout-движком, а не «на глаз» из чужого поддерева (баг ①).
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _videoSurface(widget.fit)),
          if (!_ready) _buildPoster(width, height, blurHash),
        ],
      );
    }

    final showVideo = _started && _ready && !_swappingToLocal && _frameShown;
    // Video-виджет ВСЕГДА в дереве (даже до _ready). Без этого media_kit
    // на macOS не получает рабочий Flutter compositor tick → mpv VO не
    // успевает инициализироваться к моменту selection track → libmpv
    // выдаёт «No video or audio streams selected» на валидном файле.
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: SizedBox(
            width: width,
            height: height,
            child: _videoSurface(BoxFit.contain),
          ),
        ),
        if (showVideo) CarouselVideoControls(_player),
        // Честный индикатор буферизации поверх играющего видео: пауза-за-буфером
        // ≠ зависание. Пришёл на смену баннеру «Скачать полностью?» (2026-08-31):
        // на слабом канале показываем, что идёт добор буфера, а НЕ предлагаем
        // бесполезное скачивание.
        if (showVideo && _pausedForCache)
          const Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black45,
                shape: BoxShape.circle,
              ),
              child: Padding(
                padding: EdgeInsets.all(16),
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator.adaptive(),
                ),
              ),
            ),
          ),
        if (!showVideo) ...[
          _buildPoster(width, height, blurHash),
          if (!_started)
            Center(
              child: Material(
                color: Colors.black54,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _onPlayPressed,
                  child: const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Icon(
                      Icons.play_arrow_rounded,
                      size: 56,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            )
          else
            _buildDownloadOverlay(),
        ],
      ],
    );
  }

  /// Overlay при загрузке/буферизации видео: ЧЕСТНЫЙ прогресс + пояснение
  /// «не сворачивайте». Кнопки скачивания/сохранения тут НЕТ (2026-08-31,
  /// требование руководителя): overlay всплывает во время затыка воспроизведения,
  /// и download-кнопка рядом с проблемой — ровно то «вылазит кнопкой, а не
  /// качает», что осуждено. Намеренное «Сохранить файл» живёт в long-press меню
  /// сообщения (`message_context_menu.dart`, тот же content-protection гейт).
  ///
  /// Текст и прогресс — поверх ТЁМНОЙ ПОДЛОЖКИ (scrim): overlay рисуется над
  /// ярким постером (первый кадр), и без scrim белый текст на светлом кадре
  /// нечитаем (жалоба «текст совсем не читается»).
  Widget _buildDownloadOverlay() {
    final l10n = L10n.of(context);
    final info = widget.event.content.tryGetMap<String, dynamic>('info');
    final fileSize = info?.tryGet<int>('size');
    final sizeMb = fileSize != null
        ? (fileSize / (1024 * 1024)).toStringAsFixed(1)
        : null;

    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: CircularProgressIndicator.adaptive(
                value: _downloadProgress,
              ),
            ),
            if (_downloadProgress != null) ...[
              const SizedBox(height: 8),
              Text(
                '${(_downloadProgress! * 100).round()}%'
                '${sizeMb != null ? ' · ${l10n.videoDownloadSizeMb(sizeMb)}' : ''}',
                style: const TextStyle(color: Colors.white, fontSize: 13),
              ),
            ],
            if (widget.event.isAttachmentEncrypted) ...[
              const SizedBox(height: 12),
              Text(
                l10n.videoDownloadingEncrypted,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Видео ещё отправляется ([isPendingMediaWithoutBytes]): постер + пояснение;
  /// отправка уже провалилась — честное «не удалось отправить».
  /// Без «Повторить» — `widget.event` здесь снимок локальной копии, повтор на нём
  /// дал бы тот же результат; после заливки пузырь в ленте сменится на
  /// отправленное событие, и его откроют заново.
  Widget _buildAwaitingUploadOverlay(
    double width,
    double height,
    String blurHash,
  ) {
    return Stack(
      key: const Key('video-awaiting-upload-overlay'),
      fit: StackFit.expand,
      children: [
        _buildPoster(width, height, blurHash),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _uploadFailed
                      ? Icons.cloud_off_outlined
                      : Icons.cloud_upload_outlined,
                  color: Colors.white70,
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(
                  _uploadFailed
                      ? L10n.of(context).videoSendFailed
                      : L10n.of(context).videoStillUploading,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Error overlay: постер + кнопка «Повторить» (без «Скачать» — 2026-08-31).
  Widget _buildErrorOverlay(double width, double height, String blurHash) {
    final l10n = L10n.of(context);
    return Stack(
      key: const Key('video-error-overlay'),
      fit: StackFit.expand,
      children: [
        _buildPoster(width, height, blurHash),
        Center(
          // Тёмная подложка (scrim) обязательна: оверлей лежит поверх постера
          // (BoxFit.cover), и белый текст на светлом кадре нечитаем — та же
          // жалоба «текст совсем не читается», из-за которой scrim появился у
          // _buildDownloadOverlay. Пока снизу висел Material-SnackBar с
          // контрастным фоном, нечитаемость маскировалась; став ЕДИНСТВЕННОЙ
          // поверхностью (2026-09-04), оверлей несёт контраст сам.
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.white70,
                  size: 48,
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.videoPlaybackFailed,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 20),
                // При ошибке воспроизведения — ТОЛЬКО «Повторить» (in-place),
                // никакого «Скачать»: скачивание на слабом канале бесполезно (тот
                // же оборванный путь) и провоцирует не-воспроизведение (требование
                // руководителя 2026-08-31). Намеренное «Сохранить» живёт отдельно —
                // на успешно играющем видео, не на экране ошибки.
                ElevatedButton.icon(
                  onPressed: _retryPlayback,
                  icon: const Icon(Icons.refresh),
                  label: Text(l10n.retry),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Повторная попытка воспроизведения: один cleanup и один новый engine.
  void _retryPlayback() {
    unawaited(_restart(autoStart: true));
  }

  Future<void> _restart({required bool autoStart}) {
    if (_retrying != null) return _retrying!;
    final completion = Completer<void>();
    _retrying = completion.future;
    () async {
      try {
        final next = await _freshAfter(_attempt);
        if (next == null) return;
        setState(() {
          _showErrorFallback = false;
          _started = autoStart;
          _useLocalFile = false;
          _swappingToLocal = false;
          _downloadProgress = null;
          _lastErrorDetails = null;
          _awaitingUpload = false;
          _pausedForCache = false;
          _pausedByViewer = !widget.isActive;
        });
        _swapReported = false;
        _rebufferAggregator.reset();
        _failedToOpenCount = 0;
        // После error-overlay поверхность нового engine появляется только тут.
        await WidgetsBinding.instance.endOfFrame;
        if (autoStart && _current(next)) await _start(next);
      } finally {
        _retrying = null;
        completion.complete();
        if (_restartForChangedEvent && mounted && !_disposed) {
          _restartForChangedEvent = false;
          unawaited(_restart(autoStart: widget.storyMode || _started));
        }
      }
    }();
    return completion.future;
  }
}
