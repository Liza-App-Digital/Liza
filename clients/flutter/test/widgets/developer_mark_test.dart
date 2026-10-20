import 'package:flutter/material.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/developer_mark.dart';

// Страж реестра регрессии: ledger:RL-developer-mark (см. tests/registry/).
// Рендерим РЕАЛЬНЫЙ DeveloperMark: буква из L10n, цвета из colorScheme
// (инверсия в тёмной теме), подсказка «видно только разработчикам».

Widget _host({
  required Locale locale,
  required Brightness brightness,
  required Widget child,
}) => MaterialApp(
  key: ValueKey((locale, brightness)),
  locale: locale,
  localizationsDelegates: const [
    L10n.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: L10n.supportedLocales,
  theme: ThemeData(brightness: brightness),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  // L10n грузит локали deferred-импортом: в fake-async теста вторая локаль
  // не успевает догрузиться, поэтому прогреваем обе заранее.
  setUpAll(() async {
    await L10n.delegate.load(const Locale('ru'));
    await L10n.delegate.load(const Locale('en'));
  });

  // AC:RL-developer-mark/1 — буква «Р» в ru и «D» в en.
  for (final (locale, letter) in [
    (const Locale('ru'), 'Р'),
    (const Locale('en'), 'D'),
  ]) {
    testWidgets('буква метки для ${locale.languageCode} = $letter', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale: locale,
          brightness: Brightness.light,
          child: const DeveloperMark(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(letter), findsOneWidget);
    });
  }

  // AC:RL-developer-mark/2 — фон = onSurface, буква = surface в обеих темах
  // (в тёмной плашка инвертирована, а не пропадает на чёрном фоне).
  for (final brightness in Brightness.values) {
    testWidgets('цвета метки из colorScheme ($brightness)', (tester) async {
      await tester.pumpWidget(
        _host(
          locale: const Locale('ru'),
          brightness: brightness,
          child: const DeveloperMark(),
        ),
      );
      await tester.pumpAndSettle();
      final scheme = Theme.of(
        tester.element(find.byType(DeveloperMark)),
      ).colorScheme;
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(DeveloperMark),
          matching: find.byType(DecoratedBox),
        ),
      );
      expect((box.decoration as BoxDecoration).color, scheme.onSurface);
      final text = tester.widget<Text>(find.text('Р'));
      expect(text.style?.color, scheme.surface);
      expect(scheme.onSurface, isNot(scheme.surface));
    });
  }

  // AC:RL-developer-mark/3 — подсказка и семантика «Видно только разработчикам».
  testWidgets('tooltip и semantics «Видно только разработчикам»', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        locale: const Locale('ru'),
        brightness: Brightness.light,
        child: const DeveloperMark(),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Видно только разработчикам'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Видно только разработчикам'),
      findsOneWidget,
    );
    handle.dispose();
  });
}
