import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'package:matrix/matrix.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/utils/adaptive_orientation.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/file_logger.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/utils/push_journal.dart';
import 'package:liza/utils/notification_background_handler.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/app_restart.dart';
import 'package:liza/utils/browser_context_menu.dart';
import 'package:liza/utils/secure_storage.dart';
import 'config/setting_keys.dart';
import 'utils/background_push.dart';
import 'widgets/liza_app.dart';

ReceivePort? mainIsolateReceivePort;
bool _guiStarted = false;

void main([List<String> args = const []]) async {
  // Движок отдельного окна mini App (desktop_multi_window): свой лёгкий
  // MaterialApp, а не вторая Лиза — до любой инициализации ниже.
  if (args.firstOrNull == kMiniAppWindowEntryArg) {
    await miniAppWindowMain(args);
    return;
  }
  runZonedGuarded(() async {
    if (PlatformInfos.isAndroid) {
      final port = mainIsolateReceivePort = ReceivePort();
      IsolateNameServer.removePortNameMapping(AppConfig.mainIsolatePortName);
      IsolateNameServer.registerPortWithName(
        port.sendPort,
        AppConfig.mainIsolatePortName,
      );
      await waitForPushIsolateDone();
    }

    // Our background push shared isolate accesses flutter-internal things very early in the startup proccess
    // To make sure that the parts of flutter needed are started up already, we need to ensure that the
    // widget bindings are initialized already.
    WidgetsFlutterBinding.ensureInitialized();
    debugPrint('[BOOT] WidgetsBinding initialized');

    configureBrowserContextMenu(
      isWeb: kIsWeb,
      disable: BrowserContextMenu.disableContextMenu,
    );

    // Инициализируем libmpv-бэкенд для media_kit (видео-плеер в чате)
    // и регистрируем его же как backend для just_audio на Windows/Linux.
    MediaKit.ensureInitialized();
    JustAudioMediaKit.ensureInitialized();

    // Initialize file logger early to capture all startup logs
    await FileLogger.instance.init();
    debugPrint('[BOOT] FileLogger initialized');
    // Журнал пути уведомлений (только главный изолят — единственный писатель
    // файла). Старт не ждёт чтения файла: записи до готовности держатся в
    // памяти и уходят на диск после init.
    unawaited(PushJournal.instance.init());

    // Мониторинг ошибок. No-op без build-флагов (обычная разработка/hot-reload).
    await Monitoring.init();
    debugPrint('[BOOT] Monitoring active=${Monitoring.isActive}');
    // Heartbeat живости флота — fire-and-forget (не блокирует старт). No-op без
    // мониторинга; троттлится по номеру сборки (см. Monitoring.reportHealthHeartbeat).
    unawaited(Monitoring.reportHealthHeartbeat());

    // Capture Flutter framework errors
    FlutterError.onError = (details) {
      Logs().e(
        'Flutter framework error: ${details.exceptionAsString()}',
        details.exception,
        details.stack,
      );
      FileLogger.instance.log(
        'FLUTTER_ERROR',
        details.exceptionAsString(),
        details.exception,
        details.stack,
      );
      Monitoring.capture(details.exception, details.stack);
    };

    // Capture platform dispatcher errors (e.g. errors in callbacks)
    PlatformDispatcher.instance.onError = (error, stack) {
      Logs().e('Platform dispatcher error', error, stack);
      FileLogger.instance.log('PLATFORM_ERROR', 'Platform dispatcher error', error, stack);
      Monitoring.capture(error, stack);
      return true;
    };

    // Политика ориентаций по типу устройства: телефон — только портрет,
    // планшет — поворот вслед за устройством. Это boot-window дефолт;
    // финальный авторитет — реактивный `AdaptiveOrientation` в дереве
    // (он же ловит split-screen/трансформеры). Если экран ещё не измерен,
    // хелпер деградирует к строгому портрету.
    if (PlatformInfos.isMobile) {
      await SystemChrome.setPreferredOrientations(
        allowedOrientationsForCurrentView(),
      );
    }

    debugPrint('[BOOT] Initializing AppSettings...');
    final store = await AppSettings.init();
    debugPrint('[BOOT] AppSettings done');
    Logs().i('Welcome to ${AppSettings.applicationName.value} <3');

    debugPrint('[BOOT] Initializing Vodozemac...');
    try {
      await vod.init(wasmPath: './assets/assets/vodozemac/');
    } catch (e) {
      // Already initialized (e.g. after auto-recovery retry) — safe to ignore.
      if (!e.toString().contains('twice')) rethrow;
    }
    debugPrint('[BOOT] Vodozemac done');

    // Временная диагностика «🔒 encrypted»: verbose-логи SDK,
    // чтобы видеть причины fail decrypt (no inbound session, ratchet, и т. п.).
    // Удалить после диагностики.
    Logs().level = Level.verbose;

    Logs().nativeColors = !PlatformInfos.isIOS;
    debugPrint('[BOOT] Getting clients...');
    List<Client> clients;
    try {
      clients = await ClientManager.getClients(store: store);
    } catch (e, s) {
      Logs().e(
        'Fatal: getClients failed, starting with empty client list',
        e,
        s,
      );
      FileLogger.instance.log(
        'BOOT_ERROR',
        'getClients failed, starting with empty client list',
        e,
        s,
      );
      Monitoring.capture(e, s, fatal: true);
      // Store the error so the router redirects to /init-error.
      ClientManager.initializationError ??= e;
      ClientManager.initializationErrorStack ??= s;
      // Provide a bare-minimum placeholder client so the widget tree can
      // build. It won't be logged in, so the router will redirect to
      // /init-error instead of trying to use this client.
      // On native, Client requires a database — we cannot create a
      // placeholder without one. Let the zone error handler show a loader
      // and auto-retry main().
      rethrow;
    }
    debugPrint('[BOOT] Clients ready: ${clients.length}');

    // If the app starts in detached mode, we assume that it is in
    // background fetch mode for processing push notifications. This is
    // currently only supported on Android.
    if (PlatformInfos.isAndroid &&
        AppLifecycleState.detached ==
            WidgetsBinding.instance.lifecycleState) {
      if (ClientManager.initializationError != null) {
        // Cannot do background push with a broken client — fall through
        // to start the GUI so the error page is shown when user opens the app.
        Logs().w(
          'Client initialization failed, skipping background push mode',
        );
      } else {
        // Do not send online presences when app is in background fetch mode.
        for (final client in clients) {
          client.backgroundSync = false;
          client.syncPresence = PresenceType.offline;
        }

        // In the background fetch mode we do not want to waste ressources with
        // starting the Flutter engine but process incoming push notifications.
        BackgroundPush.clientOnly(clients);
        // To start the flutter engine afterwards we add an custom observer.
        WidgetsBinding.instance.addObserver(AppStarter(clients, store));
        Logs().i(
          '${AppSettings.applicationName.value} started in background-fetch mode. No GUI will be created unless the app is no longer detached.',
        );
        return;
      }
    }

    // Started in foreground mode.
    Logs().i(
      '${AppSettings.applicationName.value} started in foreground mode. Rendering GUI...',
    );
    debugPrint('[BOOT] Starting GUI...');
    await startGui(clients, store);
    _guiStarted = true;
    debugPrint('[BOOT] GUI started');
  }, (error, stackTrace) {
    debugPrint('[ZONE_ERROR] $error');
    debugPrint('[ZONE_ERROR] $stackTrace');
    Logs().e('Uncaught error in root zone', error, stackTrace);
    FileLogger.instance.log('ZONE_ERROR', 'Uncaught error in root zone', error, stackTrace);
    // Ошибка до старта GUI — фатальный сбой; после — runtime-ошибка.
    Monitoring.capture(error, stackTrace, fatal: !_guiStarted);

    // After GUI is up, runtime errors (link preview, voice message,
    // widget rendering, temp file cleanup, etc.) should never kill the app.
    // Just log and continue — the user won't even notice.
    if (_guiStarted) return;

    // Startup failure (DB crash, Vodozemac init, etc.) — the user would
    // see a grey/black screen. Show a brief loader then hard-restart.
    try {
      WidgetsFlutterBinding.ensureInitialized();
      runApp(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                color: AppConfig.primaryColor,
              ),
            ),
          ),
        ),
      );

      Future.delayed(const Duration(seconds: 2), AppRestart.restart);
    } catch (_) {
      AppRestart.restart();
    }
  });
}

