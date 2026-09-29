import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:fcm_shared_isolate/fcm_shared_isolate.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_new_badger/flutter_new_badger.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:unifiedpush/unifiedpush.dart';
import 'package:unifiedpush_ui/unifiedpush_ui.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/main.dart';
import 'package:liza/utils/apns_push_service.dart';
import 'package:liza/utils/app_badge.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/notification_background_handler.dart';
import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/push_helper.dart';
import 'package:liza/utils/push_tap_navigation.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/widgets/liza_app.dart';
import '../config/app_config.dart';
import '../config/setting_keys.dart';
import '../widgets/matrix.dart';
import 'platform_infos.dart';

class NoTokenException implements Exception {
  String get cause => 'Cannot get firebase token';
}

class BackgroundPush {
  static BackgroundPush? _instance;
  final FlutterLocalNotificationsPlugin _flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  /// Все залогиненные клиенты устройства (мультиаккаунт). Pusher регистрируется
  /// для КАЖДОГО, входящий пуш/тап маршрутизируется по `client_name`
  /// (`push_client_resolver.dart`). Живой список — из `MatrixState`, в
  /// background-fetch режиме — снимок из `ClientManager`.
  final List<Client> _clients;
  List<Client> get clients => matrix?.widget.clients ?? _clients;

  /// Бейдж-клиент: ОДИН фиксированный писатель числа на иконке/App Group
  /// (первый в списке), чтобы при мультиаккаунте бейдж не мигал между
  /// аккаунтами. Сохраняет имя `client` для единственного аккаунта.
  Client get client => clients.first;
  MatrixState? matrix;
  String? _fcmToken;
  void Function(String errorMsg, {Uri? link})? onFcmError;
  L10n? l10n;

  Future<void> loadLocale() async {
    final context = matrix?.context;
    // inspired by _lookupL10n in .dart_tool/flutter_gen/gen_l10n/l10n.dart
    l10n ??=
        (context != null ? L10n.of(context) : null) ??
        (await L10n.delegate.load(PlatformDispatcher.instance.locale));
  }

  final pendingTests = <String, Completer<void>>{};
  bool firebaseEnabled = false;

  /// Признак того, что пушер успешно зарегистрирован на homeserver-е (либо был
  /// уже корректно настроен ранее) — per-client (ключ `clientName`), т.к. при
  /// мультиаккаунте pusher у каждого аккаунта свой. Используется hook-ом на
  /// resume в `MatrixState.didChangeAppLifecycleState`, чтобы не дёргать
  /// `setupPush()` после холодного старта, где регистрация уже прошла.
  final Map<String, bool> pusherRegisteredByClient = {};

  /// Все залогиненные клиенты зарегистрированы (агрегат для мониторинга
  /// `[push-config] no_pusher` и resume-хука).
  bool get pusherRegistered => clients
      .where((c) => c.isLogged())
      .every((c) => pusherRegisteredByClient[c.clientName] == true);
  set pusherRegistered(bool value) {
    for (final c in clients) {
      pusherRegisteredByClient[c.clientName] = value;
    }
  }

  /// Время последнего вызова `setupPush()`. Защита от частых повторных
  /// вызовов из lifecycle-хука (например, быстрые resume/pause).
  DateTime? _lastSetupPushAt;

  // On iOS/macOS use native APNs/no-FCM, on Android keep FCM
  final firebase = (Platform.isIOS || Platform.isMacOS) ? null : FcmSharedIsolate();
  final apns = (Platform.isIOS || Platform.isMacOS) ? ApnsPushService() : null;

  DateTime? lastReceivedPush;

  bool upAction = false;

  void _init() async {
    firebaseEnabled = true;
    try {
      mainIsolateReceivePort?.listen((message) async {
        try {
          await notificationTap(
            NotificationResponseJson.fromJsonString(message),
            clients: clients,
            onClientResolved: _activateClient,
            router: LizaApp.router,
            l10n: l10n,
          );
        } catch (e, s) {
          Logs().wtf('Main Notification Tap crashed', e, s);
        }
      });
      if (PlatformInfos.isAndroid) {
        final port = ReceivePort();
        IsolateNameServer.removePortNameMapping('background_tab_port');
        IsolateNameServer.registerPortWithName(
          port.sendPort,
          'background_tab_port',
        );
        port.listen((message) async {
          try {
            await notificationTap(
              NotificationResponseJson.fromJsonString(message),
              clients: clients,
              onClientResolved: _activateClient,
              router: LizaApp.router,
              l10n: l10n,
            );
          } catch (e, s) {
            Logs().wtf('Main Notification Tap crashed', e, s);
          }
        });
      }
      await _flutterLocalNotificationsPlugin.initialize(
        InitializationSettings(
          android: const AndroidInitializationSettings('notifications_icon'),
          iOS: DarwinInitializationSettings(
            // В E2E/local (`APP_ENV=local`) НЕ запрашиваем разрешение на
            // уведомления — иначе `initialize()` показывает нативный iOS-диалог
            // «разрешение на уведомления» на старте, а device-flow (flutter
            // tester/simctl/AX) его не тапает и прогон виснет на онбординге.
            // В проде `isLocal` — compile-time false → поведение байт-в-байт
            // прежнее (push не затрагивается).
            requestSoundPermission: !AppConfig.isLocal,
            requestAlertPermission: !AppConfig.isLocal,
            requestBadgePermission: !AppConfig.isLocal,
            defaultPresentSound: true,
            defaultPresentAlert: true,
            defaultPresentBadge: true,
            defaultPresentBanner: true,
            defaultPresentList: true,
          ),
          macOS: DarwinInitializationSettings(
            // Тот же гейт, что iOS: в E2E/local не показываем нативный
            // notif-диалог (вешает `flutter run -d macos --APP_ENV=local` и
            // device-flow). Прод — isLocal compile-time false.
            requestSoundPermission: !AppConfig.isLocal,
            requestAlertPermission: !AppConfig.isLocal,
            requestBadgePermission: !AppConfig.isLocal,
            defaultPresentSound: true,
            defaultPresentAlert: true,
            defaultPresentBadge: true,
            defaultPresentBanner: true,
            defaultPresentList: true,
          ),
          windows: WindowsInitializationSettings(
            appName: AppSettings.applicationName.value,
            appUserModelId: AppConfig.appId,
            guid: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
          ),
        ),
        onDidReceiveNotificationResponse: (response) => notificationTap(
          response,
          clients: clients,
          onClientResolved: _activateClient,
          router: LizaApp.router,
          l10n: l10n,
        ),
        onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
      );
      Logs().v('Flutter Local Notifications initialized');
      if (Platform.isIOS || Platform.isMacOS) {
        apns!.setListeners(
          onMessage: (message) => unawaited(handleApnsMessage(message)),
          nativeBannerGate: nativeBannerGate,
          onNotificationTap: (Platform.isIOS || Platform.isMacOS)
              ? (roomId, eventId, clientName) => nativeNotificationTap(
                    roomId: roomId,
                    eventId: eventId,
                    clientName: clientName,
                  )
              : null,
        );
      } else if (Platform.isAndroid) {
        firebase?.setListeners(
          onMessage: (message) {
            final raw = Map<String, dynamic>.from(message['data'] ?? message);
            unawaited(pushHelper(
              PushNotification.fromJson(raw),
              clients: clients,
              clientName: pushClientNameFromRaw(raw),
              l10n: l10n,
              activeRoomId: matrix?.activeRoomId,
              activeClientName: matrix?.client.clientName,
              flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
            ));
          },
          onNewToken: onFcmTokenRefresh,
        );
      }
      if (Platform.isAndroid) {
        await UnifiedPush.initialize(
          onNewEndpoint: _newUpEndpoint,
          onRegistrationFailed: (_, i) => _upUnregistered(i),
          onUnregistered: _upUnregistered,
          onMessage: _onUpMessage,
        );
      }
    } catch (e, s) {
      Logs().e('Unable to initialize Flutter local notifications', e, s);
    }
  }

  BackgroundPush._(this._clients) {
    _init();
  }

