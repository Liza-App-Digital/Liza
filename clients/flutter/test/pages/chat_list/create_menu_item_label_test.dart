// ledger:RL-create-menu-order-agent-entry
// AC:RL-create-menu-order-agent-entry/11 AC:RL-create-menu-order-agent-entry/12
// AC:RL-create-menu-order-agent-entry/13 AC:RL-create-menu-order-agent-entry/14
// guard.render:real-widget
//
// Замечание Надежды 23.10: «В меню по + нужно визуально выделить пункт Новый
// запрос». Рендерим настоящий CreateMenuItemLabel внутри открытого PopupMenu
// для КАЖДОГО пункта меню и каждой темы — так же, как его зовёт ChatListHeader.
// Спека: docs/superpowers/specs/2026-10-23-create-menu-new-request-highlight-design.md

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/create_menu_item_label.dart';
import 'package:liza/pages/chat_list/create_menu_sections.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/hexagon_clipper.dart';

const _iconKey = ValueKey('create_menu_new_request_icon');

Future<void> _openMenu(WidgetTester tester, Brightness brightness) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: brightness,
        ),
      ),
      locale: const Locale('ru'),
      localizationsDelegates: const [
        L10n.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(
        body: PopupMenuButton<CreateMenuAction>(
          key: const ValueKey('menu'),
          itemBuilder: (_) => [
            for (final section in createMenuSections(isDeveloper: true))
              for (final action in section)
                PopupMenuItem(
                  value: action,
                  child: CreateMenuItemLabel(
                    key: ValueKey(action),
                    label: action.name,
                    highlighted: highlightedActions.contains(action),
                    developerMark: developerOnlyActions.contains(action),
                  ),
                ),
          ],
        ),
      ),
    ),
  );
  // L10n грузится асинхронно — до него дерево пустое.
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('menu')));
  await tester.pumpAndSettle();
}

Finder _in(CreateMenuAction a, Finder f) =>
    find.descendant(of: find.byKey(ValueKey(a)), matching: f);

void main() {
  test('AC-13: акцент — ровно у «Нового запроса»', () {
    expect(highlightedActions, {CreateMenuAction.newRequest});
  });

  for (final brightness in Brightness.values) {
    testWidgets('AC-11/12/13/14 ∀ пункт, тема=$brightness', (tester) async {
      await _openMenu(tester, brightness);
      final scheme = Theme.of(
        tester.element(find.byKey(const ValueKey(CreateMenuAction.group))),
      ).colorScheme;

      for (final action in CreateMenuAction.values) {
        final text = tester.widget<Text>(_in(action, find.text(action.name)));
        final icon = _in(action, find.byKey(_iconKey));
        final mark = _in(action, find.byType(DeveloperMark));
        if (action == CreateMenuAction.newRequest) {
          // AC-11: шестиугольник primary 24 с «+» onPrimary, без озвучки.
          expect(icon, findsOneWidget);
          expect(tester.getSize(icon), const Size.square(24));
          final box = tester.widget<DecoratedBox>(
            find.descendant(of: icon, matching: find.byType(DecoratedBox)),
          );
          final deco = box.decoration as ShapeDecoration;
          expect(deco.shape, isA<HexagonBorder>());
          expect(deco.color, scheme.primary);
          final plus = tester.widget<Icon>(
            find.descendant(of: icon, matching: find.byType(Icon)),
          );
          expect(plus.icon, Icons.add);
          expect(plus.color, scheme.onPrimary);
          expect(
            find.ancestor(of: icon, matching: find.byType(ExcludeSemantics)),
            findsWidgets,
          );
          // AC-12: подпись жирная.
          expect(text.style?.fontWeight, FontWeight.bold);
        } else {
          // AC-13: у остальных ни значка, ни жирного.
          expect(icon, findsNothing, reason: '$action');
          expect(text.style?.fontWeight, isNull, reason: '$action');
        }
        // AC-14: метка разработчика — только у МСР.
        expect(
          mark,
          action == CreateMenuAction.mcp ? findsOneWidget : findsNothing,
          reason: '$action',
        );
      }
      // Значок стоит слева от подписи.
      expect(
        tester
            .getCenter(_in(CreateMenuAction.newRequest, find.byKey(_iconKey)))
            .dx,
        lessThan(
          tester
              .getTopLeft(
                _in(CreateMenuAction.newRequest, find.text('newRequest')),
              )
              .dx,
        ),
      );
    });
  }
}
