import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/mini_app_window.dart';
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
  // Что видит приложение под хостом: колоночный режим.
  final columnModes = <bool>[];

  setUpAll(() async {
    client = await prepareTestClient();
    room = Room(id: '!shop:example.invalid', client: client);
  });

  setUp(() {
    manager.closeAll();
    manager.windowsSupported = false;
    MiniAppOverlay.isTablet = (_) => false;
    manager.panelWidth.value = kMiniAppDefaultPanelWidth;
    manager.panelFilled.value = false;
    columnModes.clear();
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
          onScope: columnModes.add,
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
    test('режим выводится из ширины и планшета: только sheet и side', () {
      // AC:RL-miniapp-adaptive-window/1 AC:RL-miniapp-adaptive-window/48
      expect(MiniAppLayoutMode.values, [
        MiniAppLayoutMode.sheet,
        MiniAppLayoutMode.side,
      ]);
      for (final w in const [390.0, 1000.0, 1200.0, 1280.0]) {
        expect(miniAppLayoutModeFor(w), MiniAppLayoutMode.sheet, reason: '$w');
      }
      expect(miniAppLayoutModeFor(1281), MiniAppLayoutMode.side);
      expect(miniAppLayoutModeFor(1440), MiniAppLayoutMode.side);
      expect(miniAppLayoutModeFor(1920, tablet: true), MiniAppLayoutMode.sheet);
    });

    test(
      'стек: закрытие верхнего показывает предыдущее, последнего — пусто',
      () {
        // AC:RL-miniapp-adaptive-window/44
        openShop();
        openCafe();
        expect(manager.activeApp?.appId, 'cafe');
        manager.close('cafe');
        expect(manager.activeApp?.appId, 'shop');
        manager.close('shop');
        expect(manager.activeApp, isNull);
        expect(manager.hasApps, isFalse);
      },
    );

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
        expect(find.byType(Dialog), findsNothing);
        expect(homeInits, 1);
      },
    );

    for (final size in const [
      Size(390, 844),
      Size(1000, 800),
      Size(1200, 800),
    ]) {
      testWidgets('${size.width.toInt()}: на весь экран, кнопки режима нет', (
        tester,
      ) async {
        // AC:RL-miniapp-adaptive-window/1 AC:RL-miniapp-adaptive-window/48
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();

        final rect = panelRect(tester);
        expect(rect.left, 0);
        expect(rect.right, size.width);
        expect(find.byKey(const ValueKey('miniapp-dock')), findsNothing);
        expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsNothing);
      });
    }

    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      for (final windows in const [false, true]) {
        testWidgets('шапка ${size.width.toInt()}, окна ОС: $windows — '
            'только ✕, название и ↗', (tester) async {
          // AC:RL-miniapp-adaptive-window/40
          // Надежда 27.10: «Итого у нас останется крестик и разворачивание в
          // отдельное окно».
          manager.windowsSupported = windows;
          await pumpHost(tester, size);
          openShop(allowDetach: false);
          await tester.pumpAndSettle();

          expect(find.byKey(const ValueKey('miniapp-close')), findsOneWidget);
          expect(find.text('Магазин'), findsOneWidget);
          expect(
            find.byKey(const ValueKey('miniapp-detach')),
            windows ? findsOneWidget : findsNothing,
          );
          expect(
            find.byType(IconButton),
            findsNWidgets(windows ? 2 : 1),
            reason: 'в шапке нет других кнопок',
          );
          for (final key in const [
            'miniapp-copy-link',
            'miniapp-fullscreen',
            'miniapp-minimize',
            'miniapp-dock',
          ]) {
            expect(find.byKey(ValueKey(key)), findsNothing, reason: key);
          }
          expect(find.byType(PopupMenuButton<String>), findsNothing);
        });
      }
    }

    testWidgets('плашки и резерва под неё нет ни в одном состоянии', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/41
      // Надежда 27.10: «Вот такого отображения не должно быть ни на десктопах,
      // ни на мобильных, ни где-либо ещё».
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        await pumpHost(tester, size);
        expect(find.byKey(const ValueKey('miniapp-host-bar')), findsNothing);
        openShop();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('miniapp-host-bar')), findsNothing);
        manager.closeAll();
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('miniapp-host-bar')), findsNothing);
        expect(find.text('Магазин'), findsNothing);
        expect(homeSize, size, reason: 'чат без резерва под плашку');
      }
    });

    testWidgets('свайп вниз по шапке: далеко — закрывает, чуть — возвращает', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/42
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();
      final top = panelRect(tester).top;

      await tester.timedDrag(
        find.text('Магазин'),
        const Offset(0, 100),
        const Duration(seconds: 2),
      );
      await tester.pumpAndSettle();
      expect(manager.hasApps, isTrue, reason: 'ниже порога — не закрываем');
      expect(panelRect(tester).top, top);

      await tester.drag(find.text('Магазин'), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(manager.hasApps, isFalse);
      expect(find.byKey(const ValueKey('miniapp-content-shop')), findsNothing);
    });

    testWidgets('Android «назад»: сначала диалог в панели, потом закрытие '
        'активного app', (tester) async {
      // AC:RL-miniapp-adaptive-window/8 AC:RL-miniapp-adaptive-window/43
      await pumpHost(tester, const Size(390, 844));
      openShop();
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('fake-content-dialog')));
      await tester.pumpAndSettle();
      expect(find.text('fake-dialog'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('fake-dialog'), findsNothing);
      expect(manager.hasApps, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(manager.hasApps, isFalse);
      expect(homeInits, 1);
    });

    testWidgets('«назад» в боковой панели уходит чату, панель не закрывает', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/43
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(manager.hasApps, isTrue);
    });

    testWidgets('граница панели тянется мышью в пределах clamp', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/5
      await pumpHost(tester, const Size(1440, 900));
      openShop();
      await tester.pumpAndSettle();

      final handle = find.byKey(const ValueKey('miniapp-host-divider'));
      // Левый край 730 — правее середины окна (720): панель закреплена и
      // упирается в порог двух колонок.
      await tester.drag(handle, const Offset(-270, 0));
      await tester.pumpAndSettle();
      expect(manager.panelFilled.value, isFalse);
      expect(panelRect(tester).width, 1440 - kMiniAppMinChildWidth);

      await tester.drag(handle, const Offset(2000, 0));
      await tester.pumpAndSettle();
      expect(panelRect(tester).width, kMiniAppMinPanelWidth);
      expect(contentInits['shop'], 1);
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

    testWidgets('диалог из контента открывается внутри хоста', (tester) async {
      // AC:RL-miniapp-adaptive-window/8 — хост смонтирован над Router; без
      // своего Navigator тут было «context does not include a Navigator».
      for (final size in const [Size(390, 844), Size(1440, 900)]) {
        await pumpHost(tester, size);
        openShop();
        await tester.pumpAndSettle();

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
    });

    test('открепить → прикрепить: та же страница, новое поколение', () {
      // AC:RL-miniapp-detached-window/8
      openShop();
      manager.detach('shop', startPath: '#!/tproduct/5');
      final detached = manager.detachedApps.single;
      expect(detached.appStartPath, '#!/tproduct/5');
      expect(detached.generation, 1);
      expect(manager.hasApps, isFalse);

      manager.attach('shop', startPath: '#!/tproduct/6');
      expect(manager.detachedApps, isEmpty);
      expect(manager.activeApp!.appStartPath, '#!/tproduct/6');
      expect(manager.activeApp!.generation, 2);
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
      // AC:RL-miniapp-detached-window/4 AC:RL-miniapp-adaptive-window/34
      expect(find.byKey(const ValueKey('miniapp-copy-link')), findsNothing);
      expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsNothing);
      expect(find.byKey(const ValueKey('miniapp-minimize')), findsNothing);
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
  });

  group('Планшет — как на ПК, без двойного экрана', () {
    for (final size in const [
      Size(1366, 1024),
      Size(1024, 1366),
      Size(768, 1024),
    ]) {
      testWidgets(
        '${size.width.toInt()}×${size.height.toInt()}: на весь экран, '
        'ни кнопки режима, ни бегунка',
        (tester) async {
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
          expect(
            find.byKey(const ValueKey('miniapp-fullscreen')),
            findsNothing,
          );
        },
      );
    }

    test('телефон и узкое окно — по-прежнему по ширине', () {
      // AC:RL-miniapp-detached-window/5 AC:RL-miniapp-adaptive-window/48
      expect(miniAppLayoutModeFor(1100), MiniAppLayoutMode.sheet);
      expect(miniAppLayoutModeFor(1440), MiniAppLayoutMode.side);
      expect(miniAppLayoutModeFor(1366, tablet: true), MiniAppLayoutMode.sheet);
    });
  });

  group('Панель на всё окно: три положения', () {
    final divider = find.byKey(const ValueKey('miniapp-host-divider'));
    double mainWidth(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('probe-main'))).width;

    /// Тянет бегунок так, чтобы левый край панели оказался в [toLeft].
    Future<void> dragTo(WidgetTester tester, double toLeft) async {
      final from = panelRect(tester).left;
      final gesture = await tester.startGesture(Offset(from, 450));
      await gesture.moveBy(Offset((toLeft - from) / 2, 0));
      await tester.pump();
      await gesture.moveBy(Offset((toLeft - from) / 2, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
    }

    Future<void> openSide(WidgetTester tester, [double width = 1440]) async {
      await pumpHost(tester, Size(width, 900), twoColumn: true);
      openShop();
      await tester.pumpAndSettle();
    }

    for (final width in const [1300.0, 1440.0, 1920.0]) {
      testWidgets('${width.toInt()}: левее середины — панель до колонки '
          'пространств, приложение не перестраивается', (tester) async {
        // AC:RL-miniapp-adaptive-window/30
        await openSide(tester, width);
        await dragTo(tester, width / 2 - 40);
        final pinned = Size(width - manager.panelWidth.value, 900);

        expect(manager.panelFilled.value, isTrue);
        final rect = panelRect(tester);
        expect(rect.left, LizaThemes.navRailWidth);
        expect(rect.right, width);
        expect(
          homeSize,
          pinned,
          reason: 'приложение под панелью держит ширину закреплённого режима',
        );
        expect(homeInits, 1);
        expect(contentInits['shop'], 1);
        expect(find.byKey(const ValueKey('miniapp-fullscreen')), findsNothing);
        expect(
          find.byKey(const ValueKey('miniapp-host-divider')),
          findsOneWidget,
          reason: 'бегунок остаётся доступен',
        );
      });
    }

    testWidgets('скачок резкий и ровно на середине окна', (tester) async {
      // AC:RL-miniapp-adaptive-window/31
      await openSide(tester);
      await dragTo(tester, 730);
      expect(manager.panelFilled.value, isFalse);
      expect(panelRect(tester).left, 1440 - 599);

      await dragTo(tester, 710);
      expect(manager.panelFilled.value, isTrue);
      expect(panelRect(tester).left, LizaThemes.navRailWidth);
    });

    testWidgets(
      'потянуть обратно — резко в закреплённое с шириной по указателю',
      (tester) async {
        // AC:RL-miniapp-adaptive-window/32
        await openSide(tester);
        await dragTo(tester, 400);
        expect(manager.panelFilled.value, isTrue);

        await dragTo(tester, 900);
        expect(manager.panelFilled.value, isFalse);
        expect(panelRect(tester).left, 900);
        expect(panelRect(tester).width, 540);
        expect(contentInits['shop'], 1);

        await dragTo(tester, 400);
        await dragTo(tester, 2000);
        expect(manager.panelFilled.value, isFalse);
        expect(panelRect(tester).width, kMiniAppMinPanelWidth);
      },
    );

    testWidgets(
      'колонки аватарок нет: список чатов полный во всех положениях',
      (tester) async {
        // AC:RL-miniapp-adaptive-window/33
        await openSide(tester);
        const full = LizaThemes.columnWidth + LizaThemes.navRailWidth;
        expect(mainWidth(tester), full);
        await dragTo(tester, 600);
        expect(mainWidth(tester), full);
        await dragTo(tester, 1000);
        expect(mainWidth(tester), full);
        expect(
          columnModes,
          everyElement(isTrue),
          reason: 'builder шелла не переключается посреди перетаскивания',
        );
      },
    );

    testWidgets('«назад» из режима на всё окно возвращает закреплённое', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/35
      await openSide(tester);
      await dragTo(tester, 400);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(manager.panelFilled.value, isFalse);
      expect(panelRect(tester).left, 1000);
    });

    testWidgets('закрытие miniApp сбрасывает режим на всё окно', (
      tester,
    ) async {
      // AC:RL-miniapp-adaptive-window/36
      await openSide(tester);
      await dragTo(tester, 400);
      manager.closeAll();
      await tester.pumpAndSettle();
      openShop();
      await tester.pumpAndSettle();
      expect(manager.panelFilled.value, isFalse);
      expect(panelRect(tester).width, kMiniAppDefaultPanelWidth);
      expect(divider, findsOneWidget);
    });
  });
}

class _ProbeHome extends StatefulWidget {
  final bool twoColumn;
  final VoidCallback onInit;
  final VoidCallback onTitleTap;
  final ValueChanged<Size> onSize;
  final ValueChanged<bool> onScope;

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
    widget.onScope(LizaThemes.isColumnMode(context));
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
