import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:collection/collection.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:desktop_notifications/desktop_notifications.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:just_audio/just_audio.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher_string.dart';

import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/app_badge.dart';
import 'package:liza/utils/push_rule_defaults.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/custom_http_client.dart';
import 'package:liza/utils/device_capability_service.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/init_with_restore.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/network_recovery_trigger.dart';
import 'package:liza/utils/failed_send_retry_service.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/uia_request_manager.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/pages/chat/events/audio_autoplay_service.dart';
import 'package:liza/utils/transcription_service.dart';
import 'package:liza/utils/user_handle_service.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/utils/version_gate_service.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/update_read_only_http_client.dart';
import 'package:liza/utils/web_update_checker.dart';
import 'package:liza/utils/video_prefetch_manager.dart';
import 'package:liza/utils/voip/voip_handle.dart';
import 'package:liza/utils/voip/voip_loader.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import '../config/setting_keys.dart';
import '../pages/key_verification/key_verification_dialog.dart';
import '../utils/account_bundles.dart';
import '../utils/stream_extension.dart';
import '../utils/stories/stories_extension.dart';
import '../utils/background_push.dart';
import 'local_notifications_extension.dart';

// import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class Matrix extends StatefulWidget {
  final Widget? child;

  final List<Client> clients;

  final Map<String, String>? queryParameters;

  final SharedPreferences store;

  const Matrix({
    this.child,
    required this.clients,
    required this.store,
    this.queryParameters,
    super.key,
  });

  @override
  MatrixState createState() => MatrixState();

  /// Returns the (nearest) Client instance of your application.
  static MatrixState of(BuildContext context) =>
      Provider.of<MatrixState>(context, listen: false);
}

class MatrixState extends State<Matrix> with WidgetsBindingObserver {
  int _activeClient = -1;
  String? activeBundle;

  /// Set to `true` immediately before calling [Client.logout] or
  /// [Client.logoutAll] to signal that the resulting [LoginState.loggedOut]
  /// event is intentional. The flag is reset to `false` after the event is
  /// handled so it cannot accidentally suppress backup deletion for a
  /// subsequent unrelated logout.
  bool _isExplicitLogout = false;

  /// Call this immediately before invoking [Client.logout] or
  /// [Client.logoutAll] to mark the logout as intentional. This prevents
  /// the [onLoginStateChanged] handler from treating the resulting
  /// [LoginState.loggedOut] event as a soft logout.
  void markExplicitLogout() => _isExplicitLogout = true;

  SharedPreferences get store => widget.store;

  XFile? loginAvatar;
  String? loginUsername;
  bool? loginRegistrationSupported;

  BackgroundPush? backgroundPush;

  final ValueNotifier<VersionGateResult> versionGateResult = ValueNotifier(
    VersionGateResult.none,
  );

  /// Web-вкладка открыта до последнего деплоя — см. [WebUpdateChecker].
  final WebUpdateChecker webUpdateChecker = WebUpdateChecker();

  /// Бампается, когда `/sync` любого клиента принёс изменение пакетов аккаунтов
  /// (`im.fluffychat.account_bundles`), см. [onAccountDataSub].
  ///
  /// Своим `setState` здесь не обойтись: `Matrix.of` — это
  /// `Provider.of(listen: false)`, а [build] отдаёт `widget.child` тем же
  /// инстансом, поэтому обновление поддерева короткозамыкается. Паттерн тот же,
  /// что у `UserRoleService.rolesVersion`: потребители слушают через
  /// `ValueListenableBuilder`.
  final ValueNotifier<int> accountBundlesVersion = ValueNotifier(0);

  /// Бампает [accountBundlesVersion], если `/sync` принёс изменение пакетов.
  ///
  /// Вынесено из подписки отдельным методом, чтобы страж проверял РЕАЛЬНЫЙ
  /// фильтр, а не его копию в тесте. Дросселя нет намеренно: соседние подписки
  /// дросселированы, потому что слушают каждый incremental sync, а этот тип
  /// возникает единицы раз за сессию — троттл задержал бы все полезные события.
  void applyAccountBundlesSync(SyncUpdate sync) {
    for (final event in sync.accountData ?? <BasicEvent>[]) {
      if (event.type == accountBundlesType) {
        accountBundlesVersion.value++;
      }
    }
  }

  VersionGateService? _versionGateService;
  DateTime? _lastVersionCheck;

  Future<void> checkClientVersion() async {
    unawaited(refreshUpdatePolicy());
    final now = DateTime.now();
    if (_lastVersionCheck != null &&
        now.difference(_lastVersionCheck!) < const Duration(minutes: 15)) {
      return;
    }
    _lastVersionCheck = now;
    _versionGateService ??= VersionGateService(
      baseUrl: AppConfig.versionGateBaseUrl,
    );
    versionGateResult.value = await _versionGateService!.check();
  }

  /// Поэтапное обязательное обновление (howItWoks/lizaUpdates.md).
  ///
  /// Debug-сборки и локальный стек ходят в ПРОД version-gate с номером
  /// сборки ветки — жёсткий экран там ломал бы разработку и e2e. Включить
  /// для ручной проверки: `--dart-define=LIZA_UPDATE_POLICY=true`.
  static const _forceUpdatePolicy = bool.fromEnvironment('LIZA_UPDATE_POLICY');

  static bool get updatePolicyEnabled =>
      !kIsWeb &&
      (_forceUpdatePolicy || (!kDebugMode && !AppConfig.isLocal));

  UpdatePolicyController? _updatePolicyController;

  UpdatePolicyController get updatePolicyController =>
      _updatePolicyController ??= UpdatePolicyController(store);

  DateTime? _lastPolicyCheck;

  /// Свой троттл, короче плашки (15 мин): kill-switch и смена этапа должны
  /// доходить при каждом возврате в приложение, а не через четверть часа.
  static const _policyThrottle = Duration(minutes: 2);

  Future<void> refreshUpdatePolicy() async {
    if (!updatePolicyEnabled) return;
    final now = DateTime.now();
    final last = _lastPolicyCheck;
    if (last != null &&
        now.isAfter(last) &&
        now.difference(last) < _policyThrottle) {
      return;
    }
    _lastPolicyCheck = now;
    _versionGateService ??= VersionGateService(
      baseUrl: AppConfig.versionGateBaseUrl,
    );
    final fetched = await _versionGateService!.fetchPolicy();
    if (!mounted || fetched == null) return;
    final policy = fetched.policy;
    if (policy == null) {
      await updatePolicyController.applyUnavailable(fetched.build);
    } else {
      await updatePolicyController.applyFetched(policy, fetched.build);
    }
  }

  Client get client {
    if (_activeClient >= 0 && _activeClient < widget.clients.length) {
      return widget.clients[_activeClient];
    }
    final first = currentBundle.firstWhere((c) => c != null, orElse: () => null);
    if (first != null) return first;
    return widget.clients.first;
  }

  /// Звонилка. Тип — лёгкий [VoipHandle], а не `VoipPlugin`: реализация
  /// живёт за deferred-границей вместе с `flutter_webrtc` (см.
  /// `utils/voip/voip_loader.dart`). Упоминание конкретного класса здесь
  /// вернуло бы весь webrtc-стек в основной чанк.
  VoipHandle? voipPlugin;

  bool get isMultiAccount => widget.clients.length > 1;

