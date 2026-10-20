// ledger:RL-settings-invite-friends-action
// AC:RL-settings-invite-friends-action/5
//
// Текст приглашения (нативный share из настроек/меню «+»): бренд латиницей.
// Перенесено 2026-10-19 из удалённого invite_people_row_test.dart
// (RL-chat-list-invite-people-row AC-2 retired).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';

void main() {
  testWidgets('текст приглашения в ru — «Я пользуюсь Liza», не «Лиза» '
      '(бренд-латиница; ловит тихий откат inviteMessageText)', (tester) async {
    // L10n грузит языки deferred-импортом — в fake-async сам не догрузится.
    await tester.runAsync(() => L10n.delegate.load(const Locale('ru')));
    late final String ru;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        home: Builder(
          builder: (context) {
            ru = L10n.of(context).inviteMessageText('https://me.liza.ru/i/xyz');
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(ru, contains('Liza'));
    expect(ru, isNot(contains('Лиза')));
    expect(ru, contains('https://me.liza.ru/i/xyz'));
  });
}
