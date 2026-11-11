// Шапка отдельного окна mini App: единственная панель, без системной дубли.
// ledger:RL-miniapp-detached-window
// ledger:RL-liza-liquid-page
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
}
