import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/widget_generating_card.dart';
import 'package:liza/utils/widget_progress.dart';

void main() {
  // AC:RL-telegram-widgets/15
  Widget app(Widget child, {Locale locale = const Locale('ru')}) => MaterialApp(
    locale: locale,
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(body: Center(child: child)),
  );

  // use-deferred-loading: L10n-библиотека грузится вне FakeAsync, как в
  // остальных тестах чата.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  WidgetGenerationProgress progress({
    String stage = 'writing',
    int percent = 42,
  }) => WidgetGenerationProgress(
    roomId: '!r:example.invalid',
    senderId: '@bot:example.invalid',
    stage: stage,
    percent: percent,
    updatedAt: DateTime.now(),
  );

  testWidgets('карточка: этап, процент, прогресс и вращающаяся строка', (
    tester,
  ) async {
    await tester.pumpWidget(app(WidgetGeneratingCard(progress: progress())));
    await settle(tester);
    await tester.pumpAndSettle();

    expect(find.text('Собираю карточку'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('widget-generating-progress')),
      findsOneWidget,
    );
    expect(find.text('Выравниваю уголки…'), findsOneWidget);

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('Считаю на пальцах…'), findsOneWidget);
  });

  testWidgets('этап отправки', (tester) async {
    await tester.pumpWidget(
      app(
        WidgetGeneratingCard(progress: progress(stage: 'sending', percent: 96)),
      ),
    );
    await settle(tester);
    await tester.pumpAndSettle();
    expect(find.text('Показываю карточку'), findsOneWidget);
    expect(find.text('96%'), findsOneWidget);
  });
}
