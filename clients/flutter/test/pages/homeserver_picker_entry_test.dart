// ledger:RL-login-entry-modes
// AC:RL-login-entry-modes/1 AC:RL-login-entry-modes/2
// ledger:RL-auth-otp-channel-switching
// AC:RL-auth-otp-channel-switching/14 AC:RL-auth-otp-channel-switching/15
// AC:RL-auth-otp-channel-switching/16 AC:RL-auth-otp-channel-switching/17
// AC:RL-auth-otp-channel-switching/18 AC:RL-auth-otp-channel-switching/20
//
// Тот же файл — страж AC-1/AC-2 записи RL-auth-orphan-after-oidc: «экран „нет
// доступа“ не живёт на первом экране» там сформулировано как отдельный критерий,
// а проверяется этими же ассертами (дублировать тест ради тега смысла нет).
// ledger:RL-auth-orphan-after-oidc
// AC:RL-auth-orphan-after-oidc/1 AC:RL-auth-orphan-after-oidc/2
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/homeserver_picker/login_entry_actions.dart';
import 'package:liza/pages/homeserver_picker/login_entry_description.dart';

void main() {
  Widget wrap(
    Widget child, {
    Locale locale = const Locale('ru'),
    TextScaler textScaler = TextScaler.noScaling,
    ThemeData? theme,
  }) => MaterialApp(
    key: ValueKey(locale),
    theme: theme,
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
  testWidgets('RU: заголовок и подзаголовок совпадают с утверждёнными 18.10', (
    tester,
  ) async {
    await tester.pumpWidget(wrap(const LoginEntryDescription(compact: true)));
    await tester.pumpAndSettle();

    expect(find.text('Ваш ассистент для бизнес-задач'), findsOneWidget);
    expect(
      find.text(
        'Лиза соберёт лендинг, контент-план, отчёт по продажам или ссылку на оплату. Создавайте чаты с людьми и добавляйте в них ИИ-ассистента, чтобы он помогал всем участникам.',
      ),
      findsOneWidget,
    );
  });

  // AC:RL-auth-otp-channel-switching/15
  test('EN: слоган про бизнес-задачи, без отсылки к мессенджеру', () {
    Map<String, dynamic> arb(String locale) =>
        jsonDecode(File('lib/l10n/intl_$locale.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = arb('en');
    expect(en['lizaTagline'], 'Your assistant for business tasks');
    expect(
      en['lizaTaglineDetails'],
      'Liza will put together a landing page, a content plan, a sales report or a payment link. Create chats with people and add the AI assistant so it helps every participant.',
    );
    // «Платформа для общения — нельзя, это отсылка на мессенджер» (Надежда, 18.10).
    for (final locale in ['ru', 'en']) {
      for (final key in ['lizaTagline', 'lizaTaglineDetails']) {
        final value = (arb(locale)[key] as String).toLowerCase();
        for (final banned in [
          'платформ',
          'общени',
          'platform',
          'communication',
        ]) {
          expect(value, isNot(contains(banned)), reason: '$locale/$key');
        }
      }
    }
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
        'Лиза соберёт лендинг, контент-план, отчёт по продажам или ссылку на оплату. Создавайте чаты с людьми и добавляйте в них ИИ-ассистента, чтобы он помогал всем участникам.',
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  // AC:RL-auth-otp-channel-switching/20
  testWidgets(
    'узкий экран 320 dp: заголовок одной строкой, не мельче прежнего слогана',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Тестовый шрифт по умолчанию даёт ширины, далёкие от реальных, —
      // меряем системным шрифтом с кириллицей, как mini_app_button_grid_test.
      const fontPath = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';
      String? fontFamily;
      if (File(fontPath).existsSync()) {
        final loader = FontLoader('AppCyr')
          ..addFont(
            Future.value(File(fontPath).readAsBytesSync().buffer.asByteData()),
          );
        await loader.load();
        fontFamily = 'AppCyr';
      }

      await tester.pumpWidget(
        wrap(entryWithPhoneInput(), theme: ThemeData(fontFamily: fontFamily)),
      );
      await tester.pumpAndSettle();

      final title = find.text('Ваш ассистент для бизнес-задач');
      expect(title, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(title);
      expect(paragraph.didExceedMaxLines, isFalse);

      // FittedBox ужимает слоган вместо переноса, поэтому одна строка есть
      // всегда; читаемость держим относительно принятого до 18.10 слогана
      // «Платформа для вашего общения»: новый не должен ужиматься заметно
      // сильнее.
      double naturalWidth(String text) {
        final painter = TextPainter(
          text: TextSpan(text: text, style: paragraph.text.style),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final width = painter.width;
        painter.dispose();
        return width;
      }

      final ratio =
          naturalWidth('Ваш ассистент для бизнес-задач') /
          naturalWidth('Платформа для вашего общения');
      expect(ratio, lessThanOrEqualTo(1.03), reason: 'ratio=$ratio');
      expect(tester.takeException(), isNull);
    },
  );
}
