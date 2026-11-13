import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/demo_auth/demo_auth_flow.dart';
import 'package:liza/pages/demo_auth/demo_auth_service.dart';
import 'package:liza/pages/demo_auth/sms_code_source.dart';
import 'package:liza/pages/demo_auth/widgets/code_input.dart';

/// ledger:RL-auth-otp-sms-autofill
///
/// Автовставка кода из СМС: подсказка `oneTimeCode` только у первой ячейки,
/// вставка целого кода с ЛЮБОЙ ячейки уходит наружу ровно один раз, строгий
/// разбор текста СМС. Тесты идут по реальным `TextField` `CodeInput`.
void main() {
  Finder cellFinder() => find.descendant(
    of: find.byType(CodeInput),
    matching: find.byType(TextField),
  );

  Future<List<String>> pump(WidgetTester tester, {CodeInputFeed? feed}) async {
    final completed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CodeInput(length: 6, feed: feed, onCompleted: completed.add),
        ),
      ),
    );
    await tester.pump();
    return completed;
  }

  testWidgets('AC:RL-auth-otp-sms-autofill/1 oneTimeCode только у ячейки 0', (
    tester,
  ) async {
    await pump(tester);
    final fields = tester.widgetList<TextField>(cellFinder()).toList();
    expect(fields, hasLength(6));
    expect(fields.first.autofillHints, [AutofillHints.oneTimeCode]);
    for (final field in fields.skip(1)) {
      expect(field.autofillHints, isNull);
    }
  });

  group('AC:RL-auth-otp-sms-autofill/2 разбор текста СМС', () {
    test('один блок из 6 цифр', () {
      expect(extractSmsCode('Код: 123456. Никому не говорите'), '123456');
      expect(extractSmsCode('123456 — код входа Liza'), '123456');
    });
    test('неоднозначность или другая длина — не вставляем', () {
      expect(extractSmsCode('Код 123456, заказ 654321'), isNull);
      expect(extractSmsCode('Код 12345'), isNull);
      expect(extractSmsCode('Код 1234567'), isNull);
      expect(extractSmsCode('без цифр'), isNull);
    });
    test('тот же код дважды в тексте — это один код', () {
      expect(extractSmsCode('123456 ... повторяю: 123456'), '123456');
    });
  });

  for (var cell = 0; cell < 6; cell++) {
    testWidgets('AC:RL-auth-otp-sms-autofill/3 вставка 6 цифр в ячейку $cell — '
        'один onCompleted', (tester) async {
      final completed = await pump(tester);
      await tester.enterText(cellFinder().at(cell), '123456');
      await tester.pump();
      expect(completed, ['123456']);
      expect(
        tester
            .widgetList<TextField>(cellFinder())
            .map((f) => f.controller!.text)
            .join(),
        '123456',
      );
    });
  }

  testWidgets('AC:RL-auth-otp-sms-autofill/3 вставка с разделителями', (
    tester,
  ) async {
    final completed = await pump(tester);
    await tester.enterText(cellFinder().first, '123 456');
    await tester.pump();
    expect(completed, ['123456']);
  });

  testWidgets('вставка 5 цифр не завершает ввод', (tester) async {
    final completed = await pump(tester);
    await tester.enterText(cellFinder().first, '12345');
    await tester.pump();
    expect(completed, isEmpty);
  });

  testWidgets('AC:RL-auth-otp-sms-autofill/4 повтор того же кода — без '
      'второго onCompleted', (tester) async {
    final feed = CodeInputFeed();
    final completed = await pump(tester, feed: feed);
    await tester.enterText(cellFinder().first, '123456');
    await tester.pump();
    feed.push('123456');
    await tester.pump();
    await tester.enterText(cellFinder().at(3), '123456');
    await tester.pump();
    expect(completed, ['123456']);
  });

  testWidgets('AC:RL-auth-otp-sms-autofill/4 после правки ячейки код уходит '
      'снова', (tester) async {
    final feed = CodeInputFeed();
    final completed = await pump(tester, feed: feed);
    feed.push('123456');
    await tester.pump();
    await tester.enterText(cellFinder().last, '');
    await tester.pump();
    feed.push('654321');
    await tester.pump();
    expect(completed, ['123456', '654321']);
  });

  testWidgets('AC:RL-auth-otp-sms-autofill/4 замена цифры на месте после '
      'неверного кода — код уходит снова', (tester) async {
    final completed = await pump(tester);
    await tester.enterText(cellFinder().first, '123456');
    await tester.pump();
    await tester.enterText(cellFinder().at(2), '9');
    await tester.pump();
    expect(completed, ['123456', '129456']);
  });

  testWidgets('AC:RL-auth-otp-sms-autofill/4 новая СМС после «Отправить '
      'повторно» поверх заполненных ячеек — код уходит', (tester) async {
    final feed = CodeInputFeed();
    final completed = await pump(tester, feed: feed);
    feed.push('123456');
    await tester.pump();
    feed.push('654321');
    await tester.pump();
    expect(completed, ['123456', '654321']);
  });

  testWidgets('подача кода после dispose безопасна', (tester) async {
    final feed = CodeInputFeed();
    final completed = await pump(tester, feed: feed);
    await tester.pumpWidget(const SizedBox());
    feed.push('123456');
    expect(completed, isEmpty);
  });

  group('шаг СМС + источник кода', () {
    http.Response json(Map<String, Object?> body, [int status = 200]) =>
        http.Response(jsonEncode(body), status);

    var verifyCalls = 0;

    Future<void> pumpFlow(
      WidgetTester tester,
      FakeSmsSource source, {
      String channel = 'phone',
    }) async {
      verifyCalls = 0;
      final client = MockClient((request) async {
        if (request.url.path.endsWith('/phone/start')) {
          return json({
            'ticket': 't',
            'channel': channel,
            'masked_destination': '+7 999 ***-**-67',
          });
        }
        if (request.url.path.endsWith('/phone/verify')) {
          verifyCalls++;
          return json({'error': 'invalid_code'}, 400);
        }
        throw StateError('Unexpected request: ${request.url.path}');
      });
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => DemoAuthFlow(
              phone: '+79991234567',
              service: DemoAuthService(client: client),
              smsCodeSource: source,
            ),
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
    }

    testWidgets('AC:RL-auth-otp-sms-autofill/5 код из СМС уходит на проверку '
        'ровно один раз', (tester) async {
      final source = FakeSmsSource();
      await pumpFlow(tester, source);
      expect(source.nextCalls, 1);
      source.deliver('123456');
      await tester.pumpAndSettle();
      expect(verifyCalls, 1);
    });

    testWidgets('AC:RL-auth-otp-sms-autofill/6 для кода из письма источник не '
        'запрашивается', (tester) async {
      final source = FakeSmsSource();
      await pumpFlow(tester, source, channel: 'email');
      expect(source.nextCalls, 0);
    });

    testWidgets('AC:RL-auth-otp-sms-autofill/6 источник снимается в dispose', (
      tester,
    ) async {
      final source = FakeSmsSource();
      await pumpFlow(tester, source);
      await tester.pumpWidget(const SizedBox());
      expect(source.cancelCalls, greaterThanOrEqualTo(2));
      source.deliver('123456'); // опоздавший ответ — без падения
      await tester.pump();
    });
  });
}

class FakeSmsSource implements SmsCodeSource {
  final _waiters = <Completer<String?>>[];
  int nextCalls = 0;
  int cancelCalls = 0;

  @override
  Future<String?> next() {
    nextCalls++;
    final completer = Completer<String?>();
    _waiters.add(completer);
    return completer.future;
  }

  @override
  Future<void> cancel() async => cancelCalls++;

  void deliver(String code) {
    for (final w in _waiters) {
      if (!w.isCompleted) w.complete(code);
    }
  }
}
