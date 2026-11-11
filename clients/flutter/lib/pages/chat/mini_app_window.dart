import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kPrimaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/fluid_page_view.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/widgets/app_lock.dart';

/// Первый аргумент `main`, с которым desktop_multi_window запускает движок
/// нового окна: `['multi_window', windowId, arguments]`.
const kMiniAppWindowEntryArg = 'multi_window';

/// RPC под-окно → главный движок (там Client, Room, ключи E2EE).
const _hostChannel = WindowMethodChannel(
  'liza/miniapp_host',
  mode: ChannelMode.unidirectional,
);

/// Нативное окно ОС этого движка (раннеры macOS/Windows): заголовок, размер,
/// фокус, закрытие. Своё, а не window_manager: тот ставит себя делегатом окна
/// и умеет `destroy()` = завершить всё приложение.
const _nativeWindow = MethodChannel('liza/miniapp_window');

const _rpcTimeout = Duration(seconds: 20);

/// Можно ли сейчас открепить mini App в окно ОС: окна поддержаны и не включён
/// пин-код (окно ОС живёт вне экрана блокировки Лизы).
bool miniAppDetachAllowed(BuildContext context) {
  if (!MiniAppManager.instance.windowsSupported) return false;
  try {
    return !AppLock.of(context).isActive;
  } catch (_) {
    // Нет AppLockWidget выше (тесты) — блокировки нет.
    return true;
  }
}

/// Всё, что окну ОС нужно знать о своём mini App и о внешнем виде Лизы.
@immutable
class MiniAppWindowConfig {
  final String appId;
  final String appUrl;
  final String appName;
  final String appType;
  final String appStartPath;
  final String startParam;
  final String? botMxid;
  final String? joinRequestQueryId;
  final String interactiveSessionId;
  final String? accountUserId;
  final String roomId;
  final String contentKey;
  final bool dark;
  final int seedColor;

  /// Жидкая страница ([MiniAppKind.html]): окно рисует статичный документ,
  /// запрошенный у главного окна, а не mini App.
  final MiniAppKind kind;

  const MiniAppWindowConfig({
    required this.appId,
    required this.appUrl,
    required this.appName,
    required this.appType,
    required this.appStartPath,
    this.startParam = '',
    this.botMxid,
    this.joinRequestQueryId,
    this.interactiveSessionId = '',
    this.accountUserId,
    required this.roomId,
    required this.contentKey,
    required this.dark,
    required this.seedColor,
    this.kind = MiniAppKind.miniApp,
  });

  factory MiniAppWindowConfig.of(MiniAppInstance app, ThemeData? theme) =>
      MiniAppWindowConfig(
        appId: app.appId,
        appUrl: app.appUrl,
        appName: app.appName,
        appType: app.appType,
        appStartPath: app.appStartPath,
        startParam: app.startParam,
        botMxid: app.botMxid,
        joinRequestQueryId: app.joinRequestQueryId,
        interactiveSessionId: app.interactiveSessionId,
        accountUserId: app.accountUserId,
        roomId: app.room.id,
        contentKey: app.contentKey,
        dark: theme?.brightness == Brightness.dark,
        seedColor: (theme?.colorScheme.primary ?? Colors.indigo).toARGB32(),
        kind: app.kind,
      );

  factory MiniAppWindowConfig.fromJson(Map<String, Object?> json) =>
      MiniAppWindowConfig(
        appId: json['app_id'] as String,
        appUrl: json['app_url'] as String,
        appName: json['app_name'] as String,
        appType: json['app_type'] as String,
        appStartPath: json['app_start_path'] as String,
        startParam: json['start_param'] as String? ?? '',
        botMxid: json['bot_mxid'] as String?,
        joinRequestQueryId: json['join_request_query_id'] as String?,
        interactiveSessionId: json['interactive_session_id'] as String? ?? '',
        accountUserId: json['account_user_id'] as String?,
        roomId: json['room_id'] as String,
        contentKey: json['content_key'] as String,
        dark: json['dark'] as bool,
        seedColor: json['seed_color'] as int,
        kind:
            MiniAppKind.values.asNameMap()[json['kind']] ?? MiniAppKind.miniApp,
      );

