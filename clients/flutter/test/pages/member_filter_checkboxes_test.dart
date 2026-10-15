// ledger:RL-member-filter-useful-checkboxes
import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_members/company_member_entry.dart';
import 'package:liza/pages/chat_members/member_filter_checkboxes.dart';

MemberFilterFacts _m({bool server = true, bool company = true}) =>
    (belongsToServer: server, joinedCompany: company);

Future<void> _pump(
  WidgetTester tester, {
  String locale = 'ru',
  String serverLabel = 'Агро',
  bool hasServerName = true,
  bool isSpace = true,
  required bool showServer,
  required bool showCompany,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: MemberFilterCheckboxes(
          serverLabel: serverLabel,
          hasServerName: hasServerName,
          isSpace: isSpace,
          showServer: showServer,
          showCompany: showCompany,
          onServerOnly: false,
          inCompanyOnly: false,
          onServerChanged: (_) {},
          onCompanyChanged: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  // AC:RL-member-filter-useful-checkboxes/2
  group('memberFilterUsefulness: полезен ⇔ разбивает базу', () {
    ({bool server, bool company}) run(List<MemberFilterFacts> base) =>
        memberFilterUsefulness(base: base, hasServerName: true, isSpace: true);

    test('все на сервере и в компании → оба бесполезны', () {
      expect(run([_m(), _m()]), (server: false, company: false));
    });

    test('есть федеративный → «На сервере» полезен', () {
      expect(run([_m(), _m(server: false)]).server, isTrue);
    });

    test('есть участник только дочерних сущностей → «В компании» полезен', () {
      expect(run([_m(), _m(company: false)]).company, isTrue);
    });

    test('фильтр исключает ВСЕХ (вкладка приглашённых) → бесполезен', () {
      expect(run([_m(company: false), _m(company: false)]).company, isFalse);
      expect(run([_m(server: false)]).server, isFalse);
    });

    test('пустая база → оба бесполезны', () {
      expect(run(const []), (server: false, company: false));
    });

    test('польза чекбоксов независима друг от друга', () {
      expect(run([_m(), _m(server: false, company: false)]), (
        server: true,
        company: true,
      ));
    });
  });

  // AC:RL-member-filter-useful-checkboxes/6
  group('memberFilterUsefulness: ограничения', () {
    final mixed = [_m(), _m(server: false, company: false)];

    test('нет домена (roomId без «:») → «На сервере» никогда', () {
      expect(
        memberFilterUsefulness(
          base: mixed,
          hasServerName: false,
          isSpace: true,
        ).server,
        isFalse,
      );
    });

    test('не пространство → «В компании» никогда', () {
      expect(
        memberFilterUsefulness(
          base: mixed,
          hasServerName: true,
          isSpace: false,
        ).company,
        isFalse,
      );
    });
  });

  // AC:RL-member-filter-useful-checkboxes/1
  group('memberFilterServerLabel', () {
    test('экран на самой компании → её имя', () {
      expect(
        memberFilterServerLabel(
          serverName: 'liza.cyber-agro.ru',
          ownCompanyName: 'Кибер-Агро',
          companyNamesOnServer: const ['Кибер-Агро', 'Другое'],
        ),
        'Кибер-Агро',
      );
    });

    test('ровно одна компания на домене → её имя', () {
      expect(
        memberFilterServerLabel(
          serverName: 'liza.cyber-agro.ru',
          companyNamesOnServer: const ['Кибер-Агро'],
        ),
        'Кибер-Агро',
      );
    });

    test('несколько корней одного домена → домен, не чужое имя', () {
      expect(
        memberFilterServerLabel(
          serverName: 'user.liza.ru',
          companyNamesOnServer: const ['Личное А', 'Личное Б'],
        ),
        'user.liza.ru',
      );
    });

    test('компаний нет (обычный чат) → домен', () {
      expect(
        memberFilterServerLabel(
          serverName: 'synapse.liza.laba.prodamus.tech',
          companyNamesOnServer: const [],
        ),
        'synapse.liza.laba.prodamus.tech',
      );
    });
  });

  // AC:RL-member-filter-useful-checkboxes/1
  testWidgets('подпись «На сервере {server}» в ru и en', (tester) async {
    await _pump(tester, showServer: true, showCompany: true);
    expect(find.text('На сервере Агро'), findsOneWidget);
    expect(find.text('В компании'), findsOneWidget);

    await _pump(tester, locale: 'en', showServer: true, showCompany: true);
    expect(find.text('On server Агро'), findsOneWidget);
  });

  // AC:RL-member-filter-useful-checkboxes/7
  testWidgets('рисуются только полезные чекбоксы', (tester) async {
    await _pump(tester, showServer: true, showCompany: false);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.text('На сервере Агро'), findsOneWidget);
    expect(find.text('В компании'), findsNothing);

    await _pump(tester, showServer: false, showCompany: true);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.text('В компании'), findsOneWidget);

    await _pump(tester, showServer: true, showCompany: true);
    expect(find.byType(Checkbox), findsNWidgets(2));
  });

  // AC:RL-member-filter-useful-checkboxes/3
  group('оба бесполезны → плашка вместо чекбоксов', () {
    testWidgets('пространство', (tester) async {
      await _pump(tester, showServer: false, showCompany: false);
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.text('Все пользователи — с сервера Агро и из компании'),
        findsOneWidget,
      );
    });

    testWidgets('обычный чат — без «из компании»', (tester) async {
      await _pump(
        tester,
        isSpace: false,
        serverLabel: 'synapse.liza.laba.prodamus.tech',
        showServer: false,
        showCompany: false,
      );
      expect(
        find.text(
          'Все пользователи — с сервера synapse.liza.laba.prodamus.tech',
        ),
        findsOneWidget,
      );
    });

    testWidgets('пространство без домена', (tester) async {
      await _pump(
        tester,
        hasServerName: false,
        showServer: false,
        showCompany: false,
      );
      expect(find.text('Все пользователи — из компании'), findsOneWidget);
    });

    testWidgets('обычный чат без домена — ничего', (tester) async {
      await _pump(
        tester,
        isSpace: false,
        hasServerName: false,
        showServer: false,
        showCompany: false,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Text), findsNothing);
    });
  });

  // AC:RL-member-filter-useful-checkboxes/3
  testWidgets('ru: плашка и подписи без английских строк', (tester) async {
    await _pump(tester, showServer: false, showCompany: false);
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .join(' ')
        .replaceAll('Агро', '');
    expect(RegExp('[A-Za-z]').hasMatch(texts), isFalse, reason: texts);
  });
}
