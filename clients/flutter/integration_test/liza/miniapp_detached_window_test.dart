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
// Успех — строка «RL-miniapp-detached-window: native OK» (дальше процесс ждёт
// драйвер, его можно закрыть); провал — исключение теста в выводе.

import 'dart:io';

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
    miniAppWindowMain(args);
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
      request.response.write('{"init_data": "$_initData"}');
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';

    late Client client;
    await tester.runAsync(() async => client = await prepareTestClient());
    // init_data хост берёт у homeserver клиента — подменяем локальным сервером.
    client.homeserver = Uri.parse(base);
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

    Future<String?> windowLoadedUrl() async {
      final windows = await miniAppWindows();
      if (windows.isEmpty) return null;
      Map<Object?, Object?>? state;
      await tester.runAsync(() async {
        try {
          state = await windows.single.invokeMethod<Map<Object?, Object?>>(
            'state',
          );
        } catch (_) {
          // Движок окна ещё не поднял обработчик.
        }
      });
      return state?['loaded_url'] as String?;
    }

    Future<void> waitForWindowLoaded(String what) async {
      String? url;
      for (var i = 0; i < 600 && url == null; i++) {
        url = await windowLoadedUrl();
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
  });
}
