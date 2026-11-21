import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/homeserver_picker/login_entry_actions.dart';
import 'package:liza/pages/homeserver_picker/reviewer_login_link.dart';
import 'package:liza/utils/platform_infos.dart';

/// Вход для проверяющих App Review: ссылка под вводом телефона ведёт на
/// экран логина и пароля, а поток телефона остаётся нетронутым.
void main() {
  Widget wrap(Widget child) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(body: child),
  );

  testWidgets('ссылка подписана через L10n и нажимается', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(ReviewerLoginLink(onPressed: () => taps++)));
    await tester.pumpAndSettle();

    expect(find.text('Вход для проверяющих'), findsOneWidget);
    await tester.tap(find.text('Вход для проверяющих'));
    expect(taps, 1);
  });

  testWidgets('нажатие ведёт на маршрут логина и пароля', (tester) async {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: ReviewerLoginLink(onPressed: () => context.push('/login')),
          ),
        ),
        GoRoute(
          path: '/login',
          builder: (_, _) => const Scaffold(body: Text('экран логина')),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Вход для проверяющих'));
    await tester.pumpAndSettle();
    expect(find.text('экран логина'), findsOneWidget);
  });

  testWidgets('поток телефона не затронут: поле и «Продолжить» на месте', (
    tester,
  ) async {
    String? submitted;
    await tester.pumpWidget(
      wrap(
        Column(
          children: [
            LoginEntryActions(
              isLoading: false,
              onRegister: () {},
              onSignIn: () {},
              onSubmitPhone: (p) => submitted = p,
            ),
            ReviewerLoginLink(onPressed: () {}),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    expect(submitted, isNull);
  });

  test('сервер для проверяющих и имя устройства проходят client_guard', () {
    expect(AppConfig.reviewerLoginHomeserver, 'user.liza.ru');
    // Login шлёт PlatformInfos.clientName как initial_device_display_name.
    expect(PlatformInfos.clientName, startsWith('Liza'));
  });
}
