import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat_list/space_view.dart';

import 'liza_flows.dart';

/// E2E LABA-2532 на РЕАЛЬНОМ бинаре: в своей компании «+» → «Новое
/// подпространство» → имя → «Создать» — без «Нет прав доступа», подпространство
/// появляется в списке пространства.
///
/// Требует Synapse с ВКЛЮЧЁННЫМ `single_space_guard` и уже существующей
/// компанией, где пользователь E2E_USER1 — админ (на штатном локальном стенде
/// модуль намеренно выключен, 403 там не воспроизводится). Пример:
/// `--dart-define=E2E_HOMESERVER=http://localhost:8018
///  --dart-define=E2E_USER1=owner2532 --dart-define=E2E_PASS1=pw2532
///  --dart-define=E2E_COMPANY=Компания 1 --dart-define=E2E_SUBSPACE=Отдел UI`.
///
/// ledger:RL-subspace-create-with-parent
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const company = String.fromEnvironment(
    'E2E_COMPANY',
    defaultValue: 'Компания 1',
  );
  const subspace = String.fromEnvironment(
    'E2E_SUBSPACE',
    defaultValue: 'Отдел UI',
  );

  testWidgets('Компания: «+» → Новое подпространство → создано без 403', (
    tester,
  ) async {
    app.main();
    await tester.ensureLizaHome();

    // Вход в компанию: column-mode — rail (тултип = имя компании); телефон —
    // чип «Компании» → плитка компании.
    final railItem = find.byTooltip(company);
    final companiesChip = find.text('Компании');
    final end = DateTime.now().add(const Duration(seconds: 40));
    while (railItem.evaluate().isEmpty && companiesChip.evaluate().isEmpty) {
      if (DateTime.now().isAfter(end)) {
        throw Exception('Не дождались ни rail компании, ни чипа «Компании»');
      }
      await tester.pump(const Duration(milliseconds: 200));
    }
    if (railItem.evaluate().isNotEmpty) {
      await tester.tap(railItem.first);
    } else {
      await tester.tap(companiesChip.first);
      await tester.pump(const Duration(milliseconds: 700));
      final companyTile = find.text(company);
      await tester.waitUntil(companyTile, timeout: const Duration(seconds: 40));
      await tester.tap(companyTile.first);
    }
    await tester.pump(const Duration(milliseconds: 700));
    await tester.waitUntil(find.byType(SpaceView));

    // Меню ⋮ в шапке пространства (задача 04: «Новое подпространство» уехало
    // сюда из «+», вместо «+» — кнопка «Создать чат»).
    final menu = find.descendant(
      of: find.byType(SpaceView),
      matching: find.byWidgetPredicate(
        (w) => w is PopupMenuButton<SpaceActions>,
      ),
    );
    await tester.waitUntil(menu);
    await tester.tap(menu.first);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.waitUntil(find.text('Новое подпространство'));
    await tester.tap(find.text('Новое подпространство').last);
    await tester.pump(const Duration(milliseconds: 700));

    // Диалог имени → «Создать».
    final field = find.byType(TextField).last;
    await tester.waitUntil(field);
    await tester.enterText(field, subspace);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Создать').last);
    await tester.pump(const Duration(milliseconds: 700));

    // AC:RL-subspace-create-with-parent/10 — user-visible эффект: подпространство
    // в списке компании, диалога «Нет прав доступа» нет.
    await tester.waitUntil(
      find.descendant(
        of: find.byType(SpaceView),
        matching: find.text(subspace),
      ),
      timeout: const Duration(seconds: 40),
    );
    expect(find.text('Нет прав доступа'), findsNothing);
  });
}
