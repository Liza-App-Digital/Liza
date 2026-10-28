import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';
import 'package:liza/widgets/layouts/two_column_layout.dart';

import '../../utils/test_client.dart';

/// Страж адаптивного окна miniApp: боковая панель на широком окне, двойной
/// экран на узком, «на весь экран», свёрнутая плашка. Контент подменён через
/// [MiniAppOverlay.debugContentBuilder] — WebView в widget-тесте не поднимается,
/// а хост (шапка, раскладка, разделитель, Navigator) — настоящий.
/// ledger:RL-miniapp-adaptive-window
/// ledger:RL-miniapp-detached-window
void main() {
  late Client client;
  late Room room;
  final manager = MiniAppManager.instance;
  final defaultIsTablet = MiniAppOverlay.isTablet;

  // Счётчики жизни подменного контента и корня приложения: смена раскладки
  // НЕ должна пересоздавать ни WebView, ни Router.
  final contentInits = <String, int>{};
  final contentPaths = <String, String>{};
  var homeInits = 0;
  var titleTaps = 0;
  Size? homeSize;
  // Что видит приложение под хостом: колоночный режим и свёртка списка.
  final columnModes = <bool>[];
  var compact = false;

  setUpAll(() async {
    client = await prepareTestClient();
    room = Room(id: '!shop:example.invalid', client: client);
  });

  setUp(() {
    manager.closeAll();
    manager.windowsSupported = false;
    MiniAppOverlay.isTablet = (_) => false;
    manager.panelWidth.value = kMiniAppDefaultPanelWidth;
    manager.splitFraction.value = 0.5;
    manager.chatListCompactable.value = false;
    columnModes.clear();
    compact = false;
    contentInits.clear();
    contentPaths.clear();
    homeInits = 0;
    titleTaps = 0;
    homeSize = null;
    MiniAppOverlay.debugContentBuilder = (context, app) => _FakeContent(
      app: app,
      onInit: () {
        contentInits[app.appId] = (contentInits[app.appId] ?? 0) + 1;
        contentPaths[app.appId] = app.appStartPath;
      },
    );
  });

  tearDown(() {
    manager.closeAll();
    manager.windowsSupported = false;
    MiniAppOverlay.isTablet = defaultIsTablet;
    MiniAppOverlay.debugContentBuilder = null;
  });

  Future<void> pumpHost(
    WidgetTester tester,
    Size size, {
    bool twoColumn = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => MiniAppOverlay(child: child!),
        home: _ProbeHome(
          twoColumn: twoColumn,
          onInit: () => homeInits++,
          onTitleTap: () => titleTaps++,
          onSize: (s) => homeSize = s,
          onScope: (columnMode, isCompact) {
            columnModes.add(columnMode);
            compact = isCompact;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void openShop({String path = '', bool allowDetach = true}) => manager.open(
    appUrl: 'https://shop.example.invalid/',
    appId: 'shop',
    appName: 'Магазин',
    room: room,
    appStartPath: path,
    allowDetach: allowDetach,
  );

  void openCafe({bool allowDetach = true}) => manager.open(
    appUrl: 'https://cafe.example.invalid/',
    appId: 'cafe',
    appName: 'Кафе',
    room: room,
    allowDetach: allowDetach,
  );

  Rect panelRect(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('miniapp-content-shop')));

  group('MiniAppManager', () {
    test('по умолчанию: закреплённый с 1281 px, уже — на весь экран', () {
      // AC:RL-miniapp-adaptive-window/1
      expect(manager.isFullscreenFor(390), isTrue);
      expect(manager.isFullscreenFor(1000), isTrue);
      expect(manager.isFullscreenFor(1200), isTrue);
      expect(manager.isFullscreenFor(1440), isFalse);
      openShop();
      manager.setFullscreen(true);
      expect(manager.isFullscreenFor(1440), isTrue);
      manager.closeAll();
      openShop();
      expect(
        manager.fullscreenPreference,
        isNull,
        reason: 'новое открытие после закрытия всех — снова по ширине',
      );
    });

    test('ширина панели ужимается под окно', () {
      // AC:RL-miniapp-adaptive-window/5
      expect(clampMiniAppPanelWidth(100, 1440), kMiniAppMinPanelWidth);
      expect(clampMiniAppPanelWidth(5000, 1440), 1440 - kMiniAppMinChildWidth);
      expect(
        kMiniAppMinChildWidth,
        841,
        reason: 'панель не сжимает приложение ниже двух колонок',
      );
      expect(clampMiniAppPanelWidth(440, 1440), 440);
    });

    test('повторный open с новым deep-link пересоздаёт инстанс', () {
      // AC:RL-miniapp-adaptive-window/7
      openShop(path: '#!/a');
      final first = manager.activeApp!;
      openShop();
      expect(
        manager.activeApp!.contentKey,
        first.contentKey,
        reason: 'без пути — просто активировать открытый',
      );
      openShop(path: '#!/b');
      expect(manager.activeApp!.appStartPath, '#!/b');
      expect(manager.activeApp!.contentKey, isNot(first.contentKey));
      expect(manager.appCount, 1);
    });

    test('closeForClient закрывает только miniApp вышедшего клиента', () {
      // AC:RL-miniapp-adaptive-window/9
      openShop();
      manager.closeForClient(client);
      expect(manager.hasApps, isFalse);
    });
  });

  group('MiniAppOverlay', () {
    testWidgets(
      '1440: боковая панель справа, приложение сужено, не перекрыто',
      (tester) async {
        // AC:RL-miniapp-adaptive-window/1 AC:RL-miniapp-adaptive-window/2
        await pumpHost(tester, const Size(1440, 900));
        openShop();
        await tester.pumpAndSettle();

        final rect = panelRect(tester);
        expect(rect.right, 1440);
        expect(rect.width, kMiniAppDefaultPanelWidth);
        expect(
          homeSize!.width,
          1440 - kMiniAppDefaultPanelWidth,
          reason: 'MediaQuery приложения видит оставшуюся ширину',
        );
        expect(
          tester.getRect(find.byType(_ProbeHome)).right,
          1440 - kMiniAppDefaultPanelWidth,
        );
        expect(
          find.byKey(const ValueKey('miniapp-fullscreen')),
          findsOneWidget,
        );
        expect(find.byType(Dialog), findsNothing);
        expect(homeInits, 1);
      },
    );

    for (final size in const [
      Size(390, 844),
      Size(1000, 800),
      Size(1200, 800),
    ]) {
      testWidgets('${size.width.toInt()}: по умолчанию на весь экран', (
        tester,
      ) async {
        // AC:RL-miniapp-adaptive-window/1
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();

        final rect = panelRect(tester);
        expect(rect.left, 0);
        expect(rect.right, size.width);
        expect(find.byKey(const ValueKey('miniapp-dock')), findsOneWidget);
      });
    }

    testWidgets('1440: на весь экран → вернуть → свернуть → развернуть, '
        'WebView и Router живы', (tester) async {
      // AC:RL-miniapp-adaptive-window/4
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('miniapp-fullscreen')));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, 1440);

      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, kMiniAppDefaultPanelWidth);

      await tester.tap(find.byKey(const ValueKey('miniapp-minimize')));
      await tester.pumpAndSettle();
      expect(homeSize!.width, 1440);
      // AC:RL-miniapp-adaptive-window/6
      expect(find.text('Магазин'), findsOneWidget);

      manager.expand();
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, kMiniAppDefaultPanelWidth);

      expect(contentInits['shop'], 1);
      expect(homeInits, 1);
    });

    testWidgets('390: двойной экран — miniApp сверху, чат снизу; '
        'клавиатура не роняет раскладку', (tester) async {
      // AC:RL-miniapp-adaptive-window/3 AC:RL-miniapp-adaptive-window/4
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();

      final home = tester.getRect(find.byType(_ProbeHome));
      final panel = tester.getRect(
        find
            .ancestor(
              of: find.byKey(const ValueKey('miniapp-content-shop')),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(panel.top, 0);
      expect(panel.bottom, lessThanOrEqualTo(home.top));
      expect(home.top, closeTo(844 / 2, 1));
      expect(home.bottom, 844);
      expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final squeezed = tester.getRect(find.byType(_ProbeHome));
      expect(
        squeezed.height - 300,
        greaterThanOrEqualTo(160),
        reason: 'над клавиатурой чату остаётся место под поле ввода',
      );

      expect(contentInits['shop'], 1);
      expect(homeInits, 1);
    });

    testWidgets('1200: «вернуть панель» — сбоку, приложение остаётся в двух '
        'колонках', (tester) async {
      // AC:RL-miniapp-adaptive-window/2
      await pumpHost(tester, const Size(1200, 800));
      openShop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();

      expect(panelRect(tester).right, 1200);
      expect(homeSize!.width, greaterThan(840));
      expect(homeInits, 1);
    });

    testWidgets(
      '1100: на боковую панель ширины мало — закрепить = двойной экран',
      (tester) async {
        // AC:RL-miniapp-adaptive-window/3
        await pumpHost(tester, const Size(1100, 800));
        openShop();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
        await tester.pumpAndSettle();

        final home = tester.getRect(find.byType(_ProbeHome));
        expect(home.top, closeTo(400, 1));
        expect(homeSize!.width, 1100);
        expect(panelRect(tester).width, 1100);
      },
    );

    testWidgets(
      'Android «назад»: сначала диалог в панели, потом сворачивание',
      (tester) async {
        // AC:RL-miniapp-adaptive-window/8
        await pumpHost(tester, const Size(390, 844));
        openShop();
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('fake-content-dialog')));
        await tester.pumpAndSettle();
        expect(find.text('fake-dialog'), findsOneWidget);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('fake-dialog'), findsNothing);
        expect(manager.isExpanded, isTrue);

        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(manager.isExpanded, isFalse);
        expect(homeInits, 1);
      },
    );

    testWidgets('граница панели тянется мышью в пределах clamp', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/5
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      await tester.pumpAndSettle();

      final handle = find.byKey(const ValueKey('miniapp-host-divider'));
      await tester.drag(handle, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, 1440 - kMiniAppMinChildWidth);

      await tester.drag(handle, const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, kMiniAppMinPanelWidth);
      expect(contentInits['shop'], 1);
    });

    testWidgets('плашка 40 px только в свёрнутом состоянии', (tester) async {
      // AC:RL-miniapp-adaptive-window/6
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('miniapp-host-bar')), findsNothing);

      manager.minimize();
      await tester.pumpAndSettle();
      final bar = tester.getRect(
        find.byKey(const ValueKey('miniapp-host-bar')),
      );
      expect(bar.height, kMiniAppCollapsedBarHeight);
      final label = tester.widget<Text>(find.text('Магазин'));
      expect(label.style?.fontSize, 14);
    });

    testWidgets('deep-link доходит до контента; новый путь пересоздаёт его', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/7
      await pumpHost(tester, const Size(390, 844));
      openShop(path: '#!/tproduct/1');
      await tester.pumpAndSettle();
      expect(contentPaths['shop'], '#!/tproduct/1');

      openShop(path: '#!/tproduct/2');
      await tester.pumpAndSettle();
      expect(contentPaths['shop'], '#!/tproduct/2');
      expect(contentInits['shop'], 2);
    });

    testWidgets('«Скопировать ссылку» — кнопкой в шапке, меню «⋮» нет; '
        'диалог из контента открывается внутри хоста', (tester) async {
      // AC:RL-miniapp-adaptive-window/8 — хост смонтирован над Router; без
      // своего Navigator тут было «context does not include a Navigator».
      // Надежда 27.10: «пункт "еще" не имеет смысла, нужно только скопировать
      // ссылку» — меню заменено кнопкой.
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();

        expect(find.byType(PopupMenuButton<String>), findsNothing);
        expect(find.byKey(const ValueKey('miniapp-copy-link')), findsOneWidget);
        expect(
          find.byTooltip('Скопировать ссылку'),
          findsOneWidget,
          reason: 'на ${size.width.toInt()}',
        );

        await tester.tap(find.byKey(const ValueKey('fake-content-dialog')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('fake-dialog'), findsOneWidget);
        await tester.tap(find.text('ok'));
        await tester.pumpAndSettle();

        manager.closeAll();
        await tester.pumpAndSettle();
      }
    });
  });

  group('Отдельное окно ОС (десктоп)', () {
    test('по умолчанию окно, если окна поддержаны; с пин-кодом — панель', () {
      // AC:RL-miniapp-detached-window/1
      manager.windowsSupported = true;
      openShop();
      expect(manager.detachedApps.map((a) => a.appId), ['shop']);
      expect(manager.hasApps, isFalse, reason: 'в окне Лизы ничего нет');
      expect(manager.activeApp, isNull);
      expect(manager.isExpanded, isFalse);

      openCafe(allowDetach: false);
      expect(manager.detachedApps.map((a) => a.appId), ['shop']);
      expect(manager.apps.map((a) => a.appId), ['cafe']);

      manager.closeAll();
      manager.windowsSupported = false;
      openShop();
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp?.appId, 'shop');
    });

    test(
      'повторное открытие открепленного — поднять окно, не панель',
      () async {
        // AC:RL-miniapp-detached-window/1
        manager.windowsSupported = true;
        final focus = <String>[];
        final sub = manager.windowFocusRequests.listen(focus.add);
        openShop();
        openShop();
        await Future<void>.delayed(Duration.zero);
        expect(focus, ['shop']);
        expect(manager.hasApps, isFalse);
        openShop(path: '#!/tproduct/7');
        expect(manager.detachedApps.single.appStartPath, '#!/tproduct/7');
        expect(manager.detachedApps.single.generation, 1);
        await sub.cancel();
      },
    );

    test('закрытие окна ОС закрывает только его app', () {
      // AC:RL-miniapp-detached-window/3
      manager.windowsSupported = true;
      openShop();
      openCafe(allowDetach: false);
      manager.close('nope');
      expect(manager.detachedApps.length, 1);
      expect(manager.appCount, 1);
      manager.close('shop');
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp?.appId, 'cafe');
      expect(manager.isExpanded, isTrue);
    });

    test('открепить → прикрепить: та же страница, новое поколение', () {
      // AC:RL-miniapp-detached-window/8
      openShop();
      manager.detach('shop', startPath: '#!/tproduct/5');
      final detached = manager.detachedApps.single;
      expect(detached.appStartPath, '#!/tproduct/5');
      expect(detached.generation, 1);
      expect(manager.hasApps, isFalse);
      expect(manager.isExpanded, isFalse);

      manager.attach('shop', startPath: '#!/tproduct/6');
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp!.appStartPath, '#!/tproduct/6');
      expect(manager.activeApp!.generation, 2);
      expect(manager.isExpanded, isTrue);
    });

    test('выход из аккаунта закрывает и окна ОС', () {
      // AC:RL-miniapp-detached-window/9
      manager.windowsSupported = true;
      openShop();
      openCafe(allowDetach: false);
      manager.closeForClient(client);
      expect(manager.detachedApps, isEmpty);
      expect(manager.hasApps, isFalse);
    });

    test('крестик плашки закрывает панель, окна ОС не трогает', () {
      // AC:RL-miniapp-detached-window/3
      manager.windowsSupported = true;
      openShop();
      openCafe(allowDetach: false);
      manager.closeDocked();
      expect(manager.detachedApps.map((a) => a.appId), ['shop']);
      expect(manager.hasApps, isFalse);
    });

    test('конфиг окна переживает JSON без потерь', () {
      // AC:RL-miniapp-detached-window/7
      openShop(path: '#!/tproduct/9');
      final config = MiniAppWindowConfig.of(
        manager.activeApp!,
        ThemeData(brightness: Brightness.dark, colorSchemeSeed: Colors.teal),
      );
      final back = MiniAppWindowConfig.fromJson(
        Map<String, Object?>.from(
          jsonDecode(jsonEncode(config.toJson())) as Map,
        ),
      );
      expect(back.toJson(), config.toJson());
      expect(back.appStartPath, '#!/tproduct/9');
      expect(back.roomId, room.id);
      expect(back.contentKey, 'shop#0');
      expect(back.dark, isTrue);
    });

    testWidgets('открепленный не рисуется в окне Лизы; «Открепить» уводит '
        'панель в окно', (tester) async {
      // AC:RL-miniapp-detached-window/2 AC:RL-miniapp-detached-window/4
      manager.windowsSupported = true;
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      openCafe(allowDetach: false);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('miniapp-content-shop')), findsNothing);
      expect(
        find.byKey(const ValueKey('miniapp-content-cafe')),
        findsOneWidget,
      );
      expect(
        find.text('Магазин'),
        findsNothing,
        reason: 'ни панели, ни плашки',
      );

      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byKey(const ValueKey('miniapp-copy-link')), findsOneWidget);
      expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsOneWidget);
      expect(find.byKey(const ValueKey('miniapp-minimize')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('miniapp-detach')));
      await tester.pumpAndSettle();

      expect(manager.detachedApps.map((a) => a.appId), ['shop', 'cafe']);
      expect(find.byKey(const ValueKey('miniapp-content-cafe')), findsNothing);
      expect(homeSize!.width, 1440);
      expect(find.text('Кафе'), findsNothing, reason: 'свёрнутой плашки нет');
      expect(homeInits, 1);
    });

    testWidgets('без поддержки окон ОС кнопки «Открепить» нет', (tester) async {
      // AC:RL-miniapp-detached-window/4
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('miniapp-detach')), findsNothing);
        manager.closeAll();
        await tester.pumpAndSettle();
      }
    });

    testWidgets('сворачивание боковой панели — вниз, к плашке, а не вбок', (
      tester,
    ) async {
      // AC:RL-miniapp-detached-window/6
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      await tester.pumpAndSettle();
      final open = panelRect(tester);

      await tester.tap(find.byKey(const ValueKey('miniapp-minimize')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final early = panelRect(tester);
      await tester.pump(const Duration(milliseconds: 100));
      final late = panelRect(tester);

      for (final rect in [early, late]) {
        expect(rect.left, open.left, reason: 'панель не уезжает вбок');
        expect(rect.width, open.width);
      }
      expect(early.top, greaterThan(open.top));
      expect(late.top, greaterThan(early.top));
      await tester.pumpAndSettle();
      expect(find.text('Магазин'), findsOneWidget, reason: 'плашка внизу');
    });
  });

  group('Планшет — как на ПК, без двойного экрана', () {
    testWidgets('альбом: по умолчанию на весь экран, закрепить — сбоку', (
      tester,
    ) async {
      // AC:RL-miniapp-detached-window/5
      MiniAppOverlay.isTablet = (_) => true;
      await pumpHost(tester, const Size(1366, 1024));
      openShop();
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, 1366);

      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();
      expect(panelRect(tester).right, 1366);
      expect(panelRect(tester).width, kMiniAppDefaultPanelWidth);
    });

    for (final size in const [Size(1024, 1366), Size(768, 1024)]) {
      testWidgets('${size.width.toInt()}×${size.height.toInt()}: весь экран, '
          'закрепить некуда — ни кнопки, ни бегунка', (tester) async {
        // AC:RL-miniapp-detached-window/5
        MiniAppOverlay.isTablet = (_) => true;
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();
        expect(panelRect(tester).width, size.width);
        expect(find.byKey(const ValueKey('miniapp-dock')), findsNothing);
        expect(
          find.byKey(const ValueKey('miniapp-host-split-handle')),
          findsNothing,
        );
        expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsNothing);
      });
    }

    test('телефон и узкое окно — по-прежнему по ширине', () {
      // AC:RL-miniapp-detached-window/5
      expect(manager.isFullscreenFor(1440), isFalse);
      expect(manager.isFullscreenFor(1440, tablet: true), isTrue);
      expect(miniAppLayoutModeFor(manager, 1100), MiniAppLayoutMode.sheet);
      manager.setFullscreen(false);
      expect(miniAppLayoutModeFor(manager, 1100), MiniAppLayoutMode.split);
      expect(
        miniAppLayoutModeFor(manager, 1100, tablet: true),
        MiniAppLayoutMode.sheet,
      );
      expect(
        miniAppLayoutModeFor(manager, 1366, tablet: true),
        MiniAppLayoutMode.side,
      );
    });
  });

  group('Бегунок двойного экрана', () {
    Rect homeRect(WidgetTester tester) =>
        tester.getRect(find.byType(_ProbeHome));
    final handle = find.byKey(const ValueKey('miniapp-host-split-handle'));

    Future<void> openSplit(WidgetTester tester) async {
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();
    }

    testWidgets('тянется от минимума до 0.7 и держит долю', (tester) async {
      // AC:RL-miniapp-adaptive-window/11
      await openSplit(tester);
      expect(homeRect(tester).top, closeTo(422, 1));

      await tester.drag(handle, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(kMiniAppSplitMinPanelHeight, 1));

      await tester.drag(
        handle,
        Offset(0, 844 * 0.7 - kMiniAppSplitMinPanelHeight),
      );
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(844 * 0.7, 2));

      manager.minimize();
      await tester.pumpAndSettle();
      manager.expand();
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(844 * 0.7, 2));
      expect(contentInits['shop'], 1);
      expect(homeInits, 1);
    });

    testWidgets('нет полосы: панель вплотную к чату при любой доле', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/20
      await openSplit(tester);
      void expectNoGap() =>
          expect(panelRect(tester).bottom, closeTo(homeRect(tester).top, 0.5));
      expectNoGap();
      await tester.drag(handle, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expectNoGap();
      await tester.drag(
        handle,
        Offset(0, 844 * 0.78 - kMiniAppSplitMinPanelHeight),
      );
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(844 * 0.78, 2));
      expectNoGap();
    });

    testWidgets('на стыке только пилюля и линия 1 px, без фона', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/21
      await openSplit(tester);
      final seam = homeRect(tester).top;
      final pill = tester.getRect(
        find.descendant(of: handle, matching: find.byType(DecoratedBox)),
      );
      expect(pill.size, const Size(36, 5));
      expect(pill.center.dx, closeTo(195, 0.5));
      expect(pill.center.dy, closeTo(seam, 1));
      expect(
        find.descendant(of: handle, matching: find.byType(ColoredBox)),
        findsNothing,
      );
      final divider = tester.getRect(
        find.byKey(const ValueKey('miniapp-host-split-divider')),
      );
      expect(divider.height, 1);
      expect(divider.width, 390);
      expect(divider.center.dy, closeTo(seam, 0.5));
    });

    testWidgets('бегунок не крадёт тап у заголовка чата, но тянется', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/22
      await openSplit(tester);
      final seam = homeRect(tester).top;
      final zone = tester.getRect(handle);
      expect(zone.bottom - seam, lessThanOrEqualTo(26));
      expect(seam - zone.top, lessThanOrEqualTo(6));
      for (final point in [
        Offset(195, seam + 4),
        Offset(195, seam + 14),
        Offset(20, seam + 14),
      ]) {
        final before = titleTaps;
        await tester.tapAt(point);
        await tester.pumpAndSettle();
        expect(titleTaps, before + 1, reason: 'тап в $point');
      }
      expect(homeRect(tester).top, closeTo(seam, 0.5));

      await tester.dragFrom(Offset(195, seam + 20), const Offset(0, 100));
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(seam + 100, 2));
      expect(titleTaps, 3);
    });

    testWidgets('пока тянут — двигается только превью, WebView не ресайзится', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/11
      await openSplit(tester);
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await gesture.moveBy(const Offset(0, 40));
      await gesture.moveBy(const Offset(0, 160));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('miniapp-host-split-preview')),
        findsOneWidget,
      );
      expect(homeRect(tester).top, closeTo(422, 1));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('miniapp-host-split-preview')),
        findsNothing,
      );
      expect(homeRect(tester).top, greaterThan(422 + 150));
    });

    testWidgets('отпущен у низа — на весь экран, на 0.78 — двойной экран', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/12
      await openSplit(tester);
      await tester.drag(handle, Offset(0, 844 * 0.28));
      await tester.pumpAndSettle();
      expect(manager.fullscreenPreference, isFalse);
      expect(homeRect(tester).top, closeTo(844 * 0.78, 2));

      await tester.drag(handle, const Offset(0, 2000));
      await tester.pumpAndSettle();
      expect(manager.fullscreenPreference, isTrue);
      expect(panelRect(tester).left, 0);
      expect(find.byKey(const ValueKey('miniapp-dock')), findsOneWidget);
      expect(contentInits['shop'], 1);
    });

    testWidgets('клавиатура при доле 0.78: чату ≥160, доля не меняется', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/13
      await openSplit(tester);
      await tester.drag(handle, Offset(0, 844 * 0.28));
      await tester.pumpAndSettle();
      final fraction = manager.splitFraction.value;

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(homeRect(tester).height - 300, greaterThanOrEqualTo(160));
      expect(manager.splitFraction.value, fraction);

      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(homeRect(tester).top, closeTo(844 * 0.78, 2));
    });
  });

  group('Свёртка списка чатов до аватарок', () {
    final divider = find.byKey(const ValueKey('miniapp-host-divider'));
    double mainWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('probe-main'))).width;

    Future<void> openSide(WidgetTester tester) async {
      await pumpHost(tester, const Size(1440, 900), twoColumn: true);
      manager.chatListCompactable.value = true;
      openShop();
      await tester.pumpAndSettle();
    }

    testWidgets('панель тянется дальше двух колонок — список сворачивается', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/14 AC:RL-miniapp-adaptive-window/15
      // AC:RL-miniapp-adaptive-window/16
      await openSide(tester);
      expect(compact, isFalse);
      expect(
        mainWidth(tester),
        LizaThemes.columnWidth + LizaThemes.navRailWidth,
      );

      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, 1440 - kMiniAppCompactMinChildWidth);
      expect(compact, isTrue);
      expect(
        mainWidth(tester),
        LizaThemes.navRailWidth + 1 + kCompactChatListWidth,
      );
      expect(
        columnModes,
        everyElement(isTrue),
        reason: 'builder шелла не переключается посреди перетаскивания',
      );
      expect(homeInits, 1);
      expect(contentInits['shop'], 1);
    });

    testWidgets('гистерезис: сворачивается за 817, разворачивается с 841', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/14
      await openSide(tester);
      Future<void> childTo(double width) async {
        final current = 1440 - panelRect(tester).width;
        await tester.drag(divider, Offset(width - current, 0));
        await tester.pumpAndSettle();
        expect(1440 - panelRect(tester).width, closeTo(width, 1));
      }

      await childTo(830);
      expect(compact, isFalse, reason: 'зона гистерезиса — ещё полный');
      await childTo(810);
      expect(compact, isTrue);
      await childTo(830);
      expect(compact, isTrue, reason: 'зона гистерезиса — ещё свёрнут');
      await childTo(845);
      expect(compact, isFalse);
    });

    testWidgets('без открытого чата панель не шире порога двух колонок', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/18
      await openSide(tester);
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(compact, isTrue);

      manager.chatListCompactable.value = false;
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, 1440 - kMiniAppMinChildWidth);
      expect(compact, isFalse);
      expect(
        mainWidth(tester),
        LizaThemes.columnWidth + LizaThemes.navRailWidth,
      );
    });

    testWidgets('доля не съедает чат: потолок оставляет ≥160 px', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/12
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('miniapp-host-split-handle')),
        Offset(0, 844 * 0.38),
      );
      await tester.pumpAndSettle();
      expect(manager.fullscreenPreference, isFalse);
      expect(
        tester.getRect(find.byType(_ProbeHome)).height,
        greaterThanOrEqualTo(160),
      );
    });

    testWidgets('«развернуть» срабатывает и при дробной ширине окна', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/19
      await pumpHost(tester, const Size(1209.6, 900), twoColumn: true);
      manager.chatListCompactable.value = true;
      openShop();
      await tester.pumpAndSettle();
      // 1209.6 < 1281 — по умолчанию на весь экран; закрепляем сбоку.
      await tester.tap(find.byKey(const ValueKey('miniapp-dock')));
      await tester.pumpAndSettle();
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(compact, isTrue);
      manager.expandChatList();
      await tester.pumpAndSettle();
      expect(compact, isFalse);
    });

    testWidgets('«развернуть список» и закрытие miniApp возвращают полный', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/19
      await openSide(tester);
      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(compact, isTrue);

      manager.expandChatList();
      await tester.pumpAndSettle();
      expect(compact, isFalse);
      expect(panelRect(tester).width, 1440 - kMiniAppMinChildWidth - 1);

      await tester.drag(divider, const Offset(-2000, 0));
      await tester.pumpAndSettle();
      expect(compact, isTrue);
      manager.closeAll();
      await tester.pumpAndSettle();
      expect(compact, isFalse);
      expect(homeSize!.width, 1440);
    });

    testWidgets('колонка аватарок: тап открывает чат, «развернуть» зовётся', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/16
      final rooms = [
        Room(id: '!a:example.invalid', client: client),
        Room(id: '!b:example.invalid', client: client),
      ];
      final tapped = <String>[];
      var expanded = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: Scaffold(
            body: SizedBox(
              width: kCompactChatListWidth,
              child: CompactChatListColumn(
                rooms: rooms,
                activeChat: '!b:example.invalid',
                filterActive: true,
                onTap: (r) => tapped.add(r.id),
                onContextAction: (_, _) {},
                onExpand: () => expanded++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.tap(
        find.byKey(const ValueKey('compact_chat_!a:example.invalid')),
      );
      await tester.pumpAndSettle();
      expect(tapped, ['!a:example.invalid']);

      await tester.tap(find.byKey(const ValueKey('compact-chat-list-expand')));
      expect(expanded, 1);
      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(
        badge.isLabelVisible,
        isTrue,
        reason: 'активный фильтр не «Все» — точка на кнопке',
      );
      // Avatar (MxcImage) держит таймер повторной загрузки — дать ему истечь.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  });
}

class _ProbeHome extends StatefulWidget {
  final bool twoColumn;
  final VoidCallback onInit;
  final VoidCallback onTitleTap;
  final ValueChanged<Size> onSize;
  final void Function(bool columnMode, bool compact) onScope;

  const _ProbeHome({
    required this.onInit,
    required this.onTitleTap,
    required this.onSize,
    required this.onScope,
    this.twoColumn = false,
  });

  @override
  State<_ProbeHome> createState() => _ProbeHomeState();
}

class _ProbeHomeState extends State<_ProbeHome> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    widget.onSize(MediaQuery.sizeOf(context));
    widget.onScope(
      LizaThemes.isColumnMode(context),
      MiniAppHostScope.compactChatListOf(context),
    );
    // Сверху — кликабельный «заголовок чата» во всю ширину: в двойном экране
    // бегунок лежит поверх него и не должен красть тапы.
    if (!widget.twoColumn) {
      return Scaffold(
        body: Column(
          children: [
            InkWell(
              key: const ValueKey('probe-title'),
              onTap: widget.onTitleTap,
              child: const SizedBox(height: 56, width: double.infinity),
            ),
            const Expanded(child: SizedBox.expand()),
          ],
        ),
      );
    }
    return const TwoColumnLayout(
      compactable: true,
      mainView: SizedBox.expand(key: ValueKey('probe-main')),
      sideView: SizedBox.expand(key: ValueKey('probe-side')),
    );
  }
}

class _FakeContent extends StatefulWidget {
  final MiniAppInstance app;
  final VoidCallback onInit;

  const _FakeContent({required this.app, required this.onInit});

  @override
  State<_FakeContent> createState() => _FakeContentState();
}

class _FakeContentState extends State<_FakeContent> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.expand(
      key: ValueKey('miniapp-content-${widget.app.appId}'),
      child: Align(
        alignment: Alignment.topLeft,
        child: TextButton(
          key: const ValueKey('fake-content-dialog'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              content: const Text('fake-dialog'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('ok'),
                ),
              ],
            ),
          ),
          child: const Text('dialog'),
        ),
      ),
    );
  }
}
