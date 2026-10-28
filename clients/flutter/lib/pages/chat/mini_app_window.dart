import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_host_api.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
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
  final String roomId;
  final String contentKey;
  final bool dark;
  final int seedColor;

  const MiniAppWindowConfig({
    required this.appId,
    required this.appUrl,
    required this.appName,
    required this.appType,
    required this.appStartPath,
    required this.roomId,
    required this.contentKey,
    required this.dark,
    required this.seedColor,
  });

  factory MiniAppWindowConfig.of(MiniAppInstance app, ThemeData? theme) =>
      MiniAppWindowConfig(
        appId: app.appId,
        appUrl: app.appUrl,
        appName: app.appName,
        appType: app.appType,
        appStartPath: app.appStartPath,
        roomId: app.room.id,
        contentKey: app.contentKey,
        dark: theme?.brightness == Brightness.dark,
        seedColor: (theme?.colorScheme.primary ?? Colors.indigo).toARGB32(),
      );

  factory MiniAppWindowConfig.fromJson(Map<String, Object?> json) =>
      MiniAppWindowConfig(
        appId: json['app_id'] as String,
        appUrl: json['app_url'] as String,
        appName: json['app_name'] as String,
        appType: json['app_type'] as String,
        appStartPath: json['app_start_path'] as String,
        roomId: json['room_id'] as String,
        contentKey: json['content_key'] as String,
        dark: json['dark'] as bool,
        seedColor: json['seed_color'] as int,
      );

  Map<String, Object?> toJson() => {
    'app_id': appId,
    'app_url': appUrl,
    'app_name': appName,
    'app_type': appType,
    'app_start_path': appStartPath,
    'room_id': roomId,
    'content_key': contentKey,
    'dark': dark,
    'seed_color': seedColor,
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

  MiniAppHostApi _hostFor(String appId) {
    final app = _manager.detachedApps
        .where((a) => a.appId == appId)
        .firstOrNull;
    if (app == null) throw StateError('mini App $appId не открыт окном');
    return RoomMiniAppHostApi(
      room: app.room,
      appId: app.appId,
      appUrl: app.appUrl,
    );
  }

  Future<Object?> _handleHostCall(MethodCall call) async {
    final args = Map<String, Object?>.from(call.arguments as Map);
    final appId = args['app_id'] as String;
    switch (call.method) {
      case 'fetchInitData':
        return _hostFor(appId).fetchInitData();
      case 'sendData':
        final content = jsonDecode(args['content'] as String);
        await _hostFor(appId).sendData(Map<String, Object?>.from(content));
        return null;
      case 'createInviteLink':
        return _hostFor(appId).createInviteLink(args['start_path'] as String?);
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
class RemoteMiniAppHostApi implements MiniAppHostApi {
  final String appId;

  const RemoteMiniAppHostApi(this.appId);

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) =>
      _hostChannel
          .invokeMethod<T>(method, {'app_id': appId, ...?args})
          .timeout(_rpcTimeout);

  @override
  Future<String> fetchInitData() async =>
      (await _call<String>('fetchInitData'))!;

  @override
  Future<void> sendData(Map<String, Object?> content) =>
      _call<void>('sendData', {'content': jsonEncode(content)});

  @override
  Future<String> createInviteLink(String? startPath) async =>
      (await _call<String>('createInviteLink', {'start_path': startPath}))!;

  Future<void> attach(String? startPath) =>
      _call<void>('attach', {'start_path': startPath});

  Future<void> close() => _call<void>('close');
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
  late final RemoteMiniAppHostApi _host = RemoteMiniAppHostApi(_config.appId);
  // Новый ключ на каждый `navigate`: контент пересоздаётся на новом пути.
  var _contentKey = GlobalKey<MiniAppWebViewContentState>();

  String? _toast;
  int _toastGen = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.setWindowMethodHandler(_handleWindowCall);
    _nativeWindow.invokeMethod<void>('present', {'title': _config.appName});
  }

  Future<Object?> _handleWindowCall(MethodCall call) async {
    switch (call.method) {
      case 'navigate':
        final config = MiniAppWindowConfig.fromJson(
          Map<String, Object?>.from(call.arguments as Map),
        );
        setState(() {
          _config = config;
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

  Future<void> _copyLink(L10n l10n) async {
    final state = _contentKey.currentState;
    if (state == null) return;
    _showToast(l10n.miniAppCreatingLink, autoHide: false);
    final message = await state.copyInviteLink();
    if (mounted) _showToast(message);
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
                    SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              _config.appName,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('miniapp-window-copy-link'),
                            tooltip: l10n.miniAppCopyLink,
                            icon: const Icon(Icons.link, size: 22),
                            onPressed: () => _copyLink(l10n),
                          ),
                          IconButton(
                            key: const ValueKey('miniapp-window-attach'),
                            tooltip: l10n.miniAppAttach,
                            icon: const Icon(Icons.push_pin_outlined, size: 20),
                            onPressed: () => _attach(l10n),
                          ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: colorScheme.outlineVariant),
                    Expanded(
                      child: MiniAppWebViewContent(
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