  int getClientIndexByMatrixId(String matrixId) =>
      widget.clients.indexWhere((client) => client.userID == matrixId);

  late String currentClientSecret;
  RequestTokenResponse? currentThreepidCreds;

  void setActiveClient(Client? cl) {
    final i = widget.clients.indexWhere((c) => c == cl);
    if (i != -1) {
      _activeClient = i;
      // TODO: Multi-client VoiP support
      createVoipPlugin();
      // Refresh the active user's role so IfDeveloper switches between
      // accounts. Without this, the cached role of the previously active
      // account leaks into UI gates of the newly active one. Bump the
      // version immediately so role-gated UI re-evaluates against the new
      // active client even if the network refresh below is slow or fails.
      userRoleService.rolesVersion.value++;
      final newActive = widget.clients[i];
      final uid = newActive.userID;
      if (uid != null) {
        userRoleService.fetchRoles([uid], client: newActive).catchError((
          Object e,
          _,
        ) {
          Logs().w('[Matrix] Failed to refresh role on account switch: $e');
        });
      }
    } else {
      Logs().w('Tried to set an unknown client ${cl!.userID} as active');
    }
  }

  /// Клиенты активного бандла. НЕ nullable: «бандла нет» — это пустой/одиночный
  /// набор, а не отсутствие ответа. Прежняя сигнатура `List<Client?>?` вынуждала
  /// звать геттер через `!` в пяти местах, и один такой `!` падал у пользователя
  /// красным экраном при построении контекстного меню сообщения (GlitchTip 1918,
  /// `ChatController.currentRoomBundle`, сборки 3738 и 3746, Android). Заодно снят
  /// латентный `StateError` от `values.first` на пустой карте бандлов.
  List<Client?> get currentBundle {
    if (!hasComplexBundles) {
      return List.from(widget.clients);
    }
    final bundles = accountBundles;
    final active = bundles[activeBundle];
    if (active != null) return active;
    for (final b in bundles.values) {
      return b;
    }
    return List.from(widget.clients);
  }

  Map<String?, List<Client?>> get accountBundles {
    final resBundles = <String?, List<_AccountBundleWithClient>>{};
    for (var i = 0; i < widget.clients.length; i++) {
      final bundles = widget.clients[i].accountBundles;
      for (final bundle in bundles) {
        if (bundle.name == null) {
          continue;
        }
        resBundles[bundle.name] ??= [];
        resBundles[bundle.name]!.add(
          _AccountBundleWithClient(client: widget.clients[i], bundle: bundle),
        );
      }
    }
    for (final b in resBundles.values) {
      b.sort(
        (a, b) => a.bundle!.priority == null
            ? 1
            : b.bundle!.priority == null
            ? -1
            : a.bundle!.priority!.compareTo(b.bundle!.priority!),
      );
    }
    return resBundles.map(
      (k, v) => MapEntry(k, v.map((vv) => vv.client).toList()),
    );
  }

  bool get hasComplexBundles => accountBundles.values.any((v) => v.length > 1);

  Client? _loginClientCandidate;

  AudioPlayer? audioPlayer;
  final ValueNotifier<String?> voiceMessageEventId = ValueNotifier(null);

  /// Какое аудио-событие сейчас ГОТОВИТСЯ к воспроизведению (скачивание +
  /// декрипт + CAF) и с каким прогрессом. Отдельный нотифаер, а НЕ
  /// переиспользование [voiceMessageEventId]: последний слушает ещё и
  /// `chat_list_body.dart` (снимает верхний инсет списка чатов, пока жив
  /// banner-плеер) — выставив туда «готовящийся» id, мы получили бы прыжок
  /// шапки списка чатов под статус-бар на всё время подготовки.
  ///
  /// Пузырь готовящегося трека рисует по нему индикатор, поэтому фаза
  /// подготовки видна пользователю и в ручном пути, и при авто-переходе
  /// цепочки (раньше она была приватным `bool` внутри сервиса — невидимым ни
  /// пользователю, ни тесту). См. [[RL-audio-prepare-no-dead-window]].
  final ValueNotifier<({String eventId, double? progress})?> preparingAudio =
      ValueNotifier(null);

  /// Автозапуск цепочки голосовых/аудио: по завершению одного аудио стартует
  /// следующее подряд идущее. Живёт здесь рядом с глобальным плеером — он
  /// переживает dispose пузыря (скролл/banner-режим), значит и подписка на его
  /// завершение обязана быть вне виджета. См.
  /// `pages/chat/events/audio_autoplay_service.dart`.
  late final AudioAutoPlayService audioAutoPlayService = AudioAutoPlayService(
    this,
  );

  TranscriptionService? _transcriptionService;
  TranscriptionService get transcriptionService =>
      _transcriptionService ??= TranscriptionService(client);

  UserRoleService? _userRoleService;
  UserRoleService get userRoleService =>
      _userRoleService ??= UserRoleService(() => client);

  SingleSpaceService? _singleSpaceService;
  SingleSpaceService get singleSpaceService {
    final service = _singleSpaceService;
    if (service != null && service.client == client) return service;
    return _singleSpaceService = SingleSpaceService(client);
  }

  FederatedUserSearchService? _federatedUserSearchService;
  FederatedUserSearchService get federatedUserSearchService {
    final service = _federatedUserSearchService;
    if (service != null && service.client == client) return service;
    return _federatedUserSearchService = FederatedUserSearchService(client);
  }

  /// Общий кэш @-ников (B5) для всех мест, где вместо MXID показывается
  /// ник — см. `widgets/user_identifier.dart`. Один экземпляр на активного
  /// пользователя: `resolve()`/`rememberHandle()` в одном месте (например,
  /// поиск нового чата) обязаны попадать в кэш, который читают другие
  /// экраны (список участников, диалог пользователя). Пересоздаём при
  /// смене активного аккаунта — иначе `accessTokenProvider`/
  /// `serverNameProvider` продолжали бы указывать через замыкание на
  /// прежний `client`, хоть он и переопределён геттером выше.
  UserHandleService? _userHandleService;
  String? _userHandleServiceUserId;
  UserHandleService get userHandleService {
    final service = _userHandleService;
    if (service != null && _userHandleServiceUserId == client.userID) {
      return service;
    }
    _userHandleServiceUserId = client.userID;
    _userHandleService?.dispose();
    return _userHandleService = UserHandleService(
      baseUrl: AppConfig.authProxyBaseUrl,
      accessTokenProvider: () => client.accessToken,
      serverNameProvider: () => client.userID?.split(':').last ?? '',
    );
  }

