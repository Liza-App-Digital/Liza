import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'package:http/http.dart' as http show ClientException;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/app_config.dart';

/// Мониторинг ошибок клиента Liza поверх Sentry-совместимого бэкенда (GlitchTip).
///
/// Полностью инертен, пока не переданы build-флаги (см. [AppConfig]
/// `monitoringEnabled` / `monitoringDsn`): при обычной разработке и hot-reload
/// SDK не инициализируется и ничего не шлёт.
///
/// Захват ошибок добавлен в уже существующие глобальные хендлеры `main.dart`
/// (`FlutterError.onError`, `PlatformDispatcher.onError`, `runZonedGuarded`) —
/// собственную error-зону SDK не создаёт, чтобы не ломать порядок
/// инициализации (`FileLogger`, `Vodozemac`, `ClientManager`).
abstract final class Monitoring {
  static bool _active = false;

  /// Включён ли мониторинг в текущей сборке.
  static bool get isActive => _active;

  /// Сетевые ошибки не отправляем: это не баги клиента. `is`-проверки вместо
  /// сравнения имён типов: http >=1.2 кидает приватный `_ClientSocketException`,
  /// который строковый фильтр не ловил (а sentry потом переименовывал его
  /// обратно в «ClientException» в отображении). Намеренно НЕ `is IOException`:
  /// он покрыл бы и file-system ошибки (PathNotFoundException, disk full),
  /// которые репортить нужно.
  static bool _isNetworkError(Object error) =>
      error is SocketException ||
      error is TlsException ||
      error is OSError ||
      error is http.ClientException;

  /// Дедуп моста [captureSdkError] против явных [capture] из `main.dart`:
  /// одно и то же исключение, уже отправленное через глобальный хендлер,
  /// не дублируем, когда оно же всплывёт в логах SDK.
  static const int _recentThrowableMax = 32;
  static final List<int> _recentThrowableIds = [];

  static void _rememberThrowable(Object error) {
    final id = identityHashCode(error);
    if (_recentThrowableIds.contains(id)) return;
    _recentThrowableIds.add(id);
    if (_recentThrowableIds.length > _recentThrowableMax) {
      _recentThrowableIds.removeAt(0);
    }
  }

  /// Анти-лавина для моста: одну и ту же сигнатуру `тип:заголовок` шлём не
  /// чаще одного раза в окно (обрыв сети рождает поток sync-таймаутов).
  static const Duration _throttleWindow = Duration(minutes: 2);
  static final Map<String, DateTime> _lastSentBySignature = {};

  /// Инициализация. Вызывать один раз на старте, до запуска приложения.
  /// Без build-флагов или с пустым DSN — no-op.
  static Future<void> init() async {
    if (!AppConfig.monitoringEnabled || AppConfig.monitoringDsn.isEmpty) {
      return;
    }
    await SentryFlutter.init((options) {
      options.dsn = AppConfig.monitoringDsn;
      options.environment = AppConfig.monitoringEnv;
      // Performance-трейсинг не в скоупе — собираем только ошибки.
      options.tracesSampleRate = 0.0;
      // PII, скриншоты и дерево виджетов в мониторинг не уходят.
      options.sendDefaultPii = false;
      options.attachScreenshot = false;
      // ignore: experimental_member_use
      options.attachViewHierarchy = false;
      // release SDK определяет сам из package_info (version+build) —
      // регрессии считаются по номеру сборки.
      // GlitchTip не поддерживает dSYM → нативные стектрейсы приходят
      // как <redacted>, App Hang события бесполезны без символизации.
      options.enableAppHangTracking = false;
      // GlitchTip НЕ принимает Sentry sessions/release-health (session-endpoint
      // отвечает 4xx) — авто-трекинг сессий только шумит и не даёт liveness.
      // Живость флота меряем отдельным heartbeat-событием (см.
      // [reportHealthHeartbeat]), а не sessions. Явный false, т.к. дефолт SDK —
      // true (deep-research 2026-08-31).
      options.enableAutoSessionTracking = false;
      options.beforeSend = _beforeSend;
      // «Последние шаги» перед сбоем для справки поддержки (спека
      // 2026-10-19-support-client-diagnostics): только allowlist-категорий, см.
      // [filterBreadcrumb]. Нативные крошки идут мимо beforeBreadcrumb (подмешиваются
      // в событие нативным SDK) и несут http-URL с room id — выключены; жизненный
      // цикл берём Dart-наблюдателем. Клики несут подписи виджетов — выключены.
      options.maxBreadcrumbs = 50;
      options.enableAutoNativeBreadcrumbs = false;
      options.enableAppLifecycleBreadcrumbs = true;
      options.enableUserInteractionBreadcrumbs = false;
      options.beforeBreadcrumb = filterBreadcrumb;
    });
    _active = true;
  }

