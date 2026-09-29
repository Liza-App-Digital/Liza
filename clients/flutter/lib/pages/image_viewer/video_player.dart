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
import 'carousel_video_controls.dart';

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
/// Для **E2EE** и Web — сразу качаем + расшифровываем весь файл; стриминг
/// E2EE требует локального HTTP-прокси с AES-CTR (план D2-D5).
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

/// Чистый детектор мёртвого reconnect по МОНОТОННОЙ `stream-pos` (скачанные байты).
/// Терминал (сигнал `true`) РОВНО ОДИН раз, когда `stream-pos` НЕ вырос за
/// [thresholdTicks] тиков ПРИ `paused-for-cache=yes` (мёртвый цикл reconnect —
/// обрыв отдачи / пустой источник). Живой рост stream-pos (даже рывковая докачка
/// 10МБ→reset→+15МБ) сбрасывает счётчик → НЕ терминалим (формула
/// `RL-e2ee-video-proxy-resume`: «терминал только при 0 прогресса; счётчик сброс
/// на любом росте»). `streamPos<0` = метрика недоступна (не стрим/локальный файл)
/// → трактуем как «нет данных», не терминалим. Чистый (без mpv/виджета) —
/// мультикейс-тестируемый.
@visibleForTesting
class StalledReconnectDetector {
  StalledReconnectDetector({this.thresholdTicks = 8});

  final int thresholdTicks;
  int? _lastPos;
  int _ticks = 0;
  bool _reported = false;

  @visibleForTesting
  int get pendingTicks => _ticks;

  bool observe({required int streamPos, required bool pausedForCache}) {
    if (!pausedForCache) {
      _ticks = 0; // играет / не в паузе-за-буфером → не стрелл
      if (streamPos >= 0) _lastPos = streamPos;
      return false;
    }
    final last = _lastPos;
    if (streamPos >= 0 && last != null && streamPos == last) {
      _ticks++;
      if (!_reported && _ticks >= thresholdTicks) {
        _reported = true;
        return true;
      }
    } else if (streamPos >= 0) {
      _ticks = 0; // прогресс (или первый замер) — сброс
    }
    if (streamPos >= 0) _lastPos = streamPos;
    return false;
  }

  void reset() {
    _lastPos = null;
    _ticks = 0;
    _reported = false;
  }
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
/// `MxcImage._networkTimeout` полноразмера — один порог на медиа-контур, чтобы
/// логи `[MediaDiag]` читались одинаково. Заведомо больше окна
/// `StalledReconnectDetector` (16 с), поэтому гонки «кто терминалит первым» нет.
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
  late final Player _player = Player(
    configuration: PlayerConfiguration(
      logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.warn,
    ),
  );
  late final VideoController _videoController = VideoController(_player);

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription<PlayerLog>? _logSubscription;
  // Story-режим: подписки на длительность/завершение для прогресс-полоски
  // и авто-перехода сегмента. В non-story остаются null.
  StreamSubscription<Duration>? _durationSubscription;
  StreamSubscription<bool>? _completedSubscription;
  StreamSubscription<Duration>? _positionSubscription;

  // Story-режим со срезом (desktop-trim): seek к старту выполнен единожды.
  bool _seekedToTrimStart = false;

  // Story-режим: mute-состояние живёт во внешнем ValueNotifier
  // (StoryViewerController.storyMuted), общем на весь сеанс просмотра —
  // переживает пересоздание плеера по ValueKey. Дефолт (нет notifier'а или
  // его значение) — приглушено (требование ②: у зрителей звук по умолчанию
  // выключен). Плеер только читает и применяет громкость.
  bool get _muted => widget.mutedNotifier?.value ?? true;

  // Реакция на смену общего mute-переключателя из шапки вьюера.
  void _onMutedChanged() {
    if (_disposed) return;
    _player.setVolume(_muted ? 0 : 100);
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
  String? _proxySessionId;

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
  Timer? _adaptiveTimer;
  // Пауза-за-буфером сейчас: честный индикатор «Буферизация…» поверх видео
  // (пришло на смену баннеру «Скачать полностью?», убранному 2026-08-31).
  bool _pausedForCache = false;
  // Stopwatch для замера bandwidth при полном скачивании.
  Stopwatch? _downloadStopwatch;

  // Watchdog: если через 8 сек после _ready=true видео не воспроизводится
  // (позиция == 0, не playing) — трактуем как тихий сбой декодирования.
  Timer? _watchdogTimer;

  // --- Телеметрия видео-проблем (комната «Liza · Видео») ---
  // Сессионные защёлки: один сигнал на жизнь плеера, чтобы не спамить чат.
  bool _swapReported = false;
  final VideoRebufferAggregator _rebufferAggregator = VideoRebufferAggregator();

  // stalled-reconnect: детект мёртвого reconnect по МОНОТОННОЙ `stream-pos`
  // (скачанные байты). Инцидент 2026-09-01: 230МБ видео reconnect'ило вечно,
  // watchdog по `paused-for-cache=yes` считал «живым» → тихий провал. 8×2с=16с
  // (> watchdog-delay 15с MMR non-faststart первого кадра). Логика — в чистом
  // тестируемом `StalledReconnectDetector`.
  final StalledReconnectDetector _stallDetector = StalledReconnectDetector(
    thresholdTicks: 8,
  );

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
    if (!mounted) return;
    _lastErrorDetails = details ?? _lastErrorDetails;
    _scaffoldMessenger?.clearSnackBars();
    setState(() => _showErrorFallback = true);
  }