  static const _fallbackAiMxids = {
    // Прод-домен намеренно литералом: это const-фолбэк каталога ролей ai (как
    // gpt/deepseek/botfather ниже), не путь закрепления DM. Flavor-aware mxid
    // ассистента — в геттере [lizaMxid].
    '@liza:bots.liza.ru',
    '@gpt:bots.liza.ru',
    '@deepseek:bots.liza.ru',
    // BotFather: карточки-пикеры (выбор бота при /newapp, приветствие, /myapps)
    // рисуются только от отправителя роли ai; страхуемся на случай, если каталог
    // ролей ещё не подтянут к первому рендеру / не проставлен на dev-стенде.
    '@botfather:bots.liza.ru',
    // Liza News: карточка «Отправить N? [Подтвердить][Изменить]» в DM редактора
    // рисуется только от отправителя роли ai. Каноничный источник — СЕРВЕРНАЯ роль
    // ai у @liza-news:bots.liza.ru (проставлена 2026-09-02, резолвится по федерации
    // → isAiUser=true на всех сборках, вкл. старые без этого фолбэка). Фолбэк —
    // страховка на окно федеративного TTL≤5мин и dev/local-стенды. См.
    // docs/superpowers/specs/2026-09-02-liza-news-buttons-server-role-ai-design.md
    // ledger:RL-liza-news-choice-buttons-by-role
    '@liza-news:bots.liza.ru',
    // Поддержка: карточка «Подключение компании» (интент «Создать компанию») приходит
    // в ТОЛЬКО ЧТО созданный DM, где кэш ролей ещё пуст (UserRoleService — in-memory,
    // TTL, без персистенции) → первый кадр деградировал бы в body и показывал вопрос
    // БЕЗ кнопок. Серверная роль ai у @support проставлена, фолбэк закрывает окно
    // федеративного резолва. ledger:RL-company-request-intro
    '@support:bots.liza.ru',
    '@cup:liza.cyber-agro.ru',
    // dev-стенд: AI-бот «Лиза miniApp» (на случай, если роль ai ещё не подтянута).
    '@liza:dev.liza.laba.prodamus.tech',
    // локальный стек (APP_ENV=local): каталог ролей пуст, опираемся на fallback.
    '@liza:liza.local',
    '@bot_father:liza.local',
    '@liza-news:liza.local',
    '@support:liza.local',
  };

  bool isAiUser(String userId) =>
      userRoleService.isAiUser(userId) || _fallbackAiMxids.contains(userId);

  bool get isCurrentUserDeveloper => userRoleService.isCurrentUserDeveloper;

  Future<Client> getLoginClient() async {
    if (widget.clients.isNotEmpty && !client.isLogged()) {
      return client;
    }
    final candidate = _loginClientCandidate ??=
        await ClientManager.createClient(
            '${AppSettings.applicationName.value}-${DateTime.now().millisecondsSinceEpoch}',
            store,
          )
          ..onLoginStateChanged.stream
              .where((l) => l == LoginState.loggedIn)
              .first
              .then((_) {
                final cand = _loginClientCandidate;
                if (cand == null) return;
                final candUid = cand.userID;
                // Дедуп: тот же userID мог попасть в bundle при повторном
                // нажатии «Войти» пока HomeserverPicker оставался видимым.
                final existing = candUid == null
                    ? null
                    : widget.clients.firstWhereOrNull(
                        (c) => c.userID == candUid && !identical(c, cand),
                      );
                if (existing != null) {
                  Logs().w(
                    '[Matrix] Duplicate login for $candUid detected, '
                    'discarding candidate ${cand.clientName}',
                  );
                  unawaited(cand.logout().catchError((_) {}));
                  ClientManager.removeClientNameFromStore(
                    cand.clientName,
                    store,
                  );
                  _loginClientCandidate = null;
                  setActiveClient(existing);
                  unawaited(_leaveAddAccountAsDuplicate());
                  return;
                }
                if (!widget.clients.contains(cand)) widget.clients.add(cand);
                ClientManager.addClientNameToStore(cand.clientName, store);
                // replayCachedLoggedIn: подхватить уже зафиксированный loggedIn.
                // Подписка регистрируется после события, и без replay редирект
                // на /rooms (или /backup для developer) не происходит.
                _registerSubs(cand.clientName, replayCachedLoggedIn: true);
                setActiveClient(cand);
                _loginClientCandidate = null;
                // Редирект после логина решается в _registerSubs.onLoginStateChanged,
                // где роль загружается и developer → /backup, остальные → /rooms.
              });
    if (widget.clients.isEmpty) widget.clients.add(candidate);
    return candidate;
  }

  /// Вход аккаунтом, который уже добавлен: без сообщения возврат в список
  /// чатов читался как «выкинуло из приложения» (вход по номеру телефона
  /// СВОЕГО аккаунта из «Добавить аккаунт»).
  Future<void> _leaveAddAccountAsDuplicate() async {
    await _collapseAddAccountStack();
    if (!mounted) return;
    final messengerContext =
        LizaApp.router.routerDelegate.navigatorKey.currentContext ?? context;
    LizaApp.router.go('/rooms');
    ScaffoldMessenger.of(messengerContext).showSnackBar(
      SnackBar(content: Text(L10n.of(messengerContext).accountAlreadyAdded)),
    );
  }

  /// На addaccount-флоу go_router не схлопывает вложенный ShellRoute
  /// /rooms/settings/addaccount при обычном go('/rooms'), и экран входа
  /// остаётся видимым. Сворачиваем стек перед переходом.
  Future<void> _collapseAddAccountStack() async {
    final router = LizaApp.router;
    final currentPath = router.routeInformationProvider.value.uri.path;
    if (!currentPath.contains('/settings/addaccount')) return;
    // go_router применяет pop к своей конфигурации только на следующем
    // кадре: без ожидания canPop() в том же цикле снова видит ТОТ ЖЕ
    // маршрут, второй pop по нему роняет «Future already completed», и
    // до router.go дело не доходит — второй аккаунт добавлен, а экран
    // входа остаётся на месте (поймано живым прогоном 2026-09-21).
    // 8 — защитный потолок: обычно хватает 1–2 pop; без кадров (фон) каждый
    // шаг ограничен 500 мс, поэтому хуже ~4 с, а не вечного ожидания.
    for (var i = 0; i < 8 && router.canPop(); i++) {
      router.pop();
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    }
  }

  Client? getClientByName(String name) =>
      widget.clients.firstWhereOrNull((c) => c.clientName == name);

  final onRoomKeyRequestSub = <String, StreamSubscription>{};
  final onKeyVerificationRequestSub = <String, StreamSubscription>{};
  final onNotification = <String, StreamSubscription>{};
  final onSyncBadgeUpdate = <String, StreamSubscription>{};
  final onLoginStateChanged = <String, StreamSubscription<LoginState>>{};
  final onUiaRequest = <String, StreamSubscription<UiaRequest>>{};
  final onAccountDataSub = <String, StreamSubscription>{};
  final onRoleToDeviceSub = <String, StreamSubscription>{};
  final onRolesRefreshSub = <String, StreamSubscription>{};
  final onStoryAutoJoinSub = <String, StreamSubscription>{};
  NetworkRecoveryTrigger? _networkRecoveryTrigger;
  FailedSendRetryService? _failedSendRetryService;

  String? _cachedPassword;
  Timer? _cachedPasswordClearTimer;

  String? get cachedPassword => _cachedPassword;

  set cachedPassword(String? p) {
    Logs().d('Password cached');
    _cachedPasswordClearTimer?.cancel();
    _cachedPassword = p;
    _cachedPasswordClearTimer = Timer(const Duration(minutes: 10), () {
      _cachedPassword = null;
      Logs().d('Cached Password cleared');
    });
  }

  String? get activeRoomId {
    final route = LizaApp.router.routeInformationProvider.value.uri.path;
    if (!route.startsWith('/rooms/')) return null;
    return route.split('/')[2];
  }