  /// Отправить пойманное исключение. No-op, если мониторинг выключен.
  ///
  /// [fatal] — пометить событие как фатальное (краш на старте), иначе `error`.
  static void capture(
    Object error,
    StackTrace? stack, {
    bool fatal = false,
  }) {
    if (!_active) return;
    if (_isNetworkError(error)) return;
    _rememberThrowable(error);
    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) => scope.level =
          fatal ? SentryLevel.fatal : SentryLevel.error,
    );
  }

  /// Мост из `Logs()` SDK (см. [FileLogger]): ошибки уровня error/wtf, которые
  /// SDK ловит внутри себя и НЕ пробрасывает в глобальные хендлеры `main.dart`
  /// (sync-логика, decrypt, парсинг). Иначе они невидимы для мониторинга.
  ///
  /// Фильтры: сеть/IO ([_ignoredTypes]); уже отправленное через [capture]
  /// (дедуп по identity); одинаковые сигнатуры троттлятся ([_throttleWindow]),
  /// чтобы обрыв сети не залил мониторинг потоком sync-таймаутов.
  static void captureSdkError(Object? error, StackTrace? stack, String title) {
    if (!_active || error == null) return;
    if (_isNetworkError(error)) return;
    // Таймаут /sync — симптом среды (заморозка процесса iOS, сеть, медленный
    // сервер), а не баг клиента: копим в агрегат вместо потока error-событий.
    if (error is TimeoutException && title == _sdkSyncErrorTitle) {
      _countSyncTimeout();
      return;
    }
    if (_recentThrowableIds.contains(identityHashCode(error))) return;

    final signature = '${error.runtimeType}:$title';
    final now = DateTime.now();
    final last = _lastSentBySignature[signature];
    if (last != null && now.difference(last) < _throttleWindow) return;
    _lastSentBySignature[signature] = now;
    if (_lastSentBySignature.length > 128) {
      // Чистим только протухшие записи: полный clear() стирал бы и только
      // что вставленную сигнатуру, ломая троттл для неё.
      _lastSentBySignature.removeWhere(
        (_, t) => now.difference(t) >= _throttleWindow,
      );
    }

    _rememberThrowable(error);
    Sentry.captureException(
      error,
      stackTrace: stack,
      withScope: (scope) => scope.level = SentryLevel.error,
    );
  }

  /// Отправить агрегированное предупреждение (не исключение). No-op, если
  /// мониторинг выключен. Для метрик-симптомов вроде всплеска неудачных
  /// загрузок медиа, которые сами по себе не бросают исключений.
  static void captureMessage(String message) {
    if (!_active) return;
    Sentry.captureMessage(message, level: SentryLevel.warning);
  }

  /// ⚠️ GlitchTip физически РЕЖЕТ `issue.title` на 100 символов (99 + «…») —
  /// проверено на прод-БД 2026-09-10 (`select max(char_length(title))` = 100,
  /// ровно на пределе лежали ВСЕ наши контекстные медиа-алёрты). Notifier постит
  /// в чат именно этот обрезанный title (webhook несёт только его), поэтому
  /// хвост контекста до дежурного НЕ доезжал: алёрт приходил как
  /// `… host=synapse.liza.laba.prodamus.tech e2ee=t…` — без `mime`/`size`/`kind`,
  /// то есть без единого поля, по которому инцидент можно триажить.
  /// Бюджет держим сами ([buildAlertTitle]): 99 — последний символ, который
  /// доезжает целым.
  static const int maxAlertTitleLength = 99;

  /// Короткая форма хоста для title: первые ДВА лейбла. `host=` съедал 36 из 99
  /// символов бюджета при почти нулевой различающей ценности — общий суффикс
  /// (`.laba.prodamus.tech`, `.ru`) одинаков у всех инстансов. Первые два лейбла
  /// различают весь наш парк однозначно (`synapse.liza`, `liza.cyber-agro`,
  /// `user.liza`, `dev.liza`, `nadezhda.liza`), а дедуп notifier'а `room|title`
  /// продолжает различать инциденты по хосту.
  ///
  /// ⚠️ Различимость держится на том, что ПЕРВЫЙ лейбл поддомена уникален для
  /// каждого инстанса — это гарантирует процесс онбординга (`liza-new-server`),
  /// а НЕ структура кода. Проверяется снимком всего парка `server_name` в
  /// страже `AC:RL-media-monitoring-audio-signal/9`: заводя инстанс с уже
  /// занятым первым лейблом, обнови список — иначе дедуп notifier'а `room|title`
  /// молча схлопнет два разных хоста в один инцидент.
  static String shortHost(String? host) {
    if (host == null || host.isEmpty) return 'unknown';
    final labels = host.split('.');
    return labels.length <= 2 ? host : labels.take(2).join('.');
  }

  /// Собирает title алёрта ПО БЮДЖЕТУ [maxAlertTitleLength]: `prefix`, `reason`
  /// и `host` неприкосновенны (маркер роутинга notifier + ось дедупа), а поля
  /// [context] идут в порядке УБЫВАНИЯ диагностической ценности и отбрасываются
  /// с хвоста, пока title не влезет. Так теряется наименее ценное поле целиком,
  /// а не произвольная середина слова, как при обрезке GlitchTip'ом.
  ///
  /// Секретов не кладём (пин `RL-mediadiag-no-secret`): [reason] и значения
  /// [context] — из ЗАКРЫТЫХ перечислений вызывающей стороны, не `e.toString()`.
  @visibleForTesting
  static String buildAlertTitle({
    required String prefix,
    required String reason,
    String? host,
    Map<String, String> context = const {},
  }) {
    final head = '$prefix reason=$reason host=${shortHost(host)}';
    final tail = context.entries.map((e) => '${e.key}=${e.value}').toList();
    while (tail.isNotEmpty &&
        '$head ${tail.join(' ')}'.length > maxAlertTitleLength) {
      tail.removeLast();
    }
    final title = tail.isEmpty ? head : '$head ${tail.join(' ')}';
    // Голова длиннее бюджета (аномально длинный reason) — режем сами, чтобы
    // граница была наша и детерминированная, а не «где придётся» у GlitchTip.
    return title.length <= maxAlertTitleLength
        ? title
        : title.substring(0, maxAlertTitleLength);
  }

  /// Префиксы title видео-сигналов. Notifier роутит в отдельную комнату
  /// «Liza · Видео» ПО ЭТОМУ ПРЕФИКСУ (Sentry-тег через Slack-webhook GlitchTip
  /// до notifier НЕ доезжает — доказано комиссией). Контракт префикса запинен
  /// с обеих сторон: клиент здесь + `servers/monitoring-notifier/test_notifier.py`.
  static const String videoFailurePrefix = '[video-fail]';
  static const String videoSwapPrefix = '[video-swap]';
  static const String videoRebufferPrefix = '[video-rebuffer]';

  /// Собирает title видео-сигнала. host+reason кладутся В TITLE (низкая
  /// кардинальность: ~3 хоста × несколько reason) — так дедуп notifier
  /// `room|title` РАЗЛИЧАЕТ инциденты по хосту сам, без eventId (иначе GlitchTip
  /// расклеит на тысячи issue и утечёт локатор контента). Никаких секретов
  /// (пин `RL-mediadiag-no-secret`): только префикс/reason/host.
  static String videoIssueTitle(String prefix, String reason, String? host) =>
      buildAlertTitle(prefix: prefix, reason: reason, host: host);

  /// Симптом воспроизведения видео (свап на скачивание / устойчивый ребуферинг)
  /// — НЕ исключение. Оконно/сессионно агрегируется на СТОРОНЕ ВЫЗОВА (один
  /// сигнал на сессию плеера, см. `VideoRebufferAggregator` и флаг
  /// `_swapReported` в `video_player.dart`), поэтому здесь троттла нет.
  ///
  /// [prefix] задаёт видео-комнату (роутинг notifier по маркеру); [reason]/[host]
  /// уходят в title (дедуп notifier по инциденту). [context] — НИЗКОкардинальный
  /// контекст (e2ee/mime/size-бакет), тоже в TITLE: только через title он
  /// доезжает и до чата (notifier читает body из title/text), и до дедуп-ключа.
  /// В теги класть бесполезно — Slack-webhook GlitchTip их до notifier не несёт.
  /// Кардинальность контекста держать низкой (бакеты, не сырой size), иначе
  /// GlitchTip расклеит message-issue. Секретов не кладём (пин `RL-mediadiag-no-secret`).
  static void reportVideoIssue({
    required String prefix,
    required String reason,
    String? host,
    Map<String, String> context = const {},
  }) {
    if (!_active) return;
    Sentry.captureMessage(
      buildAlertTitle(
        prefix: prefix,
        reason: reason,
        host: host,
        context: context,
      ),
      level: SentryLevel.warning,
      withScope: (scope) => scope.setTag('liza.category', 'video'),
    );
  }

  /// Префиксы title аудио-сигналов. Notifier роутит их в тот же чат «Liza ·
  /// Медиа» ПО ПРЕФИКСУ `[audio-*]` (как и `[video-*]`; Sentry-тег через
  /// Slack-webhook GlitchTip до notifier не доезжает — доказано комиссией).
  /// Отдельный метод от `reportVideoIssue`, а НЕ общий funnel: у аудио своя
  /// троттл-политика (per-reason окно, [audioIssueThrottleAllows]) — проект
  /// осознанно держит параллельные `reportVideoIssue`/`reportPushIssue`.
  static const String audioFailurePrefix = '[audio-fail]';
  static const String audioTranscriptionFailurePrefix = '[audio-transcription-fail]';

  /// Строит стабильный low-cardinality title аудио-сигнала. host+reason в TITLE
  /// (как у видео) — дедуп notifier `room|title` различает инциденты по хосту
  /// сам. Никаких секретов/локаторов контента: [reason] обязан быть из
  /// ЗАКРЫТОГО перечисления вызывающей стороны (`download-fail`/`source-error`/
  /// `transcription-<kind>`/`autoplay-next-fail`), НЕ `e.toString()` (пин
  /// `RL-mediadiag-no-secret` — иначе в title утёк бы путь temp-файла с mxc id).
  static String audioIssueTitle(String prefix, String reason, String? host) =>
      buildAlertTitle(prefix: prefix, reason: reason, host: host);

  /// Троттл аудио-сигнала per-reason. Обрыв сети рождает поток одинаковых
  /// download/source ошибок по всем открытым аудио-пузырям — без троттла это
  /// лавина в чат «Liza · Медиа». Окно 5 минут per-reason (как
  /// [pushIssueThrottleAllows], но короче — аудио-инциденты чаще). Чистый
  /// (принимает `now`, состояние в статике) — тестируется без `_active`/Sentry.
  static const Duration _audioIssueWindow = Duration(minutes: 5);
  static final Map<String, DateTime> _lastAudioIssueByReason = {};

  @visibleForTesting
  static bool audioIssueThrottleAllows(String reason, DateTime now) {
    final last = _lastAudioIssueByReason[reason];
    if (last != null && now.difference(last) < _audioIssueWindow) return false;
    _lastAudioIssueByReason[reason] = now;
    return true;
  }

  @visibleForTesting
  static void resetAudioIssueThrottle() => _lastAudioIssueByReason.clear();

  /// Симптом сбоя воспроизведения/транскрибации аудио, который видит только
  /// устройство (сервер медиа отдал 200, а плеер не смог). Парный сигнал к
  /// пользовательскому SnackBar'у (принцип «где показана ошибка — там сигнал»).
  ///
  /// [prefix] задаёт семейство ([audioFailurePrefix]/[audioTranscriptionFailurePrefix]);
  /// [reason] — из ЗАКРЫТОГО перечисления (НЕ сырой `e.toString()` — PII);
  /// [host] — хост хоумсервера (не PII); [context] — низкокардинальный контекст
  /// (mime/size-бакет), тоже в TITLE. Троттлится per-reason ([audioIssueThrottleAllows]).
  static void reportAudioIssue({
    required String prefix,
    required String reason,
    String? host,
    Map<String, String> context = const {},
  }) {
    if (!_active) return;
    if (!audioIssueThrottleAllows(reason, DateTime.now())) return;
    Sentry.captureMessage(
      buildAlertTitle(
        prefix: prefix,
        reason: reason,
        host: host,
        context: context,
      ),
      level: SentryLevel.warning,
      withScope: (scope) => scope.setTag('liza.category', 'audio'),
    );
  }

  /// Категории шагов, которые доезжают до справки поддержки. Всё прочее (http с
  /// URL комнат, консоль с текстами, клики с подписями) режется: справку читает
  /// сотрудник, а владелец исключил тексты, имена файлов и собеседников.
  static const Set<String> breadcrumbCategories = {
    // Диагностика mpv из `video_player.dart` — в контекст видео-событий; в
    // справку поддержки не идёт (там свой allowlist сборщика).
    'media_kit',
    'app.lifecycle',
    'nav',
    'send',
    'net',
  };

  @visibleForTesting
  static Breadcrumb? filterBreadcrumb(Breadcrumb? crumb, Hint hint) =>
      crumb != null && breadcrumbCategories.contains(crumb.category)
      ? crumb
      : null;

  /// Шаг пользователя для справки: [category] из [breadcrumbCategories],
  /// [message] — из закрытого перечисления (шаблон маршрута, стадия отправки).
  static void breadcrumb(String category, String message) {
    if (!_active) return;
    Sentry.addBreadcrumb(Breadcrumb(category: category, message: message));
  }

  /// Провал отправки вложений. До 2026-10-19 такие провалы оставались в
  /// `Logs().w` и SnackBar'е — сервер не видел ничего (заявка №54: видео не
  /// уходило, в GlitchTip ноль событий). Префикс `[media-` — notifier роутит его в
  /// «Liza · Медиа» без правки маркеров. Через `captureMessage`, не [capture]:
  /// `_beforeSend` выбрасывает сетевые исключения, а сеть — главный класс провала.
  static const String mediaSendFailurePrefix = '[media-send-fail]';

  static const Duration _mediaSendWindow = Duration(minutes: 5);
  static final Map<String, DateTime> _lastMediaSendByReason = {};

  @visibleForTesting
  static bool mediaSendThrottleAllows(String reason, DateTime now) {
    final last = _lastMediaSendByReason[reason];
    if (last != null && now.difference(last) < _mediaSendWindow) return false;
    _lastMediaSendByReason[reason] = now;
    return true;
  }

  @visibleForTesting
  static void resetMediaSendThrottle() => _lastMediaSendByReason.clear();

  /// Тип набора по mime: `image`/`video`/`audio`/`file`, разнородный — `mixed`.
  static String mediaTypeOf(Iterable<String?> mimes) {
    final types = mimes.map((m) {
      final top = m?.split('/').first;
      return const {'image', 'video', 'audio'}.contains(top) ? top! : 'file';
    }).toSet();
    if (types.isEmpty) return 'file';
    return types.length == 1 ? types.single : 'mixed';
  }

  /// [reason] — стадия (`upload`/`prepare`/`dialog`/`share`), [kind] — класс
  /// причины из `classifySendErrorCause`, [error] — только ради имени типа при
  /// `kind=unknown` (тип, не текст: в тексте пути и mxid).
  @visibleForTesting
  static String mediaSendTitle({
    required String reason,
    required String kind,
    required String media,
    String? host,
    Object? error,
    int? notSent,
    int? total,
  }) => buildAlertTitle(
    prefix: mediaSendFailurePrefix,
    reason: reason,
    host: host,
    context: {
      'kind': kind,
      // При неизвестном классе тип ошибки ценнее типа набора — раньше в бюджете.
      if (kind == 'unknown' && error != null) 'err': _errorTypeName(error),
      'media': media,
      if (notSent != null && total != null) 'n': '$notSent/$total',
    },
  );

  static String _errorTypeName(Object error) {
    final name = error.runtimeType.toString().replaceAll(
      RegExp(r'[^A-Za-z0-9_]'),
      '',
    );
    return name.length > 30 ? name.substring(0, 30) : name;
  }

  static void reportMediaSendFailure({
    required String reason,
    required String kind,
    required String media,
    String? host,
    Object? error,
    int? notSent,
    int? total,
  }) {
    if (!_active) return;
    if (!mediaSendThrottleAllows(reason, DateTime.now())) return;
    Sentry.captureMessage(
      mediaSendTitle(
        reason: reason,
        kind: kind,
        media: media,
        host: host,
        error: error,
        notSent: notSent,
        total: total,
      ),
      level: SentryLevel.warning,
      withScope: (scope) => scope.setTag('liza.category', 'send'),
    );
  }

  /// Префикс title сигналов о сбое пушей КЛИЕНТСКОГО слоя (вторичный к серверному
  /// детектору `analytics.pusher_app_id_dist`, который ловит класс unknown-app-id
  /// из БД Synapse и покрывает killed-app). Notifier роутит `[push-*]` в общий
  /// `ALERT_ROOM` — маркер НЕ зарегистрирован в `route_room` (как `[llm-credits]`).
  /// Контракт префикса запинен с обеих сторон: клиент здесь +
  /// `deploy/grafana/analytics/pusher-health-poller.py` + `monitoring-notifier`.
  static const String pushFailurePrefix = '[push-fail]';

  /// Строит стабильный low-cardinality title клиентского push-сигнала. Только
  /// префикс + reason (техническая метка) — без токена/pushkey/mxid (пин
  /// `RL-mediadiag-no-secret`). Выделено для страж-теста контракта.
  static String pushIssueTitle(String reason) => '$pushFailurePrefix reason=$reason';

  /// Троттл push-сигнала per-reason. `fcm_token_unavailable` иначе повторялся бы
  /// на КАЖДЫЙ resume (>5с) при устройстве без FCM → счётчик issue в GlitchTip
  /// растёт (Matrix-чат защищён дедупом notifier'а 30м, но не GlitchTip). Окно 10м
  /// per-reason: транзиентный `post_pusher_exhausted` тоже не флудит. Чистый
  /// (принимает now, состояние в статике) — тестируется без `_active`/Sentry.
  static const Duration _pushIssueWindow = Duration(minutes: 10);
  static final Map<String, DateTime> _lastPushIssueByReason = {};

  @visibleForTesting
  static bool pushIssueThrottleAllows(String reason, DateTime now) {
    final last = _lastPushIssueByReason[reason];
    if (last != null && now.difference(last) < _pushIssueWindow) return false;
    _lastPushIssueByReason[reason] = now;
    return true;
  }

  /// Симптом сбоя пушей, который знает ТОЛЬКО само устройство (сервер не видит):
  /// [reason] — низкокардинальная техническая метка (`fcm_token_unavailable`,
  /// `post_pusher_exhausted`), БЕЗ токена/pushkey/mxid. Не агрегируется оконно —
  /// события редки (не поток), дедуп notifier'а (`room|title`, 30м) достаточно.
  ///
  /// Honest-gap: работает ТОЛЬКО когда Dart жив (foreground). При убитом
  /// приложении / фоновом FCM-изоляте (`_active` статичен per-isolate → там
  /// всегда false) сигнал слеп — полноту даёт серверный слой, не зависящий от
  /// живости клиента. Звать ТОЛЬКО из foreground-путей.
  ///
  /// [tags] — низкокардинальные детали в теги (latency/decision), НЕ в title:
  /// title — ключ дедупа notifier'а и порога GlitchTip, детали в нём взорвали бы
  /// кардинальность issue.
  static void reportPushIssue(String reason, {Map<String, String>? tags}) {
    if (!_active) return;
    if (!pushIssueThrottleAllows(reason, DateTime.now())) return;
    Sentry.captureMessage(
      pushIssueTitle(reason),
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('liza.category', 'push');
        tags?.forEach(scope.setTag);
      },
    );
  }

  /// Префикс КОНФИГ-сигнала: пуши не сломаны, их выключили настройками
  /// (Matrix push-правила аккаунта / системные настройки ОС). Тот же маркер у
  /// серверного `pusher-health-poller.py`; notifier роутит в общий `ALERT_ROOM`.
  static const String pushConfigPrefix = '[push-config]';

  static String pushConfigTitle(String reason) => '$pushConfigPrefix reason=$reason';

  static const Duration _pushConfigWindow = Duration(hours: 24);

  /// Троттл персистентный (SharedPreferences), а не in-memory, как у
  /// [pushIssueThrottleAllows]: состояние хроническое, а мобильная ОС убивает
  /// процесс — in-memory окно обнулялось бы на каждом холодном старте.
  @visibleForTesting
  static bool pushConfigDue({required DateTime? lastSent, required DateTime now}) =>
      lastSent == null || now.difference(lastSent) >= _pushConfigWindow;

  /// [reason] — закрытый перечень: `default_rule_disabled` (выключено дефолтное
  /// notify-правило, часть чатов без пуша и счётчика), `os_denied` (ОС запретила
  /// уведомления приложению). Инцидент 2026-09-14: оба состояния были у
  /// пользователя, а мониторинг о них не знал. Без PII; кто — видно по
  /// `setUserIdentity` в GlitchTip.
  static Future<void> reportPushConfig(String reason) async {
    if (!_active) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'monitoring.push_config_last_ms.$reason';
      final lastMs = prefs.getInt(key);
      final now = DateTime.now();
      final lastSent = lastMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!pushConfigDue(lastSent: lastSent, now: now)) return;
      await prefs.setInt(key, now.millisecondsSinceEpoch);
      Sentry.captureMessage(
        pushConfigTitle(reason),
        level: SentryLevel.warning,
        withScope: (scope) => scope.setTag('liza.category', 'push'),
      );
    } catch (_) {
      // Сигнал диагностический: ошибка персиста не должна мешать resume.
    }
  }

  /// Префикс title heartbeat живости флота. Notifier ПОДАВЛЯЕТ этот маркер
  /// (в чат не постит) — heartbeat нужен как СЧЁТЧИК живых репортеров в самом
  /// GlitchTip (сколько устройств какой сборки шлют события), а не как алёрт.
  /// Контракт запинен с обеих сторон: клиент здесь + `test_notifier.py`.
  static const String healthPrefix = '[health]';

  /// Пороговый интервал повторного heartbeat в пределах ОДНОЙ сборки. Ключ
  /// троттла — номер сборки: смена сборки эмитит heartbeat НЕМЕДЛЕННО (иначе
  /// liveness молчал бы ровно после раската нового релиза, где он критичнее
  /// всего — прокурорский KILLER-5). В пределах той же сборки — не чаще окна.
  static const Duration _healthWindow = Duration(hours: 20);

  /// Ключи персиста троттла heartbeat в SharedPreferences.
  static const String _healthLastBuildKey = 'monitoring.health_last_build';
  static const String _healthLastSentKey = 'monitoring.health_last_sent_ms';

  /// Чистый детектор «пора ли слать heartbeat»: другая сборка → всегда да;
  /// та же сборка → только если прошло окно. Тестируется без SharedPreferences.
  @visibleForTesting
  static bool healthHeartbeatDue({
    required int? lastBuild,
    required DateTime? lastSent,
    required int currentBuild,
    required DateTime now,
  }) {
    if (lastBuild != currentBuild) return true;
    if (lastSent == null) return true;
    return now.difference(lastSent) >= _healthWindow;
  }

  /// ВТОРИЧНЫЙ liveness-сигнал: раз в сборку/окно шлёт `[health] build=N env=E`.
  /// Первичный liveness — серверный поллер, не зависящий от раскатки сборки.
  /// Персист троттла — SharedPreferences ЛЕНИВО (НЕ в `init()`, чтобы не
  /// блокировать инициализацию). No-op без мониторинга. Ошибки персиста глотаем
  /// (heartbeat — не критичный путь).
  static Future<void> reportHealthHeartbeat() async {
    if (!_active) return;
    try {
      final info = await PackageInfo.fromPlatform();
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;
      final prefs = await SharedPreferences.getInstance();
      final lastBuild = prefs.getInt(_healthLastBuildKey);
      final lastSentMs = prefs.getInt(_healthLastSentKey);
      final lastSent = lastSentMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(lastSentMs);
      final now = DateTime.now();
      if (!healthHeartbeatDue(
        lastBuild: lastBuild,
        lastSent: lastSent,
        currentBuild: currentBuild,
        now: now,
      )) {
        return;
      }
      Sentry.captureMessage(
        '$healthPrefix build=$currentBuild env=${AppConfig.monitoringEnv}',
        level: SentryLevel.info,
        withScope: (scope) => scope.setTag('liza.category', 'health'),
      );
      await prefs.setInt(_healthLastBuildKey, currentBuild);
      await prefs.setInt(_healthLastSentKey, now.millisecondsSinceEpoch);
    } catch (e) {
      // Heartbeat не критичен: сбой package_info/prefs не должен ронять старт.
      return;
    }
  }

  /// Title суточного отчёта о пушах с устройства. Под маркером `[health]` —
  /// notifier его глушит (`is_health`), в чат он не идёт: это данные для
  /// сравнения когорт, а не алёрт.
  ///
  /// ⚠️ В title НЕЛЬЗЯ писать `env=`: `fleet-health-poller.py` ищет живость
  /// флота как `title LIKE '[health]%' AND title LIKE '%env=prod%'`, и
  /// ежедневный отчёт замаскировал бы пропажу heartbeat. Окружение — тегом
  /// `liza.env`. Страж — `RL-push-health-report` (обе стороны).
  @visibleForTesting
  static String pushReportTitle(String platform) =>
      '$healthPrefix push-report platform=$platform';

  static const Duration _pushReportWindow = Duration(hours: 24);
  static const String _pushReportLastKey = 'monitoring.push_report_last_ms';

  /// Потолок хвоста журнала в `extra`: события GlitchTip до ~56 КБ лежат целиком,
  /// но отчёт шлётся с каждого устройства — держим запас.
  static const int pushReportTailBytes = 24 * 1024;

  static const String pushReportContextKey = 'push_report';

  /// Ключи тегов когорты — закрытый словарь (AC-11): по ним сервер группирует
  /// устройства «версия ОС × модель × стиль баннера × копии приложения».
  static const Set<String> pushReportTagKeys = {
    'liza.env',
    'liza.build',
    'liza.bundle',
    'liza.device_id',
    'liza.accounts',
    'liza.os_version',
    'liza.lifecycle',
    'liza.auth',
    'liza.alert',
    'liza.alert_style',
    'liza.badge_setting',
    'liza.sound_setting',
    'liza.nc_setting',
    'liza.app_copies',
    'liza.legacy_copies',
    'liza.running_copies',
    'liza.install_location',
  };

  static const int _tagValueMax = 32;

  /// Оставить только ключи словаря и обрезать значения — свободный текст в
  /// теги не просочится, кардинальность ограничена.
  @visibleForTesting
  static Map<String, String> sanitizePushReportTags(Map<String, String> raw) => {
    for (final e in raw.entries)
      if (pushReportTagKeys.contains(e.key) && e.value.isNotEmpty)
        e.key: e.value.length > _tagValueMax
            ? e.value.substring(0, _tagValueMax)
            : e.value,
  };

  @visibleForTesting
  static bool pushReportDue({required DateTime? lastSent, required DateTime now}) =>
      lastSent == null || now.difference(lastSent) >= _pushReportWindow;

  /// Пора ли собирать отчёт — дешёвая проверка ДО нативных проб (их не дёргаем
  /// на каждом resume).
  static Future<bool> pushReportIsDue() async {
    if (!_active) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_pushReportLastKey);
      return pushReportDue(
        lastSent: lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs),
        now: DateTime.now(),
      );
    } catch (_) {
      return false;
    }
  }

  /// Суточный отчёт о пути уведомлений с устройства: теги когорты + счётчики
  /// журнала + хвост журнала (только hash8, без текста). Отметка времени
  /// пишется ДО отправки: сбой capture не должен давать повтор в том же окне.
  ///
  /// [send] — точка подмены для стража (по умолчанию `Sentry.captureMessage`).
  static Future<bool> reportPushHealth({
    required String platform,
    required Map<String, String> tags,
    required Map<String, num> counters,
    required String journalTail,
    DateTime? now,
    @visibleForTesting
    void Function(String title, Map<String, String> tags, Map<String, Object> extra)?
        send,
    @visibleForTesting bool force = false,
  }) async {
    if (!_active && send == null) return false;
    try {
      final at = now ?? DateTime.now();
      final prefs = await SharedPreferences.getInstance();
      final lastMs = prefs.getInt(_pushReportLastKey);
      final lastSent = lastMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastMs);
      if (!force && !pushReportDue(lastSent: lastSent, now: at)) return false;
      await prefs.setInt(_pushReportLastKey, at.millisecondsSinceEpoch);
      final cleanTags = sanitizePushReportTags(tags);
      final extra = <String, Object>{...counters, 'journal': journalTail};
      final title = pushReportTitle(platform);
      if (send != null) {
        send(title, cleanTags, extra);
        return true;
      }
      // Теги и данные — в самом событии, а не в scope: scope синхронизируется в
      // нативный SDK, и хвост журнала прилип бы ко всем последующим событиям.
      // Данные — контекстом `push_report` (`extra` в SDK объявлен устаревшим);
      // GlitchTip хранит contexts целиком, сервер читает
      // `data->'contexts'->'push_report'`.
      await Sentry.captureEvent(
        SentryEvent(
          message: SentryMessage(title),
          level: SentryLevel.info,
          tags: {'liza.category': 'push-report', ...cleanTags},
          contexts: Contexts()..[pushReportContextKey] = extra,
        ),
      );
      return true;
    } catch (_) {
      // Отчёт диагностический — не мешает resume/старту.
      return false;
    }
  }

  /// Оконный агрегатор дрейфа бейджа — один сигнал за окно (captureMessage без
  /// троттла залил бы GlitchTip потоком на каждый sync).
  static final BadgeDriftAggregator _badgeDrift = BadgeDriftAggregator();

  /// Оконный агрегатор РАСХОЖДЕНИЯ РЕНДЕРА бейджа — зеркало [_badgeDrift].
  static final BadgeMismatchAggregator _badgeMismatch = BadgeMismatchAggregator();

  /// Префикс title сигнала о расхождении рендера бейджа. Отдельный маркер от
  /// `[video-/audio-/media-]` — своя комната «Liza · Бейдж» (notifier роутит по
  /// `[badge-mismatch]`). Платформа — В TITLE (низкая кардинальность ios/macos
  /// для дедупа `room|title`), числа expected/shown — в теги (PII нет). Контракт
  /// запинен с обеих сторон: клиент здесь + `servers/monitoring-notifier`.
  static const String badgeMismatchPrefix = '[badge-mismatch]';

  /// Стабильный low-cardinality title: префикс + платформа. Числа НЕ в title
  /// (иначе GlitchTip расклеит issue по каждому значению) — они в тегах.
  static String badgeMismatchTitle(String platform) =>
      '$badgeMismatchPrefix platform=$platform';

  /// Итог чистки комнат-призраков (`ghost_room_prune.dart`). Шлётся только
  /// когда кандидаты были: ноль удалений при кандидатах тоже сигнал, а
  /// `aborted` = сработал предохранитель — смотреть руками. Только числа:
  /// id комнат — ПД переписки.
  static void reportGhostRooms({
    required int candidates,
    required int probed,
    required int removed,
    required bool aborted,
    bool resynced = false,
  }) {
    if (!_active) return;
    Sentry.captureMessage(
      '[ghost-room] removed=$removed aborted=$aborted resync=$resynced',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('ghost_candidates', '$candidates');
        scope.setTag('ghost_probed', '$probed');
        scope.setTag('ghost_removed', '$removed');
        scope.setTag('ghost_aborted', '$aborted');
        scope.setTag('ghost_resync', '$resynced');
      },
    );
  }

  /// Наблюдение дрейфа бейджа (ВТОРИЧНЫЙ, human-facing сигнал): серверное
  /// push-payload `counts.unread` против пост-sync СЫРОГО серверного числа
  /// непрочитанных комнат ([postSyncRaw] = комнаты с notificationCount>0 +
  /// приглашения, НЕ topology-filtered — иначе поймали бы штатный зазор скрытых
  /// комнат). Расхождение = симптом серверной грязи `event_push_summary` (корень
  /// накопительной инфляции бейджа). Только числа — PII не уходит. Оконно
  /// агрегируется (как sync-таймауты). No-op без мониторинга / при drift < порога.
  ///
  /// Honest-gap: ловится только когда Dart жив (foreground/alive-push). При
  /// полностью закрытом приложении бейдж пишет NSE/native и сигнал слеп —
  /// первичный источник полноты — серверный view `analytics.push_summary_drift`.
  static void reportBadgeDrift({
    required int pushUnread,
    required int postSyncRaw,
    DateTime? now,
  }) {
    if (!_active) return;
    final flushed = _badgeDrift.observe(pushUnread, postSyncRaw, now ?? DateTime.now());
    if (flushed == null || flushed.count == 0) return;
    Sentry.captureMessage(
      'Badge count drift',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('drift_events', '${flushed.count}');
        scope.setTag('drift_max', '${flushed.maxDrift}');
      },
    );
  }

  /// Наблюдение РАСХОЖДЕНИЯ РЕНДЕРА бейджа (симптом, который знает ТОЛЬКО
  /// устройство): [expected] — клиент-авторитетное `AppBadge.visibleUnreadCount`;
  /// [shown] — то, что платформа реально держит на иконке (`FlutterNewBadger
  /// .getBadge()` = applicationIconBadgeNumber на iOS, dockTile-слой на macOS).
  /// Расхождение = бейдж на иконке разъехался с клиентским счётом (залипшая «N»,
  /// не снявшийся badge, или наоборот пусто при непрочитанных). Только числа —
  /// PII не уходит. Оконно агрегируется.
  ///
  /// [shown] == null (getBadge вернул null / бейдж запрещён) → НЕ сигнал:
  /// read-back невозможен, расхождение неизмеримо. Вызывающая сторона обязана
  /// пропускать null-read (см. background_push.updateBadgeCount).
  ///
  /// Honest-gap: ловится только когда Dart жив (foreground). При закрытом
  /// приложении иконку двигает NSE/native — сигнал слеп. Первичная полнота у
  /// серверного view `analytics.push_summary_drift`.
  static void reportBadgeRenderMismatch({
    required int expected,
    required int? shown,
    DateTime? now,
  }) {
    if (!_active) return;
    if (shown == null) return;
    final flushed =
        _badgeMismatch.observe(expected, shown, now ?? DateTime.now());
    if (flushed == null || flushed.count == 0) return;
    final platform =
        Platform.isIOS ? 'ios' : (Platform.isMacOS ? 'macos' : 'other');
    Sentry.captureMessage(
      badgeMismatchTitle(platform),
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('liza.category', 'badge');
        scope.setTag('mismatch_events', '${flushed.count}');
        scope.setTag('mismatch_max_delta', '${flushed.maxDelta}');
        scope.setTag('mismatch_last_expected', '${flushed.lastExpected}');
        scope.setTag('mismatch_last_shown', '${flushed.lastShown}');
      },
    );
  }

  /// Заголовок generic-catch sync-цикла matrix SDK 4.1.0 (client.dart:2496),
  /// под которым TimeoutException из `/sync` доходит до моста. При апгрейде
  /// SDK сверить, что строка не изменилась — иначе агрегация молча отвалится.
  static const String _sdkSyncErrorTitle = 'Error during processing events';

  /// Агрегат sync-таймаутов: одно warning-сообщение за окно с разбивкой
  /// foreground/background вместо потока error-событий. Деградация Synapse
  /// выглядит как высокий foreground-счёт у многих устройств одновременно;
  /// фоновые — штатная заморозка процесса iOS. Хвост последнего окна при
  /// убийстве процесса теряется — приемлемо для warning-телеметрии.
  static const Duration _syncTimeoutWindow = Duration(minutes: 10);
  static DateTime? _syncTimeoutWindowStart;
  static int _syncTimeoutFg = 0;
  static int _syncTimeoutBg = 0;

  static void _countSyncTimeout() {
    final now = DateTime.now();
    final start = _syncTimeoutWindowStart;
    if (start != null && now.difference(start) >= _syncTimeoutWindow) {
      _flushSyncTimeouts();
    }
    _syncTimeoutWindowStart ??= now;
    final state = WidgetsBinding.instance.lifecycleState;
    // null = lifecycle ещё неизвестен (ранний старт) — считаем foreground,
    // чтобы не занижать «подозрительную» часть сигнала.
    if (state == null || state == AppLifecycleState.resumed) {
      _syncTimeoutFg++;
    } else {
      _syncTimeoutBg++;
    }
  }

  static void _flushSyncTimeouts() {
    final fg = _syncTimeoutFg;
    final bg = _syncTimeoutBg;
    _syncTimeoutFg = 0;
    _syncTimeoutBg = 0;
    _syncTimeoutWindowStart = null;
    if (fg + bg == 0) return;
    // Текст константный: GlitchTip группирует message-события по тексту,
    // вся вариативность — только в тегах.
    Sentry.captureMessage(
      'Sync timeouts in 10m window',
      level: SentryLevel.warning,
      withScope: (scope) {
        scope.setTag('timeout_total', '${fg + bg}');
        scope.setTag('timeout_foreground', '$fg');
        scope.setTag('timeout_background', '$bg');
      },
    );
  }

  /// Строит `SentryUser` из Matrix ID пострадавшего. ЧИСТАЯ функция (тестируется
  /// без Sentry/`_active`): `id` = полный mxid (@localpart:server), `username` =
  /// localpart (синхронный разбор, без сетевого fetchOwnProfile — логин не
  /// блокируем), `name` = display name (best-effort, обычно null на этом слое).
  ///
  /// localpart из `@localpart:server`: берём между `@` и первым `:`. Для
  /// невалидного mxid (нет `@`/`:`) — как есть, чтобы не терять идентификатор.
  @visibleForTesting
  static SentryUser buildSentryUser(String matrixUserId, {String? displayName}) {
    var localpart = matrixUserId;
    if (localpart.startsWith('@')) localpart = localpart.substring(1);
    final colon = localpart.indexOf(':');
    if (colon >= 0) localpart = localpart.substring(0, colon);
    return SentryUser(
      id: matrixUserId,
      username: localpart,
      name: displayName,
    );
  }

  /// Прикрепляет ЛИЧНОСТЬ пользователя к событиям в self-hosted GlitchTip, чтобы
  /// владелец мог узнать, КОМУ писать «перепроверь» по медиа-сбою (`[video-*]`/
  /// `[audio-*]`/`[media-*]`). Кладёт реальный mxid + localpart в scope-user.
  ///
  /// ⚠️ Осознанное снятие прежнего инварианта hash-only (был `setUserHash` →
  /// sha256): личность НУЖНА для контакта с пострадавшим. Безопасно, потому что:
  /// (1) GlitchTip self-hosted (за auth, периметр владельца); (2) `SentryUser`
  /// живёт в scope события, а НЕ в `captureMessage(title)` — а в чат «Liza ·
  /// Медиа» notifier перекладывает ТОЛЬКО title/body/url/env (webhook GlitchTip),
  /// scope-user туда физически не доезжает. То есть mxid виден в GlitchTip UI
  /// (секция Users), но в чат НЕ утекает. `sendDefaultPii=false` явный setUser НЕ
  /// режет — это намеренно. Причина снятия инварианта — реестр
  /// `RL-video-playback-monitoring-signal` + `howItWoks/monitoring/videoMonitoring.md`.
  ///
  /// Глобальный scope (как было у `setUserHash`): при типичном одном аккаунте
  /// корректно. Мультиаккаунт (последний логин перебивает scope-user) —
  /// per-event атрибуция через `withScope` вынесена в FU-3.
  static void setUserIdentity(String matrixUserId, {String? displayName}) {
    if (!_active) return;
    Sentry.configureScope(
      (scope) => scope.setUser(buildSentryUser(matrixUserId, displayName: displayName)),
    );
  }

  static void clearUser() {
    if (!_active) return;
    Sentry.configureScope((scope) => scope.setUser(null));
  }

  /// Что выставить в scope по списку залогиненных аккаунтов. ЧИСТАЯ функция
  /// для стража: `user` — первый аккаунт (основной), остальное — теги.
  @visibleForTesting
  static ({SentryUser? user, Map<String, String> tags}) identityFor(
    List<({String userId, String? deviceId})> accounts,
  ) {
    if (accounts.isEmpty) return (user: null, tags: const {});
    final primary = accounts.first;
    return (
      user: buildSentryUser(primary.userId),
      tags: {
        'liza.accounts': '${accounts.length}',
        if (primary.deviceId != null) 'liza.device_id': primary.deviceId!,
      },
    );
  }

  /// Идемпотентная атрибуция: зовётся на старте для ВСЕХ восстановленных
  /// сессий и на каждую смену состава аккаунтов.
  ///
  /// Почему не через `handleLoginStateChange`: подписка восстановленных
  /// клиентов идёт с `replayCachedLoggedIn=false` (go_router не переносит
  /// спонтанный redirect на старте), поэтому `loggedIn` у них не приходит
  /// никогда — и до 2026-10-16 у 98% событий GlitchTip не было пользователя
  /// (61 из 3650 за 14 дней).
  static void syncIdentity(List<({String userId, String? deviceId})> accounts) {
    if (!_active) return;
    final identity = identityFor(accounts);
    Sentry.configureScope((scope) {
      scope.setUser(identity.user);
      for (final key in const ['liza.accounts', 'liza.device_id']) {
        if (!identity.tags.containsKey(key)) scope.removeTag(key);
      }
      for (final e in identity.tags.entries) {
        scope.setTag(e.key, e.value);
      }
    });
  }

  /// Фильтрация события перед отправкой: отбрасываем сетевые/IO-исключения
  /// и шумные ошибки файлового кэша (matrix SDK TOCTOU race).
  static FutureOr<SentryEvent?> _beforeSend(SentryEvent event, Hint hint) {
    // Геттер throwable сам разворачивает ThrowableMechanism до исходного
    // исключения — `is`-проверки работают без доппреобразований.
    final throwable = event.throwable;
    if (throwable == null) return event;

    if (_isNetworkError(throwable)) return null;

    if (_isFileCacheNoise(throwable, event)) return null;

    return event;
  }

  /// [PathNotFoundException] (iOS чистит Library/Caches/ между dir.list() и
  /// file.delete()) и [PathAccessException] (Windows: файл кэша залочен другим
  /// процессом, errno 32) из deleteOldFiles/deleteFile/getFile/storeFile —
  /// шумовой TOCTOU-класс файл-кэша. SafeDatabaseApi перехватывает оба, но на
  /// случай если исключение пролетит мимо — фильтруем и здесь.
  static bool _isFileCacheNoise(Object throwable, SentryEvent event) {
    if (throwable is! PathNotFoundException &&
        throwable is! PathAccessException) {
      return false;
    }
    final frames = event.exceptions
        ?.expand((e) => e.stackTrace?.frames ?? <SentryStackFrame>[]);
    if (frames == null) return false;
    return frames.any(
      (f) =>
          f.function != null &&
          (f.function!.contains('deleteOldFiles') ||
              f.function!.contains('deleteFile') ||
              f.function!.contains('getFile') ||
              f.function!.contains('storeFile')) &&
          (f.absPath?.contains('database_file_storage') ?? false),
    );
  }
}

