// Нативный страж ledger:RL-miniapp-adaptive-window (macOS, Ярус C).
//
// Widget-тест хоста подменяет WebView заглушкой и не видит platform view.
// Здесь в хост MiniAppOverlay подставлен НАСТОЯЩИЙ InAppWebView: смена раскладки
// (боковая панель → на весь экран → обратно → свернуть → развернуть) и
// перетаскивание границы не должны перезагружать страницу и пересоздавать
// нативный view (иначе на проде теряется корзина магазина / страница оплаты).
//
// Прод-сессия не нужна: контент — example.com, Room — от тестового клиента.
// Запуск: flutter test integration_test/liza/miniapp_adaptive_window_native_test.dart -d macos

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';

import '../../test/utils/test_client.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS: настоящий WebView переживает смену раскладки и ресайз',
      (tester) async {
    late Client client;
    await tester.runAsync(() async => client = await prepareTestClient());
    final room = Room(id: '!shop:example.invalid', client: client);
    final manager = MiniAppManager.instance;

    var loads = 0;
    var webViewCreated = 0;
    MiniAppOverlay.debugContentBuilder = (context, app) => InAppWebView(
          initialUrlRequest: URLRequest(url: WebUri('https://example.com/')),
          onWebViewCreated: (_) => webViewCreated++,
          onLoadStop: (_, _) => loads++,
        );
    addTearDown(() {
      manager.closeAll();
      MiniAppOverlay.debugContentBuilder = null;
    });

    // Окно теста на macOS ~800 px (узкий режим). Логическую область 1440×900
    // вписываем масштабом — так хост раскладывает боковую панель.
    const logical = Size(1440, 900);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => FittedBox(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: logical,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: logical),
              child: MiniAppOverlay(child: child!),
            ),
          ),
        ),
        home: const Scaffold(body: Center(child: Text('chat'))),
      ),
    );
    await tester.pumpAndSettle();

    manager.open(
      appUrl: 'https://example.com/',
      appId: 'shop',
      appName: 'Магазин',
      room: room,
    );

    Future<void> settle([int seconds = 1]) async {
      for (var i = 0; i < seconds * 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    for (var i = 0; i < 150 && loads == 0; i++) {
      await settle();
    }
    expect(loads, 1, reason: 'example.com загрузилась');
    expect(webViewCreated, 1);

    await tester.tap(find.byKey(const ValueKey('miniapp-fullscreen')));
    await settle();
    await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
    await settle();
    await tester.drag(
      find.byKey(const ValueKey('miniapp-host-divider')),
      const Offset(-300, 0),
    );
    await settle();
    await tester.tap(find.byKey(const ValueKey('miniapp-minimize')));
    await settle();
    manager.expand();
    await settle(2);

    expect(tester.takeException(), isNull);
    expect(webViewCreated, 1, reason: 'нативный WebView не пересоздавался');
    expect(loads, 1, reason: 'страница не перезагружалась');
  });
}
