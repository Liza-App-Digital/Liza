// Нативный страж ledger:RL-miniapp-detached-window (macOS, Ярус C).
//
// mini App открывается ОТДЕЛЬНЫМ окном ОС: у окна свой Flutter-движок
// (desktop_multi_window), Matrix — только у главного. Widget-тест этого не
// видит: здесь настоящие окна, настоящий WebView во втором движке и настоящий
// RPC между движками.
//
// Прод-сессия не нужна: локальный HTTP-сервер отвечает за Synapse
// (`/_synapse/client/miniapp/v1/init_data`) — по его журналу видно, что initData
// окну выдал главный движок. Страница — https://example.com (контент mini App
// отменяет любую навигацию не по https). Что загрузило окно, спрашиваем у
// самого окна методом `state`.
//
// Windows (VM): то же собранным release-приложением с LIZA_PILOT_RESULT=<файл>
// (AC:RL-miniapp-detached-window/13 — пилот 27.10 прошёл все шаги).
// Запуск — собранным приложением, НЕ `flutter test -d macos`: под flutter test
// изолят второго движка стартует на паузе отладчика и не исполняется.
//   flutter build macos --debug -t integration_test/liza/miniapp_detached_window_test.dart
//   build/macos/Build/Products/Debug/Liza.app/Contents/MacOS/Liza
// Успех — строка «RL-miniapp-detached-window: native OK»; затем окно mini App
// открывается снова (строка «можно закрывать Лизу») — на Windows драйвер VM
// закрывает окно Лизы и ждёт, что процесс завершится (AC-16..19). Провал —
// исключение теста в выводе.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/mini_app_window.dart';

import '../../test/utils/test_client.dart';

const _initData = 'user=%7B%22id%22%3A1%7D&hash=test';

/// Шаг прогона: в лог и, если задан `LIZA_PILOT_RESULT`, в файл — на Windows в
/// VM приложение без консоли, результат забираем файлом.
void _step(String message) {
  debugPrint(message);
  final path = Platform.environment['LIZA_PILOT_RESULT'];
  if (path != null) {
    File(path).writeAsStringSync('$message\n', mode: FileMode.append);
  }
}

const _appUrl = 'https://example.com/';

