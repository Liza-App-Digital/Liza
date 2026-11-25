// Счета СБП на экране «Ваш ID»: состояния раздела, привязка, отзыв.
//
// ledger:RL-sbp-account-bindings
// Критерии приёмки (запрос владельца, сессия 2026-11-24): «на экране настроек
// "Ваш ID" пользователь может привязать к своему кабинету 1 или несколько счетов
// СБП». Тесты рендерят РЕАЛЬНЫЙ виджет SbpMethodsSection.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/settings_email/sbp_methods.dart';

const _keys = <String>[
  'settingsSbpTitle',
  'settingsSbpEmpty',
  'settingsSbpAttach',
  'settingsSbpCheck',
  'settingsSbpPending',
  'settingsSbpPendingHint',
  'settingsSbpActive',
  'settingsSbpRevoked',
  'settingsSbpExpired',
  'settingsSbpDetach',
  'settingsSbpDetachConfirm',
  'settingsSbpError',
  'settingsSbpNoContact',
  'settingsSbpLimit',
  'settingsSbpUnavailable',
  'settingsSbpLinkFailed',
];

class _FakeApi extends SbpMethodsApi {
  _FakeApi(this.methods)
      : super(baseUrl: 'auth.example', token: 'token', serverName: 'srv');

  List<SbpMethod> methods;
  String? failCode;
  int attachFailures = 0;
  final List<String> attachKeys = [];
  int listCalls = 0;
  int detachCalls = 0;
  bool refreshSeen = false;
  SbpAttachResult? attachResult;

  @override
  Future<List<SbpMethod>> list({bool refresh = false}) async {
    listCalls += 1;
    refreshSeen = refreshSeen || refresh;
    final code = failCode;
    if (code != null) throw SbpMethodsException(code);
    return methods;
  }

  @override
  Future<SbpAttachResult> attach(String attachKey) async {
    attachKeys.add(attachKey);
    if (attachFailures > 0) {
      attachFailures -= 1;
      throw const SbpMethodsException('network_error');
    }
    final result = attachResult ??
        const SbpAttachResult(
          SbpMethod(bindingId: 'b-new', state: 'pending'),
          'https://bank.example/pay',
        );
    methods = [...methods, result.method!];
    return result;
  }

  @override
  Future<void> detach(String bindingId) async {
    detachCalls += 1;
    methods = methods.where((m) => m.bindingId != bindingId).toList();
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api,
    {Future<bool> Function(String)? openLink}) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Scaffold(
      body: ListView(
        children: [
          SbpMethodsSection(
            baseUrl: 'auth.example',
            token: 'token',
            serverName: 'srv',
            api: api,
            openLink: openLink ?? (_) async => true,
          ),
        ],
      ),
    ),
  ));
  // initState запускает загрузку; pumpAndSettle дожидается, пока флаг
  // загрузки снимется и индикатор исчезнет (иначе он анимирован бесконечно).
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('AC:RL-sbp-account-bindings/1 пустой список предлагает привязать счёт', (tester) async {
    final api = _FakeApi(const []);
    await _pump(tester, api);
    expect(find.text('Счета СБП'), findsOneWidget);
    expect(find.textContaining('Пока нет счетов'), findsOneWidget);
    expect(find.text('Привязать счёт СБП'), findsOneWidget);
  });

  testWidgets('AC:RL-sbp-account-bindings/2 активный счёт: банк, маска, состояние',
      (tester) async {
    final api = _FakeApi(const [
      SbpMethod(
        bindingId: 'b-1',
        state: 'active',
        bank: 'sberbank',
        mask: '+7 ••• ••• 24 24',
        chargeable: true,
      ),
    ]);
    await _pump(tester, api);
    expect(find.text('sberbank +7 ••• ••• 24 24'), findsOneWidget);
    expect(find.text('Активен'), findsOneWidget);
    expect(find.byIcon(Icons.link_off), findsOneWidget);
  });

  testWidgets('AC:RL-sbp-account-bindings/2 ожидающий счёт: «Проверить» и перечитывание',
      (tester) async {
    final api = _FakeApi(const [
      SbpMethod(bindingId: 'b-1', state: 'pending', bank: 'sberbank'),
    ]);
    await _pump(tester, api);
    expect(find.text('Ждёт подтверждения банка'), findsOneWidget);
    expect(find.textContaining('Откройте ссылку банка'), findsOneWidget);

    await tester.tap(find.text('Проверить'));
    await tester.pumpAndSettle();
    expect(api.refreshSeen, isTrue);
  });

  testWidgets('AC:RL-sbp-account-bindings/3 отзыв только после подтверждения',
      (tester) async {
    final api = _FakeApi(const [
      SbpMethod(
        bindingId: 'b-1',
        state: 'active',
        bank: 'sberbank',
        mask: '+7 ••• ••• 24 24',
        chargeable: true,
      ),
    ]);
    await _pump(tester, api);

    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    expect(find.textContaining('Отвязать этот счёт?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Отмена'));
    await tester.pumpAndSettle();
    expect(api.detachCalls, 0);

    await tester.tap(find.byIcon(Icons.link_off));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Отвязать').last);
    await tester.pumpAndSettle();
    expect(api.detachCalls, 1);
  });

  testWidgets('AC:RL-sbp-account-bindings/4 ошибка сервиса — текстом',
      (tester) async {
    final api = _FakeApi(const [])..failCode = 'payments_unavailable';
    await _pump(tester, api);
    expect(find.textContaining('Сервис оплаты недоступен'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('AC:RL-sbp-account-bindings/4 привязка открывает ссылку банка', (tester) async {
    final api = _FakeApi(const []);
    String? opened;
    await _pump(tester, api, openLink: (url) async {
      opened = url;
      return true;
    });
    await tester.tap(find.text('Привязать счёт СБП'));
    await tester.pumpAndSettle();
    expect(opened, 'https://bank.example/pay');
  });

  testWidgets('AC:RL-sbp-account-bindings/7 повтор привязки идёт с тем же ключом',
      (tester) async {
    final api = _FakeApi(const [])..attachFailures = 1;
    await _pump(tester, api);
    await tester.tap(find.text('Привязать счёт СБП'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Привязать счёт СБП'));
    await tester.pumpAndSettle();
    expect(api.attachKeys.length, 2);
    expect(api.attachKeys[0], api.attachKeys[1],
        reason: 'повтор после сбоя обязан нести тот же ключ операции');
  });

  testWidgets('AC:RL-sbp-account-bindings/6 выключенный модуль не рисует раздел',
      (tester) async {
    final api = _FakeApi(const [])..failCode = 'payments_disabled';
    await _pump(tester, api);
    expect(find.text('Счета СБП'), findsNothing);
    expect(find.text('Привязать счёт СБП'), findsNothing);
  });

  test('AC:RL-sbp-account-bindings/5 ключи есть в en и ru', () {
    // Ловушка проекта: без ключа в ru Flutter молча подставит английский.
    for (final file in ['lib/l10n/intl_en.arb', 'lib/l10n/intl_ru.arb']) {
      final arb = jsonDecode(File(file).readAsStringSync()) as Map;
      for (final key in _keys) {
        expect(arb.containsKey(key), isTrue, reason: 'нет $key в $file');
      }
    }
  });
}