/// Оконный агрегатор дрейфа бейджа — ЧИСТЫЙ и тестируемый (принимает `now`,
/// состояние держит сам, эмит — через возвращаемое значение, без зависимости от
/// Sentry). Один сигнал за окно вместо потока на каждый sync.
///
/// Порог 2: диагностика 2026-08-14 нашла 13 застрявших комнат — реальный дрейф
/// исчисляется единицами-десятками, а не «1»; ниже порога — штатная
/// рассинхронизация момента открытия приложения. Хвост последнего окна при
/// убийстве процесса теряется — приемлемо для warning-телеметрии (как sync-таймауты).
class BadgeDriftAggregator {
  BadgeDriftAggregator({
    this.threshold = 2,
    this.window = const Duration(minutes: 10),
  });

  final int threshold;
  final Duration window;

  DateTime? _windowStart;
  int _count = 0;
  int _maxDrift = 0;

  /// Сколько наблюдений дрейфа накоплено в текущем (ещё не сброшенном) окне.
  @visibleForTesting
  int get pendingCount => _count;

  /// Чистый детектор: величина дрейфа = серверное − клиентское сырое. ≤0 — дрейфа
  /// нет (клиент считающий МЕНЬШЕ сервера — не патология, это и есть цель фикса).
  static int amount(int pushUnread, int postSyncRaw) => pushUnread - postSyncRaw;