  bool _appForeground = true;
  String? _nativeActiveRoomKey;
  // Создаётся в initState, а не инициализатором поля: конструктор State не должен
  // трогать WidgetsBinding.instance — иначе MatrixState не создать вне дерева
  // виджетов (account_bundle_live_update_test). Семантика та же: initState идёт
  // сразу после конструктора, lifecycleState — на момент монтирования.
  late final ResumeHttpRefreshGate _resumeHttpRefreshGate;

  /// Единственный писатель «открытого чата» для нативного `willPresent`: маршрут
  /// меняется — слушатель роутера, уход в фон — [didChangeAppLifecycleState].
  void _syncActiveRoomToNative() {
    if (!(PlatformInfos.isIOS || PlatformInfos.isMacOS)) return;
    final payload = nativeActiveRoomPayload(
      activeRoomId: activeRoomId,
      clientName: widget.clients.isEmpty ? null : client.clientName,
      foreground: _appForeground,
      clientCount: widget.clients.length,
    );
    final key = payload?.toString();
    if (key == _nativeActiveRoomKey) return;
    _nativeActiveRoomKey = key;
    sendNativeActiveRoom(payload);
  }

  final linuxNotifications = PlatformInfos.isLinux
      ? NotificationsClient()
      : null;
  final Map<String, int> linuxNotificationIds = {};