/// Fetch the pincode for the applock and start the flutter engine.
Future<void> startGui(List<Client> clients, SharedPreferences store) async {
  // Fetch the pin for the applock if existing for mobile applications.
  String? pin;
  if (PlatformInfos.isMobile) {
    try {
      pin = await flutterSecureStorage.read(
        key: 'chat.fluffy.app_lock',
      );
    } catch (e, s) {
      Logs().d('Unable to read PIN from Secure storage', e, s);
    }
  }

  // Preload first client
  final firstClient = clients.firstOrNull;
  await firstClient?.roomsLoading;
  await firstClient?.accountDataLoading;

  // mini App отдельным окном ОС — на десктопах, где есть WebView (на Linux
  // flutter_inappwebview не работает).
  final miniApps = MiniAppManager.instance;
  miniApps.windowsSupported = PlatformInfos.isMacOS || PlatformInfos.isWindows;
  if (miniApps.windowsSupported) MiniAppWindows.instance.start();

  runApp(LizaApp(clients: clients, pincode: pin, store: store));
}

/// Watches the lifecycle changes to start the application when it
/// is no longer detached.
class AppStarter with WidgetsBindingObserver {
  final List<Client> clients;
  final SharedPreferences store;
  bool guiStarted = false;

  AppStarter(this.clients, this.store);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (guiStarted) return;
    if (state == AppLifecycleState.detached) return;

    Logs().i(
      '${AppSettings.applicationName.value} switches from the detached background-fetch mode to ${state.name} mode. Rendering GUI...',
    );
    // Switching to foreground mode needs to reenable send online sync presence.
    for (final client in clients) {
      client.backgroundSync = true;
      client.syncPresence = PresenceType.online;
    }
    startGui(clients, store);
    // We must make sure that the GUI is only started once.
    guiStarted = true;
  }
}
