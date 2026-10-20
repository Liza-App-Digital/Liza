// Device-flow страж (Ярус C, живой прогон на iOS+Android) новых точек входа
// приглашения (итерация 2026-08-20).
// ledger:RL-chat-list-phone-search-invite
// ledger:RL-create-menu-contacts-items
// ledger:RL-settings-invite-friends-action
//
// Живьём на реальном бинаре проверяем клиентский слой, который host widget-тесты
// не покрывают (полный ChatList/Settings + навигация + меню-гейты):
//   #6 меню «+» показывает «Пригласить контакт» и «Контакты» (isMobile), тап по
//      «Пригласить контакт» не роняет приложение (нативный share integration_test
//      НЕ видит — native residual);
//   #2 настройки показывают «Пригласить людей» и «Ваш ID» (не «Почта»);
//   #3/#4 в режиме поиска строки-приглашения НЕТ (с 19.10 — только в «+»),
//      пустой запрос не рисует публичных разделов, ввод номера телефона в
//      поиск не роняет приложение (матч lookup требует живого auth-proxy —
//      best-effort).
// Гоняется .claude/tools/prove-ui/run.sh на iOS И Android.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liza/main.dart' as app;

import 'liza_flows.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('#6 меню «+»: пункты «Пригласить контакт» и «Контакты» живьём',
      (tester) async {
    app.main();
    await tester.ensureLizaHome();

    // Кнопка «+» в шапке (Icons.add_outlined) вне режима поиска.
    final plusBtn = find.byIcon(Icons.add_outlined);
    await tester.waitUntil(plusBtn);
    await tester.tap(plusBtn.first);
    await tester.pump(const Duration(milliseconds: 700));

    // Оба пункта присутствуют (гейт isMobile отдаёт «Контакты» на iOS/Android).
    await tester.waitUntil(find.text('Пригласить контакт'));
    expect(find.text('Пригласить контакт'), findsWidgets,
        reason: '#6: «Пригласить контакт» отсутствует в меню «+».');
    expect(find.text('Контакты'), findsWidgets,
        reason: '#6: «Контакты» отсутствует в меню «+» на мобильной платформе.');

    // Тап по «Пригласить контакт» — нативный share; проверяем, что не роняет.
    await tester.tap(find.text('Пригласить контакт').last);
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull,
        reason: '#6: тап «Пригласить контакт» бросил исключение.');
  });

  testWidgets('#2 настройки: «Пригласить людей» и «Ваш ID» видны живьём',
      (tester) async {
    app.main();
    await tester.ensureLizaHome();

    // Маршрутом, а не тапами через меню аватара: путь до настроек стерегут
    // свои тесты, а прежний best-effort через `if` молча зеленел, не найдя
    // меню. Здесь предмет — подписи пунктов (Надежда, В5 18.10).
    final ctx = tester.element(find.byType(Navigator).first);
    GoRouter.of(ctx).go('/rooms/settings');
    await tester.pump(const Duration(milliseconds: 900));

    await tester.waitUntil(find.text('Пригласить людей'),
        timeout: const Duration(seconds: 15));
    expect(find.text('Пригласить людей'), findsOneWidget,
        reason: '#2: пункт «Пригласить людей» не найден в настройках.');
    expect(find.text('Пригласить друзей'), findsNothing,
        reason: '#2: в настройках осталась старая подпись «Пригласить друзей».');
    expect(find.text('Ваш ID'), findsOneWidget,
        reason: '#2: пункт «Ваш ID» не найден в настройках.');
    expect(find.text('Почта'), findsNothing,
        reason: '#2: в настройках осталась подпись «Почта».');
    expect(tester.takeException(), isNull);
  });

  testWidgets('#3/#4 поиск: без строки-приглашения + ввод номера телефона живьём',
      (tester) async {
    app.main();
    await tester.ensureLizaHome();

    // Войти в режим поиска: иконка поиска в шапке.
    final searchIcon = find.byIcon(Icons.search_outlined);
    await tester.waitUntil(searchIcon);
    await tester.tap(searchIcon.first);
    await tester.pump(const Duration(milliseconds: 600));

    // #4 (негатив с 19.10, RL-chat-list-search-empty-and-order AC-5): пустая
    // лупа — ни строки «Пригласить людей», ни глобальных разделов; дебаунс
    // поиска 500 мс, ждём с запасом.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('Пригласить людей'), findsNothing,
        reason: '#4: в поиске осталась строка-приглашение.');
    expect(find.text('Публичные чаты'), findsNothing,
        reason: '#4: пустой запрос показал публичные чаты.');
    expect(find.text('Публичные каналы'), findsNothing,
        reason: '#4: пустой запрос показал публичные каналы.');

    // #3: ввод полного номера телефона в поле поиска не роняет приложение.
    final searchField = find.byType(TextField);
    if (searchField.evaluate().isNotEmpty) {
      await tester.enterText(searchField.first, '+7 999 123-45-67');
      // Дебаунс поиска — 500 мс; ждём с запасом на lookup.
      await tester.pump(const Duration(milliseconds: 1500));
      expect(tester.takeException(), isNull,
          reason: '#3: ввод номера телефона в поиск бросил исключение.');
      // Несовпавший номер больше не предлагает пригласить: это — «+».
      expect(find.text('Пригласить людей'), findsNothing);
    }
  });
}