  /// Экземпляр БЕЗ платформенной инициализации (плагин уведомлений, порты
  /// изолята, listeners) — для host-тестов регистрации pusher-ов
  /// (`RL-push-multiaccount-pusher-per-client`). Не singleton.
  @visibleForTesting
  BackgroundPush.forTest(this._clients);

  factory BackgroundPush.clientOnly(List<Client> clients) {
    return _instance ??= BackgroundPush._(clients);
  }

  factory BackgroundPush(
    MatrixState matrix, {
    final void Function(String errorMsg, {Uri? link})? onFcmError,
  }) {
    final instance = BackgroundPush.clientOnly(matrix.widget.clients);
    instance.matrix = matrix;
    // ignore: prefer_initializing_formals
    instance.onFcmError = onFcmError;
    return instance;
  }

  /// Exposes the initialized [FlutterLocalNotificationsPlugin] for use by
  /// other parts of the app (e.g. macOS local notifications).
  FlutterLocalNotificationsPlugin get localNotificationsPlugin =>
      _flutterLocalNotificationsPlugin;

  int? _lastBadgeCount;

  /// Тап по уведомлению чужого (неактивного) аккаунта: переключаем активный
  /// клиент ДО навигации — экраны чата/StoryViewer читают
  /// `Matrix.of(context).client` (образец `local_notifications_extension.dart`).
  void _activateClient(Client target) {
    final m = matrix;
    if (m == null) return;
    if (identical(m.client, target)) return;
    m.setActiveClient(target);
  }

  /// Recalculates and updates the app icon badge count from current room state.
  /// Called after sync to keep badge in sync across devices.
  Future<void> updateBadgeCount() async {
    if (!Platform.isIOS && !Platform.isMacOS && !Platform.isAndroid) return;
    // См. AppBadge.refreshFrom: порядок квитанции досчитывается до подсчёта.
    await UnseenOrderCache.reconcile(client);
    final unreadCount =
        client.rooms.where((room) => room.countsTowardAppBadge).length;
    await AppBadge.trySet(unreadCount);

    // Read-back рендера бейджа: сверяем клиент-авторитетное число с тем, что
    // платформа РЕАЛЬНО держит на иконке. Ловит класс «Dart посчитал N — на
    // иконке M» (залипшая метка, не снявшийся badge), невидимый серверному
    // reportBadgeDrift. Best-effort, оконно агрегируется в Monitoring.
    if (Platform.isIOS || Platform.isMacOS) {
      unawaited(_reportBadgeRenderMismatch(unreadCount));
    }

    // При переходе к нулю видимых непрочитанных снимаем и остаточные
    // доставленные уведомления: на macOS/iOS оставшаяся запись в Центре
    // уведомлений может заново нативно посадить бейдж в обход Dart. Делаем
    // только на смене счётчика, чтобы не дёргать cancelAll на каждый sync.
    if (unreadCount != _lastBadgeCount) {
      _lastBadgeCount = unreadCount;
      // При мультиаккаунте ноль у бейдж-клиента ≠ ноль у всех: cancelAll снёс бы
      // уведомления соседнего аккаунта.
      final zeroEverywhere = clients.every(
        (c) => c.rooms.where((room) => room.countsTowardAppBadge).isEmpty,
      );
      if (zeroEverywhere && (Platform.isIOS || Platform.isMacOS)) {
        await _flutterLocalNotificationsPlugin.cancelAll();
      }
    }
  }

  /// Сверяет ожидаемый бейдж с фактическим applicationIconBadgeNumber (iOS) /
  /// dockTile (macOS) через read-back и репортит расхождение в мониторинг.
  /// getBadge()==null или бейдж запрещён юзером — пропуск (read-back невозможен).
  /// macOS: dockTile выставляется через DispatchQueue.main.async — read-back в
  /// том же кадре гоняется с ним, поэтому откладываем на кадр. iOS —
  /// applicationIconBadgeNumber синхронен. Best-effort: ошибки канала не критичны.
  Future<void> _reportBadgeRenderMismatch(int expected) async {
    // isWriteSuppressed, а не isDenied: до permission-латча на iOS `trySet`
    // выходит молча, оставляя `_denied == false` — сравнивать было бы не с чем.
    if (AppBadge.isWriteSuppressed) return;
    // Снимок счётчика записей ДО ожидания: если за время read-back бейдж переписал
    // другой писатель ЭТОГО изолята (onSync-подписка на каждый клиент, resume,
    // cancelNotification — последний намеренно пишет N−1), измеренное расхождение
    // — наша собственная гонка, а не залипший бейдж. Прод-факт 2026-09-08: 87%
    // событий имели delta==1, а у одного юзера расхождение ходило в ОБЕ стороны
    // (0→1, 1→2, 2→1) — залипание так себя не ведёт.
    // Граница: `_writeSeq` статичен ПО ИЗОЛЯТУ, поэтому запись из фонового
    // push-изолята (push_helper) им не видна. Пути не пересекаются — read-back
    // живёт вместе с onSync-подпиской UI-изолята, — но полноты гард не даёт.
    final seqBefore = AppBadge.writeSeq;
    try {
      if (Platform.isMacOS) {
        await Future.delayed(Duration.zero);
      }
      final shown = await FlutterNewBadger.getBadge();
      if (AppBadge.writeSeq != seqBefore) return;
      Monitoring.reportBadgeRenderMismatch(expected: expected, shown: shown);
    } on PlatformException {
      // best-effort: канал бейджа недоступен
    } on MissingPluginException {
      // фон-изолят без зарегистрированного плагина
    }
  }

  /// События, по которым баннер уже нарисовал КЛИЕНТ (macOS-путь из /sync).
  /// Нужен, чтобы опоздавший APNs-пуш того же события не дал второй баннер.
  /// Ограничен по размеру: держать всю историю незачем, дубль возможен только
  /// в окне «локально показали → приехал пуш».
  final _locallyShownEventIds = <String>[];
  static const _locallyShownLimit = 200;

  void markLocallyShown(String eventId) {
    if (eventId.isEmpty) return;
    _locallyShownEventIds.remove(eventId);
    _locallyShownEventIds.add(eventId);
    if (_locallyShownEventIds.length > _locallyShownLimit) {
      _locallyShownEventIds.removeAt(0);
    }
  }

  @visibleForTesting
  bool isLocallyShown(String eventId) => _locallyShownEventIds.contains(eventId);

  /// События, по которым APNs-пуш УЖЕ дошёл до этого процесса (`onMessage`;
  /// на macOS его зовёт `willPresent`, на iOS — `didReceiveRemoteNotification`,
  /// но там читателя нет: локальный путь `onNotification` на iOS не подписан).
  /// Обратная сторона `isLocallyShown`: когда пуш
  /// обгоняет /sync (Мак проснулся — apsd отдаёт сохранённое мгновенно, догоняющий
  /// sync идёт дольше), баннер уже нарисовал натив, и локальное уведомление из
  /// sync дало бы второй баннер и второй звук — инвариант «ровно один
  /// показывающий» (LABA-2354, `RL-macos-push-background-banner`).
  final _nativelyReceivedEventIds = <String>[];

  void markNativelyReceived(String eventId) {
    if (eventId.isEmpty) return;
    _nativelyReceivedEventIds.remove(eventId);
    _nativelyReceivedEventIds.add(eventId);
    if (_nativelyReceivedEventIds.length > _locallyShownLimit) {
      _nativelyReceivedEventIds.removeAt(0);
    }
  }

  bool isNativelyReceived(String eventId) =>
      _nativelyReceivedEventIds.contains(eventId);

  /// Нативный слой (NSE/AppDelegate) спрашивает ПЕРЕД показом баннера. Отвечаем
  /// «подавить», только когда это ДОКАЗУЕМО лишний баннер:
  ///   1. событие уже показано локальным уведомлением этого же клиента;
  ///   2. событие клиенту УЖЕ ИЗВЕСТНО (sync его принёс) и комната при этом не
  ///      числится непрочитанной — значит пользователь его прочитал, в том числе
  ///      на другом устройстве.
  ///
  /// ⚠️ Проверка «событие известно» обязательна. Без неё штатный случай «пуш
  /// обогнал sync» выглядел бы как «комната прочитана» и глушил бы НОВЫЕ
  /// сообщения. Прочитанность берём из [Room.isUnreadOrInvited] (тот же
  /// инвариант, что у бейджа), а НЕ из `notificationCount` — он server-stuck в
  /// федеративных и mentions-only комнатах.
  Future<bool> shouldSuppressNativeBanner(Map<String, dynamic> userInfo) async =>
      (await classifyNativeBanner(userInfo)).suppress;