  Map<String, Object?> toJson() => {
    'app_id': appId,
    'app_url': appUrl,
    'app_name': appName,
    'app_type': appType,
    'app_start_path': appStartPath,
    'start_param': startParam,
    'bot_mxid': botMxid,
    'join_request_query_id': joinRequestQueryId,
    'interactive_session_id': interactiveSessionId,
    'account_user_id': accountUserId,
    'room_id': roomId,
    'content_key': contentKey,
    'dark': dark,
    'seed_color': seedColor,
    'kind': kind.name,
  };
}

/// Окно ОС одного открепленного mini App (со стороны главного движка).
class _MiniAppWindow {
  _MiniAppWindow(this.contentKey);

  /// Какой контент окно должно показывать сейчас.
  String contentKey;

  /// Какой контент окну уже отправлен (при создании или `navigate`).
  String? sentKey;
  WindowController? controller;
}

/// Окна ОС открепленных mini App — живёт в главном движке.
///
/// Источник истины — [MiniAppManager]: окно есть ровно у каждого инстанса с
/// `detached`. Сверка идёт на каждое изменение менеджера, поэтому закрытие,
/// прикрепление, выход из аккаунта и новый deep-link обрабатываются в одном
/// месте. Окно, закрытое крестиком ОС, замечаем по `onWindowsChanged`.
class MiniAppWindows {
  MiniAppWindows._();
  static final MiniAppWindows instance = MiniAppWindows._();

  final _manager = MiniAppManager.instance;
  final Map<String, _MiniAppWindow> _windows = {};
  bool _started = false;

  /// Тема Лизы — последняя, с которой строился хост (MiniAppOverlay).
  ThemeData? theme;

  void start() {
    if (_started) return;
    _started = true;
    _manager.addListener(_reconcile);
    _manager.windowFocusRequests.listen(_focus);
    onWindowsChanged.listen((_) => _forgetClosedWindows());
    unawaited(_hostChannel.setMethodCallHandler(_handleHostCall));
  }

  void _reconcile() {
    final detached = {for (final a in _manager.detachedApps) a.appId: a};
    for (final appId in _windows.keys.toList()) {
      if (!detached.containsKey(appId)) _close(_windows.remove(appId)!);
    }
    for (final app in detached.values) {
      final window = _windows[app.appId];
      if (window == null) {
        unawaited(_create(app));
      } else {
        window.contentKey = app.contentKey;
        _sync(app.appId, window);
      }
    }
  }

  Future<void> _create(MiniAppInstance app) async {
    final window = _windows[app.appId] = _MiniAppWindow(app.contentKey);
    final config = MiniAppWindowConfig.of(app, theme);
    try {
      final controller = await WindowController.create(
        WindowConfiguration(
          arguments: jsonEncode(config.toJson()),
          hiddenAtLaunch: true,
        ),
      );
      window
        ..controller = controller
        ..sentKey = config.contentKey;
    } catch (e, s) {
      // Окно не создалось — не теряем приложение: показываем панелью.
      Logs().e('[MiniAppWindows] не удалось создать окно', e, s);
      Monitoring.capture(e, s);
      if (_windows[app.appId] == window) {
        _windows.remove(app.appId);
        _manager.attach(app.appId);
      }
      return;
    }
    if (_windows[app.appId] != window) {
      // Пока окно создавалось, app закрыли или прикрепили.
      _close(window);
      return;
    }
    _sync(app.appId, window);
  }

