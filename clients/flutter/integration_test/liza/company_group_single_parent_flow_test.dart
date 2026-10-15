import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat_list/space_view.dart';

import 'liza_flows.dart';

/// E2E задачи 04 (newInterface) на РЕАЛЬНОМ бинаре: в подпространстве своей
/// компании кнопка «Создать чат» → имя → «Создать» → группа появляется в списке
/// подпространства. Что её НЕТ в корне компании (ровно один входящий
/// `m.space.child`), сверяется по серверу после прогона — REST-запросом
/// `/hierarchy` корня (см. RL-company-group-single-parent).
///
/// Требует Synapse с ВКЛЮЧЁННЫМ `single_space_guard`, компанию E2E_COMPANY с
/// подпространством E2E_PARENT, где E2E_USER1 — админ (на штатном локальном
/// стенде модуль намеренно выключен). Пример:
/// `--dart-define=APP_ENV=local --dart-define=E2E_HOMESERVER=http://localhost:8018
///  --dart-define=E2E_USER1=owner04 --dart-define=E2E_PASS1=pass04
///  --dart-define=E2E_COMPANY=Компания 1 --dart-define=E2E_PARENT=Отдел
///  --dart-define=E2E_CHAT=Чат UI 04`.
///
/// ledger:RL-company-group-single-parent
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const company = String.fromEnvironment(
    'E2E_COMPANY',
    defaultValue: 'Компания 1',
  );
  const parent = String.fromEnvironment('E2E_PARENT', defaultValue: 'Отдел');
  const chat = String.fromEnvironment('E2E_CHAT', defaultValue: 'Чат UI 04');

  testWidgets('Подпространство: «Создать чат» → группа в подпространстве', (
    tester,
  ) async {
    app.main();
    await tester.ensureLizaHome();

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

    // AC:RL-company-group-single-parent/8 — у админа в корне компании видна
    // явная кнопка «Создать чат», а иконки «+» в шапке больше нет.
    final createChat = find.descendant(
      of: find.byType(SpaceView),
      matching: find.text('Создать чат'),
    );
    await tester.waitUntil(createChat);
    expect(
      find.descendant(
        of: find.byType(SpaceView),
        matching: find.byIcon(Icons.add_outlined),
      ),
      findsNothing,
    );

    // Внутрь подпространства.
    final parentTile = find.descendant(
      of: find.byType(SpaceView),
      matching: find.text(parent),
    );
    await tester.waitUntil(parentTile, timeout: const Duration(seconds: 40));
    await tester.tap(parentTile.first);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.waitUntil(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text(parent),
      ),
    );

    await tester.waitUntil(createChat);
    await tester.tap(createChat.last);
    await tester.pump(const Duration(milliseconds: 700));

    final field = find.byType(TextField).last;
    await tester.waitUntil(field);
    await tester.enterText(field, chat);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Создать').last);
    await tester.pump(const Duration(milliseconds: 700));

    // User-visible эффект: группа в списке подпространства, ошибок нет.
    await tester.waitUntil(
      find.descendant(of: find.byType(SpaceView), matching: find.text(chat)),
      timeout: const Duration(seconds: 40),
    );
    expect(find.text('Нет прав доступа'), findsNothing);
  });
}