  /// Ответ `willPresent` (его macOS зовёт ТОЛЬКО у активного приложения).
  /// Активная ветка натива по неоткрытому чату баннер не рисует — считает, что
  /// его нарисует локальный путь из /sync. Но если пуш обогнал sync
  /// (`unknownEvent`), локальный путь потом упрётся в «APNs already handled», и
  /// баннера не будет ни одного — только звук (разбор 2026-09-28, `pushes.md` §22).
  /// Поэтому при `unknownEvent` баннер отдаём нативу, а локальный путь по этому
  /// событию закрываем.
  ///
  /// Перепроверка `isLocallyShown` и отметка идут в одном синхронном такте после
  /// последнего `await`: sync не может вклиниться между ними и дать второй баннер.
  /// `.banner` — ТОЛЬКО при `unknownEvent`: вердикт `show` значит, что локальный
  /// путь событие видел и сознательно промолчал (старше 5 мин, скрытая комната,
  /// Liza News другой платформы) — баннер там дал бы шквал старых после сна.
  Future<NativeBannerGate> nativeBannerGate(
    Map<String, dynamic> userInfo,
  ) async {
    final verdict = await classifyNativeBanner(userInfo);
    return nativeBannerGateFor(
      verdict.decision,
      userInfo['event_id'] as String?,
    );
  }

  @visibleForTesting
  NativeBannerGate nativeBannerGateFor(
    ApnsBannerDecision decision,
    String? eventId,
  ) {
    switch (decision) {
      case ApnsBannerDecision.suppressLocal:
      case ApnsBannerDecision.suppressRead:
        return NativeBannerGate.suppress;
      case ApnsBannerDecision.unknownEvent:
        if (eventId == null || eventId.isEmpty) return NativeBannerGate.silent;
        if (isLocallyShown(eventId)) return NativeBannerGate.suppress;
        markNativelyReceived(eventId);
        Logs().v('[Push] Native banner: push ahead of sync', eventId);
        return NativeBannerGate.banner;
      case ApnsBannerDecision.show:
      case ApnsBannerDecision.noEvent:
        return NativeBannerGate.silent;
    }
  }

  /// Тот же предикат, но с именем причины и временем известного события —
  /// для решения на приходе пуша ([handleApnsMessage]) и телеметрии.
  Future<ApnsBannerVerdict> classifyNativeBanner(
    Map<String, dynamic> userInfo,
  ) async {
    final roomId = userInfo['room_id'] as String?;
    final eventId = userInfo['event_id'] as String?;
    if (eventId != null && eventId.isNotEmpty && isLocallyShown(eventId)) {
      Logs().v('[Push] Suppress native banner: already shown locally', eventId);
      return const ApnsBannerVerdict(ApnsBannerDecision.suppressLocal);
    }
    if (roomId == null || roomId.isEmpty || eventId == null || eventId.isEmpty) {
      return const ApnsBannerVerdict(ApnsBannerDecision.noEvent);
    }
    final clientName = userInfo['client_name'] as String?;
    final target = clientForPush(
      clients: clients,
      clientName: (clientName?.isEmpty ?? true) ? null : clientName,
      roomId: roomId,
      senderId: userInfo['sender'] as String?,
    );
    final room = target.getRoomById(roomId);
    if (room == null) return const ApnsBannerVerdict(ApnsBannerDecision.unknownEvent);
    // ТОЛЬКО локальная база: `Room.getEventById` при промахе идёт в сеть
    // (`/rooms/../event/..`), а это синхронный участок показа баннера — сетевой
    // запрос здесь означал бы задержку и лишний трафик на каждый пуш.
    final known = await target.database.getEventById(eventId, room);
    if (known == null) return const ApnsBannerVerdict(ApnsBannerDecision.unknownEvent);
    if (room.isUnreadOrInvited) {
      return ApnsBannerVerdict(
        ApnsBannerDecision.show,
        originServerTs: known.originServerTs,
      );
    }
    Logs().v('[Push] Suppress native banner: already read', roomId);
    return ApnsBannerVerdict(
      ApnsBannerDecision.suppressRead,
      originServerTs: known.originServerTs,
    );
  }

  /// Латентность APNs, с которой пуш считается опоздавшим и уходит в мониторинг.
  static const apnsLateThreshold = Duration(seconds: 120);

  /// Низкокардинальный бакет для title GlitchTip (`[push-fail] reason=…`);
  /// `null` — не опоздал. Чистая функция — страж без Sentry.
  static String? apnsLateReason(Duration latency) {
    if (latency < apnsLateThreshold) return null;
    if (latency < const Duration(minutes: 5)) return 'apns_late_2m';
    if (latency < const Duration(minutes: 15)) return 'apns_late_5m';
    return 'apns_late_15m';
  }

  /// APNs-пуш дошёл до ЖИВОГО процесса. На macOS это
  /// `application(_:didReceiveRemoteNotification:)` — он приходит на КАЖДЫЙ пуш
  /// за ~0,3 с, независимо от того, активно ли окно; `willPresent` (и гейт
  /// `shouldSuppressBanner` в нём) система зовёт только у активного приложения
  /// (заявка №31, 2026-09-17). Поэтому решение «лишний ли баннер» принимаем
  /// здесь, а показанный системой оригинал снимаем вдогонку
  /// (`retractDelivered`). Остаток: вспышка баннера и звук — помешать показу у
  /// неактивного приложения нечем.
  ///
  /// iOS оставлен как был (haptic через [pushHelper]): спящее приложение пуш не
  /// видит вовсе, а foreground рисует NSE/willPresent.
  ///
  /// [retract]/[deliver]/[report]/[now] — точки подмены для host-стражей
  /// (`RL-macos-push-late-apns-retract`); `BackgroundPush.forTest` platform-
  /// listeners не ставит, поэтому логика живёт в именованном методе.
  Future<ApnsMessageOutcome> handleApnsMessage(
    Map<dynamic, dynamic> message, {
    DateTime? now,
    Future<int?> Function(String eventId)? retract,
    Future<void> Function(Map<String, dynamic> raw)? deliver,
    void Function(String reason, Map<String, String> tags)? report,
    Future<void> Function(Map<String, dynamic> raw)? clearing,
  }) async {
    final raw = Map<String, dynamic>.from(message['data'] ?? message);
    // Тихий «почисти шторку» — не уведомление: мимо pushHelper (там counts-only
    // при одном аккаунте = cancelAll плагина), мимо гейта баннера и дедупа.
    if (isClearingPush(raw)) {
      await (clearing ?? handleClearingPush)(raw);
      return const ApnsMessageOutcome(ApnsBannerDecision.noEvent);
    }
    final eventId = raw['event_id'] as String? ?? '';
    final deliverFn = deliver ??
        (Map<String, dynamic> r) => pushHelper(
              PushNotification.fromJson(r),
              clients: clients,
              clientName: pushClientNameFromRaw(r),
              l10n: l10n,
              activeRoomId: matrix?.activeRoomId,
              activeClientName: matrix?.client.clientName,
              flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
            );
    // Дубль того же пуша (второй делегат при активном окне, ретрай APNs) —
    // одно решение и один pushHelper.
    if (eventId.isNotEmpty && isNativelyReceived(eventId)) {
      Logs().v('[Push] apns duplicate onMessage ignored', eventId);
      return const ApnsMessageOutcome(ApnsBannerDecision.noEvent, duplicate: true);
    }
    // До всего остального: `showLocalNotification` из догоняющего sync смотрит
    // на эту отметку (RL-macos-push-banner-read-suppress AC-10).
    markNativelyReceived(eventId);
    if (!Platform.isMacOS) {
      await deliverFn(raw);
      return const ApnsMessageOutcome(ApnsBannerDecision.noEvent);
    }
    final verdict = await classifyNativeBanner(raw);
    var retractResult = 'n/a';
    if (verdict.suppress) {
      final ms = retract != null
          ? await retract(eventId)
          : await apns?.retractDelivered(eventId);
      retractResult = ms == null ? 'not-found' : 'found:${ms}ms';
    } else {
      await deliverFn(raw);
    }
    final moment = now ?? DateTime.now();
    final origin = verdict.originServerTs;
    final latency = origin == null ? null : moment.difference(origin);
    final outcome = ApnsMessageOutcome(
      verdict.decision,
      latency: latency,
      retract: retractResult,
    );
    try {
      final state = WidgetsBinding.instance.lifecycleState?.name ?? 'unknown';
      Logs().v(
        '[Push] apns latency=${latency == null ? 'unknown' : '${latency.inSeconds}s'} '
        'decision=${verdict.decision.name} retract=$retractResult state=$state',
      );
      final reason = latency == null ? null : apnsLateReason(latency);
      if (reason != null) {
        final tags = <String, String>{
          'push.latency_s': '${latency!.inSeconds}',
          'push.decision': verdict.decision.name,
          'push.retract': retractResult,
          'push.app_state': state,
        };
        if (report != null) {
          report(reason, tags);
        } else {
          Monitoring.reportPushIssue(reason, tags: tags);
        }
      }
    } catch (e, s) {
      // Телеметрия — наблюдатель: решение уже принято, баннер уже снят/показан.
      Logs().w('[Push] apns telemetry failed', e, s);
    }
    return outcome;
  }