void main([List<String> args = const []]) {
  // Этот же entrypoint desktop_multi_window запускает в движке окна.
  if (args.firstOrNull == kMiniAppWindowEntryArg) {
    // Движок окна пишет в журнал пилота сам: его ошибки иначе уходят только
    // в консоль главного движка, которой у задачи планировщика нет.
    _step('окно: движок запущен, аргументов ${args.length}');
    runZonedGuarded(() async {
      await miniAppWindowMain(args);
      _step('окно: runApp');
      final report = FlutterError.onError;
      FlutterError.onError = (details) {
        _step('окно: ошибка ${details.exceptionAsString()}');
        report?.call(details);
      };
      final platformReport = PlatformDispatcher.instance.onError;
      PlatformDispatcher.instance.onError = (error, stack) {
        _step('окно: ошибка платформы $error\n$stack');
        return platformReport?.call(error, stack) ?? false;
      };
    }, (error, stack) => _step('окно: ошибка $error\n$stack'));
    return;
  }

  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final defaultReporter = reportTestException;
  reportTestException = (details, description) {
    _step('FAIL: ${details.exceptionAsString()}');
    defaultReporter(details, description);
  };

  testWidgets('macOS: mini App отдельным окном — WebView во втором движке, '
      'прикрепить/открепить, крестик ОС', (tester) async {
    final requests = <String>[];
    late HttpServer server;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    });
    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;
      // verified_app_url — сервер подтверждает адрес app (014e6123), без
      // него хост отказывает: «Unverified Mini App URL».
      request.response.write(
        jsonEncode({'init_data': _initData, 'verified_app_url': _appUrl}),
      );
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';

    late Client client;
    await tester.runAsync(() async => client = await prepareTestClient());
    // init_data хост берёт у homeserver клиента — подменяем локальным сервером.
    client.homeserver = Uri.parse(base);
    // Хост mini App отдаёт init_data только сессии с токеном (014e6123):
    // без него окно получало «Mini App session changed» и не грузилось.
    client.accessToken = 'pilot-token';
    final room = Room(id: '!shop:localhost', client: client);
    final manager = MiniAppManager.instance;
    manager.windowsSupported = true;
    MiniAppWindows.instance.start();
    addTearDown(() async {
      manager.closeAll();
      manager.windowsSupported = false;
      await server.close(force: true);
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => MiniAppOverlay(child: child!),
        home: const Scaffold(body: Center(child: Text('chats'))),
      ),
    );
    await tester.pumpAndSettle();

    int initDataRequests() => requests
        .where((r) => r == '/_synapse/client/miniapp/v1/init_data')
        .length;
    Future<void> waitFor(bool Function() done, String what) async {
      for (var i = 0; i < 300 && !done(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(done(), isTrue, reason: what);
    }

    Future<int> windowCount() async {
      late int count;
      await tester.runAsync(
        () async => count = (await WindowController.getAll()).length,
      );
      return count;
    }

    Future<List<WindowController>> miniAppWindows() async {
      late List<WindowController> all;
      late WindowController own;
      await tester.runAsync(() async {
        all = await WindowController.getAll();
        own = await WindowController.fromCurrentEngine();
      });
      return all.where((w) => w.windowId != own.windowId).toList();
    }

    var windowsSeen = -1;
    String? stateError;
    Future<String?> windowLoadedUrl() async {
      final windows = await miniAppWindows();
      windowsSeen = windows.length;
      if (windows.isEmpty) return null;
      Map<Object?, Object?>? state;
      await tester.runAsync(() async {
        try {
          state = await windows.single.invokeMethod<Map<Object?, Object?>>(
            'state',
          );
          stateError = null;
        } catch (e) {
          // Движок окна ещё не поднял обработчик. Ошибку — в журнал пилота:
          // без неё пустой loaded_url в VM не отличить от «окна нет».
          stateError = '$e';
        }
      });
      return state?['loaded_url'] as String?;
    }

    Future<Map<Object?, Object?>> windowCall(String method) async {
      final window = (await miniAppWindows()).single;
      late Map<Object?, Object?> value;
      await tester.runAsync(() async {
        final result = await window.invokeMethod<Object?>(method);
        value = result is Map ? result : {'value': result};
      });
      return value;
    }

    // AC:RL-miniapp-detached-window/26 — «должен открываться большим»:
    // контент 1100×820 (не больше 90% экрана);
    // AC:RL-miniapp-detached-window/27 (Windows), AC:RL-miniapp-detached-window/24
    // (macOS) — минимум окна 800×600 (так же).
    Future<void> expectOpenedLarge(String what) async {
      final g = await windowCall('geometry');
      final areaW = (g['areaWidth'] as num).toDouble();
      final areaH = (g['areaHeight'] as num).toDouble();
      double fit(double v, double area) => v < area * 0.9 ? v : area * 0.9;
      _step('detached-window: $what — геометрия $g');
      expect(g['maximized'], isFalse, reason: what);
      expect(
        (g['width'] as num).toDouble(),
        greaterThanOrEqualTo(fit(1100, areaW) - 20),
        reason: '$what: ширина по умолчанию',
      );
      expect(
        (g['height'] as num).toDouble(),
        greaterThanOrEqualTo(fit(820, areaH) - 20),
        reason: '$what: высота по умолчанию',
      );
      expect(
        (g['minWidth'] as num).toDouble(),
        closeTo(fit(800, areaW), 20),
        reason: '$what: минимальная ширина',
      );
      expect(
        (g['minHeight'] as num).toDouble(),
        closeTo(fit(600, areaH), 20),
        reason: '$what: минимальная высота',
      );
    }

    Future<void> waitForWindowLoaded(String what) async {
      String? url;
      for (var i = 0; i < 600 && url == null; i++) {
        url = await windowLoadedUrl();
        if (url == null && i % 100 == 99) {
          _step(
            'detached-window: ждём «$what» ${(i + 1) ~/ 10} с — '
            'окон mini App $windowsSeen, ошибка state: $stateError',
          );
        }
        if (url == null) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
        }
      }
      expect(url, startsWith(_appUrl), reason: what);
      expect(
        url,
        contains('hash=test'),
        reason: 'initData пришла по RPC из главного движка',
      );
    }

    // LIZA_PILOT_GO — пилот VM сначала переносит окно Лизы на другой монитор
    // (другой масштаб), затем создаёт этот файл: окно mini App должно открыться
    // на мониторе Лизы (AC-26).
    final go = Platform.environment['LIZA_PILOT_GO'];
    if (go != null) {
      _step('detached-window: ждём перенос окна Лизы');
      for (var i = 0; i < 1200 && !File(go).existsSync(); i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
      }
    }

    // AC:RL-miniapp-detached-window/10 — по умолчанию отдельное окно ОС.
    manager.open(
      appUrl: _appUrl,
      appId: 'shop',
      appName: 'Магазин',
      room: room,
    );
    _step('detached-window: шаг 1 — окно по умолчанию');
    await waitForWindowLoaded('окно загрузило магазин');
    expect(initDataRequests(), 1);
    expect(await windowCount(), 2, reason: 'окно Лизы + окно mini App');
    expect(manager.hasApps, isFalse, reason: 'в окне Лизы панели нет');

    _step('detached-window: шаг 1б — размер и «развернуть»');
    await expectOpenedLarge('первое открытие');
    // AC:RL-miniapp-detached-window/29 — «увеличить можно весь экран».
    final before = await windowCall('geometry');
    expect((await windowCall('toggleMaximize'))['value'], isTrue);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    final zoomed = await windowCall('geometry');
    expect(zoomed['maximized'], isTrue, reason: 'окно развёрнуто');
    expect(
      (zoomed['width'] as num).toDouble(),
      greaterThan((before['width'] as num).toDouble()),
      reason: 'развёрнутое шире',
    );
    expect((await windowCall('toggleMaximize'))['value'], isFalse);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 800)),
    );
    expect((await windowCall('geometry'))['maximized'], isFalse);

    // AC:RL-miniapp-detached-window/12 — «Прикрепить»: окно уходит, панель
    // в окне Лизы запрашивает initData уже сама.
    _step('detached-window: шаг 2 — прикрепить');
    manager.attach('shop');
    await waitFor(() => initDataRequests() == 2, 'панель запросила initData');
    expect(manager.hasApps, isTrue, reason: 'панель в окне Лизы');
    var count = await windowCount();
    for (var i = 0; i < 50 && count != 1; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      count = await windowCount();
    }
    expect(count, 1, reason: 'окно mini App закрыто');

    // «Открепить» снова: окно на месте, панели нет.
    _step('detached-window: шаг 3 — открепить снова');
    manager.detach('shop');
    await tester.pumpAndSettle();
    await waitForWindowLoaded('окно снова загрузило магазин');
    expect(manager.hasApps, isFalse);
    // Размер прошлого окна не переносится — снова большое (AC-26).
    await expectOpenedLarge('повторное открытие');

    // AC:RL-miniapp-detached-window/12 — окно закрыли крестиком ОС (мимо
    // менеджера): app закрывается и в менеджере, плашки в окне Лизы нет.
    _step('detached-window: шаг 4 — крестик ОС');
    final window = (await miniAppWindows()).single;
    await tester.runAsync(() => window.invokeMethod<void>('close'));
    await waitFor(
      () => manager.detachedApps.isEmpty,
      'закрытое окно закрыло app в менеджере',
    );
    expect(manager.hasApps, isFalse);
    expect(await windowCount(), 1);
    // Без драйвера integration_test на успехе молчит и ждёт драйвер — маркер
    // для запуска собранным приложением.
    _step('RL-miniapp-detached-window: native OK');

    // AC:RL-miniapp-detached-window/16 — окно снова открыто: драйвер VM
    // (scripts/windows-vm/pilot-miniapp-window.sh) закрывает окно Лизы и
    // проверяет, что процесс завершился вместе с ним (заявка №61: окно mini App
    // оставалось «зомби»); AC:RL-miniapp-detached-window/17 — сторож выхода не
    // сработал; AC:RL-miniapp-detached-window/18 — с LIZA_TEST_HANG_AFTER_LOOP
    // процесс убил сторож.
    manager.open(
      appUrl: _appUrl,
      appId: 'shop',
      appName: 'Магазин',
      room: room,
    );
    await waitForWindowLoaded('окно открыто перед закрытием Лизы');
    _step(
      'detached-window: ready-to-close — окно открыто, можно закрывать Лизу',
    );
    // LIZA_PILOT_HOLD — то же на macOS: окно живёт, пока его меряют снаружи
    // (Accessibility: минимум при ресайзе, AC-24/27).
    if (Platform.isWindows ||
        Platform.environment.containsKey('LIZA_PILOT_HOLD')) {
      // Окно должно дожить до WM_CLOSE от драйвера: иначе tearDown закроет его
      // сам (closeAll) и проверка пройдёт без окна mini App.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(minutes: 5)),
      );
    }
  });
}
