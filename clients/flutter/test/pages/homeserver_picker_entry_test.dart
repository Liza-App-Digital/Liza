// ledger:RL-login-entry-modes
// AC:RL-login-entry-modes/1 AC:RL-login-entry-modes/2
// ledger:RL-auth-otp-channel-switching
// AC:RL-auth-otp-channel-switching/14 AC:RL-auth-otp-channel-switching/15
// AC:RL-auth-otp-channel-switching/16 AC:RL-auth-otp-channel-switching/17
// AC:RL-auth-otp-channel-switching/18
//
// Тот же файл — страж AC-1/AC-2 записи RL-auth-orphan-after-oidc: «экран „нет
// доступа“ не живёт на первом экране» там сформулировано как отдельный критерий,
// а проверяется этими же ассертами (дублировать тест ради тега смысла нет).
// ledger:RL-auth-orphan-after-oidc
// AC:RL-auth-orphan-after-oidc/1 AC:RL-auth-orphan-after-oidc/2
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/homeserver_picker/login_entry_actions.dart';
import 'package:liza/pages/homeserver_picker/login_entry_description.dart';

void main() {
  Widget wrap(
    Widget child, {
    Locale locale = const Locale('ru'),
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    key: ValueKey(locale),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: locale,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Scaffold(body: child),
  );

  /// Минимальная композиция реальных виджетов первого экрана. Её намеренно
  /// не дублирует фиктивная разметка: при увеличенном шрифте важно сохранить
  /// достижимость и поля телефона, и юридической сноски.
  Widget entryWithPhoneInput() => SingleChildScrollView(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          const LoginEntryDescription(compact: true),
          const SizedBox(height: 24),
          LoginEntryActions(
            isLoading: false,
            onRegister: () {},
            onSignIn: () {},
            onSubmitPhone: (_) {},
          ),
        ],
      ),
    ),
  );

  testWidgets('первый экран: регистрация первой и жирной, вход ниже', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        LoginEntryActions(isLoading: false, onRegister: () {}, onSignIn: () {}),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Зарегистрироваться'), findsOneWidget);
    expect(find.text('Войти в существующий аккаунт'), findsOneWidget);

    // AC-1: экран «нет доступа» больше не живёт на первом экране.
    expect(find.text('Оставить заявку'), findsNothing);
    expect(find.textContaining('Упс'), findsNothing);

    final registerY = tester.getTopLeft(find.text('Зарегистрироваться')).dy;
    final signInY = tester
        .getTopLeft(find.text('Войти в существующий аккаунт'))
        .dy;
    expect(registerY, lessThan(signInY));

    expect(
      find.ancestor(
        of: find.text('Зарегистрироваться'),
        matching: find.byType(ElevatedButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('Войти в существующий аккаунт'),
        matching: find.byType(TextButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('описание первого экрана не содержит текста «нет доступа»', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginEntryDescription()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Упс'), findsNothing);
    expect(find.textContaining('заявку'), findsNothing);
  });

  // AC:RL-auth-otp-channel-switching/14
  testWidgets('RU: слоган сохранён, подзаголовок совпадает с утверждённым', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginEntryDescription(compact: true)));
    await tester.pumpAndSettle();

    expect(find.text('Платформа для вашего общения'), findsOneWidget);
    expect(
      find.text(
        'Ставьте задачи Лизе лично или вместе с другими. Создавайте общие чаты, приглашайте людей — ИИ-ассистент поможет каждому участнику',
      ),
      findsOneWidget,
    );
  });

  // AC:RL-auth-otp-channel-switching/15
  test('EN: подзаголовок передаёт смысл общения с Liza', () {
    final en =
        jsonDecode(File('lib/l10n/intl_en.arb').readAsStringSync())
            as Map<String, dynamic>;
    expect(en['lizaTagline'], 'A platform for your communication');
    expect(
      en['lizaTaglineDetails'],
      'Give Liza tasks on your own or together with others. Create group chats, invite people — the AI assistant will help every participant',
    );
  });

  // AC:RL-auth-otp-channel-switching/16
  // AC:RL-auth-otp-channel-switching/17
  testWidgets('узкий экран с увеличенным текстом не обрезает вход и сноску', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      wrap(entryWithPhoneInput(), textScaler: TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byType(TextField),
      100,
      scrollable: scrollable,
    );
    expect(find.byType(TextField), findsOneWidget);

    final notice = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.textSpan?.toPlainText().contains(
                'политику конфиденциальности',
              ) ==
              true,
    );
    await tester.scrollUntilVisible(notice, 100, scrollable: scrollable);
    expect(notice, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // AC:RL-auth-otp-channel-switching/18
  testWidgets('desktop: длинный подзаголовок не вызывает overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(wrap(entryWithPhoneInput()));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Ставьте задачи Лизе лично или вместе с другими. Создавайте общие чаты, приглашайте людей — ИИ-ассистент поможет каждому участнику',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