  /// Снять нативные баннеры комнат, которые уже не числятся непрочитанными.
  /// Закрывает кросс-устройственный случай: прочитал на Маке — на телефоне
  /// баннер висел, потому что снять его мог только сам телефон, а он спал.
  /// Комнату, неизвестную клиенту, НЕ трогаем (консервативно — может быть
  /// свежее приглашение, ещё не доехавшее в sync).
  ///
  /// Квитанция с другого устройства приезжает только следующим /sync — на
  /// самом `resumed` локальная модель ещё считает комнату непрочитанной, и без
  /// ожидания баннер снимался лишь со ВТОРОГО пробуждения (заявка №19).
  /// Ждём первый sync после вызова, не дольше [resumeSyncWait]; молчание →
  /// проверяем по текущему состоянию (fail-open, лишний баннер безопаснее).
  static const resumeSyncWait = Duration(seconds: 3);

  Future<void> cancelDeliveredForReadRooms() async {
    if (!Platform.isIOS && !Platform.isMacOS) return;
    await Future.wait(
      clients.map(
        (c) => c.onSync.stream.first
            .timeout(resumeSyncWait)
            .then<void>((_) {}, onError: (_) {}),
      ),
    );
    await cancelDeliveredOfReadRooms();
  }

  /// Ядро чистки: снять нативные баннеры комнат, которые клиент уже не
  /// считает непрочитанными. Общее для resume и clearing-пуша — одно
  /// определение «прочитано» (`isUnreadOrInvited`), без новых копий предиката.
  /// Возвращает снятые комнаты.
  Future<List<String>> cancelDeliveredOfReadRooms({
    Future<List<String>> Function()? delivered,
    Future<void> Function(String roomId)? cancel,
  }) async {
    final rooms = await (delivered ?? _deliveredRoomIds)();
    final dropped = <String>[];
    for (final roomId in rooms.toSet()) {
      final room = clients
          .map((c) => c.getRoomById(roomId))
          .whereType<Room>()
          .firstOrNull;
      if (room == null || room.isUnreadOrInvited) continue;
      Logs().v('[Push] Dropping banner of already read room', roomId);
      await (cancel ?? _cancelDelivered)(roomId);
      dropped.add(roomId);
    }
    return dropped;
  }

  Future<List<String>> _deliveredRoomIds() async =>
      await apns?.deliveredRoomIds() ?? const <String>[];

  Future<void> _cancelDelivered(String roomId) async =>
      apns?.cancelDeliveredForRoom(roomId);

  static const clearingSyncTimeout = Duration(seconds: 8);

  /// Тихий пуш «почисти шторку» (Sygnal шлёт его на свою квитанцию с другого
  /// устройства, howItWoks/pushes.md §21): догнать квитанции sync'ом → снять
  /// прочитанное → отпустить нативный `completionHandler` (iOS держит фоновое
  /// окно до этого ответа, не дольше 25 с). Ответ уходит при ЛЮБОМ исходе.
  Future<List<String>> handleClearingPush(
    Map<String, dynamic> raw, {
    Future<void> Function(Client client)? sync,
    Future<List<String>> Function()? delivered,
    Future<void> Function(String roomId)? cancel,
    Future<void> Function(String? clearingId)? done,
    Duration syncTimeout = clearingSyncTimeout,
  }) async {
    var dropped = const <String>[];
    try {
      final clientName = pushClientNameFromRaw(raw);
      final own = clients.where((c) => c.clientName == clientName).toList();
      await Future.wait(
        (own.isEmpty ? clients : own).map(
          (c) => (sync ?? _clearingSync)(c)
              .timeout(syncTimeout)
              .then<void>((_) {}, onError: (_) {}),
        ),
      );
      dropped = await cancelDeliveredOfReadRooms(
        delivered: delivered,
        cancel: cancel,
      );
      Logs().v('[Push] Clearing push: dropped ${dropped.length} room(s)');
    } catch (e, s) {
      Logs().w('[Push] Clearing push failed', e, s);
    } finally {
      await (done ?? _clearingDone)(raw[pushClearIdKey] as String?);
    }
    return dropped;
  }

  static Future<void> _clearingSync(Client client) async {
    await client.roomsLoading;
    await client.oneShotSync();
  }

  Future<void> _clearingDone(String? id) async => apns?.clearingDone(id);

  /// Комнаты, непрочитанные на прошлом sync, — по аккаунтам.
  final _unreadOnLastSync = <String, Set<String>>{};

  /// Живой клиент: квитанция с ДРУГОГО устройства приходит sync'ом — снять
  /// уведомления комнат, которые с прошлого sync перестали быть непрочитанными
  /// (нативные баннеры iOS/macOS и уведомления плагина этого аккаунта). Без
  /// этого баннер на работающем Маке висел до активации окна. Сравниваем
  /// СОСТОЯНИЕ, а не события: пропущенный rate-limit'ом sync не теряет переход.
  Future<List<String>> clearNotificationsOfRoomsReadSinceLastSync(
    Client client, {
    Future<void> Function(Client client, String roomId)? cancel,
  }) async {
    final unread = {
      for (final room in client.rooms)
        if (room.isUnreadOrInvited) room.id,
    };
    final previous = _unreadOnLastSync[client.clientName];
    _unreadOnLastSync[client.clientName] = unread;
    if (previous == null) return const [];
    final read = previous.difference(unread).toList();
    for (final roomId in read) {
      try {
        await (cancel ?? _cancelRoomNotifications)(client, roomId);
      } catch (e, s) {
        Logs().w('[Push] Dropping notifications of read room failed', e, s);
      }
    }
    return read;
  }

  /// Аккаунт вышел: снимок его непрочитанного живёт по жизни клиента, иначе
  /// повторный вход под тем же clientName сравнивался бы со старой сессией.
  void forgetReadSnapshot(String clientName) =>
      _unreadOnLastSync.remove(clientName);

  Future<void> _cancelRoomNotifications(Client client, String roomId) async {
    Logs().v('[Push] Room read elsewhere, dropping its notifications', roomId);
    await _flutterLocalNotificationsPlugin.cancel(
      pushNotificationId(client.clientName, roomId),
    );
    await _flutterLocalNotificationsPlugin.cancel(roomId.hashCode);
    if (Platform.isIOS || Platform.isMacOS) {
      await apns?.cancelDeliveredForRoom(roomId);
    }
  }