  @override
  void initState() {
    super.initState();
    _errorSubscription = _player.stream.error.listen(_onPlayerError);
    // log-поток libmpv. Высокий уровень (info) нужен, чтобы видеть demuxer/
    // hwdec/stream-сообщения, но он шумит на каждом chunk-е. Поэтому:
    //   - error/fatal → Logs().w + fail-safe swap (см. ниже)
    //   - warn → Logs().w
    //   - info с интересными prefix-ами (cplayer/demux/ffmpeg/file/stream/
    //     vd/vo/hwdec) → Logs().i
    //   - всё остальное → Logs().v (verbose, не засирает /logs)
    _logSubscription = _player.stream.log.listen((event) {
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
    });
    // Постер не блокирует первый кадр UI: подхватываем уже извлечённый
    // inline-bubble-ом кадр из disk-cache. libmpv-экстракцию тут НЕ
    // запускаем — это тяжело и single-slot semaphore занят лентой.
    VideoPosterCache.instance.getCached(widget.event).then((file) {
      if (file != null && mounted) {
        setState(() => _cachedPoster = file);
      }
    });
    if (widget.storyMode) {
      // Общий mute-переключатель сеанса: применяем громкость на лету при
      // переключении из шапки вьюера. Отписка — в dispose/didUpdateWidget.
      widget.mutedNotifier?.addListener(_onMutedChanged);
      // Авто-старт без кнопки play: дожидаемся первого кадра, чтобы Video-
      // виджет уже был в дереве (media_kit на macOS нужен compositor tick).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_started) _onPlayPressed();
      });
      // Сообщить длительность, когда libmpv её узнает (для прогресс-полоски).
      // Со срезом (desktop-trim) прогресс-полоса меряет ДЛИНУ ОКНА, а не файла.
      final trimStart = widget.startPositionMs;
      final trimEnd = widget.endPositionMs;
      _durationSubscription = _player.stream.duration.listen((d) {
        if (d <= Duration.zero) return;
        if (trimStart != null && trimEnd != null && trimEnd > trimStart) {
          widget.onDurationKnown?.call(
            Duration(milliseconds: trimEnd - trimStart),
          );
        } else {
          widget.onDurationKnown?.call(d);
        }
      });
      // Авто-переход по завершению сегмента.
      _completedSubscription = _player.stream.completed.listen((done) {
        if (done && mounted) widget.onStoryEnded?.call();
      });
      // Срез [startMs..endMs] (desktop-trim): seek к старту, как только известна
      // длительность; авто-переход по достижению конца окна (раньше конца файла).
      if (trimStart != null || trimEnd != null) {
        _positionSubscription = _player.stream.position.listen((pos) {
          if (!mounted) return;
          if (!_seekedToTrimStart &&
              (trimStart ?? 0) > 0 &&
              _player.state.duration > Duration.zero) {
            _seekedToTrimStart = true;
            _player.seek(Duration(milliseconds: trimStart!));
            return;
          }
          if (trimEnd != null && pos.inMilliseconds >= trimEnd) {
            widget.onStoryEnded?.call();
          }
        });
      }
    }
  }

  /// Запускает периодический монитор состояния буфера libmpv.
  ///
  /// Каждые 2 сек читает `demuxer-cache-duration` и `paused-for-cache`:
  ///  - адаптирует cache-secs / demuxer-max-bytes на лету;
  ///  - на паузе-за-буфером показывает честный индикатор «Буферизация…»
  ///    (НЕ предложение скачать — требование руководителя 2026-08-31);
  ///  - кормит телеметрию ребуферинга (наблюдаемость).
  void _startAdaptiveMonitor() {
    _adaptiveTimer?.cancel();
    _adaptiveTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_ready || _useLocalFile) return;

      final cacheDurationStr = await getMpvProperty(
        _player,
        'demuxer-cache-duration',
      );
      final pausedForCacheStr = await getMpvProperty(
        _player,
        'paused-for-cache',
      );

      // Плеер мог быть закрыт пока шли два await getMpvProperty — guard перед
      // любыми side-effects (баннер/телеметрия/setMpvProperty).
      if (_disposed) return;

      final cacheDuration = double.tryParse(cacheDurationStr ?? '') ?? -1;
      final pausedForCache = pausedForCacheStr == 'yes';

      // Честный индикатор «Буферизация…» поверх играющего видео, чтобы пауза
      // за буфером не выглядела зависанием. Единственный писатель — этот монитор.
      if (pausedForCache != _pausedForCache && mounted) {
        setState(() => _pausedForCache = pausedForCache);
      }

      if (pausedForCache) {
        // Телеметрия ребуферинга (наблюдаемость): один сигнал за сессию.
        // UX-баннер «Скачать полностью?» УБРАН (2026-08-31, требование
        // руководителя): при слабом канале честно буферизуемся, а не предлагаем
        // бесполезное скачивание того же оборванного пути/битрейта.
        if (_rebufferAggregator.observe(DateTime.now())) {
          _reportVideoRebuffer();
        }
      }
      // stalled-reconnect: мёртвый цикл reconnect (обрыв отдачи/пустой источник) —
      // paused-for-cache=yes, но `stream-pos` (скачанные байты) НЕ растёт N тиков.
      // Живая рывковая докачка растит stream-pos → детектор НЕ терминалит
      // (RL-e2ee-video-proxy-resume). Терминал → свап/`[video-fail]` + overlay
      // «Повторить» вместо вечного спиннера «как будто не загрузилось».
      final streamPosStr = await getMpvProperty(_player, 'stream-pos');
      if (_disposed) return;
      final streamPos = int.tryParse(streamPosStr ?? '') ?? -1;
      if (_stallDetector.observe(
            streamPos: streamPos,
            pausedForCache: pausedForCache,
          ) &&
          mounted &&
          !_useLocalFile &&
          !_swappingToLocal) {
        _handlePlaybackError(
          'Video stalled: no stream-pos progress while paused-for-cache '
          '(stream-pos=$streamPos); ${_videoFailureDiag('stalled-reconnect')}',
          StackTrace.current,
          reason: 'stalled-reconnect',
        );
        return;
      }

      // Адаптация буферизации на лету (mpv properties runtime-writable)
      if (cacheDuration >= 0 && cacheDuration < 2.0) {
        await setMpvProperty(_player, 'cache-secs', '120');
        await setMpvProperty(_player, 'cache-pause-wait', '5');
      } else if (cacheDuration > 15.0) {
        await setMpvProperty(_player, 'cache-secs', '30');
        await setMpvProperty(_player, 'cache-pause-wait', '2');
      }
    });
  }

  /// Watchdog: через [delay] (8с; 15с на MMR-стриминге, где non-faststart
  /// делает Range-seek к moov-в-хвосте и первый кадр может прийти позже)
  /// после _ready=true проверяем, что видео живо.
  ///
  /// Важно отличить ДВА состояния, когда позиция всё ещё ~0:
  ///  - **зависание** — буфер пуст (`demuxer-cache-duration≈0`): mpv открыл
  ///    поток, но данные не идут. Причины: back-seek к `mdat` у non-faststart
  ///    файла повис, или декод тихо упал. → уходим в полное скачивание.
  ///  - **медленная буферизация** — буфер РАСТЁТ: данные идут, просто
  ///    соединение медленнее, чем нужно для мгновенного старта (тяжёлый
  ///    высокобитрейтный файл на LTE). Это РАБОЧИЙ стрим — НЕ трогаем, иначе
  ///    сами рубим воспроизведение и заставляем качать весь файл.
  /// Раньше watchdog свопал по одному `pos<500ms` без учёта буфера и убивал
  /// медленный, но живой стрим.
  void _startWatchdog({Duration delay = const Duration(seconds: 8)}) {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(delay, () async {
      if (!mounted || _disposed || !_ready || _showErrorFallback) return;
      if (_swappingToLocal || _useLocalFile) return;
      final pos = _player.state.position;
      if (pos >= const Duration(milliseconds: 500)) return; // играет — ок

      final cacheStr = await getMpvProperty(_player, 'demuxer-cache-duration');
      final cache = double.tryParse(cacheStr ?? '') ?? 0;
      if (!mounted || _disposed || _swappingToLocal || _useLocalFile) return;
      if (cache > 0.3) {
        // Буфер набирается → стрим живой, просто медленный. Дальше следит
        // адаптивный монитор (баннер «Медленное соединение» + ручное «Скачать»).
        Logs().i(
          'Video watchdog: pos~0, но буфер растёт '
          '(demux-cache=${cache}s) — стрим живой, не свопаем',
        );
        return;
      }
      // M-1: буфер пуст (cache~0), но плеер может ЖДАТЬ данные при активном
      // reconnect/resume — libmpv (не-E2EE) или E2eeMediaProxy (докачка Range).
      // paused-for-cache=yes = идёт добор данных, а НЕ зависание → не убиваем
      // живой resume (иначе watchdog схлопнет докачку 169МБ E2EE на 15-й секунде).
      final pausedForCache = await getMpvProperty(_player, 'paused-for-cache');
      if (!mounted || _disposed || _swappingToLocal || _useLocalFile) return;
      if (pausedForCache == 'yes') {
        Logs().i(
          'Video watchdog: pos~0, cache~0, но paused-for-cache=yes — '
          'идёт reconnect/resume, стрим живой, не свопаем',
        );
        return;
      }
      Logs().w(
        'Video watchdog: зависание (pos=$pos, demux-cache=${cache}s) '
        '→ swap на скачивание',
      );
      final event = widget.event;
      if (!event.isAttachmentEncrypted && !kIsWeb) {
        // fire-and-forget безопасен: `_swapToLocal` не выпускает исключений
        // наружу — провал он сам переводит в терминальный error-overlay.
        unawaited(_swapToLocal(trigger: 'watchdog-no-progress'));
      } else {
        // E2EE/Web watchdog: свапать некуда → _handlePlaybackError сам шлёт
        // терминальный `[video-fail]` с reason=watchdog-no-progress (единый
        // сигнал, без дубля). Диагностику кладём в текст ошибки (уйдёт в cause).
        _handlePlaybackError(
          'Video watchdog: no playback after 8s (pos=$pos, cache=$cache); '
          '${_videoFailureDiag('watchdog-no-progress')}',
          StackTrace.current,
          reason: 'watchdog-no-progress',
        );
      }
    });
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
    );
  }

  /// Устойчивый ребуферинг («медленно, но играет»). Сигнал low, один раз за
  /// сессию (агрегатор). Контекст (size-бакет/mime) — чтобы отличить тяжёлый
  /// файл (аргумент за транскодер) от слабой сети пользователя.
  void _reportVideoRebuffer() {
    Monitoring.reportVideoIssue(
      prefix: Monitoring.videoRebufferPrefix,
      reason: 'slow-network',
      host: _alertHost,
      context: _videoContext(),
    );
  }

  /// Запуск воспроизведения по тапу на кнопку play. До этого момента
  /// показывается только постер (см. media-v-format.md §8.2).
  void _onPlayPressed() {
    if (_started) return;
    setState(() => _started = true);
    _start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  @override
  void didUpdateWidget(EventVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Общий mute-notifier мог смениться (страховка чек-листа lifecycle):
    // пере-подписываемся, чтобы висящий слушатель не дёргал уже мёртвый плеер.
    if (oldWidget.mutedNotifier != widget.mutedNotifier) {
      oldWidget.mutedNotifier?.removeListener(_onMutedChanged);
      widget.mutedNotifier?.addListener(_onMutedChanged);
    }
    // Свайп карусели увёл на другую страницу — ставим видео на паузу
    // (media-v-format.md §8.9).
    if (oldWidget.isActive && !widget.isActive && _started) {
      _player.pause();
    }
    // Обратный переход (isActive false -> true) — авто-play ТОЛЬКО в
    // story-режиме: story-viewer снимает паузу диалога подтверждения
    // удаления, а у сториз нет ручных контролов (NoVideoControls), так что
    // молчаливая пауза без авто-play выглядела бы как зависший экран.
    // В карусели (storyMode=false) `isActive` меняется на каждый свайп
    // PageView, а пауза там — РУЧНОЕ действие пользователя через
    // CarouselVideoControls.playOrPause() (напрямую на Player, в обход этого
    // State) — авто-play здесь при возврате на страницу тихо отменял бы
    // явную паузу пользователя. Поэтому в карусели после свайпа прочь и
    // обратно видео должно остаться на паузе, пока пользователь сам не
    // нажмёт play.
    if (!oldWidget.isActive &&
        widget.isActive &&
        _started &&
        widget.storyMode) {
      _player.play();
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
  Future<void> _tuneMpvCommon() async {
    await setMpvProperty(_player, 'hwdec', 'auto-safe');
    await setMpvProperty(_player, 'hr-seek', 'yes');
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
  Future<void> _tuneMpvForStreaming({
    required bool encrypted,
    required bool mediaOriginOnMmr,
  }) async {
    await setMpvProperty(_player, 'cache-on-disk', 'no');
    await setMpvProperty(_player, 'cache', 'yes');
    await setMpvProperty(_player, 'cache-secs', '30');
    await setMpvProperty(_player, 'cache-pause-initial', 'yes');
    await setMpvProperty(_player, 'cache-pause-wait', '2');
    await setMpvProperty(_player, 'demuxer-max-bytes', '33554432'); // 32 MiB
    await setMpvProperty(
      _player,
      'demuxer-max-back-bytes',
      '16777216',
    ); // 16 MiB
    await setMpvProperty(_player, 'demuxer-readahead-secs', '15');
    await setMpvProperty(_player, 'network-timeout', '30');
    final lavfOpts = buildStreamLavfOpts(
      encrypted: encrypted,
      mediaOriginOnMmr: mediaOriginOnMmr,
    );
    await setMpvProperty(_player, 'stream-lavf-o', lavfOpts);
    // seek в пределах RAM-кэша (внутри cache-secs) стабильнее принудительно.
    await setMpvProperty(_player, 'demuxer-seekable-cache', 'yes');
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

  Future<void> _start() async {
    final event = widget.event;

    // Один лог-маркер на каждое открытие плеера: даёт точку отсчёта в /logs
    // и сразу видно, какой именно mov/mp4/mkv открывали (по mimetype/size).
    final info = event.content.tryGetMap<String, dynamic>('info');
    final mimeType = info?.tryGet<String>('mimetype');
    final size = info?.tryGet<int>('size');
    final fileName = event.content.tryGet<String>('body');
    Logs().i(
      'Video open[${event.eventId}]: name=$fileName mime=$mimeType '
      'size=$size e2ee=${event.isAttachmentEncrypted} kIsWeb=$kIsWeb',
    );

    // Файл ещё не залит и байтов у SDK нет — ни стримить, ни качать нечего.
    // Без этой проверки путь уходил в скачивание → свап → ложный `swap-failed`.
    if (event.isPendingMediaWithoutBytes) {
      Logs().i(
        'Video open[${event.eventId}]: still uploading, nothing to play',
      );
      if (mounted) {
        setState(() {
          _awaitingUpload = true;
          _uploadFailed = event.status.isError;
        });
      }
      return;
    }

    try {
      // Общие настройки декода применяем ВСЕГДА (стриминг, E2EE-download,
      // local swap) — без hwdec=auto-safe libmpv может зафейлить HEVC.
      await _tuneMpvCommon();

      // Story-режим: применяем громкость (дефолт — приглушено, требование ②)
      // ДО первого _player.open() — иначе первый кадр даст «пшик звука» до
      // применения mute. Все ветки open ниже идут после этой точки.
      if (widget.storyMode) {
        await _player.setVolume(_muted ? 0 : 100);
      }

      // Проверяем prefetch-кэш: малые видео могли быть скачаны в фоне.
      if (!kIsWeb) {
        final cachedFile = await VideoPrefetchCache.instance.getCached(event);
        if (cachedFile != null && await cachedFile.exists()) {
          Logs().i('Video play from prefetch cache: ${cachedFile.path}');
          _useLocalFile = true;
          await setMpvProperty(_player, 'cache', 'no');
          await _player.open(Media(cachedFile.path));
          if (mounted) {
            setState(() => _ready = true);
            _startWatchdog();
          }
          return;
        }
      }

      // Прямой стриминг возможен только в non-E2EE и не на Web.
      // Web-сборка не даёт media_kit стримить HTTP с custom headers,
      // на всех остальных платформах libmpv пробрасывает Bearer-токен.
      if (!event.isAttachmentEncrypted && !kIsWeb) {
        final originalUrl = await event.getAttachmentUri();
        if (originalUrl == null) {
          Logs().w(
            'Video stream: getAttachmentUri returned null, '
            'fallback to download+decrypt',
          );
        } else {
          // Выбор варианта качества по bandwidth (если доступны)
          final url = _resolveVideoVariant(event, originalUrl);
          final token = event.room.client.accessToken;
          final headers = <String, String>{
            if (token != null) 'Authorization': 'Bearer $token',
          };
          // Гейт по ORIGIN медиа, не по хоумсерверу читателя: для СВОЕГО
          // local_media (MMR/S3, нативный Range) снимаем seekable=0 → частичный
          // стриминг. Для чужого origin (федеративное `user.liza.ru` = MMR
          // remote_media на диске, обрез открытого Range 10 МБ; либо
          // cyber-agro/nadezhda без MMR) seekable=0 сохраняем — иначе ffmpeg
          // зацикливается на reconnect (инцидент 2026-09-01).
          final onMmr = isMmrBackedHost(_mediaOriginHost);
          await _tuneMpvForStreaming(encrypted: false, mediaOriginOnMmr: onMmr);
          // Плеер мог быть закрыт пока шли async setMpvProperty.
          if (!mounted || _disposed) return;
          Logs().i(
            'Video stream open: $url '
            '(authHeader=${token == null ? 'no' : 'yes'}, mmr=$onMmr)',
          );
          await _player.open(Media(url.toString(), httpHeaders: headers));
          if (mounted) {
            setState(() => _ready = true);
            // При снятом seekable non-faststart файл делает Range-seek к moov-
            // в-хвосте: на медленной сети первый кадр может прийти позже 8с при
            // pos~0 → даём watchdog больше времени, чтобы не свопнуть живой стрим.
            _startWatchdog(
              delay: onMmr
                  ? const Duration(seconds: 15)
                  : const Duration(seconds: 8),
            );
          }
          _startAdaptiveMonitor();
          return;
        }
      }
      // E2EE стриминг через локальный прокси (non-Web).
      // Прокси расшифровывает AES-CTR потоково, libmpv стримит через HTTP.
      // Fallback на полное скачивание при ошибке.
      if (event.isAttachmentEncrypted && !kIsWeb) {
        try {
          final proxyUrl = await E2eeMediaProxy.instance.registerSession(
            event: event,
          );
          _proxySessionId = Uri.parse(proxyUrl).pathSegments.firstOrNull;
          // E2EE: seekable НЕ форсим (данные из локального прокси, не из S3) —
          // encrypted:true гарантирует это в buildStreamLavfOpts независимо от origin.
          await _tuneMpvForStreaming(
            encrypted: true,
            mediaOriginOnMmr: isMmrBackedHost(_mediaOriginHost),
          );
          if (!mounted || _disposed) {
            // Плеер закрыли пока шли async registerSession/tune — снимаем
            // только что зарегистрированную прокси-сессию (dispose уже мог
            // отработать с sid==null до присвоения _proxySessionId).
            final sid = _proxySessionId;
            if (sid != null) E2eeMediaProxy.instance.removeSession(sid);
            return;
          }
          Logs().i('Video E2EE stream via proxy: $proxyUrl');
          await _player.open(Media(proxyUrl));
          if (mounted) {
            setState(() => _ready = true);
            // 15с (как MMR-ветка): оживлённый E2EE-прокси делает Range-seek к
            // moov-в-хвосте через прокси + AES-расшифровку первого чанка — на LTE
            // первый кадр может прийти позже 8с при pos~0 → иначе watchdog ложно
            // свопнет живой стрим на полное скачивание.
            _startWatchdog(delay: const Duration(seconds: 15));
          }
          _startAdaptiveMonitor();
          return;
        } catch (e) {
          Logs().w('E2EE proxy failed, falling back to download: $e');
          // Fallback — скачиваем целиком
        }
      }
      // Web / fallback: качаем целиком, потом играем из файла/blob.
      await _downloadAndPlay();
    } on IOException catch (e, s) {
      Logs().e('Video stream IO error', e);
      _lastErrorDetails = e.toString();
      // IOException входит в _ignoredTypes Monitoring — оборачиваем в
      // VideoPlaybackException, чтобы алерт гарантированно дошёл.
      Monitoring.capture(
        VideoPlaybackException(
          'IO error during video download/play',
          cause: e,
          reason: 'io-error',
          host: _alertHost,
        ),
        s,
      );
      if (!mounted) return;
      // Раньше здесь показывался SnackBar на 4с БЕЗ выставления
      // `_showErrorFallback` — под плашкой оставался `_buildDownloadOverlay`,
      // то есть вечный крутящийся индикатор без кнопки. Плашка уезжала, спиннер
      // оставался навсегда. Теперь тот же error-overlay с «Повторить», что и на
      // остальных путях провала: класс ошибки не остаётся немым.
      _enterErrorState(e.toString());
    } catch (e, s) {
      _handlePlaybackError(e, s);
    }
  }

  Future<void> _downloadAndPlay() async {
    await _downloadAndOpenLocal();
    if (mounted && !_disposed) {
      setState(() => _ready = true);
      _startWatchdog();
    }
  }

  /// Троттлинг обновления UI-прогресса скачивания (≤ раз/250мс). Единственный
  /// писатель `_downloadProgress` при активной загрузке.
  void _maybeUpdateDownloadProgress(int received, int? total) {
    final now = DateTime.now();
    if (now.difference(_lastProgressUpdate).inMilliseconds < 250) return;
    _lastProgressUpdate = now;
    if (!mounted) return;
    final p = (total != null && total > 0) ? received / total : null;
    setState(() => _downloadProgress = (p != null && p < 1) ? p : null);
  }

  /// Качает + расшифровывает целиком и открывает Player из локального файла
  /// (или Blob на Web). Используется и при первом открытии (E2EE/Web),
  /// и при swap-е со стриминга после seek-ошибки.
  ///
  /// [seekTo] — позиция, на которую нужно встать после открытия (для swap-а
  /// со стриминга). Файл всегда открывается с `play=true` — и при первом
  /// открытии E2EE/Web, и при swap-е после ошибки: пользователь хотел
  /// смотреть, после ожидания скачивания логично сразу играть.
  Future<void> _downloadAndOpenLocal({Duration? seekTo}) async {
    final event = widget.event;
    final fileSize = event.content
        .tryGetMap<String, dynamic>('info')
        ?.tryGet<int>('size');

    Logs().i(
      'Video download start[${event.eventId}]: '
      'expected size=$fileSize',
    );
    _downloadStopwatch = Stopwatch()..start();
    // Отдельный HTTP-клиент для скачивания видео: не привязан к lifecycle
    // MatrixState. Корневая причина бага «Connection closed while receiving
    // data» (из лога): при уходе приложения в фон на мобильном
    // MatrixState.didChangeAppLifecycleState → _refreshHttpClients() →
    // httpClient.close() уничтожал TCP-соединение скачивания 24-МБ файла.
    // Отдельный клиент живёт пока download не закончится.
    final downloadClient = http.Client();
    final token = event.room.client.accessToken;
    // Время загрузки считается по ОТКРЫТОМУ приложению (см. ForegroundWitness):
    // сон процесса в фоне — не мёртвый канал (#2064). На desktop свёрнутое
    // окно не замораживается — свидетель не нужен.
    final witness = PlatformInfos.isMobile ? ForegroundWitness.attach() : null;
    try {
      Future<MatrixFile> download() => event.downloadAndDecryptAttachmentHealed(
        downloadCallback: (url) async {
          final request = http.Request('GET', url);
          if (token != null) {
            request.headers['authorization'] = 'Bearer $token';
          }
          // Таймаут на фазе connect+заголовки: «сокет принят, но ответ не
          // приходит» иначе висит вечно — у ЭТОГО клиента своего таймаута нет
          // (он намеренно создан вне `room.client.httpClient`), а SDK-шный
          // здесь не участвует, т.к. мы передаём собственный downloadCallback.
          final response = await downloadClient
              .send(request)
              .timeout(_downloadIdleTimeout);
          // Чтение тела — с ПОМЕЖЧАНКОВЫМ таймаутом (см.
          // `readBytesWithIdleTimeout`): счётчик сбрасывается на каждом чанке,
          // поэтому легитимная докачка 161 МБ на слабом канале не рубится, а
          // «тлеющее» соединение без единого байта перестаёт быть вечным
          // спиннером и становится терминалом с кнопкой «Повторить».
          return readBytesWithIdleTimeout(
            response.stream,
            idleTimeout: _downloadIdleTimeout,
            witness: witness,
            onChunk: (received) =>
                _maybeUpdateDownloadProgress(received, fileSize),
          );
        },
      );
      // Сокет, переживший заморозку, рвётся сразу после возврата (или сервер
      // закрыл его, пока процесс спал) — это не сбой канала: один тихий повтор,
      // когда пользователь снова смотрит, без алёрта и error-overlay.
      final videoFile = await retryOnceAfterSuspension(
        download,
        witness,
        abandoned: () => _disposed,
        onRetry: (e) {
          Logs().i(
            'Video download interrupted by app suspension[${event.eventId}]: '
            '${mediaFailureErrorType(e)} — retry on foreground',
          );
          if (mounted) setState(() => _downloadProgress = 0);
          _downloadStopwatch = Stopwatch()..start();
        },
      );
      _downloadStopwatch!.stop();
      BandwidthEstimator.instance.addTimedSample(
        videoFile.bytes.length,
        _downloadStopwatch!.elapsed,
      );
      Logs().i(
        'Video download done[${event.eventId}]: '
        'got ${videoFile.bytes.length} bytes name=${videoFile.name} '
        'mime=${videoFile.mimeType} '
        'bw=${BandwidthEstimator.instance.estimatedMbps.toStringAsFixed(1)} Mbps',
      );

      // Player мог быть dispose-нут пока шло скачивание (пользователь
      // закрыл плеер). Из логов: «setProperty cache=no failed: Assertion
      // failed: "[Player] has been disposed"» — после 22 сек download.
      if (_disposed) {
        Logs().i(
          'Video download done but player already disposed, '
          'skipping open',
        );
        return;
      }

      _useLocalFile = true;
      await setMpvProperty(_player, 'cache', 'no');
      if (kIsWeb) {
        // faststart-перекладка moov→в начало и на Web (тот же приём, что в
        // non-Web ветке ниже): iPhone-оригинал/ReplayKit пишет moov в хвост, и
        // Blob-воспроизведение без faststart тянет весь файл до индекса.
        // process() отдаёт null для не-mp4/уже-faststart → деградация, не порча.
        final relocated = Mp4Faststart.process(videoFile.bytes);
        if (relocated != null) {
          Logs().i(
            'Video faststart applied (web)[${event.eventId}]: '
            'moov→front (${videoFile.bytes.length} bytes)',
          );
        }
        final blob = html.Blob([relocated ?? videoFile.bytes]);
        final blobUrl = html.Url.createObjectUrlFromBlob(blob);
        Logs().i('Video open local (web blob)');
        await _player.open(Media(blobUrl));
      } else {
        // faststart-перекладка moov→в начало на ПРИЁМЕ. iPhone-оригинал пишет
        // moov в хвост; libmpv тогда либо тянет весь файл до индекса, либо (через
        // прокси) проваливается в playlist-эвристику и виснет (γ, лог «Reading
        // plaintext playlist»). На отправке faststart делается только с desktop
        // (send_file_dialog.dart), приём не покрыт. Здесь у нас уже весь
        // расшифрованный буфер в RAM — переложить дёшево. process() сам отдаёт
        // null (→ оригинал) для не-mp4/уже-faststart/fMP4/cmov — деградация, не
        // порча.
        final relocated = Mp4Faststart.process(videoFile.bytes);
        final playBytes = relocated ?? videoFile.bytes;
        if (relocated != null) {
          Logs().i(
            'Video faststart applied[${event.eventId}]: '
            'moov→front (${videoFile.bytes.length} bytes)',
          );
        }
        final tempDir = await getTemporaryDirectory();
        // Голый `!` ронял бы фолбэк-путь на битом E2EE-событии без file.url
        // (тот же случай, что ловит VideoProxyException в прокси). Фолбэк-имя
        // из хэша eventId — временный файл всё равно уникален.
        final mxcSegment =
            event.attachmentOrThumbnailMxcUrl()?.pathSegments.last ??
            'video_${event.eventId.hashCode.toUnsigned(32).toRadixString(16)}';
        final ext = _safeExtensionFor(videoFile.name);
        // faststart-версия хранится под своим именем, чтобы не спутать с
        // возможной оригинальной раскладкой в кэше.
        final safeName = relocated != null
            ? '${mxcSegment}_fs$ext'
            : '$mxcSegment$ext';
        final file = File('${tempDir.path}/$safeName');
        final alreadyExisted = await file.exists();
        if (!alreadyExisted) {
          await file.writeAsBytes(playBytes);
        }
        final onDisk = await file.length();
        final probe = await file.openRead(0, 16).first;
        final probeAscii = String.fromCharCodes(
          probe.map((b) => (b >= 0x20 && b < 0x7f) ? b : 0x2e),
        );
        Logs().i(
          'Video open local: path=${file.path} '
          'size=$onDisk existedBefore=$alreadyExisted '
          'first16=$probe ascii="$probeAscii"',
        );
        if (_disposed) return;
        await _player.open(Media(file.path));
      }

      if (_disposed) return;
      if (seekTo != null && seekTo > Duration.zero) {
        await _seekWhenReady(seekTo);
      }

      if (mounted) {
        setState(() => _downloadProgress = null);
      }
    } finally {
      witness?.dispose();
      downloadClient.close();
    }
  }

  Future<void> _seekWhenReady(Duration target) async {
    // Ждём, пока mpv доложит ненулевую duration (= файл реально открылся).
    // Без этого seek(target) на не-загруженном media молча сбросится в 0.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (mounted && !_disposed && DateTime.now().isBefore(deadline)) {
      final dur = _player.state.duration;
      if (dur > Duration.zero) break;
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted || _disposed) return; // не трогаем уничтоженный _player
    await _player.seek(target);
  }

  /// Поток-стриминг сорвался (Synapse без Range) или открытие упало.
  /// Если уже играли (`_ready=true`) — переключаемся на локальный файл,
  /// сохраняя позицию. Если ещё не успели — обычное полное скачивание.
  ///
  /// На время swap-а скрываем `Video`-виджет и показываем тот же thumbnail+
  /// progress, что и при первом открытии — иначе пользователь видит
  /// замороженный последний кадр без признаков жизни.
  Future<void> _swapToLocal({required String trigger, Duration? seekTo}) async {
    if (_swappingToLocal || _useLocalFile) return;
    // Телеметрия «стриминг не пошёл» — до setState, единственная точка входа в
    // свап (сюда сходятся watchdog и _handlePlaybackError). Гейт по MMR-хосту
    // внутри: на не-MMR свап штатный, не сигналим.
    _reportVideoSwap(trigger);
    Logs().i('Video swap to local file ($trigger), seekTo=$seekTo');
    if (mounted) {
      setState(() {
        _swappingToLocal = true;
        _downloadProgress = 0;
      });
    } else {
      _swappingToLocal = true;
    }
    try {
      await _downloadAndOpenLocal(seekTo: seekTo);
    } catch (e, s) {
      // Терминал держится КОДОМ, а не дисциплиной вызывающих. Раньше catch жил
      // только у вызова из `_handlePlaybackError`, а watchdog звал этот же метод
      // fire-and-forget (`// ignore: discarded_futures`) — бросок улетал в
      // zone-хендлер `main.dart`, где сетевой класс ещё и отфильтрован
      // (`Monitoring._isNetworkError`). Итог: `_showErrorFallback` не ставился
      // НИКОГДА, на экране оставался мёртвый кадр без «Повторить», а в
      // мониторинге — ноль. Второй вход в метод появился уже после фикса
      // LABA-2557 и контракт не соблюл — значит контракту место здесь.
      //
      // `_handlePlaybackError` звать НЕЛЬЗЯ: он делает ранний return при
      // `_swappingToLocal` (глушение вторичных ошибок libmpv), а флаг ещё не
      // сброшен — терминал бы проглотился. Ставим его напрямую, тем же
      // способом, что и ветка `canSwap` ниже.
      Logs().e('Video swap to local file failed', e, s);
      _lastErrorDetails = '${_lastErrorDetails ?? ''}; swap: $e';
      _reportVideoFailure('swap-failed', cause: e, stack: s);
      _enterErrorState(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          _swappingToLocal = false;
          // Индикатор буферизации обязан сняться вместе со свапом: его
          // единственный писатель — адаптивный монитор, а он после свапа
          // замолкает навсегда (ранний return по `_useLocalFile`). Без этого
          // спиннер переживал УСПЕШНОЕ восстановление и висел поверх играющего
          // видео до конца просмотра — снять его было нечем, т.к. сброс есть
          // только в `_retryPlayback`, куда с играющего видео не попасть.
          // Комбинация не редкая, а основная: свап по `stalled-reconnect`
          // срабатывает ровно при `paused-for-cache=yes`.
          _pausedForCache = false;
        });
      } else {
        _swappingToLocal = false;
        _pausedForCache = false;
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
    final text = event.text;
    if (!_fatalSwapTextPatterns.any((re) => re.hasMatch(text))) return;
    final fatalReason = _fatalReasonFor(text);
    // Глушим только ВО ВРЕМЯ перехода на локальный файл (вторичные ошибки
    // рвущегося стрима). Если УЖЕ на локальном файле (_useLocalFile) и он
    // фатально упал — не глотаем: ниже уйдёт в _handlePlaybackError →
    // терминальный error-overlay (canSwap=false при _useLocalFile).
    if (_swappingToLocal) return;
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
    );
  }

  Future<void> _handlePlaybackError(
    Object e,
    StackTrace s, {
    String reason = 'unable-to-play',
  }) async {
    // После swap наш же `_player.open(local)` рвёт текущий HTTP-стрим,
    // и libmpv поверх летит со вторичными ошибками (`tls: mbedtls_ssl_read
    // returned -0x0`, `partial file`). Они приезжают в stream.error и
    // повторно дёргают этот хендлер — лог `[ERROR] Unable to play video`
    // × N штук, Sentry-шум. Реальной проблемы нет, мы уже на пути
    // перехода, ранний return.
    // Только ВО ВРЕМЯ перехода на локальный файл вторичные ошибки шумовые —
    // глушим. НО если мы УЖЕ играем из локального файла (_useLocalFile) и он
    // упал (codec-fail на скачанном файле) — это ТЕРМИНАЛ, не шум: раньше он
    // молча глотался на ВСЕХ платформах (чёрный экран без сигнала, комиссия
    // 2026-08-31). Свапать некуда (уже локально) → error-overlay + сигнал.
    if (_swappingToLocal) {
      Logs().v('Suppressed late playback error during local swap: $e');
      return;
    }
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
    final canSwap = !event.isAttachmentEncrypted && !kIsWeb && !_useLocalFile;

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
    final sid = _proxySessionId;
    if (sid != null) {
      E2eeMediaProxy.instance.removeSession(sid);
    }
    _scaffoldMessenger?.clearSnackBars();
    _watchdogTimer?.cancel();
    _adaptiveTimer?.cancel();
    _errorSubscription?.cancel();
    _logSubscription?.cancel();
    _durationSubscription?.cancel();
    _completedSubscription?.cancel();
    _positionSubscription?.cancel();
    _player.dispose();
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
          Positioned.fill(
            child: Video(
              controller: _videoController,
              fit: widget.fit,
              controls: NoVideoControls,
            ),
          ),
          if (!_ready) _buildPoster(width, height, blurHash),
        ],
      );
    }

    final showVideo = _started && _ready && !_swappingToLocal;
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
            child: Video(
              controller: _videoController,
              fit: BoxFit.contain,
              controls: NoVideoControls,
            ),
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

  /// Повторная попытка воспроизведения: сброс состояния + restart.
  void _retryPlayback() {
    final sid = _proxySessionId;
    if (sid != null) {
      E2eeMediaProxy.instance.removeSession(sid);
      _proxySessionId = null;
    }
    setState(() {
      _showErrorFallback = false;
      _ready = false;
      _started = true;
      _useLocalFile = false;
      _swappingToLocal = false;
      _downloadProgress = null;
      _lastErrorDetails = null;
    });
    // Сброс сессионных защёлок телеметрии/детекции — иначе после «Повторить»
    // старая защёлка блокирует повторный сигнал/детект (регресс «retry не помогает»).
    _swapReported = false;
    _rebufferAggregator.reset();
    _pausedForCache = false;
    _stallDetector.reset();
    _failedToOpenCount = 0;
    _start();
  }
}