  @override
  void initState() {
    super.initState();
    _resumeHttpRefreshGate = ResumeHttpRefreshGate(
      WidgetsBinding.instance.lifecycleState,
    );
    WidgetsBinding.instance.addObserver(this);
    LizaApp.router.routeInformationProvider.addListener(
      _syncActiveRoomToNative,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => checkClientVersion());
    UpdateReadOnlyHttpClient.isCallActive = () =>
        voipPlugin?.hasActiveCall ?? false;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => webUpdateChecker.start(),
    );
    // Старт сразу в чате (восстановление/диплинк) не меняет маршрут после
    // подписки — сообщаем нативу стартовое состояние.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _syncActiveRoomToNative(),
    );
    initMatrix();
  }

  void _registerSubs(String name, {bool replayCachedLoggedIn = false}) {
    final c = getClientByName(name);
    if (c == null) {
      Logs().w(
        'Attempted to register subscriptions for non-existing client $name',
      );
      return;
    }
    onRoomKeyRequestSub[name] ??= c.onRoomKeyRequest.stream.listen((
      RoomKeyRequest request,
    ) async {
      if (widget.clients.any(
        ((cl) =>
            cl.userID == request.requestingDevice.userId &&
            cl.identityKey == request.requestingDevice.curve25519Key),
      )) {
        Logs().i(
          '[Key Request] Request is from one of our own clients, forwarding the key...',
        );
        await request.forwardKey();
      }
    });
    onKeyVerificationRequestSub[name] ??= c.onKeyVerificationRequest.stream
        .listen((KeyVerification request) async {
          var hidPopup = false;
          request.onUpdate = () {
            if (!hidPopup &&
                {
                  KeyVerificationState.done,
                  KeyVerificationState.error,
                }.contains(request.state)) {
              LizaApp.router.pop('dialog');
            }
            hidPopup = true;
          };
          request.onUpdate = null;
          hidPopup = true;
          await KeyVerificationDialog(request: request).show(
            LizaApp.router.routerDelegate.navigatorKey.currentContext ??
                context,
          );
        });
    Future<void> handleLoginStateChange(LoginState state) async {
      final loggedInWithMultipleClients = widget.clients.length > 1;
      if (state == LoginState.loggedIn && c.userID != null) {
        Monitoring.setUserIdentity(c.userID!);
        unawaited(_reportDeviceCapability(c));
      }
      if (state == LoginState.loggedOut) {
        _cancelSubs(c.clientName);
        widget.clients.remove(c);
        if (widget.clients.isEmpty) Monitoring.clearUser();
        ClientManager.removeClientNameFromStore(c.clientName, store);
        // Only delete the session backup on an explicit user-initiated logout.
        // Soft logouts caused by network errors, timeouts, or database failures
        // must preserve the backup so that initWithRestore can recover the
        // session without requiring the user to log in again.
        if (_isExplicitLogout) {
          InitWithRestoreExtension.deleteSessionBackup(name, userId: c.userID);
        }
        _isExplicitLogout = false;
      }
      if (loggedInWithMultipleClients && state != LoginState.loggedIn) {
        ScaffoldMessenger.of(
          LizaApp.router.routerDelegate.navigatorKey.currentContext ?? context,
        ).showSnackBar(
          SnackBar(content: Text(L10n.of(context).oneClientLoggedOut)),
        );

        if (state != LoginState.loggedIn) {
          LizaApp.router.go('/rooms');
        }
      } else {
        // Pre-load the freshly logged-in user's role so we can decide where
        // to send them. Pass `client: c` explicitly: in multi-account flow
        // the active client (used by default) may be a different account
        // (e.g. an existing developer session), and the role for THIS login
        // lives only on this client's homeserver.
        var newClientIsDeveloper = false;
        if (state == LoginState.loggedIn && c.userID != null) {
          try {
            await userRoleService.fetchRoles([c.userID!], client: c);
            newClientIsDeveloper = userRoleService.isDeveloper(c.userID!);
          } catch (_) {
            // Falling back to default "user" role hides developer-only UI
            // and skips the bootstrap dialog.
          }
        }
        // The bootstrap/recovery-key dialog is developer-only. Regular users
        // skip it and go straight to the room list, even if a developer
        // session is currently active in the background.
        final target = state == LoginState.loggedIn
            ? (newClientIsDeveloper ? '/backup' : '/rooms')
            : '/home';
        final router = LizaApp.router;
        if (state == LoginState.loggedIn) await _collapseAddAccountStack();
        if (!mounted) return;
        router.go(target);
      }
    }

    onLoginStateChanged[name] ??= c.onLoginStateChanged.stream.listen(
      handleLoginStateChange,
    );

    // CachedStreamController хранит последнее значение, но его broadcast-поток
    // не реплеит уже пройденные события новым подписчикам. Для свежего логина
    // (getLoginClient → client.login → loggedIn) подписка регистрируется ПОСЛЕ
    // того, как loggedIn уже отстрелил, поэтому без подхвата .value редирект
    // на /rooms (или /backup для developer) не сработает и пользователь
    // остаётся на стартовом экране. Из initMatrix этот флаг false: там клиенты
    // уже залогинены после restore, и спонтанный redirect ломает стартовый
    // роутинг go_router.
    if (replayCachedLoggedIn &&
        c.onLoginStateChanged.value == LoginState.loggedIn) {
      unawaited(handleLoginStateChange(LoginState.loggedIn));
    }
    onUiaRequest[name] ??= c.onUiaRequest.stream.listen(uiaRequestHandler);

    // Мгновенный синк собственной роли через Matrix /sync account_data.
    // Synapse доставляет global account_data владельца в его /sync без broadcast.
    // Это бесплатный push-канал — не нужен поллинг.
    onAccountDataSub[name] ??= c.onSync.stream.listen((sync) {
      final uid = c.userID;
      if (uid == null) return;
      for (final event in sync.accountData ?? <BasicEvent>[]) {
        if (event.type == 'com.liza.user_role') {
          userRoleService.applyOwnAccountData(uid, event.content);
        }
      }
      applyAccountBundlesSync(sync);
    });

    // Push-канал для чужих ролей: Synapse шлёт to-device com.liza.user_role
    // всем участникам общих комнат, когда у кого-то меняется роль либо когда
    // админ редактирует справочник. Подхватываем без дополнительного /sync
    // batch-запроса; рестарт клиента поднимет очередь оффлайн-сообщений.
    onRoleToDeviceSub[name] ??= c.onToDeviceEvent.stream
        .where((e) => e.type == 'com.liza.user_role')
        .listen((event) {
          final content = event.content;
          final uid = content['user_id'];
          if (uid is! String) return;
          final role = content['role'];
          userRoleService.applyToDeviceEvent(
            uid,
            role is Map<String, dynamic> ? role : null,
          );
        });

    // Дроссельный refetch ролей видимых участников.
    // Срабатывает не чаще 1 раза в 5 минут (incremental sync) и обновляет
    // только устаревшие записи в кэше. Берём ТОЛЬКО DM-партнёров плюс
    // самого пользователя: UserRoleBadge рисуется только для direct-чатов
    // (chat_list_item.dart), а собственная роль нужна для IfDeveloper.
    // Сбор participants по всем комнатам подряд раздувал запрос до десятков
    // ролей и срабатывал на крупных аккаунтах гораздо дороже.
    onRolesRefreshSub[name] ??= c.onSync.stream
        .where((s) => s.rooms != null) // только incremental, не initial
        .rateLimit(const Duration(minutes: 5))
        .listen((_) {
          final dmPartners = collectDmPartnersForPrefetch(c);
          userRoleService.refreshIfStale(dmPartners, client: c).catchError((
            Object e,
            _,
          ) {
            Logs().w('[Matrix] Фоновый refetch ролей завершился с ошибкой: $e');
          });
        });

    // Федеративные сторис-инвайты джойнит клиент гостя, не сервер. Раньше auto-join
    // вызывался только в stories_bar.initState: инвайт, пришедший позже или без
    // открытого бара, висел в invite, и сторис автора с другого сервера не
    // показывался. Добираем на sync (throttle как у ролей, чтобы не джойнить на
    // каждый батч). Импорт: '../utils/stories/stories_extension.dart'.
    onStoryAutoJoinSub[name] ??= c.onSync.stream
        .where((s) => s.rooms != null) // только incremental, не initial
        .rateLimit(const Duration(seconds: 10))
        .listen((_) {
          c.autoJoinStoryInvites().catchError((Object e, StackTrace s) {
            Logs().w('[Matrix] auto-join сторис-инвайтов не удался: $e', e, s);
          });
        });

    // macOS здесь наравне с прочими десктопами (2026-09-16): пока приложение
    // живо, уведомление строится из /sync за секунды и не ждёт APNs, который
    // при простаивающей NAT-сессии приезжает пачками раз в полчаса. Дубль с
    // опоздавшим APNs-баннером снимает нативный гейт `shouldSuppressBanner`.
    if (PlatformInfos.isWeb ||
        PlatformInfos.isLinux ||
        PlatformInfos.isWindows ||
        PlatformInfos.isMacOS) {
      c.onSync.stream.first.then((s) {
        if (PlatformInfos.isWeb) {
          html.Notification.requestPermission();
        }
        onNotification[name] ??= c.onNotification.stream.listen(
          showLocalNotification,
        );
      });
    }
    // Auto-create DM with @liza if it doesn't exist yet (after first sync).
    // Префетч ролей строго для DM-партнёров плюс собственного пользователя:
    // бейдж роли (UserRoleBadge) виден только в direct-чатах
    // (chat_list_item.dart), а роль владельца аккаунта нужна для IfDeveloper.
    // Префетч по всем участникам всех комнат раздувал запрос на десятки
    // лишних ролей при первом /sync.
    c.onSync.stream.first.then((_) async {
      _ensureLizaDm(c);
      _ensureMainSpaceJoin(c);
      final dmPartners = collectDmPartnersForPrefetch(c);
      await userRoleService.fetchRoles(dmPartners);
    });

    // Прогрев героев DM-комнат. После restore из БД комнаты partial, и
    // getLocalizedDisplayname фолбэчит на localpart MXID (логин) вместо ФИО.
    // loadHeroUsers подтягивает RoomMember state партнёра, после чего ближайший
    // sync-ребилд ChatListItem отрисует имя.
    unawaited(_prefetchDmHeroes(c));

    // Keep badge count in sync after each sync cycle (rate-limited).
    if (PlatformInfos.isMobile || PlatformInfos.isMacOS) {
      onSyncBadgeUpdate[name] ??= c.onSync.stream
          .rateLimit(const Duration(seconds: 2))
          .listen((_) {
            backgroundPush?.updateBadgeCount();
            // Прочитано на другом устройстве → снять уведомления этого чата
            // здесь, не дожидаясь активации окна (howItWoks/pushes.md §21).
            final push = backgroundPush;
            if (push != null) {
              unawaited(push.clearNotificationsOfRoomsReadSinceLastSync(c));
            }
          });
    }
  }

  void _cancelSubs(String name) {
    onRoomKeyRequestSub[name]?.cancel();
    onRoomKeyRequestSub.remove(name);
    onKeyVerificationRequestSub[name]?.cancel();
    onKeyVerificationRequestSub.remove(name);
    onLoginStateChanged[name]?.cancel();
    onLoginStateChanged.remove(name);
    onNotification[name]?.cancel();
    onNotification.remove(name);
    onSyncBadgeUpdate[name]?.cancel();
    onSyncBadgeUpdate.remove(name);
    backgroundPush?.forgetReadSnapshot(name);
    onAccountDataSub[name]?.cancel();
    onAccountDataSub.remove(name);
    onRoleToDeviceSub[name]?.cancel();
    onRoleToDeviceSub.remove(name);
    onRolesRefreshSub[name]?.cancel();
    onRolesRefreshSub.remove(name);
    onStoryAutoJoinSub[name]?.cancel();
    onStoryAutoJoinSub.remove(name);
  }

  /// Re-run [ClientManager.getClients] and replace the current client list.
  /// Returns `true` if the new clients were created successfully (i.e. no
  /// [ClientManager.initializationError]), `false` otherwise.
  /// Used by [InitErrorPage] to retry after a Keychain lockout.
  Future<bool> reinitializeClients() async {
    ClientManager.initializationError = null;
    ClientManager.initializationErrorStack = null;

    final newClients = await ClientManager.getClients(store: store);

    if (ClientManager.initializationError != null) {
      return false;
    }

    // Cancel all existing subscriptions on old clients.
    for (final client in List<Client>.from(widget.clients)) {
      _cancelSubs(client.clientName);
    }

    // Replace the mutable client list in-place.
    widget.clients
      ..clear()
      ..addAll(newClients);

    // Re-register subscriptions for the new clients.
    initMatrix();

    return true;
  }

  void initMatrix() {
    // reinitializeClients() зовёт initMatrix() повторно поверх живого состояния
    // (восстановление после Keychain-сбоя). Без dispose старые сервисы держат
    // StreamSubscription/Timer на onSyncStatus прежнего клиента → две живые
    // подписки → двойной авто-досыл (лишний MXC-объект). Гасим прежние ПЕРЕД
    // созданием новых.
    _failedSendRetryService?.dispose();
    _networkRecoveryTrigger?.dispose();

    for (final c in widget.clients) {
      _registerSubs(c.clientName);
    }

    // Фоновая предзагрузка малых видео (< 5 МБ) из активной комнаты.
    final primaryClient = widget.clients.firstOrNull;
    if (primaryClient != null) {
      VideoPrefetchManager.instance.init(primaryClient);
    }

    if (PlatformInfos.isMobile ||
        PlatformInfos.isMacOS ||
        PlatformInfos.isWindows) {
      backgroundPush = BackgroundPush(
        this,
        onFcmError: (errorMsg, {Uri? link}) async {
          final result = await showOkCancelAlertDialog(
            context:
                LizaApp.router.routerDelegate.navigatorKey.currentContext ??
                context,
            title: L10n.of(context).pushNotificationsNotAvailable,
            message: errorMsg,
            okLabel: link == null
                ? L10n.of(context).ok
                : L10n.of(context).learnMore,
            cancelLabel: L10n.of(context).doNotShowAgain,
          );
          if (result == OkCancelResult.ok && link != null) {
            launchUrlString(
              link.toString(),
              mode: LaunchMode.externalApplication,
            );
          }
          if (result == OkCancelResult.cancel) {
            await AppSettings.showNoGoogle.setItem(true);
          }
        },
      );
    }

    createVoipPlugin();

    // Оживление после смены сети без сворачивания приложения (Wi-Fi <-> LTE):
    // пересоздаём HTTP-клиенты, чтобы sync-loop не бился в мёртвые сокеты.
    // Только mobile (внутри триггера) — на desktop/macOS refresh вреден.
    _networkRecoveryTrigger = NetworkRecoveryTrigger(
      stream: Connectivity().onConnectivityChanged,
      onRefresh: _refreshHttpClients,
      isMobile: PlatformInfos.isMobile,
    )..start();

    // Авто-досыл упавших голосовых/медиа при возврате связи (флап без VPN):
    // на переходе sync error→finished досылает то, что упало по сети, минуя
    // ручной «отправить повторно». Живёт здесь (не в ChatController), чтобы
    // пережить уход пользователя из чата.
    _failedSendRetryService = FailedSendRetryService(
      syncStatus: client.onSyncStatus.stream,
      failedMediaEvents: () =>
          FailedSendRetryService.collectFailedMediaEvents(() => client.rooms),
      isForeground: () {
        final lifecycle = WidgetsBinding.instance.lifecycleState;
        return lifecycle == AppLifecycleState.resumed ||
            (PlatformInfos.isDesktop &&
                lifecycle == AppLifecycleState.inactive);
      },
    )..start();
  }

  /// Поколение запроса звонилки. Раньше плагин создавался синхронно, теперь
  /// его чанк едет по сети — а `createVoipPlugin()` дёргается и из
  /// `initState`, и на КАЖДОЙ смене активного аккаунта. Без счётчика поздний
  /// ответ от предыдущего вызова затёр бы плагин, созданный для нового
  /// клиента.
  int _voipGeneration = 0;

  /// Создаёт звонилку, ЕСЛИ она включена. Иначе не трогает чанк вовсе —
  /// в этом весь смысл выноса: без флага `experimentalVoip` код webrtc не
  /// должен качаться.
  ///
  /// ⚠️ Условие ИНВЕРТИРОВАНО относительно интуиции, и так было и до выноса
  /// в чанк (см. origin/main): плагин создавался при `experimentalVoip ==
  /// false`. При этом кнопку звонка `chat_view.dart` показывает только при
  /// `experimentalVoip == true`, а включить флаг нечем — тумблер в
  /// `settings_chat_view.dart` закомментирован, сеттера в коде нет. То есть
  /// плагин создавался всегда, а позвонить было нельзя никогда.
  /// Здесь условие приведено к прямому смыслу: нет флага — нет плагина и
  /// нет загрузки чанка. Поведение для пользователя не меняется (кнопки не
  /// было и нет), но webrtc перестаёт ехать всем.
  void createVoipPlugin() async {
    final generation = ++_voipGeneration;
    if (!AppSettings.experimentalVoip.value) {
      voipPlugin = null;
      return;
    }
    // Чанк звонилки подгружается асинхронно — до его приезда voipPlugin
    // остаётся null, и UI-гейты просто не показывают кнопку звонка.
    final plugin = await loadVoipPlugin(this);
    if (!mounted || generation != _voipGeneration) return;
    setState(() => voipPlugin = plugin);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final refreshHttpClients = _resumeHttpRefreshGate.onStateChange(state);
    // На iOS/Android `inactive` означает «приложение скоро уйдёт в фон»
    // (входящий звонок, шторка уведомлений) — sync безопасно ставить.
    // На macOS `inactive` прилетает при каждой потере фокуса окна (Cmd-Tab,
    // клик в другое приложение): окно остаётся видимым, пользователь ждёт
    // новые сообщения. Если на это `inactive` остановить sync — переписка
    // с другого устройства не появится в открытом окне, а сообщение от
    // собеседника не отрендерится. Поэтому на macOS считаем foreground
    // строго по paused/detached, без inactive.
    // `hidden` (Cmd+H, окно спрятано) на macOS тоже НЕ фон: процесс жив, а
    // уведомление нужно как раз тогда, когда окна не видно. Пока sync на
    // `hidden` глушился, клиент 12,9 ч из 22 рабочих (замер 2026-09-16) висел
    // без sync и зависел только от APNs — а тот держит пуш до следующего
    // keep-alive, если NAT-сессия простаивает (до 1,5 ч на роутере владельца).
    final foreground = PlatformInfos.isMacOS
        ? (state != AppLifecycleState.paused &&
              state != AppLifecycleState.detached)
        : (state != AppLifecycleState.inactive &&
              state != AppLifecycleState.paused);
    _appForeground = foreground;
    _syncActiveRoomToNative();
    for (final client in widget.clients) {
      client.syncPresence = state == AppLifecycleState.resumed
          ? null
          : PresenceType.unavailable;
      if (PlatformInfos.isMobile || PlatformInfos.isMacOS) {
        client.backgroundSync = foreground;
        client.requestHistoryOnLimitedTimeline = !foreground;
        Logs().v('Set background sync to', foreground);
      }
      // Обрываем подвисший long-poll при уходе в фон: iOS замораживает
      // процесс с запросом в полёте, и его 40-секундный таймер выстреливает
      // TimeoutException сразу после resume — шум в sync-цикле и мониторинге.
      // Только paused (не inactive): шторка/диалоги не должны рвать sync.
      if (PlatformInfos.isMobile && state == AppLifecycleState.paused) {
        unawaited(client.abortSync());
      }
    }
    // Refresh HTTP clients and badge count when returning to the app.
    if (state == AppLifecycleState.resumed) {
      checkClientVersion();
      unawaited(webUpdateChecker.onResumed());
      for (final c in widget.clients) {
        if (c.isLogged()) {
          unawaited(_reportDeviceCapability(c));
        }
      }
      // HTTP-клиенты пересоздаём ТОЛЬКО на mobile: iOS/Android по-настоящему
      // выгружают приложение и закрывают сокеты, оставляя в пуле мёртвые
      // дескрипторы. На macOS приложение при потере фокуса не выгружается,
      // сокеты живут — а `resumed` прилетает на каждый возврат фокуса окна.
      // Пересоздание клиента там рвало бы активные upload/download/sync
      // (отсюда «Syncloop failed / Client has not connection» и зависание
      // загрузки видео при переключении между окнами).
      // И на mobile — только после заморозки: возврат из шторки тоже приходит
      // `resumed`, а force-close рвал загрузки в полёте (GlitchTip #2026).
      if (PlatformInfos.isMobile && refreshHttpClients) {
        _refreshHttpClients();
      }
      if (PlatformInfos.isMobile || PlatformInfos.isMacOS) {
        // Сброс до обновления: юзер мог включить бейджи в Настройках iOS,
        // процесс при смене notification-тоггла не перезапускается.
        AppBadge.resetDenied();
        backgroundPush?.updateBadgeCount();
        // Диагностика бейджа: спрашиваем ОС о фактических настройках. Без этой
        // строки лог пользователя не отвечает на вопрос «система подавила
        // рендер или мы не записали» — read-back бейджа на macOS тавтологичен
        // (setBadge/getBadge ходят в одну in-process переменную).
        unawaited(_reportPushConfig());
      }
      // Сверяем пушер с сервером на КАЖДЫЙ возврат в foreground, а не только
      // когда `pusherRegistered == false`. Причина (LABA-1891): при reject от
      // Sygnal Synapse безвозвратно удаляет пушер (mid-session ротация FCM/APNs-
      // токена, переустановка, обновление ОС). Клиент про это не узнаёт — нет
      // onNewToken-листенера, а `pusherRegistered` — оптимистичный in-memory
      // флаг, остающийся true после серверного удаления. Без сверки на resume
      // восстановление требовало холодного перезапуска → «в фоне пушей нет».
      // `setupPush()` → `setupPusher()` уже делает getPushers-сверку и постит
      // заново только при расхождении; внутренний 5s-throttle гасит частые
      // resume/pause, так что лишний трафик — максимум один getPushers/5с.
      if ((PlatformInfos.isMobile || PlatformInfos.isMacOS) &&
          backgroundPush != null) {
        Logs().v('[Push] Resume: reconciling pusher with server');
        // ignore: unawaited_futures
        backgroundPush?.setupPush();
        // Баннеры, которые пользователь уже «отработал» на ДРУГОМ устройстве,
        // висят до сих пор: снять их мог только этот процесс, а он спал.
        // ignore: unawaited_futures
        backgroundPush?.cancelDeliveredForReadRooms();
      }
    }
    // Auto-retry client initialization on resume if previously failed
    // (e.g. Keychain was locked). One attempt, no loop.
    if (state == AppLifecycleState.resumed &&
        ClientManager.initializationError != null) {
      _autoRetryInitialization();
    }
  }

  /// Replace the inner HTTP client for each Matrix client to force fresh
  /// TCP connections. iOS/Android close all sockets after the app has been
  /// backgrounded, leaving the Dart connection pool with dead descriptors.
  /// macOS приложение при потере фокуса не выгружает — там пересоздание не
  /// нужно и вредно (рвёт активные запросы), поэтому вызывается лишь на mobile.
  void _refreshHttpClients() {
    for (final client in widget.clients) {
      final httpClient = client.httpClient;
      if (httpClient is TimeoutHttpClient) {
        final oldInner = httpClient.inner;
        httpClient.inner = CustomHttpClient.createHTTPClient();
        oldInner.close();
        Logs().v('Refreshed HTTP client for ${client.clientName}');
      }
    }
  }

  Future<void> _autoRetryInitialization() async {
    Logs().i('[Recovery] App resumed with init error, attempting auto-retry');
    final success = await reinitializeClients();
    if (success && mounted) {
      final hasLoggedIn = widget.clients.any((c) => c.isLogged());
      LizaApp.router.go(hasLoggedIn ? '/rooms' : '/home');
    }
  }

  /// Сигнал `[push-config]` в мониторинг: пуши не сломаны, а выключены
  /// настройками (ОС запретила уведомления / у аккаунта выключено дефолтное
  /// notify-правило). Инцидент 2026-09-14: оба состояния были у пользователя,
  /// мониторинг молчал. Проверяем активный клиент — его видит пользователь.
  Future<void> _reportPushConfig() async {
    final authorization = await AppBadge.logNotificationSettings();
    if (authorization == AppBadge.authorizationDenied) {
      await Monitoring.reportPushConfig('os_denied');
    }
    final c = client;
    if (!c.isLogged()) return;
    final deviations = PushRuleDefaults.deviations(c.globalPushRules);
    if (deviations != null && PushRuleDefaults.anySilencing(deviations)) {
      await Monitoring.reportPushConfig('default_rule_disabled');
    }
  }

  Future<void> _reportDeviceCapability(Client c) async {
    final deviceId = c.deviceID;
    if (deviceId == null) return;

    await DeviceCapabilityService(
      putCapability: (deviceId, platform, build) async {
        try {
          await c.request(
            RequestType.PUT,
            '/client/unstable/com.liza/devices/$deviceId/capabilities',
            data: {'platform': platform, 'build': build},
          );
          return true;
        } catch (_) {
          return false;
        }
      },
      resolvePlatform: () => PlatformInfos.isAndroid
          ? 'android'
          : PlatformInfos.isIOS
          ? 'ios'
          : PlatformInfos.isMacOS
          ? 'macos'
          : PlatformInfos.isWindows
          ? 'windows'
          : 'web',
      resolveBuild: () async {
        try {
          final info = await PackageInfo.fromPlatform();
          return int.tryParse(info.buildNumber);
        } catch (_) {
          return null;
        }
      },
      prefs: await SharedPreferences.getInstance(),
    ).reportIfNeeded(deviceId: deviceId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LizaApp.router.routeInformationProvider.removeListener(
      _syncActiveRoomToNative,
    );

    // Iterable.map в Dart — lazy: без терминальной операции функция не
    // вызывается. Используем явный цикл, иначе подписки утекают.
    for (final s in onRoomKeyRequestSub.values) {
      s.cancel();
    }
    for (final s in onKeyVerificationRequestSub.values) {
      s.cancel();
    }
    for (final s in onLoginStateChanged.values) {
      s.cancel();
    }
    for (final s in onNotification.values) {
      s.cancel();
    }
    for (final s in onSyncBadgeUpdate.values) {
      s.cancel();
    }
    for (final s in onAccountDataSub.values) {
      s.cancel();
    }
    for (final s in onRoleToDeviceSub.values) {
      s.cancel();
    }
    for (final s in onRolesRefreshSub.values) {
      s.cancel();
    }
    for (final s in onStoryAutoJoinSub.values) {
      s.cancel();
    }
    _networkRecoveryTrigger?.dispose();
    _failedSendRetryService?.dispose();
    client.httpClient.close();
    // Сначала обрываем автозапуск (in-flight подготовку), затем гасим активный
    // плеер — иначе нативный just_audio-плеер утёк бы при logout.
    audioAutoPlayService.dispose();
    audioPlayer?.stop();
    audioPlayer?.dispose();
    audioPlayer = null;
    _userRoleService?.dispose();
    _userHandleService?.dispose();
    VideoPrefetchManager.instance.dispose();

    linuxNotifications?.close();
    versionGateResult.dispose();
    webUpdateChecker.dispose();
    accountBundlesVersion.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Provider(create: (_) => this, child: widget.child);
  }

  /// MXID живого ассистента Лизы. Flavor-aware по образцу
  /// [AppConfig.supportBotMxidForHomeserver]: на проде и клиентских/company-инстансах бот
  /// федеративно живёт на выделенном `bots.liza.ru`, локально — на общем
  /// `liza.local`. Мёртвый prod-предшественник `@liza:synapse...` (деактивирован
  /// при миграции 2026-07-14) сюда НЕ попадает — закрепление и создание DM идут
  /// строго против этого mxid.
  static String get lizaMxid =>
      AppConfig.isLocal ? '@liza:liza.local' : '@liza:bots.liza.ru';

  Future<void> _ensureLizaDm(Client c) async {
    try {
      // Поиск по MEMBER-стейту, а не по m.direct — см. [findLizaAssistantDm].
      final lizaRoom = findLizaAssistantDm(c, lizaMxid);

      if (lizaRoom != null) {
        // Комната есть. Если её нет в m.direct — самолечим ЗАПИСЬ источника,
        // иначе directChatMatrixID вернёт null и закрепление наверху не сработает
        // при корректном серверном m.direct. addToDirectChat идемпотентен.
        final inMDirect = c.directChats[lizaMxid]?.contains(lizaRoom.id) ?? false;
        if (!inMDirect) {
          Logs().i('[Liza] Self-heal m.direct: add ${lizaRoom.id} for $lizaMxid');
          await lizaRoom.addToDirectChat(lizaMxid);
        }
        return;
      }

      Logs().i('[Liza] Creating DM with $lizaMxid');
      await c.ensureDirectChat(lizaMxid);
    } catch (e, s) {
      Logs().w('[Liza] Failed to ensure DM with Liza', e, s);
    }
  }

  Future<void> _ensureMainSpaceJoin(Client c) async {
    try {
      final service = SingleSpaceService(c);
      final result = await service.fetch();
      final roomId = result.roomId;
      if (!result.exists || roomId == null) return;

      final existing = c.getRoomById(roomId);
      if (existing?.membership == Membership.join) return;

      Logs().i('[MainSpace] joining $roomId');
      await c.joinRoom(roomId);
    } catch (e, s) {
      Logs().w('[MainSpace] Failed to join main space', e, s);
    }
  }

  Future<void> _prefetchDmHeroes(Client c) => prefetchDmHeroes(c.rooms);

  Future<void> dehydrateAction(BuildContext context) async {
    final response = await showOkCancelAlertDialog(
      context: context,
      isDestructive: true,
      title: L10n.of(context).dehydrate,
      message: L10n.of(context).dehydrateWarning,
    );
    if (response != OkCancelResult.ok) {
      return;
    }
    final result = await showFutureLoadingDialog(
      context: context,
      future: client.exportDump,
    );
    final export = result.result;
    if (export == null) return;

    final exportBytes = Uint8List.fromList(const Utf8Codec().encode(export));

    final exportFileName =
        'liza-export-${DateFormat(DateFormat.YEAR_MONTH_DAY).format(DateTime.now())}.lizabackup';

    final file = MatrixFile(bytes: exportBytes, name: exportFileName);
    file.save(context);
  }
}