  /// Тап по НАТИВНОМУ баннеру (iOS NSE / macOS AppDelegate) — тёплый старт и
  /// cold-start через `getInitialNotificationTap`. Навигация — общий
  /// `navigatePushTap`, как у `notificationTap` для локальных уведомлений:
  /// сторис-комната → просмотрщик, invite → `/rooms`, обычная → `/rooms/$id`.
  /// Раньше здесь была своя прямая навигация в `/rooms/$roomId` — тап по пушу
  /// сторис открывал скрытый технический чат (`RL-push-tap-stories-opens-viewer`).
  Future<void> nativeNotificationTap({
    required String roomId,
    String? eventId,
    String? clientName,
  }) async {
    Logs().v('[Push] Native notification tap for room: $roomId');
    final client = clientForPush(
      clients: clients,
      clientName: clientName,
      roomId: roomId,
    );
    _activateClient(client);
    await client.roomsLoading;
    await client.accountDataLoading;
    if (client.getRoomById(roomId) == null) {
      await client
          .waitForRoomInSync(roomId)
          .timeout(const Duration(seconds: 30));
    }
    navigatePushTap(
      client: client,
      router: LizaApp.router,
      roomId: roomId,
      eventId: eventId,
    );
  }

  Future<void> cancelNotification(String roomId) async {
    Logs().v('Cancel notification for room', roomId);
    // id уведомления — со скоупом аккаунта-владельца комнаты; legacy-id без
    // скоупа гасим тоже (уведомления прежней сборки после обновления).
    final owner = clients.firstWhereOrNull((c) => c.getRoomById(roomId) != null);
    if (owner != null) {
      await _flutterLocalNotificationsPlugin.cancel(
        pushNotificationId(owner.clientName, roomId),
      );
    }
    await _flutterLocalNotificationsPlugin.cancel(roomId.hashCode);
    // Баннеры, нарисованные НАТИВНО (NSE на iOS, AppDelegate на macOS), плагину
    // не принадлежат: их идентификатор — UUID от APNs, и `cancel(id)` их не
    // видит. Снимаем отдельно, по threadIdentifier == roomId.
    if (Platform.isIOS || Platform.isMacOS) {
      await apns?.cancelDeliveredForRoom(roomId);
    }

    // Workaround for app icon badge not updating
    if (Platform.isIOS || Platform.isMacOS || Platform.isAndroid) {
      final unreadCount = client.rooms
          .where((room) => room.countsTowardAppBadge && room.id != roomId)
          .length;
      await AppBadge.trySet(unreadCount);
    }
  }

  Future<void> setupPusher({
    required Client client,
    String? gatewayUrl,
    String? token,
    Set<String?>? oldTokens,
    bool useDeviceSpecificAppId = false,
  }) async {
    if ((PlatformInfos.isIOS || PlatformInfos.isMacOS) && !AppConfig.isLocal) {
      // В E2E/local не дёргаем APNs-диалог (см. DarwinInitializationSettings) —
      // иначе device-flow виснет на нативном окне разрешения. Прод — isLocal
      // compile-time false → путь неизменен.
      await apns!.requestPermission();
      AppBadge.markPermissionRequested();
    }
    if (PlatformInfos.isAndroid) {
      // Fire-and-forget: не блокируем регистрацию pusher на системном диалоге.
      // НО с обработкой ошибки — иначе reject этого floating future становится
      // unhandled async error (шумит в проде, роняет integration-прогон). Результат
      // в v1 не читаем (детекция perm_denied — follow-up, см.
      // RL-push-health-signal-client).
      final permFuture = _flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
      if (permFuture != null) {
        unawaited(
          permFuture.catchError((Object e, StackTrace s) {
            Logs().w('[Push] requestNotificationsPermission failed', e, s);
            return null;
          }),
        );
      }
    }
    final clientName = PlatformInfos.clientName;
    oldTokens ??= <String>{};
    final pushers =
        await (client.getPushers().catchError((e) {
          Logs().w('[Push] Unable to request pushers', e);
          return <Pusher>[];
        })) ??
        [];
    var setNewPusher = false;
    // Just the plain app id, we add the .data_message suffix later
    var appId = AppConfig.pushNotificationsAppId;
    // we need the deviceAppId to remove potential legacy UP pusher
    var deviceAppId = '$appId.${client.deviceID}';
    // appId may only be up to 64 chars as per spec
    if (deviceAppId.length > 64) {
      deviceAppId = deviceAppId.substring(0, 64);
    }
    if (!useDeviceSpecificAppId && PlatformInfos.isAndroid) {
      appId = androidDataMessageAppId(appId);
    }
    final thisAppId = useDeviceSpecificAppId ? deviceAppId : appId;
    if (gatewayUrl != null && token != null) {
      final currentPushers = pushers.where((pusher) => pusher.pushkey == token);
      // Ровно один существующий pusher с этим токеном — сверяем поля; иначе
      // (0 или >1) регистрируем заново. mismatchReason == null ⇔ pusher уже
      // идентичен ожидаемому, ничего не трогаем.
      final mismatchReason = currentPushers.length == 1
          ? pusherMismatchReason(
              pusher: currentPushers.single,
              expectedAppId: thisAppId,
              expectedAppDisplayName: clientName,
              expectedDeviceDisplayName: client.deviceName,
              expectedGatewayUrl: gatewayUrl,
              expectedFormat:
                  AppSettings.pushNotificationsPusherFormat.value.isEmpty
                      ? null
                      : AppSettings.pushNotificationsPusherFormat.value,
              expectedAdditionalProperties: pusherAdditionalPropertiesFor(client),
            )
          : 'pusherCount=${currentPushers.length}';
      if (mismatchReason == null) {
        Logs().i(
          '[Push] Pusher already set (kind=http appId=$thisAppId '
          'client=${client.clientName})',
        );
        pusherRegisteredByClient[client.clientName] = true;
      } else {
        // Логируем ИМЯ разошедшегося поля: без него ложное расхождение
        // (поверхностное сравнение вложенного default_payload) превращалось в
        // невидимую петлю delete+post на каждый resume — ловили её на проде по
        // тысячам удалений. См. RL-pusher-dedup-nested-payload.
        Logs().i(
          '[Push] Need to set new pusher (mismatch: $mismatchReason '
          'client=${client.clientName})',
        );
        // Серверный пушер отсутствует/расходится (удалён после reject, ротация
        // токена) — флаг перестаёт лгать до успешного повторного постинга.
        pusherRegisteredByClient[client.clientName] = false;
        // Synapse `add_pusher` = upsert по (app_id, pushkey, user_name): при
        // расхождении только по данным (data.*, имена) достаточно POST — без
        // предварительного DELETE нет окна «удалён → ещё не создан», а разовая
        // перерегистрация флота при смене default_payload = 1 POST, 0 DELETE.
        // Delete остаётся для смены app_id/kind и дублей по токену.
        if (pusherUpsertNeedsDelete(mismatchReason)) {
          oldTokens.add(token);
        }
        if (client.isLogged()) {
          setNewPusher = true;
        }
      }
    } else {
      Logs().w('[Push] Missing required push credentials');
    }
    for (final pusher in pushers) {
      if ((token != null &&
              pusher.pushkey != token &&
              deviceAppId == pusher.appId) ||
          oldTokens.contains(pusher.pushkey)) {
        try {
          await client.deletePusher(pusher);
          Logs().i('[Push] Removed legacy pusher for this device');
        } catch (err) {
          Logs().w('[Push] Failed to remove old pusher', err);
        }
      }
    }
    if (setNewPusher) {
      final pushkeyPreview = token!.length >= 12
          ? '${token.substring(0, 12)}...'
          : '$token...';
      final pusher = Pusher(
        pushkey: token,
        appId: thisAppId,
        appDisplayName: clientName,
        deviceDisplayName: client.deviceName!,
        lang: 'en',
        data: PusherData(
          url: Uri.parse(gatewayUrl!),
          format: AppSettings.pushNotificationsPusherFormat.value.isEmpty
              ? null
              : AppSettings.pushNotificationsPusherFormat.value,
          additionalProperties: pusherAdditionalPropertiesFor(client),
        ),
        kind: 'http',
      );
      // append: см. pusherAppendFor — true ТОЛЬКО при ≥2 своих аккаунтов на одном
      // хоумсервере (иначе Synapse снёс бы pusher соседа с тем же pushkey).
      final append = pusherAppendFor(client, clients);
      // Сбой регистрации = пользователь молча остаётся без пушей до
      // следующего setupPush (resume/рестарт). Поэтому: ретрай на сетевых
      // ошибках + репорт финального провала в мониторинг.
      const maxAttempts = 3;
      for (var attempt = 1; attempt <= maxAttempts; attempt++) {
        try {
          Logs().i(
            '[Push] Posting new pusher pushkey=$pushkeyPreview '
            'appId=$thisAppId client=${client.clientName} append=$append '
            '(attempt $attempt)',
          );
          await client.postPusher(pusher, append: append);
          pusherRegisteredByClient[client.clientName] = true;
          break;
        } on MatrixException catch (e, s) {
          // Ответ сервера (4xx и пр.) — повтор с теми же данными бессмыслен.
          Logs().e('[Push] Server rejected pusher registration', e, s);
          Monitoring.capture(e, s);
          break;
        } catch (e, s) {
          // Промежуточные попытки — warning: до моста в мониторинг доходят
          // только error/wtf, а сетевой сбой до исчерпания ретраев — не ошибка.
          if (attempt == maxAttempts) {
            Logs().e('[Push] Unable to set pusher (attempt $attempt)', e, s);
            // Стабильный маркер [push-fail] (роутинг notifier + дедуп), вместо
            // прежнего свободного captureMessage — чтобы этот класс сбоя пушей
            // попадал в мониторинг-комнату наравне с серверным детектором.
            Monitoring.reportPushIssue('post_pusher_exhausted');
          } else {
            Logs().w('[Push] Unable to set pusher (attempt $attempt)', e, s);
            await Future.delayed(Duration(seconds: 2 * attempt));
          }
        }
      }
    }
  }

