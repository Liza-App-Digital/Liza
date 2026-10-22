// ledger:RL-create-company-support-entry
// AC:RL-create-company-support-entry/23 AC:RL-create-company-support-entry/24
// guard.render:real-widget
//
// Замечания Надежды 2026-10-21: попап «Создать компанию» на телефоне уходил в
// прокрутку (обрыв на «- при увольнении сотрудника»), а «+» плашки стоял правее
// оси аватаров компаний. Отдельный файл: тест грузит настоящий Roboto вместо
// тестового шрифта (его квадратные глифы вдвое шире и дали бы ложное «не влезло»),
// а реестр шрифтов общий на процесс — соседним стражам он не нужен.
// Спека: docs/superpowers/specs/2026-10-21-create-company-popup-short-text-plus-align-design.md

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/create_company_list_tile.dart';
import 'package:liza/utils/support_chat.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

import '../../utils/test_client.dart';

const _roboto = 'packages/alchemist/assets/fonts/Roboto/Roboto';

/// Roboto — системный шрифт Android; им же подменяем SF для Cupertino
/// (на Linux-CI SF нет): ширина у них близкая, обе семьи с кириллицей.
Future<void> _loadRealFonts() async {
  for (final family in [
    'Roboto',
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
  ]) {
    final loader = FontLoader(family);
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('$_roboto-$weight.ttf'));
    }
    await loader.load();
  }
}

Widget _localized(Widget home) => Builder(
  builder: (context) => MaterialApp(
    theme: LizaThemes.buildTheme(context, Brightness.light),
    locale: const Locale('ru'),
    localizationsDelegates: const [
      L10n.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: L10n.supportedLocales,
    home: home,
  ),
);

void main() {
  setUpAll(() async {
    await _loadRealFonts();
    SharedPreferences.setMockInitialValues({});
    // Тема приложения читает цвет из настроек — как в main().
    await AppSettings.init(loadWebConfigFile: false);
  });

  testWidgets(
    'AC-23: попап целиком без прокрутки — Android 360×780 (1.0, 1.15), '
    '360×640, iPhone SE 375×667 — AC:RL-create-company-support-entry/23',
    (tester) async {
      const cases = [
        (TargetPlatform.android, Size(360, 780), 1.0),
        (TargetPlatform.android, Size(360, 780), 1.15),
        (TargetPlatform.android, Size(360, 640), 1.0),
        (TargetPlatform.iOS, Size(375, 667), 1.0),
      ];
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      try {
        for (final (platform, size, scale) in cases) {
          final reason =
              '${platform.name} ${size.width}×${size.height} ×$scale';
          debugDefaultTargetPlatformOverride = platform;
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          // Строка статуса и полоска жестов, как на скрине Надежды.
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 16);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          await tester.pumpWidget(
            _localized(
              Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => confirmCreateCompanyRequest(context),
                    child: const Text('OPEN'),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('OPEN'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: reason);
          final text = find.byKey(const ValueKey('create_company_intro_text'));
          expect(text, findsOneWidget, reason: reason);
          expect(
            tester.widget<Text>(text).data,
            isNot(startsWith('Привет')),
            reason: reason,
          );
          // Под попапом прокручиваемого нет, значит все Scrollable — диалога
          // (текст и, на Material, столбец кнопок): ни одному нечего крутить.
          final scrollables = find.byType(Scrollable);
          expect(scrollables, findsWidgets, reason: reason);
          for (final element in scrollables.evaluate()) {
            final position =
                (element as StatefulElement).state as ScrollableState;
            expect(
              position.position.maxScrollExtent,
              0,
              reason: '$reason: есть что прокручивать',
            );
          }
          for (final key in [
            'create_company_intro_request',
            'create_company_intro_details',
            'create_company_intro_cancel',
          ]) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            expect(rect.bottom, lessThanOrEqualTo(size.height), reason: reason);
          }
          await tester.tap(
            find.byKey(const ValueKey('create_company_intro_cancel')),
          );
          await tester.pumpAndSettle();
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  group('плашка рядом с компанией', () {
    late Client client;
    late SharedPreferences store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      client = await prepareTestClient(loggedIn: true);
      client.backgroundSync = false;
      store = await SharedPreferences.getInstance();
    });

    tearDown(() => client.dispose(closeDatabase: true));

    Room company() {
      final room = Room(id: '!company:example.invalid', client: client);
      for (final (type, content) in [
        (EventTypes.RoomCreate, <String, Object>{'type': 'm.space'}),
        (EventTypes.RoomName, <String, Object>{'name': 'Laba'}),
      ]) {
        room.setState(
          Event(
            eventId: '\$$type',
            senderId: '@creator:example.invalid',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
            type: type,
            content: content,
            room: room,
            stateKey: '',
          ),
        );
      }
      return room;
    }

    testWidgets(
      '«+» на оси аватара компании: тот же центр и левый край, заголовки '
      'с одной линии — AC:RL-create-company-support-entry/24',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 780);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _localized(
            Matrix(
              clients: [client],
              store: store,
              child: Scaffold(
                body: Column(
                  children: [
                    ChatListItem(company(), onTap: () {}),
                    const CreateCompanyListTile(),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final avatar = tester.getRect(
          find
              .descendant(
                of: find.byType(ChatListItem),
                matching: find.byType(Avatar),
              )
              .first,
        );
        final plus = tester.getRect(
          find.byKey(const ValueKey('create_company_row_plus')),
        );
        expect(
          plus.center.dx,
          moreOrLessEquals(avatar.center.dx, epsilon: 0.5),
        );
        expect(plus.left, moreOrLessEquals(avatar.left, epsilon: 0.5));
        expect(plus.size, avatar.size);
        expect(
          tester.getTopLeft(find.text('Создать компанию')).dx,
          moreOrLessEquals(
            tester.getTopLeft(find.text('Laba')).dx,
            epsilon: 0.5,
          ),
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(minutes: 1));
      },
    );
  });
}