  /// Новый deep-link для уже открытого окна — пересоздать контент в нём.
  void _sync(String appId, _MiniAppWindow window) {
    final controller = window.controller;
    if (controller == null || window.sentKey == window.contentKey) return;
    final app = _manager.detachedApps
        .where((a) => a.appId == appId)
        .firstOrNull;
    if (app == null) return;
    final config = MiniAppWindowConfig.of(app, theme);
    window.sentKey = config.contentKey;
    controller.invokeMethod<void>('navigate', config.toJson()).catchError((
      Object e,
    ) {
      // Движок окна ещё не поднял обработчик — повторим при следующей сверке.
      Logs().w('[MiniAppWindows] navigate → ${controller.windowId}: $e');
      if (window.sentKey == config.contentKey) window.sentKey = null;
    });
  }

  void _focus(String appId) {
    final controller = _windows[appId]?.controller;
    if (controller != null) _invoke(controller, 'focus');
  }

  void _close(_MiniAppWindow window) {
    final controller = window.controller;
    // Ещё создаётся — закроем, когда create вернётся (см. _create).
    if (controller != null) _invoke(controller, 'close');
  }

  void _invoke(WindowController controller, String method, [Object? args]) {
    controller.invokeMethod<void>(method, args).catchError((Object e) {
      Logs().w('[MiniAppWindows] $method → ${controller.windowId}: $e');
    });
  }

  /// Окна, закрытые крестиком ОС: их app закрываем и в менеджере.
  Future<void> _forgetClosedWindows() async {
    // Проверяем только окна, созданные ДО запроса списка: окно, которое
    // создастся, пока ждём ответ, в старый список не попадёт и не должно
    // считаться закрытым.
    final known = {
      for (final entry in _windows.entries)
        if (entry.value.controller != null) entry.key: entry.value,
    };
    final alive = (await WindowController.getAll())
        .map((c) => c.windowId)
        .toSet();
    for (final MapEntry(key: appId, value: window) in known.entries) {
      if (alive.contains(window.controller!.windowId)) continue;
      // За время ожидания окно могли уже заменить или закрыть штатно.
      if (_windows[appId] != window) continue;
      _windows.remove(appId);
      _manager.close(appId);
    }
  }

  RoomMiniAppHostApi _hostFor(String appId, Map<String, Object?> args) {
    final app = _manager.detachedApps
        .where((a) => a.appId == appId)
        .firstOrNull;
    if (app == null ||
        !app.sessionCurrent ||
        args['content_key'] != app.contentKey ||
        args['session_id'] != app.interactiveSessionId ||
        args['account_user_id'] != app.accountUserId) {
      throw StateError('Mini App window session changed');
    }
    return RoomMiniAppHostApi(
      room: app.room,
      appId: app.appId,
      appUrl: app.appUrl,
      startParam: app.startParam,
      botMxid: app.botMxid,
      joinRequestQueryId: app.joinRequestQueryId,
      interactiveSessionId: app.interactiveSessionId,
      interactiveState: app.interactiveState,
      isCurrent: () =>
          app.sessionCurrent && _manager.detachedApps.contains(app),
      beforePresent: () async {
        if (defaultTargetPlatform == TargetPlatform.macOS) {
          await const MethodChannel(
            'liza/macos_window',
          ).invokeMethod<void>('bringToFront');
        }
      },
    );
  }