class _AccountBundleWithClient {
  final Client? client;
  final AccountBundle? bundle;

  _AccountBundleWithClient({this.client, this.bundle});
}

/// Собирает множество matrix-ID, для которых нужно префетчить роли при заходе
/// в приложение: DM-партнёров всех direct-чатов плюс самого пользователя.
///
/// UserRoleBadge показывается только в direct-чатах (chat_list_item.dart),
/// поэтому брать participants всех комнат подряд (включая группы и спейсы)
/// смысла нет — это лишний HTTP и десятки лишних ролей в кэше. Собственная
/// роль остаётся обязательной: её читает IfDeveloper и другие role-gated
/// виджеты.
///
/// Помечено [visibleForTesting], чтобы юнит-тест мог подтвердить, что групповые
/// чаты и спейсы не вкатываются в префетч.
@visibleForTesting
Set<String> collectDmPartnersForPrefetch(Client c) {
  final dmPartners = <String>{};
  for (final room in c.rooms) {
    if (!room.isDirectChat) continue;
    final partner = room.directChatMatrixID;
    if (partner != null) dmPartners.add(partner);
  }
  final uid = c.userID;
  if (uid != null) dmPartners.add(uid);
  return dmPartners;
}

/// Последовательно прогревает героев всех direct-комнат через
/// [Room.loadHeroUsers]. Используется на старте клиента, чтобы избежать
/// показа MXID-локалпарта вместо ФИО партнёра, когда комната восстановлена
/// из БД в состоянии partial. Идём последовательно: при 30+ DM одновременные
/// /profile/{userId} запросы перегружают Synapse.
///
/// Дополнительно для каждой DM-комнаты проверяем state партнёра и, если в
/// нём не хватает displayName или avatarUrl, тянем глобальный профиль через
/// [Client.getUserProfile] и применяем его в room state. Это нужно потому,
/// что [Room.requestUser] (внутри [Room.loadHeroUsers]) не дёргает профиль,
/// если в комнате уже есть RoomMember state партнёра, даже когда у этого
/// state нет displayname/avatar_url. У Liza Synapse часто отдаёт именно
/// такой "огрызок" RoomMember (особенно при федерации между двумя
/// homeserver), и без отдельного fetch-а профиля в списке чатов остаются
/// логины вместо ФИО и пустые аватары.
@visibleForTesting
Future<void> prefetchDmHeroes(Iterable<Room> rooms) async {
  final dmRooms = rooms.where((r) => r.isDirectChat).toList();
  for (final room in dmRooms) {
    try {
      await room.loadHeroUsers();
    } catch (e) {
      Logs().d('[DM] loadHeroUsers failed for ${room.id}', e);
    }
    await _ensureDmPartnerProfile(room);
  }
}

