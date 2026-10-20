// Device-flow страж (Ярус C, живой прогон на iOS+Android) фичи «Добавить контакты».
// ledger:RL-contacts-screen-match-invite
// ledger:RL-chat-list-agents-people-tabs
//
// Живьём на реальном бинаре: пункт меню «Контакты» открывает экран ContactsPage
// без краша/белого экрана (навигация + route + меню-гейт isMobile работают), и
// внизу списка чатов на «Все» есть строка «+ Новый запрос» (с 2026-10-19 вместо
// «Пригласить людей»; закреплённая «Лиза ИИ» ей не нужна — ассерт безусловный).
// Нативный доступ к книге/share integration_test НЕ видит (native residual) —
// здесь проверяем клиентский слой живьём, чего host widget-тесты не покрывают.
// Гоняется .claude/tools/prove-ui/run.sh на iOS И Android.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat_list/client_chooser_button.dart';
import 'package:liza/pages/contacts/contacts_page.dart';

import 'liza_flows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Добавить контакты: пункт «Контакты» открывает экран живьём (+ строка «Новый запрос»)',
      (tester) async {
    app.main();
    await tester.ensureLizaHome();

    // Строка «+ Новый запрос» — последней под переписками; ищем по ключу:
    // текст «Новый запрос» носят и сами чаты-запросы. «Пригласить людей» нет.
    // AC:RL-chat-list-agents-people-tabs/5
    final newRequestRow = find.byKey(const ValueKey('new_request_row'));
    final chatList = find
        .descendant(
          of: find.byKey(const PageStorageKey('chatListScrollView')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(newRequestRow, 300, scrollable: chatList);
    expect(newRequestRow, findsOneWidget);
    expect(find.text('Пригласить людей'), findsNothing);

    // ОСНОВНОЙ живой ассерт: меню аккаунта → «Контакты» → экран открывается.
    // Шапка с меню аккаунта могла уехать вверх вместе со списком — вернуть.
    final chooser = find.byType(ClientChooserButton);
    await tester.scrollUntilVisible(chooser, -300, scrollable: chatList);
    await tester.waitUntil(chooser);
    await tester.tap(chooser.first);
    await tester.pump(const Duration(milliseconds: 700));

    // Пункт «Контакты» присутствует (гейт isMobile отдаёт его на iOS/Android).
    await tester.waitUntil(find.text('Контакты'));
    await tester.tap(find.text('Контакты').last);
    await tester.pump(const Duration(milliseconds: 800));

    // Экран отрисовался живьём: запрос доступа/объяснение/список/пусто — но НЕ
    // краш и НЕ белый экран.
    await tester.waitUntil(find.byType(ContactsPage),
        timeout: const Duration(seconds: 25));
    expect(find.byType(ContactsPage), findsOneWidget,
        reason: 'Экран «Контакты» не открылся живьём.');
    expect(tester.takeException(), isNull,
        reason: 'Экран «Контакты» бросил исключение при рендере на устройстве.');
  });
}