  void _setVisibility(String appId, Map<Object?, Object?> snapshot) {
    final app = _manager.detachedApps
        .where((app) => app.appId == appId)
        .firstOrNull;
    if (app == null) return;
    final sequence = snapshot['sequence'];
    final nativeEpoch = snapshot['visibility_epoch'];
    if (sequence is! int || nativeEpoch is! int) {
      app.interactiveState.setVisible(false);
      return;
    }
    if (sequence <= app.interactiveState.nativeSnapshotSequence) return;
    app.interactiveState.nativeSnapshotSequence = sequence;
    final previous = app.interactiveState.nativeVisibilityEpoch;
    if (previous != null && nativeEpoch != previous) {
      app.interactiveState.setVisible(false);
    }
    app.interactiveState.nativeVisibilityEpoch = nativeEpoch;
    final focusEpoch = snapshot['focus_epoch'];
    final mainFocusEpoch = snapshot['main_focus_epoch'];
    if (focusEpoch is! int || mainFocusEpoch is! int) {
      app.interactiveState.setVisible(false);
      return;
    }
    final state = app.interactiveState;
    final oldFocus = state.nativeFocusEpoch;
    final oldMainFocus = state.nativeMainFocusEpoch;
    if (oldFocus != null && oldFocus != focusEpoch) {
      if (state.presenting &&
          state.presentationVisibilityEpoch == state.visibilityEpoch &&
          !state.mainFocusTransferred &&
          focusEpoch == oldFocus + 1 &&
          snapshot['direct_main_focus_epoch'] == focusEpoch &&
          snapshot['main_focused'] == true) {
        state.mainFocusTransferred = true;
      } else {
        state.setVisible(false);
      }
    }
    if (oldMainFocus != null && oldMainFocus != mainFocusEpoch) {
      state.setVisible(false);
    }
    state.nativeFocusEpoch = focusEpoch;
    state.nativeMainFocusEpoch = mainFocusEpoch;

    // Подъём главного окна для prepared-picker — намеренный перевод фокуса.
    // Он допускается лишь пока наш picker открыт, окно app видимо, а главное
    // окно действительно foreground. Уход в другое приложение отменяет запрос.
    app.interactiveState.setVisible(
      snapshot['closed'] == false &&
          snapshot['visible'] == true &&
          snapshot['minimized'] == false &&
          (snapshot['focused'] == true ||
              (state.presenting &&
                  state.mainFocusTransferred &&
                  state.presentationVisibilityEpoch == state.visibilityEpoch &&
                  snapshot['direct_main_focus_epoch'] == focusEpoch &&
                  snapshot['main_focused'] == true)),
    );
  }

  Future<void> _refreshVisibility(String appId) async {
    final controller = _windows[appId]?.controller;
    if (controller == null) return; // Тестовый IPC не создаёт настоящее окно.
    try {
      final snapshot = await controller
          .invokeMethod<Object?>('interactiveVisibility')
          .timeout(const Duration(seconds: 2));
      _setVisibility(appId, snapshot is Map ? snapshot : const {});
    } catch (_) {
      _setVisibility(appId, const {});
    }
  }

  @visibleForTesting
  Future<Object?> debugHandleHostCall(MethodCall call) => _handleHostCall(call);

  Future<Object?> _handleHostCall(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final appId = args['app_id'] as String;
    if (call.method != 'reportError') _hostFor(appId, args);
    switch (call.method) {
      case 'windowVisibility':
        _setVisibility(appId, args['snapshot'] as Map? ?? const {});
        return null;
      case 'interactive':
        await _refreshVisibility(appId);
        return _hostFor(appId, args).interactiveRequest(
          args['action'] as String,
          Map<String, dynamic>.from(args['data'] as Map),
        );
      case 'fetchInitData':
        return _hostFor(appId, args).fetchInitData();
      case 'fetchPageDocument':
        final event = _manager.detachedApps
            .where((a) => a.appId == appId)
            .firstOrNull
            ?.pageEvent;
        if (event == null) throw StateError('нет страницы для окна $appId');
        return loadFluidPageDocument(event);
      case 'sendData':
        final content = jsonDecode(args['content'] as String);
        await _hostFor(
          appId,
          args,
        ).sendData(Map<String, Object?>.from(content));
        return null;
      case 'createInviteLink':
        return _hostFor(
          appId,
          args,
        ).createInviteLink(args['start_path'] as String?);
      case 'attach':
        _manager.attach(appId, startPath: args['start_path'] as String?);
        // Окно Лизы могли закрыть (на macOS оно лишь скрыто) — панель
        // появится в нём, показываем его.
        if (defaultTargetPlatform == TargetPlatform.macOS) {
          const MethodChannel(
            'liza/macos_window',
          ).invokeMethod<void>('bringToFront').catchError((_) {});
        }
        return null;
      case 'close':
        _manager.close(appId);
        return null;
      case 'reportError':
        final error = Exception('[mini App window] ${args['error']}');
        final stack = args['stack'] as String?;
        Logs().e(
          '[MiniAppWindow] ${args['error']}',
          null,
          stack == null ? null : StackTrace.fromString(stack),
        );
        Monitoring.capture(
          error,
          stack == null ? null : StackTrace.fromString(stack),
        );
        return null;
    }
    throw MissingPluginException(call.method);
  }
}

