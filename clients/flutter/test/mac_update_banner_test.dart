// ledger:RL-macos-stale-process-update
// AC:RL-macos-stale-process-update/6 AC:RL-macos-stale-process-update/7
// AC:RL-macos-stale-process-update/8
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/mac_update_banner.dart';
import 'package:liza/utils/mac_update_checker.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(body: Column(children: [child])),
  );

  MacUpdateChecker checker() => MacUpdateChecker(
    enabled: false,
    readDiskBuild: () async => null,
    readRunningBuild: () async => '3807',
    onStale: (_, _) {},
  );

  testWidgets(
    'процесс свежий — плашки нет; устарел — «Liza обновилась · Выйти»',
    (tester) async {
      final c = checker();
      addTearDown(c.dispose);
      await tester.pumpWidget(wrap(MacUpdateBanner(checker: c, quit: () {})));
      await tester.pumpAndSettle();
      expect(
        find.text('Liza обновилась — закройте и откройте заново'),
        findsNothing,
      );
      expect(find.text('Выйти'), findsNothing);

      c.updateAvailable.value = true;
      await tester.pumpAndSettle();
      expect(
        find.text('Liza обновилась — закройте и откройте заново'),
        findsOneWidget,
      );
      expect(find.text('Выйти'), findsOneWidget);
      expect(find.text('Доступна новая версия Liza'), findsNothing);
    },
  );

  testWidgets('двойной тап «Выйти» — выход ровно один раз', (tester) async {
    final c = checker()..updateAvailable.value = true;
    addTearDown(c.dispose);
    var quits = 0;
    await tester.pumpWidget(
      wrap(MacUpdateBanner(checker: c, quit: () => quits++)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выйти'));
    await tester.tap(find.text('Выйти'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(quits, 1);
  });

  test('строки есть в en и ru', () {
    Map<String, dynamic> arb(String lang) =>
        jsonDecode(File('lib/l10n/intl_$lang.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = arb('en');
    final ru = arb('ru');
    expect(
      en['macUpdateRestartNeeded'],
      'Liza has been updated — quit and open it again',
    );
    expect(en['macUpdateQuit'], 'Quit');
    expect(
      ru['macUpdateRestartNeeded'],
      'Liza обновилась — закройте и откройте заново',
    );
    expect(ru['macUpdateQuit'], 'Выйти');
  });
}
