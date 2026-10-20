// ledger:RL-member-filter-useful-checkboxes
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_members/company_member_entry.dart';
import 'package:liza/pages/chat_members/member_filter_checkboxes.dart';

MemberFilterFacts _m({bool server = true, bool company = true}) =>
    (belongsToServer: server, joinedCompany: company);

const _domain = 'nadezhda.liza.ru';
const _company = 'Компания Розенталь';

Future<void> _pump(
  WidgetTester tester, {
  String locale = 'ru',
  String serverName = _domain,
  String spaceName = _company,
  bool isSpace = true,
  bool isCompanyRoot = true,
  required bool showServer,
  required bool showCompany,
}) async {
  // Локали L10n — deferred-библиотеки: первую загрузку в процессе
  // pumpAndSettle не дожидается, и экран остаётся пустым.
  await tester.runAsync(() => L10n.delegate.load(Locale(locale)));
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(locale),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: MemberFilterCheckboxes(
          serverName: serverName,
          spaceName: spaceName,
          isSpace: isSpace,
          isCompanyRoot: isCompanyRoot,
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

Map<String, dynamic> _arb(String locale) =>
    jsonDecode(File('lib/l10n/intl_$locale.arb').readAsStringSync())
        as Map<String, dynamic>;

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

  // AC:RL-member-filter-useful-checkboxes/8
  group('«На сервере» — всегда домен, никогда имя компании', () {
    for (final locale in ['ru', 'en']) {
      final prefix = locale == 'ru' ? 'На сервере' : 'On server';

      testWidgets('$locale: корень компании', (tester) async {
        await _pump(
          tester,
          locale: locale,
          showServer: true,
          showCompany: true,
        );
        expect(find.text('$prefix $_domain'), findsOneWidget);
        expect(find.textContaining('$prefix $_company'), findsNothing);
      });

      testWidgets('$locale: подпространство', (tester) async {
        await _pump(
          tester,
          locale: locale,
          isCompanyRoot: false,
          spaceName: 'Отдел продаж',
          showServer: true,
          showCompany: true,
        );
        expect(find.text('$prefix $_domain'), findsOneWidget);
      });

      testWidgets('$locale: обычный чат', (tester) async {
        await _pump(
          tester,
          locale: locale,
          isSpace: false,
          isCompanyRoot: false,
          spaceName: '',
          showServer: true,
          showCompany: false,
        );
        expect(find.text('$prefix $_domain'), findsOneWidget);
      });
    }
  });

  // AC:RL-member-filter-useful-checkboxes/9
  group('сервер и компания различаются', () {
    testWidgets('корень компании: домен + «В компании {имя}»', (tester) async {
      await _pump(tester, showServer: true, showCompany: true);
      expect(find.text('На сервере $_domain'), findsOneWidget);
      expect(find.text('В компании $_company'), findsOneWidget);

      await _pump(tester, locale: 'en', showServer: true, showCompany: true);
      expect(find.text('In company $_company'), findsOneWidget);
    });

    testWidgets('подпространство: «В пространстве {имя}»', (tester) async {
      await _pump(
        tester,
        isCompanyRoot: false,
        spaceName: 'Отдел продаж',
        showServer: true,
        showCompany: true,
      );
      expect(find.text('В пространстве Отдел продаж'), findsOneWidget);
      expect(find.textContaining('В компании'), findsNothing);
    });

    testWidgets('обычный чат: «В компании» нет', (tester) async {
      await _pump(
        tester,
        isSpace: false,
        isCompanyRoot: false,
        spaceName: '',
        showServer: true,
        showCompany: false,
      );
      expect(find.textContaining('В компании'), findsNothing);
      expect(find.textContaining('В пространстве'), findsNothing);
    });
  });

  // AC:RL-member-filter-useful-checkboxes/7
  testWidgets('рисуются только полезные чекбоксы', (tester) async {
    await _pump(tester, showServer: true, showCompany: false);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.text('На сервере $_domain'), findsOneWidget);
    expect(find.textContaining('В компании'), findsNothing);

    await _pump(tester, showServer: false, showCompany: true);
    expect(find.byType(Checkbox), findsOneWidget);
    expect(find.text('В компании $_company'), findsOneWidget);

    await _pump(tester, showServer: true, showCompany: true);
    expect(find.byType(Checkbox), findsNWidgets(2));
  });

  // AC:RL-member-filter-useful-checkboxes/3
  // AC:RL-member-filter-useful-checkboxes/10
  group('оба бесполезны → плашка вместо чекбоксов', () {
    testWidgets('корень компании', (tester) async {
      await _pump(tester, showServer: false, showCompany: false);
      expect(find.byType(Checkbox), findsNothing);
      expect(
        find.text(
          'Все пользователи — с сервера $_domain и из компании $_company',
        ),
        findsOneWidget,
      );
    });

    testWidgets('подпространство', (tester) async {
      await _pump(
        tester,
        isCompanyRoot: false,
        spaceName: 'Отдел продаж',
        showServer: false,
        showCompany: false,
      );
      expect(
        find.text(
          'Все пользователи — с сервера $_domain и из пространства Отдел продаж',
        ),
        findsOneWidget,
      );
    });

    testWidgets('обычный чат — без «из компании»', (tester) async {
      await _pump(
        tester,
        isSpace: false,
        isCompanyRoot: false,
        spaceName: '',
        serverName: 'synapse.liza.laba.prodamus.tech',
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
        serverName: '',
        showServer: false,
        showCompany: false,
      );
      expect(
        find.text('Все пользователи — из компании $_company'),
        findsOneWidget,
      );

      await _pump(
        tester,
        serverName: '',
        isCompanyRoot: false,
        spaceName: 'Отдел продаж',
        showServer: false,
        showCompany: false,
      );
      expect(
        find.text('Все пользователи — из пространства Отдел продаж'),
        findsOneWidget,
      );
    });

    testWidgets('обычный чат без домена — ничего', (tester) async {
      await _pump(
        tester,
        isSpace: false,
        isCompanyRoot: false,
        serverName: '',
        spaceName: '',
        showServer: false,
        showCompany: false,
      );
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(Text), findsNothing);
    });

    testWidgets('en: домен и имя на месте', (tester) async {
      await _pump(tester, locale: 'en', showServer: false, showCompany: false);
      expect(
        find.text('All users are from server $_domain and company $_company'),
        findsOneWidget,
      );
    });
  });

  // AC:RL-member-filter-useful-checkboxes/3
  // AC:RL-member-filter-useful-checkboxes/10
  testWidgets('ru: плашка и подписи без латиницы, кроме домена', (
    tester,
  ) async {
    Future<void> expectNoLatin() async {
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .join(' ')
          .replaceAll(_domain, '');
      expect(RegExp('[A-Za-z]').hasMatch(texts), isFalse, reason: texts);
    }

    await _pump(tester, showServer: false, showCompany: false);
    await expectNoLatin();
    await _pump(tester, showServer: true, showCompany: true);
    await expectNoLatin();
    await _pump(
      tester,
      isCompanyRoot: false,
      spaceName: 'Отдел продаж',
      showServer: false,
      showCompany: false,
    );
    await expectNoLatin();
  });

  // AC:RL-member-filter-useful-checkboxes/11
  testWidgets('два чекбокса — столбиком, обе подписи целиком на 360 dp', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, showServer: true, showCompany: true);
    final server = find.text('На сервере $_domain');
    final company = find.text('В компании $_company');
    expect(
      tester.getTopLeft(company).dy,
      greaterThan(tester.getBottomLeft(server).dy - 1),
      reason: '«В компании» должна быть под «На сервере», а не рядом',
    );
    for (final label in [server, company]) {
      final paragraph = tester.renderObject<RenderParagraph>(label);
      expect(paragraph.didExceedMaxLines, isFalse);
      expect(tester.getRect(label).right, lessThanOrEqualTo(360));
    }
  });

  // AC:RL-member-filter-useful-checkboxes/12
  test('у каждого ключа фильтра с {…} в arb есть placeholders', () {
    const keys = [
      'memberFilterOnServer',
      'memberFilterInCompany',
      'memberFilterInSpace',
      'memberFiltersAllFromServerAndCompany',
      'memberFiltersAllFromServerAndSpace',
      'memberFiltersAllFromServer',
      'memberFiltersAllFromCompany',
      'memberFiltersAllFromSpace',
    ];
    for (final locale in ['ru', 'en']) {
      final arb = _arb(locale);
      for (final key in keys) {
        final value = arb[key] as String?;
        expect(value, isNotNull, reason: '$locale: нет $key');
        final params = RegExp(
          r'\{(\w+)\}',
        ).allMatches(value!).map((m) => m.group(1)!).toSet();
        final meta = arb['@$key'] as Map<String, dynamic>?;
        final placeholders =
            (meta?['placeholders'] as Map<String, dynamic>?)?.keys.toSet() ??
            const <String>{};
        expect(placeholders, params, reason: '$locale: @$key');
      }
    }
  });
}