/// Хост контента в окне ОС: каждый вызов — RPC к главному движку.
class RemoteMiniAppHostApi
    implements MiniAppHostApi, MiniAppInteractiveHostApi {
  final String appId;
  final String contentKey;
  final String sessionId;
  final String? accountUserId;

  const RemoteMiniAppHostApi(
    this.appId, {
    this.contentKey = '',
    this.sessionId = '',
    this.accountUserId,
  });

  factory RemoteMiniAppHostApi.fromConfig(MiniAppWindowConfig config) =>
      RemoteMiniAppHostApi(
        config.appId,
        contentKey: config.contentKey,
        sessionId: config.interactiveSessionId,
        accountUserId: config.accountUserId,
      );

  @override
  Future<Map<String, dynamic>> interactiveRequest(
    String action,
    Map<String, dynamic> data,
  ) async => Map<String, dynamic>.from(
    (await _call<Map>('interactive', {'action': action, 'data': data}))!,
  );

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) =>
      _hostChannel
          .invokeMethod<T>(method, {
            'app_id': appId,
            'content_key': contentKey,
            'session_id': sessionId,
            'account_user_id': accountUserId,
            ...?args,
          })
          .timeout(switch (method) {
            'interactive' => const Duration(seconds: 100),
            // Скачать и расшифровать до 1,5 МБ — дольше обычного RPC.
            'fetchPageDocument' => const Duration(seconds: 45),
            _ => _rpcTimeout,
          });

  @override
  Future<String> fetchInitData() async =>
      (await _call<String>('fetchInitData'))!;

  @override
  Future<void> sendData(Map<String, Object?> content) =>
      _call<void>('sendData', {'content': jsonEncode(content)});

  @override
  Future<String> createInviteLink(String? startPath) async =>
      (await _call<String>('createInviteLink', {'start_path': startPath}))!;

  /// Документ жидкой страницы (с CSP): у окна нет Matrix-клиента, событие
  /// скачивает и расшифровывает главное окно.
  Future<String> fetchPageDocument() async =>
      (await _call<String>('fetchPageDocument'))!;

  Future<void> attach(String? startPath) =>
      _call<void>('attach', {'start_path': startPath});

  Future<void> close() => _call<void>('close');

  Future<void> reportVisibility(Map<Object?, Object?> snapshot) =>
      _call<void>('windowVisibility', {'snapshot': snapshot});
}

void _reportError(Object error, StackTrace? stack) {
  _hostChannel
      .invokeMethod<void>('reportError', {
        'app_id': '',
        'error': '$error',
        'stack': stack?.toString(),
      })
      .catchError((_) {});
}

/// Точка входа движка окна ОС. Ничего из запуска Лизы здесь нет: ни Matrix,
/// ни логгера в файл, ни пушей, ни мониторинга — всё это у главного движка, а
/// второй писатель тех же файлов и ключей их бы испортил.
Future<void> miniAppWindowMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    _reportError(details.exceptionAsString(), details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _reportError(error, stack);
    return true;
  };
  final config = MiniAppWindowConfig.fromJson(
    Map<String, Object?>.from(jsonDecode(args[2]) as Map),
  );
  final controller = await WindowController.fromCurrentEngine();
  runApp(MiniAppWindowApp(controller: controller, config: config));
}

