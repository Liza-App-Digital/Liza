import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/new_liza_request_list_tile.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/hexagon_clipper.dart';

// Страж единой стилистики аватарок (Надежда, 23.10; цвет вернули 26.10).
// Спека: docs/superpowers/specs/2026-10-26-avatar-pastel-colors-design.md
// ledger:RL-avatar-unified-style
//
// Рендерим РЕАЛЬНЫЕ Avatar и NewLizaRequestListTile, ассерт — по цвету фона и
// буквы, которые видит пользователь.

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Widget _app(Widget child, Brightness brightness) => MaterialApp(
  theme: ThemeData(brightness: brightness, useMaterial3: true),
  home: Scaffold(body: Center(child: child)),
);

// MxcImage без валидного uri крутит backoff-таймеры (2/4/8/16/30 с) —
// прокачиваем, иначе «A Timer is still pending» (см. deleted_bot_avatar_golden_test).
Future<void> _drain(WidgetTester tester) async {
  for (final s in const [3, 5, 9, 17, 31]) {
    await tester.pump(Duration(seconds: s));
  }
}

Color _letterBackground(WidgetTester tester, String letter) {
  final box = tester.widget<Container>(
    find
        .ancestor(of: find.text(letter), matching: find.byType(Container))
        .first,
  );
  return (box.decoration as BoxDecoration).color!;
}

Color _letterColor(WidgetTester tester, String letter) =>
    tester.widget<Text>(find.text(letter)).style!.color!;

void main() {
  // AC:RL-avatar-unified-style/2 — ∀ {человек, группа, компания, без имени} ×
  // {светлая, тёмная}: фон — пастель запросов Лизы по хэшу имени (одна на обе
  // темы), буква #1A1A1A, контраст ≥ 4.5; одно имя → один цвет.
  const cases = {
    'Мерчант Розенталь': 'М', // человек
    'Laba: Интерфейс Prodamus ID': 'L', // группа
    'Компания Розенталь': 'К', // компания
    'Даниэль Фурман': 'Д',
  };
  const palette = Avatar.fallbackBackgrounds;
  for (final brightness in Brightness.values) {
    for (final entry in cases.entries) {
      testWidgets('AC-2 ${brightness.name}: «${entry.key}» — пастельный фон, '
          'тёмная буква — AC:RL-avatar-unified-style/2', (tester) async {
        await tester.pumpWidget(_app(Avatar(name: entry.key), brightness));
        final bg = _letterBackground(tester, entry.value);
        final fg = _letterColor(tester, entry.value);
        expect(palette, contains(bg));
        expect(bg, palette[Avatar.fallbackShade(entry.key)]);
        expect(fg, Avatar.fallbackLetter);
        expect(_contrast(bg, fg), greaterThanOrEqualTo(4.5));
        await _drain(tester);
      });
    }

    testWidgets('AC-2 ${brightness.name}: без имени — «@» на пастели, а не '
        'белое на белом — AC:RL-avatar-unified-style/2', (tester) async {
      await tester.pumpWidget(_app(Avatar(), brightness));
      expect(_letterBackground(tester, '@'), palette[0]);
      expect(_letterColor(tester, '@'), Avatar.fallbackLetter);
      await _drain(tester);
    });

    testWidgets('AC-4 ${brightness.name}: ИИ без картинки (шестиугольник) — '
        'та же пастель — AC:RL-avatar-unified-style/4', (tester) async {
      await tester.pumpWidget(
        _app(Avatar(name: 'SomeBot', isHexagonal: true), brightness),
      );
      expect(palette, contains(_letterBackground(tester, 'S')));
      await _drain(tester);
    });
  }

  test('AC-2: разные имена дают разные цвета — палитра используется вся — '
      'AC:RL-avatar-unified-style/2', () {
    final shades = {
      for (final n in ['А', 'Б', 'В', 'Г', 'Д']) Avatar.fallbackShade(n),
    };
    expect(shades.length, palette.length);
  });

  test('AC-2: все цвета палитры — контраст буквы ≥ 4.5 — '
      'AC:RL-avatar-unified-style/2', () {
    for (final bg in palette) {
      expect(_contrast(bg, Avatar.fallbackLetter), greaterThanOrEqualTo(4.5));
    }
  });

  test('AC-8: палитра клиента = PALETTE запросов Лизы (request_avatar.py) — '
      'AC:RL-avatar-unified-style/8', () {
    final py = File(
      '../../servers/bots/liza/request_avatar.py',
    ).readAsStringSync();
    final tuple = RegExp(
      r'^PALETTE = \(([^)]*)\)',
      multiLine: true,
    ).firstMatch(py)!.group(1)!;
    final hex = RegExp(r'#([0-9A-Fa-f]{6})')
        .allMatches(tuple)
        .map((m) => Color(int.parse('FF${m.group(1)}', radix: 16)))
        .toList();
    expect(palette, hex);
  });

  testWidgets('AC-4: явный backgroundColor/textColor вызывающего главнее — '
      'AC:RL-avatar-unified-style/4', (tester) async {
    await tester.pumpWidget(
      _app(Avatar(name: 'X', backgroundColor: Colors.teal), Brightness.light),
    );
    expect(_letterBackground(tester, 'X'), Colors.teal);
    expect(_letterColor(tester, 'X'), Colors.white);
    await _drain(tester);

    await tester.pumpWidget(
      _app(
        Avatar(
          name: 'Y',
          backgroundColor: Colors.teal,
          textColor: Colors.amber,
        ),
        Brightness.light,
      ),
    );
    expect(_letterColor(tester, 'Y'), Colors.amber);
    await _drain(tester);
  });

  testWidgets('AC-3: удалённый аккаунт — призрак, не буква — '
      'AC:RL-avatar-unified-style/3', (tester) async {
    await tester.pumpWidget(
      _app(const Avatar(name: 'Gone', isDeleted: true), Brightness.light),
    );
    expect(find.byIcon(Icons.person_off_outlined), findsOneWidget);
    expect(find.text('G'), findsNothing);
  });

  // AC:RL-avatar-unified-style/1 — «+ Новый запрос» шестиугольником цвета primary.
  for (final brightness in Brightness.values) {
    testWidgets('AC-1 ${brightness.name}: «Новый запрос» — шестиугольник '
        'primary, бокс 44 — AC:RL-avatar-unified-style/1', (tester) async {
      final theme = ThemeData(brightness: brightness, useMaterial3: true);
      await tester.runAsync(() => L10n.delegate.load(const Locale('ru')));
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          locale: const Locale('ru'),
          home: const Scaffold(body: NewLizaRequestListTile()),
        ),
      );
      await tester.pumpAndSettle();
      final icon = find.byKey(const ValueKey('new_liza_request_icon'));
      expect(tester.getSize(icon), const Size(44, 44));
      final material = tester.widget<Material>(
        find.descendant(of: icon, matching: find.byType(Material)),
      );
      expect(material.shape, isA<HexagonBorder>());
      expect(material.color, theme.colorScheme.primary);
      expect(find.byType(CircleAvatar), findsNothing);
    });
  }
}