  // On iOS we keep data_message as "ios" — Sygnal sends a silent push
  // (content-available:1) which is forwarded to Flutter via didReceiveRemoteNotification.
  // Flutter's pushHelper then shows a local notification with appropriate sound/haptic.
  // On Android we use "android" for FCM data-only messages.
  final pusherDataMessageFormat = Platform.isAndroid ? 'android' : 'ios';

  // mutable-content=1 запускает NSE на iOS (расшифровка loc-keys, аватар, звук).
  // sound=liza_ding.aiff — звук на macOS, где NSE не существует.
  // Sygnal читает default_payload из pusher.data и мержит его в top-level FCM data /
  // APNs payload → `client_name` приезжает в каждом пуше и маршрутизирует его к
  // аккаунту-адресату при мультиаккаунте (см. push_client_resolver.dart).
  // Смена формы = разовая перерегистрация у всего парка (1 POST, без DELETE).
  // `platform` — для адресных постов Liza News: по нему Sygnal не шлёт пуш
  // устройству вне аудитории. У второго аккаунта client_name = «Liza-<ms>», а
  // app_id и topic у iOS и macOS общие — без явного поля они неразличимы.
  Map<String, dynamic> pusherAdditionalPropertiesFor(Client client) =>
      pusherAdditionalProperties(
        client.clientName,
        dataMessage: pusherDataMessageFormat,
        apple: Platform.isIOS || Platform.isMacOS,
        platform: currentNewsPlatform,
      );

  @visibleForTesting
  static Map<String, dynamic> pusherAdditionalProperties(
    String clientName, {
    required String dataMessage,
    required bool apple,
    String? platform,
  }) => {
        "data_message": dataMessage,
        "default_payload": {
          pushClientNameKey: clientName,
          if (platform != null) "platform": platform,
          // Умеем тихий clearing-пуш «почисти шторку» (howItWoks/pushes.md §21):
          // без этого ключа Sygnal его не шлёт — старые сборки зря не будятся.
          if (apple) pushClearCapabilityKey: 1,
          if (apple)
            "aps": {
              "mutable-content": 1,
              "sound": "liza_ding.aiff",
            },
        },
      };

  /// Нужен ли DELETE перед POST при расхождении pusher-а: только когда меняется
  /// идентичность строки (app_id/kind) или pushers по токену не ровно один;
  /// расхождение по `data.*`/именам закрывается upsert-ом одним POST.
  @visibleForTesting
  static bool pusherUpsertNeedsDelete(String mismatchReason) =>
      mismatchReason == 'appId' ||
      mismatchReason == 'kind' ||
      mismatchReason.startsWith('pusherCount=');

  /// Регистрировать ли pusher в Sygnal для этой сборки.
  ///
  /// Отладочная (не release) сборка на iOS/macOS получает от APNs SANDBOX-токен,
  /// а Sygnal ходит только в production APNs: каждый пуш отвергается
  /// `400 BadDeviceToken`, Synapse по отказу сам удаляет pusher, клиент на
  /// ближайшем resume ставит его снова. Итог — ни одного доставленного пуша и
  /// петля в `deleted_pushers`, будящая детектор `pusher_rechurn` (алёрт
  /// 2026-09-15 по `Liza macosDebug`; тот же токен APNs-пробой признан sandbox
  /// ещё в разборе `a24589c2`). Глушить петлю в поллере нельзя надёжно: между
  /// удалением и resume строки pusher'а нет, и признак отладочной сборки не
  /// прочитать. Локальный стек и Android (FCM-токен от типа сборки не зависит) —
  /// без изменений.
  ///
  /// ⚠️ Исключение для локального стенда считается по хоумсерверу КОНКРЕТНОГО
  /// клиента, а НЕ по режиму сборки (`AppConfig.isLocal`). Причина найдена живым
  /// прогоном 2026-09-16: в одном приложении рядом живут локальный и ПРОД
  /// аккаунт (штатная ситуация — `lizaBotApiBaseForHomeserver` уже её
  /// учитывает). Гейт по режиму сборки пропускал sandbox-токен на ПРОД-аккаунт:
  /// local-сборка зарегистрировала pusher на `synapse.liza.laba.prodamus.tech`
  /// → production-Sygnal отвечает `BadDeviceToken` → Synapse удаляет pusher →
  /// клиент ставит снова. Это ровно петля `pusher_rechurn`, от которой и
  /// защищались.
  @visibleForTesting
  static bool shouldRegisterPusher({
    required bool apple,
    required bool releaseMode,
    required bool localHomeserver,
  }) => !apple || releaseMode || localHomeserver;

  /// Смотрит ли клиент на локальный стенд. Только по адресу хоумсервера —
  /// режим сборки о конкретном аккаунте ничего не говорит. Предикат общий с
  /// Bot API и @support (`AppConfig.isLocalHost`), включая LAN-IP физического
  /// телефона против стенда.
  @visibleForTesting
  static bool isLocalHomeserver(Uri? homeserver) =>
      AppConfig.isLocalHost(homeserver?.host);

  /// Сверяет существующий серверный pusher с ожидаемым для этого устройства.
  /// Возвращает имя ПЕРВОГО несовпавшего поля, либо `null` если pusher уже
  /// идентичен ожидаемому (перерегистрировать не нужно).
  ///
  /// `additionalProperties` сравниваются ГЛУБОКО (`DeepCollectionEquality`): на
  /// iOS/macOS они содержат вложенную карту `default_payload.aps`, а
  /// поверхностный `mapEquals` сравнивал бы вложенный `Map` по ссылке (у `Map`
  /// нет value-`==`) → расхождение репортилось ВСЕГДА, хотя payload идентичен →
  /// pusher бесконечно пересоздавался на каждый `setupPush`/resume (петля
  /// delete+post, теряющая пуши в окне «удалён → ещё не создан»). Android
  /// иммунен: там карта плоская. См. `howItWoks/pushes.md`,
  /// `RL-pusher-dedup-nested-payload`. Остальные поля — скаляры, сравниваются
  /// прямым `==`; их несовпадение (напр. `deviceDisplayName`) тоже должно вести
  /// к перерегистрации — но теперь причина видна в логе.
  /// app_id, под которым Android регистрирует pusher в Sygnal: базовый
  /// `AppConfig.pushNotificationsAppId` + суффикс `.data_message` (отдельный ключ
  /// FCM-pushkin). Базовый app_id ОБЯЗАН совпадать с ключом в `apps:` Sygnal —
  /// иначе пуши молча дохнут (`unknown app ID`, инцидент сборки 3734: миграция
  /// Apple `cd01dca8` увела дефолт на `ru.prodamus.liza`, а `build-android.sh` не
  /// переопределял `PUSH_APP_ID`). Вынесено чистой функцией ради стража
  /// `RL-android-push-app-id` (`AppConfig.pushNotificationsAppId` —
  /// compile-time-константа, в тесте не подменить).
  @visibleForTesting
  static String androidDataMessageAppId(String base) => '$base.data_message';

