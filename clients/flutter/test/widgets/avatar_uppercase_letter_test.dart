import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/widgets/avatar.dart';

// AC:RL-avatar-uppercase-letter — без фото буква на аватарке всегда заглавная.
// MxcImage без uri крутит backoff-таймеры — прокачиваем.
Future<void> _pump(WidgetTester tester, String? name) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Avatar(name: name, size: 40)),
    ),
  );
  for (final s in const [3, 5, 9, 17, 31]) {
    await tester.pump(Duration(seconds: s));
  }
}

void main() {
  for (final c in {
    'alice': 'A',
    'roman': 'R',
    'bob': 'B',
    'Надежда': 'Н',
    'иван': 'И',
    'Alice': 'A',
    '1abc': '1',
  }.entries) {
    testWidgets('AC:RL-avatar-uppercase-letter/1 «${c.key}» → ${c.value}', (
      tester,
    ) async {
      await _pump(tester, c.key);
      expect(find.text(c.value), findsOneWidget);
    });
  }

  testWidgets('AC:RL-avatar-uppercase-letter/1 пустое имя → @', (tester) async {
    await _pump(tester, null);
    expect(find.text('@'), findsOneWidget);
  });
}