  /// Зарегистрировать наблюдение. Возвращает payload `(count, maxDrift)`, когда
  /// истёкшее окно надо ЭМИТИТЬ (первое наблюдение нового окна сбрасывает
  /// предыдущее), иначе null. Наблюдение с `drift < threshold` игнорируется, но
  /// сброс истёкшего окна всё равно происходит.
  ({int count, int maxDrift})? observe(
    int pushUnread,
    int postSyncRaw,
    DateTime now,
  ) {
    ({int count, int maxDrift})? flushed;
    final start = _windowStart;
    if (start != null && now.difference(start) >= window) {
      flushed = (count: _count, maxDrift: _maxDrift);
      _count = 0;
      _maxDrift = 0;
      _windowStart = null;
    }
    final drift = amount(pushUnread, postSyncRaw);
    if (drift < threshold) return flushed;
    _windowStart ??= now;
    _count++;
    if (drift > _maxDrift) _maxDrift = drift;
    return flushed;
  }
}

/// Оконный агрегатор РАСХОЖДЕНИЯ РЕНДЕРА бейджа — ЧИСТЫЙ и тестируемый (принимает
/// `now`, состояние держит сам, эмит через возвращаемое значение). Зеркало
/// [BadgeDriftAggregator]. Один сигнал за окно вместо потока на каждый sync.
/// threshold=1: любое подтверждённое расхождение iconBadge↔expected — уже дефект
/// (в отличие от серверного drift, где ниже 2 — штатный зазор момента открытия;
/// read-back-расхождение штатного зазора не имеет).
class BadgeMismatchAggregator {
  BadgeMismatchAggregator({
    this.threshold = 1,
    this.window = const Duration(minutes: 20),
  });

