// ledger:RL-account-erasure-full
// AC:RL-account-erasure-full/7
//
// Страж текста удаления аккаунта (Apple 5.1.1(v)): первый диалог говорит
// «удалит аккаунт и данные», а не «деактивирует», и диалог подтверждения
// называет, что стирается и что остаётся по закону. Рендерим настоящий
// диалог — проверяем то, что читает человек, а не содержимое .arb.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_security/delete_account_dialog.dart';

Iterable<String> _visibleTexts(WidgetTester tester) sync* {
  for (final w in tester.widgetList<Text>(find.byType(Text))) {
    final data = w.data;
    if (data != null) yield data;
  }
}

void main() {
  for (final (locale, warningWord, deletedName, retention) in const [
    (Locale('ru'), 'удалит', 'Удалённый аккаунт', 'до 5 лет'),
    (Locale('en'), 'delete', 'Deleted account', 'up to 5 years'),
  ]) {
    testWidgets(
      'AC-7: первый диалог про удаление, не деактивацию (${locale.languageCode})',
      (tester) async {
        final l10n = await tester.runAsync(() => L10n.delegate.load(locale));
        expect(
          l10n!.deleteAccountFirstWarning.toLowerCase(),
          contains(warningWord),
        );
        expect(
          l10n.deleteAccountFirstWarning.toLowerCase(),
          isNot(contains('деактив')),
        );
        expect(
          l10n.deleteAccountFirstWarning.toLowerCase(),
          isNot(contains('deactivate')),
        );
      },
    );

    testWidgets(
      'AC-7: диалог подтверждения называет, что остаётся по закону (${locale.languageCode})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() => L10n.delegate.load(locale));
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            locale: locale,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showDeleteAccountDialog(
                    context,
                    accountTitle: 'user_f86a7e57',
                    accountLogin: '@user_f86a7e57:user.liza.ru',
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();

        final texts = _visibleTexts(tester).join('\n');
        expect(texts, contains(deletedName));
        expect(texts, contains(retention));
      },
    );
  }
}