  @visibleForTesting
  static String? pusherMismatchReason({
    required Pusher pusher,
    required String expectedAppId,
    required String expectedAppDisplayName,
    required String? expectedDeviceDisplayName,
    required String expectedGatewayUrl,
    required String? expectedFormat,
    required Map<String, Object?> expectedAdditionalProperties,
  }) {
    if (pusher.kind != 'http') return 'kind';
    if (pusher.appId != expectedAppId) return 'appId';
    if (pusher.appDisplayName != expectedAppDisplayName) {
      return 'appDisplayName';
    }
    if (pusher.deviceDisplayName != expectedDeviceDisplayName) {
      return 'deviceDisplayName';
    }
    if (pusher.lang != 'en') return 'lang';
    if (pusher.data.url.toString() != expectedGatewayUrl) return 'data.url';
    if (pusher.data.format != expectedFormat) return 'data.format';
    if (!const DeepCollectionEquality().equals(
        pusher.data.additionalProperties, expectedAdditionalProperties)) {
      return 'additionalProperties';
    }
    return null;
  }

  static bool _wentToRoomOnStartup = false;

  Future<void> setupPush() async {
    Logs().d("SetupPush");
    if (!clients.any((c) => c.onLoginStateChanged.value == LoginState.loggedIn) ||
        (!PlatformInfos.isMobile && !PlatformInfos.isMacOS) ||
        matrix == null) {
      return;
    }
    // Защита от частых повторных вызовов из lifecycle-хука: если меньше 5 сек
    // назад уже стартовали setupPush, пропускаем. Не мешает первому вызову
    // (поле начинается с null).
    final now = DateTime.now();
    final last = _lastSetupPushAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      Logs().v('[Push] setupPush throttled (called <5s ago)');
      return;
    }
    _lastSetupPushAt = now;
    // Do not setup unifiedpush if this has been initialized by
    // an unifiedpush action
    if (upAction) {
      return;
    }
    if (!PlatformInfos.isIOS && !PlatformInfos.isMacOS &&
        (await UnifiedPush.getDistributors()).isNotEmpty) {
      await setupUp();
    } else {
      // Pusher — КАЖДОМУ залогиненному аккаунту (мультиаккаунт): иначе второй/
      // третий аккаунт на устройстве не получает ни пушей, ни внутренних
      // уведомлений (инцидент 2026-09-03, сторис Нади).
      // Снимок списка: `clients` — живой `matrix.widget.clients`, во время
      // `await` в него добавляет/убирает клиента логин/логаут → без снимка
      // ConcurrentModificationError (поймано iOS e2e 2026-09-03).
      for (final c in List<Client>.of(clients)) {
        if (!c.isLogged()) continue;
        await setupFirebase(c);
      }
    }

    // ignore: unawaited_futures
    _flutterLocalNotificationsPlugin.getNotificationAppLaunchDetails().then((
      details,
    ) {
      if (details == null ||
          !details.didNotificationLaunchApp ||
          _wentToRoomOnStartup) {
        return;
      }
      _wentToRoomOnStartup = true;
      final response = details.notificationResponse;
      if (response != null) {
        notificationTap(
          response,
          clients: clients,
          onClientResolved: _activateClient,
          router: LizaApp.router,
          l10n: l10n,
        );
      }
    });

    // Cold-start тап по нативному баннеру (iOS — NSE, macOS — AppDelegate до
    // регистрации плагина). flutter_local_notifications такие тапы не видит —
    // спрашиваем свой плагин.
    if ((Platform.isIOS || Platform.isMacOS) && !_wentToRoomOnStartup) {
      apns?.getInitialNotificationTap().then((tap) async {
        if (tap == null || _wentToRoomOnStartup) return;
        final roomId = tap['room_id'] ?? '';
        if (roomId.isEmpty) return;
        _wentToRoomOnStartup = true;
        Logs().v('[Push] Cold-start notification tap for room: $roomId');
        await nativeNotificationTap(
          roomId: roomId,
          eventId: tap['event_id'],
          clientName: tap[pushClientNameKey],
        );
      });
    }