/// Проверяет, есть ли в room state DM-партнёра полные displayName и
/// avatarUrl. Если хоть чего-то не хватает, подтягивает глобальный профиль
/// через homeserver и мержит результат в room state. Все ошибки сети
/// глотаются (это best-effort фоновый прогрев).
Future<void> _ensureDmPartnerProfile(Room room) async {
  final partnerId = room.directChatMatrixID;
  if (partnerId == null) return;
  final existing = room
      .getState(EventTypes.RoomMember, partnerId)
      ?.asUser(room);
  final hasDisplayName = (existing?.displayName ?? '').isNotEmpty;
  final hasAvatar = (existing?.avatarUrl?.toString() ?? '').isNotEmpty;
  if (hasDisplayName && hasAvatar) return;
  try {
    final profile = await room.client.getUserProfile(partnerId);
    final newDisplayName = profile.displayname ?? existing?.displayName;
    final newAvatarUrl =
        profile.avatarUrl?.toString() ?? existing?.avatarUrl?.toString();
    if ((newDisplayName ?? '').isEmpty && (newAvatarUrl ?? '').isEmpty) {
      return;
    }
    final merged = User(
      partnerId,
      displayName: newDisplayName,
      avatarUrl: newAvatarUrl,
      membership: existing?.membership.name ?? Membership.join.name,
      room: room,
    );
    room.setState(merged);
  } catch (e) {
    Logs().d('[DM] getUserProfile failed for $partnerId', e);
  }
}
