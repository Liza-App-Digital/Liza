// Шапка отдельного окна mini App: единственная панель, без системной дубли.
// ledger:RL-miniapp-detached-window
// ledger:RL-liza-liquid-page
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/pages/chat/mini_app_window.dart';

Future<void> _pump(
  WidgetTester tester, {
  required String title,
  required double width,
  VoidCallback? onAttach,
  VoidCallback? onClose,
  VoidCallback? onDrag,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = Size(width, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: MiniAppWindowHeader(
          title: title,
          attachTooltip: 'Прикрепить к Лизе',
          closeTooltip: 'Закрыть',
          onAttach: onAttach ?? () {},
          onClose: onClose ?? () {},
          onDragStart: onDrag ?? () {},
        ),
      ),
    ),
  );
}

void main() {
  // AC:RL-miniapp-detached-window/19 — ∀ {короткое, длинное название; 360, 1100;
  // светлая, тёмная}: ровно два действия (прикрепить, закрыть), ссылки нет.
  for (final title in [
    'Магазин',
    'Очень длинное название мини-приложения ' * 4,
  ]) {
    for (final width in [360.0, 1100.0]) {
      for (final b in Brightness.values) {
        testWidgets('AC-19 шапка: «$title» $width $b', (tester) async {
          await _pump(tester, title: title, width: width, brightness: b);
          expect(find.byType(IconButton), findsNWidgets(2));
          expect(find.byKey(const ValueKey('miniapp-window-attach')), findsOne);
          expect(find.byKey(const ValueKey('miniapp-window-close')), findsOne);
          expect(
            find.byKey(const ValueKey('miniapp-window-copy-link')),
            findsNothing,
          );
          expect(find.byIcon(Icons.link), findsNothing);
          expect(find.byIcon(Icons.push_pin), findsNothing);
          expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
          // AC:RL-miniapp-detached-window/45 — «открепить» наоборот: ↗ на π.
          final rotated = find.descendant(
            of: find.byKey(const ValueKey('miniapp-window-attach')),
            matching: find.byType(Transform),
          );
          expect(rotated, findsWidgets);
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('miniapp-window-attach')),
              matching: find.byIcon(Icons.open_in_new),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  // AC:RL-miniapp-detached-window/20
  testWidgets('AC-20 attach и крестик вызывают свои обработчики', (
    tester,
  ) async {
    var attach = 0, close = 0;
    await _pump(
      tester,
      title: 'Магазин',
      width: 800,
      onAttach: () => attach++,
      onClose: () => close++,
    );
    await tester.tap(find.byKey(const ValueKey('miniapp-window-attach')));
    await tester.tap(find.byKey(const ValueKey('miniapp-window-close')));
    expect([attach, close], [1, 1]);
  });

  // AC:RL-miniapp-detached-window/22 — drag только за названием, не за кнопками.
  testWidgets('AC-22 перетаскивание стартует с названия, не с кнопок', (
    tester,
  ) async {
    var drag = 0;
    await _pump(tester, title: 'Магазин', width: 800, onDrag: () => drag++);
    await tester.tap(find.text('Магазин'));
    expect(drag, 1);
    await tester.tap(find.byKey(const ValueKey('miniapp-window-attach')));
    await tester.tap(find.byKey(const ValueKey('miniapp-window-close')));
    expect(drag, 1);
  });

  // AC:RL-liza-liquid-page/46 — окно жидкой страницы: без «Прикрепить», только
  // крестик; длинное название не ломает шапку.
  for (final width in [360.0, 1100.0]) {
    testWidgets('окно страницы без «Прикрепить» ($width)', (tester) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var closed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MiniAppWindowHeader(
              title: 'Сравнение тарифов связи ' * 4,
              attachTooltip: 'Прикрепить к Лизе',
              closeTooltip: 'Закрыть',
              onClose: () => closed++,
              onDragStart: () {},
            ),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('miniapp-window-attach')), findsNothing);
      expect(find.byType(IconButton), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('miniapp-window-close')));
      expect(closed, 1);
      expect(tester.takeException(), isNull);
    });
  }

  Future<void> pumpFull(
    WidgetTester tester, {
    required double width,
    bool maximized = false,
    VoidCallback? onToggle,
    ValueChanged<MiniAppWindowEdge>? onResize,
    VoidCallback? onDrag,
    VoidCallback? onClose,
  }) async {
    tester.view.physicalSize = Size(width, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MiniAppWindowHeader(
            title: 'Очень длинное название мини-приложения ' * 4,
            attachTooltip: 'Прикрепить к Лизе',
            closeTooltip: 'Закрыть',
            maximizeTooltip: 'Развернуть на весь экран',
            restoreTooltip: 'Восстановить размер',
            onAttach: () {},
            onClose: onClose ?? () {},
            onDragStart: onDrag ?? () {},
            onToggleMaximize: onToggle ?? () {},
            onResizeStart: onResize,
            maximized: maximized,
          ),
        ),
      ),
    );
  }

  // AC:RL-miniapp-detached-window/29 — «увеличить можно весь экран»: ∀ {360,
  // 1100} × {обычное, развёрнутое} кнопка «Развернуть/Восстановить» стоит между
  // «Прикрепить» и крестиком, значок и подсказка по состоянию, переполнения нет.
  for (final width in [360.0, 1100.0]) {
    for (final maximized in [false, true]) {
      testWidgets('AC-29 кнопка развернуть ($width, maximized=$maximized)', (
        tester,
      ) async {
        var toggles = 0;
        await pumpFull(
          tester,
          width: width,
          maximized: maximized,
          onToggle: () => toggles++,
        );
        expect(find.byType(IconButton), findsNWidgets(3));
        final attachX = tester
            .getCenter(find.byKey(const ValueKey('miniapp-window-attach')))
            .dx;
        final maxX = tester
            .getCenter(find.byKey(const ValueKey('miniapp-window-maximize')))
            .dx;
        final closeX = tester
            .getCenter(find.byKey(const ValueKey('miniapp-window-close')))
            .dx;
        expect(attachX < maxX && maxX < closeX, isTrue);
        expect(
          find.byIcon(maximized ? Icons.filter_none : Icons.crop_square),
          findsOneWidget,
        );
        expect(
          find.byTooltip(
            maximized ? 'Восстановить размер' : 'Развернуть на весь экран',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const ValueKey('miniapp-window-maximize')));
        expect(toggles, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }

  // AC:RL-miniapp-detached-window/29 — двойной клик по названию разворачивает;
  // одиночные клики (и два далёких по времени) — перетаскивание.
  testWidgets('AC-29 двойной клик по названию — развернуть, не drag', (
    tester,
  ) async {
    var toggles = 0, drags = 0;
    await pumpFull(
      tester,
      width: 1100,
      onToggle: () => toggles++,
      onDrag: () => drags++,
    );
    final title = find.byKey(const ValueKey('miniapp-window-drag'));
    final at = tester.getCenter(title);
    final g1 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await g1.up();
    await tester.pump(const Duration(milliseconds: 100));
    final g2 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await g2.up();
    expect([toggles, drags], [1, 1]);
    await tester.pump(const Duration(seconds: 1));
    final g3 = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await g3.up();
    expect([toggles, drags], [1, 2]);
  });

  // AC:RL-miniapp-detached-window/28 — верхний край (Windows): полоса 5 dp над
  // шапкой тянет окно вверх, углы — по диагонали; у развёрнутого окна полосы
  // нет; клик ниже полосы — не ресайз (кнопки и название работают).
  testWidgets('AC-28 верхняя полоса ресайза', (tester) async {
    final edges = <MiniAppWindowEdge>[];
    var closes = 0;
    await pumpFull(
      tester,
      width: 1100,
      onResize: edges.add,
      onClose: () => closes++,
    );
    final header = tester.getRect(find.byType(MiniAppWindowHeader));
    Future<void> clickAt(Offset p) async {
      final g = await tester.startGesture(p, kind: PointerDeviceKind.mouse);
      await g.up();
      await tester.pump(const Duration(seconds: 1));
    }

    await clickAt(Offset(header.center.dx, header.top + 2));
    await clickAt(Offset(header.left + 2, header.top + 2));
    await clickAt(Offset(header.right - 2, header.top + 2));
    expect(edges, [
      MiniAppWindowEdge.top,
      MiniAppWindowEdge.topLeft,
      MiniAppWindowEdge.topRight,
    ]);
    await clickAt(Offset(header.center.dx, header.top + 10));
    await tester.tap(find.byKey(const ValueKey('miniapp-window-close')));
    expect(edges.length, 3);
    expect(closes, 1);

    await pumpFull(tester, width: 1100, maximized: true, onResize: edges.add);
    expect(
      find.byKey(const ValueKey('miniapp-window-resize-top')),
      findsNothing,
    );
    await clickAt(Offset(header.center.dx, header.top + 2));
    expect(edges.length, 3);
  });

  // macOS: без onResizeStart полосы нет совсем (края тянет сама AppKit).
  testWidgets('AC-28 без onResizeStart полосы нет', (tester) async {
    await pumpFull(tester, width: 1100);
    expect(
      find.byKey(const ValueKey('miniapp-window-resize-top')),
      findsNothing,
    );
  });
}