    // Share credentials with the NSE so it can download avatars (iOS only).
    if (Platform.isIOS) {
      // Натив снимает баннеры по clearing-пушу без Dart (приложение выгружено):
      // баннер без client_name он считает своим, только если аккаунт один.
      apns?.saveClientNames(clients.map((c) => c.clientName).toList());
      apns?.saveCredentials(
        homeserverUrl: client.homeserver.toString(),
        accessToken: client.accessToken ?? '',
      );
    }
  }

  Future<void> _noFcmWarning() async {
    if (matrix == null) {
      return;
    }
    if (AppSettings.showNoGoogle.value) {
      return;
    }
    await loadLocale();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (PlatformInfos.isAndroid) {
        onFcmError?.call(
          l10n!.noGoogleServicesWarning,
          link: Uri.parse(AppConfig.faqUrl),
        );
        return;
      }
      onFcmError?.call(l10n!.oopsPushError);
    });
  }

  /// Получить push-токен с экспоненциальным backoff (1s, 2s, 4s).
  ///
  /// На холодном старте native-слой APNs/FCM может ещё не успеть зарегистрировать
  /// устройство, и `getToken()` вернёт `null` либо бросит исключение. Раньше
  /// одна неудачная попытка отключала пушер до полного перезапуска приложения.
  ///
  /// Возвращает первый непустой токен, либо `null` после 3 неудач.
  /// Выделено в статическую функцию, чтобы было удобно покрыть unit-тестом.
  @visibleForTesting
  static Future<String?> getTokenWithRetry(
    Future<String?> Function() fetch, {
    int maxAttempts = 3,
    Duration initialDelay = const Duration(seconds: 1),
    Future<void> Function(Duration) sleep = Future.delayed,
  }) async {
    var delay = initialDelay;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final stopwatch = Stopwatch()..start();
      try {
        final token = await fetch();
        stopwatch.stop();
        final ms = stopwatch.elapsedMilliseconds;
        Logs().i(
          '[Push] getToken took ${ms}ms, success=${token != null} '
          '(attempt $attempt/$maxAttempts)',
        );
        if (token != null && token.isNotEmpty) {
          return token;
        }
      } catch (e, s) {
        stopwatch.stop();
        final ms = stopwatch.elapsedMilliseconds;
        Logs().w(
          '[Push] getToken failed after ${ms}ms (attempt $attempt/$maxAttempts)',
          e,
          s,
        );
      }
      if (attempt < maxAttempts) {
        await sleep(delay);
        delay *= 2;
      }
    }
    return null;
  }

  Future<void> setupFirebase(Client client) async {
    Logs().v('Setup push notifications for ${client.clientName}');
    if ((PlatformInfos.isIOS || PlatformInfos.isMacOS) && !AppConfig.isLocal) {
      // В E2E/local не дёргаем APNs-диалог (см. DarwinInitializationSettings) —
      // иначе device-flow виснет на нативном окне разрешения. Прод — isLocal
      // compile-time false → путь неизменен.
      await apns!.requestPermission();
      AppBadge.markPermissionRequested();
    }
    // Гейт здесь, в пути получения APNs/FCM-токена, а не в общем `setupPusher`:
    // ротация FCM и UnifiedPush регистрируют не APNs-токен.
    if (!shouldRegisterPusher(
      apple: PlatformInfos.isIOS || PlatformInfos.isMacOS,
      releaseMode: kReleaseMode,
      localHomeserver: isLocalHomeserver(client.homeserver),
    )) {
      Logs().i(
        '[Push] Debug build on Apple: sandbox APNs token is rejected by '
        'production Sygnal — pusher not registered (client=${client.clientName}, '
        'homeserver=${client.homeserver?.host})',
      );
      return;
    }
    if (_fcmToken?.isEmpty ?? true) {
      final token = await getTokenWithRetry(() async {
        if (Platform.isIOS || Platform.isMacOS) {
          return apns!.getToken();
        }
        return firebase?.getToken();
      });
      if (token == null || token.isEmpty) {
        Logs().w('[Push] cannot get token after retries');
        // Транспорт пушей мёртв на этом устройстве (FCM/APNs не отдали токен —
        // напр. нет google-services в сборке / нет служб Google). Знает только
        // само устройство; foreground-путь (setupFirebase ← setupPush), Dart жив.
        Monitoring.reportPushIssue('fcm_token_unavailable');
        await _noFcmWarning();
        return;
      }
      _fcmToken = token;
    }
    await setupPusher(
      client: client,
      gatewayUrl: AppSettings.pushNotificationsGatewayUrl.value,
      token: _fcmToken,
    );
  }

  /// FCM ротирует токен в любой момент: после установки НОВОЙ сборки (для нас —
  /// sideload'ом, .apk напрямую, не через Play), обновления Google Play
  /// Services, очистки данных, восстановления из бэкапа. `setupFirebase`
  /// кэширует `_fcmToken` и на resume НЕ перезапрашивает его — поэтому ротацию
  /// «на живом приложении» ловим ТОЛЬКО здесь. `onNewToken` приходит из
  /// `FirebaseMessagingService` и будит isolate даже при убитом приложении
  /// (тот же механизм, что onMessage), так что перерегистрация проходит без
  /// ожидания, пока пользователь откроет приложение. Старый токен на сервере
  /// удаляем (`oldTokens`), новый регистрируем. Работает и в фоновом isolate:
  /// `setupPusher` требует только `client`, не `matrix`.
  @visibleForTesting
  Future<void> onFcmTokenRefresh(String newToken) async {
    if (newToken.isEmpty) return;
    final oldToken = _fcmToken;
    if (oldToken == newToken) return;
    Logs().i('[Push] FCM token refreshed — re-registering pushers');
    _fcmToken = newToken;
    // Токен один на устройство → перерегистрируем pusher КАЖДОГО аккаунта, иначе
    // остальные остались бы на мёртвом pushkey. Снимок списка — см. setupPush.
    for (final c in List<Client>.of(clients)) {
      if (!c.isLogged()) continue;
      await setupPusher(
        client: c,
        gatewayUrl: AppSettings.pushNotificationsGatewayUrl.value,
        token: newToken,
        oldTokens: oldToken != null ? {oldToken} : null,
      );
    }
  }

  Future<void> setupUp() async {
    await UnifiedPushUi(
      context: matrix!.context,
      instances: ["default"],
      unifiedPushFunctions: UPFunctions(),
      showNoDistribDialog: false,
      onNoDistribDialogDismissed: () {}, // TODO: Implement me
    ).registerAppWithDialog();
  }

  Future<void> _newUpEndpoint(PushEndpoint newPushEndpoint, String i) async {
    final newEndpoint = newPushEndpoint.url;
    upAction = true;
    if (newEndpoint.isEmpty) {
      await _upUnregistered(i);
      return;
    }
    var endpoint =
        'https://matrix.gateway.unifiedpush.org/_matrix/push/v1/notify';
    try {
      final url = Uri.parse(newEndpoint)
          .replace(path: '/_matrix/push/v1/notify', query: '')
          .toString()
          .split('?')
          .first;
      final res = json.decode(
        utf8.decode((await http.get(Uri.parse(url))).bodyBytes),
      );
      if (res['gateway'] == 'matrix' ||
          (res['unifiedpush'] is Map &&
              res['unifiedpush']['gateway'] == 'matrix')) {
        endpoint = url;
      }
    } catch (e) {
      Logs().i(
        '[Push] No self-hosted unified push gateway present: $newEndpoint',
      );
    }
    Logs().i('[Push] UnifiedPush using endpoint $endpoint');
    final oldTokens = <String?>{};
    try {
      final fcmToken = (Platform.isIOS || Platform.isMacOS)
          ? await apns?.getToken()
          : await firebase?.getToken();
      oldTokens.add(fcmToken);
    } catch (_) {}
    for (final c in List<Client>.of(clients)) {
      if (!c.isLogged()) continue;
      await setupPusher(
        client: c,
        gatewayUrl: endpoint,
        token: newEndpoint,
        oldTokens: oldTokens,
        useDeviceSpecificAppId: true,
      );
    }
    await AppSettings.unifiedPushEndpoint.setItem(newEndpoint);
    await AppSettings.unifiedPushRegistered.setItem(true);
  }

  Future<void> _upUnregistered(String i) async {
    upAction = true;
    Logs().i('[Push] Removing UnifiedPush endpoint...');
    final oldEndpoint = AppSettings.unifiedPushEndpoint.value;
    await AppSettings.unifiedPushEndpoint.setItem(
      AppSettings.unifiedPushEndpoint.defaultValue,
    );
    await AppSettings.unifiedPushRegistered.setItem(false);
    if (oldEndpoint.isNotEmpty) {
      // remove the old pusher
      for (final c in List<Client>.of(clients)) {
        if (!c.isLogged()) continue;
        await setupPusher(client: c, oldTokens: {oldEndpoint});
      }
    }
  }

  Future<void> _onUpMessage(PushMessage pushMessage, String i) async {
    Logs().wtf('Push Notification from UP received', pushMessage);
    final message = pushMessage.content;
    upAction = true;
    final data = Map<String, dynamic>.from(
      json.decode(utf8.decode(message))['notification'],
    );
    // UP may strip the devices list
    data['devices'] ??= [];
    await pushHelper(
      PushNotification.fromJson(data),
      clients: clients,
      clientName: pushClientNameFromRaw(data),
      l10n: l10n,
      activeRoomId: matrix?.activeRoomId,
      activeClientName: matrix?.client.clientName,
      flutterLocalNotificationsPlugin: _flutterLocalNotificationsPlugin,
      useNotificationActions:
          false, // Buggy with UP: https://codeberg.org/UnifiedPush/flutter-connector/issues/34
    );
  }
}

class UPFunctions extends UnifiedPushFunctions {
  final List<String> features = [
    /*list of features*/
  ];

  @override
  Future<String?> getDistributor() async {
    return await UnifiedPush.getDistributor();
  }

  @override
  Future<List<String>> getDistributors() async {
    return await UnifiedPush.getDistributors(features);
  }

  @override
  Future<void> registerApp(String instance) async {
    await UnifiedPush.register(instance: instance, features: features);
  }

  @override
  Future<void> saveDistributor(String distributor) async {
    await UnifiedPush.saveDistributor(distributor);
  }
}

/// Решение живого клиента по APNs-пушу (см. [BackgroundPush.classifyNativeBanner]).
enum ApnsBannerDecision {
  /// Показать: событие известно, комната непрочитана.
  show,

  /// Лишний: баннер уже нарисован локальным уведомлением из /sync.
  suppressLocal,

  /// Лишний: событие известно и комната прочитана (в т.ч. на другом устройстве).
  suppressRead,

  /// Пуш обогнал sync (события/комнаты в локальной базе нет) — показать.
  unknownEvent,

  /// Без event_id (counts-only / clearing) — гейт не касается.
  noEvent,
}

class ApnsBannerVerdict {
  const ApnsBannerVerdict(this.decision, {this.originServerTs});

  final ApnsBannerDecision decision;

  /// Время известного события — для латентности; `null`, если события в базе нет.
  final DateTime? originServerTs;

  bool get suppress =>
      decision == ApnsBannerDecision.suppressLocal ||
      decision == ApnsBannerDecision.suppressRead;
}

/// Итог [BackgroundPush.handleApnsMessage] — для стражей и лога.
class ApnsMessageOutcome {
  const ApnsMessageOutcome(
    this.decision, {
    this.latency,
    this.retract = 'n/a',
    this.duplicate = false,
  });

  final ApnsBannerDecision decision;

  /// `now − originServerTs` известного события; `null` — измерить нечем.
  final Duration? latency;

  /// `n/a` (не подавляли) / `found:<ms>` / `not-found`.
  final String retract;

  /// Повторный `onMessage` по тому же event_id — проигнорирован.
  final bool duplicate;
}