/// Окно mini App рисует свою шапку вместо системной (macOS — прозрачный
/// titlebar, Windows — снятый WS_CAPTION). Откат Windows — выставить false.
final bool miniAppWindowFrameless =
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

/// Единственная шапка отдельного окна: название, «Прикрепить к Лизе», крестик.
/// Без [onAttach] кнопки «Прикрепить» нет (жидкая страница живёт в окне).
class MiniAppWindowHeader extends StatelessWidget {
  final String title;
  final String attachTooltip;
  final String closeTooltip;
  final VoidCallback? onAttach;
  final VoidCallback onClose;
  final VoidCallback onDragStart;

  const MiniAppWindowHeader({
    required this.title,
    required this.attachTooltip,
    required this.closeTooltip,
    this.onAttach,
    required this.onClose,
    required this.onDragStart,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              key: const ValueKey('miniapp-window-drag'),
              behavior: HitTestBehavior.translucent,
              onPointerDown: (e) {
                if (e.buttons == kPrimaryMouseButton) onDragStart();
              },
              child: Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ),
          if (onAttach != null)
            IconButton(
              key: const ValueKey('miniapp-window-attach'),
              tooltip: attachTooltip,
              // Обратный «Открепить» из шапки панели: тот же значок, повёрнутый.
              icon: ExcludeSemantics(
                child: Transform.rotate(
                  angle: math.pi,
                  child: const Icon(Icons.open_in_new, size: 20),
                ),
              ),
              onPressed: onAttach,
            ),
          IconButton(
            key: const ValueKey('miniapp-window-close'),
            tooltip: closeTooltip,
            icon: const Icon(Icons.close, size: 22),
            onPressed: onClose,
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

class MiniAppWindowApp extends StatefulWidget {
  final WindowController controller;
  final MiniAppWindowConfig config;

  const MiniAppWindowApp({
    required this.controller,
    required this.config,
    super.key,
  });

  @override
  State<MiniAppWindowApp> createState() => _MiniAppWindowAppState();
}

class _MiniAppWindowAppState extends State<MiniAppWindowApp> {
  late MiniAppWindowConfig _config = widget.config;
  late RemoteMiniAppHostApi _host = RemoteMiniAppHostApi.fromConfig(_config);
  // Новый ключ на каждый `navigate`: контент пересоздаётся на новом пути.
  var _contentKey = GlobalKey<MiniAppWebViewContentState>();

  String? _toast;
  int _toastGen = 0;
  Timer? _visibilityTimer;
  Future<void> _visibilityReports = Future<void>.value();

  Future<Map<Object?, Object?>> _nativeVisibility() async {
    try {
      return await _nativeWindow.invokeMapMethod<Object?, Object?>(
            'visibility',
          ) ??
          const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> _reportVisibility([Map<Object?, Object?>? snapshot]) {
    final host = _host;
    // Не теряем hidden/closed callback, даже если предыдущий RPC ещё идёт.
    // Снимки сериализованы: старое visible не перезапишет более новое hidden.
    _visibilityReports = _visibilityReports
        .then((_) async {
          if (!mounted || !identical(host, _host)) return;
          final value = snapshot ?? await _nativeVisibility();
          if (mounted && identical(host, _host)) {
            await host.reportVisibility(value);
          }
        })
        .catchError((Object _) {});
    return _visibilityReports;
  }

  @override
  void dispose() {
    _visibilityTimer?.cancel();
    _nativeWindow.setMethodCallHandler(null);
    unawaited(
      _host.reportVisibility(const {'closed': true}).catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    widget.controller.setWindowMethodHandler(_handleWindowCall);
    _nativeWindow.setMethodCallHandler((call) async {
      if (call.method == 'visibilityChanged') {
        await _reportVisibility(
          call.arguments is Map ? call.arguments as Map : const {},
        );
      }
    });
    _nativeWindow
        .invokeMethod<void>('present', {
          'title': _config.appName,
          'frameless': miniAppWindowFrameless,
        })
        .then((_) => _reportVisibility());
    // Снимок страхует пропущенное native notification и смену главного окна.
    _visibilityTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      unawaited(_reportVisibility());
    });
  }

  Future<Object?> _handleWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'interactiveVisibility':
        return _nativeVisibility();
      case 'navigate':
        final config = MiniAppWindowConfig.fromJson(
          Map<String, Object?>.from(call.arguments as Map),
        );
        setState(() {
          _config = config;
          _host = RemoteMiniAppHostApi.fromConfig(config);
          _contentKey = GlobalKey<MiniAppWebViewContentState>();
        });
        await _nativeWindow.invokeMethod<void>('setTitle', {
          'title': config.appName,
        });
        await _nativeWindow.invokeMethod<void>('focus');
      case 'focus':
        await _nativeWindow.invokeMethod<void>('focus');
      case 'close':
        // Сначала ответить: закрытое окно уносит с собой движок, и ответ
        // после закрытия уже некому отправить — вызывающий ждал бы вечно.
        Timer.run(() => _nativeWindow.invokeMethod<void>('close'));
      case 'state':
        // Что показывает окно — для диагностики и нативного стража.
        return {
          'content_key': _config.contentKey,
          'loaded_url': _contentKey.currentState?.loadedUrl,
        };
    }
    return null;
  }

  void _showToast(String message, {bool autoHide = true}) {
    final gen = ++_toastGen;
    setState(() => _toast = message);
    if (autoHide) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted && _toastGen == gen) setState(() => _toast = null);
      });
    }
  }

  Future<void> _attach(L10n l10n) async {
    final state = _contentKey.currentState;
    if (state != null && state.paymentInProgress) {
      _showToast(l10n.miniAppMoveDuringPayment);
      return;
    }
    final startPath = await state?.currentStartPath();
    try {
      await _host.attach(startPath);
    } catch (e, s) {
      _reportError(e, s);
    }
  }

  void _startDrag() {
    _nativeWindow.invokeMethod<void>('startDrag').catchError((Object _) {});
  }

  void _close() {
    _host.close().catchError((Object e, StackTrace s) {
      _reportError(e, s);
      // Главный движок не ответил — окно всё равно закрываем.
      _nativeWindow.invokeMethod<void>('close');
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = _config.dark ? Brightness.dark : Brightness.light;
    final theme = LizaThemes.buildTheme(
      context,
      brightness,
      Color(_config.seedColor),
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: _config.appName,
      theme: theme,
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) {
          final l10n = L10n.of(context);
          final colorScheme = Theme.of(context).colorScheme;
          return Scaffold(
            backgroundColor: colorScheme.surface,
            body: Stack(
              children: [
                Column(
                  children: [
                    MiniAppWindowHeader(
                      title: _config.appName,
                      attachTooltip: l10n.miniAppAttach,
                      closeTooltip: l10n.close,
                      onAttach: _config.kind == MiniAppKind.html
                          ? null
                          : () => _attach(l10n),
                      onClose: _close,
                      onDragStart: _startDrag,
                    ),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    Expanded(
                      child: _config.kind == MiniAppKind.html
                          ? FluidPageView(
                              key: ValueKey(_config.contentKey),
                              pageKey: _config.contentKey,
                              loadDocument: _host.fetchPageDocument,
                            )
                          : MiniAppWebViewContent(
                              key: _contentKey,
                              appUrl: _config.appUrl,
                              appId: _config.appId,
                              appName: _config.appName,
                              host: _host,
                              roomId: _config.roomId,
                              appType: _config.appType,
                              appStartPath: _config.appStartPath,
                              onClose: _close,
                            ),
                    ),
                  ],
                ),
                if (_toast != null)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 32,
                    child: MiniAppToast(text: _toast!),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