  final int threshold;
  final Duration window;

  DateTime? _windowStart;
  int _count = 0;
  int _maxDelta = 0;
  int _lastExpected = 0;
  int _lastShown = 0;

  @visibleForTesting
  int get pendingCount => _count;

  /// |expected − shown|: величина расхождения рендера. 0 — рендер совпал.
  static int delta(int expected, int shown) => (expected - shown).abs();

  /// Зарегистрировать наблюдение. Возвращает payload, когда истёкшее окно надо
  /// ЭМИТИТЬ (первое наблюдение нового окна сбрасывает предыдущее), иначе null.
  /// Наблюдение с `delta < threshold` (совпало) игнорируется, но сброс истёкшего
  /// окна всё равно происходит.
  ({int count, int maxDelta, int lastExpected, int lastShown})? observe(
    int expected,
    int shown,
    DateTime now,
  ) {
    ({int count, int maxDelta, int lastExpected, int lastShown})? flushed;
    final start = _windowStart;
    if (start != null && now.difference(start) >= window) {
      flushed = (
        count: _count,
        maxDelta: _maxDelta,
        lastExpected: _lastExpected,
        lastShown: _lastShown,
      );
      _count = 0;
      _maxDelta = 0;
      _windowStart = null;
    }
    final d = delta(expected, shown);
    if (d < threshold) return flushed;
    _windowStart ??= now;
    _count++;
    if (d > _maxDelta) _maxDelta = d;
    _lastExpected = expected;
    _lastShown = shown;
    return flushed;
  }
}
