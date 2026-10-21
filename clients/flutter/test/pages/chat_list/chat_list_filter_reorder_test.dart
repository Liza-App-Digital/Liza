// ledger:RL-chat-list-filter-reorder
//
// Порядок вкладок списка чатов меняется зажатием (замечание Надежды 20.10
// «Если можно будет поменять порядок по зажатию — будет очень удобно»).
// Чистые resolveFilterOrder/encodeFilterOrder + РЕАЛЬНЫЙ ChatListFilterRow с
// настоящим жестом зажатия и SharedPreferences (mock-хранилище плагина).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/chat_list_filter_row.dart';

typedef _F = ActiveFilter;

const _userA = '@anna:example.invalid';
const _userB = '@boris:example.invalid';

const _defaultLabels = [
  'Все',
  'Агенты и боты',
  'Люди',
  'Компании',
  'Группы',
  'Каналы',
  'Новые',
];

void main() {
  // AC:RL-chat-list-filter-reorder/1
  group('AC-1: resolveFilterOrder', () {
    final cases = <String, (List<String>?, List<ActiveFilter>)>{
      'нет сохранённого (null)': (null, chatListFilterOrder),
      'пустой список': (const [], chatListFilterOrder),
      'сохранённый порядок': (
        const ['people', 'agents', 'channels', 'companies', 'groups', 'unread'],
        const [
          _F.allChats,
          _F.people,
          _F.agents,
          _F.channels,
          _F.spaces,
          _F.groups,
          _F.unread,
        ],
      ),
      'мусор и неизвестные id отброшены': (
        const ['zzz', 'people', '', 'Личные', 'agents'],
        const [
          _F.allChats,
          _F.people,
          _F.agents,
          _F.spaces,
          _F.groups,
          _F.channels,
          _F.unread,
        ],
      ),
      'повторы отброшены': (
        const ['groups', 'groups', 'people', 'groups'],
        const [
          _F.allChats,
          _F.groups,
          _F.people,
          _F.agents,
          _F.spaces,
          _F.channels,
          _F.unread,
        ],
      ),
      'недостающие (новые в версии) дописаны в конец по умолчанию': (
        const ['channels'],
        const [
          _F.allChats,
          _F.channels,
          _F.agents,
          _F.people,
          _F.spaces,
          _F.groups,
          _F.unread,
        ],
      ),
      '«Все» в хранилище не первой — всё равно первая': (
        const ['people', 'all', 'agents'],
        const [
          _F.allChats,
          _F.people,
          _F.agents,
          _F.spaces,
          _F.groups,
          _F.channels,
          _F.unread,
        ],
      ),
    };
    for (final MapEntry(key: name, value: (stored, expected))
        in cases.entries) {
      test(name, () {
        final order = resolveFilterOrder(stored);
        expect(order, expected);
        expect(order.first, _F.allChats);
        expect(order.toSet(), ActiveFilter.values.toSet());
        expect(
          order.length,
          ActiveFilter.values.length,
          reason: 'без повторов',
        );
      });
    }

    test('encodeFilterOrder: без «Все», обратим через resolveFilterOrder', () {
      final order = resolveFilterOrder(const ['unread', 'people']);
      final ids = encodeFilterOrder(order);
      expect(ids, isNot(contains('all')));
      expect(resolveFilterOrder(ids), order);
    });

    test('ключ хранилища свой у каждого аккаунта', () {
      expect(filterOrderPrefsKey(_userA), isNot(filterOrderPrefsKey(_userB)));
    });
  });

  group('ряд чипов', () {
    late SharedPreferences prefs;
    late List<ActiveFilter> selected;

    Future<void> pumpRow(
      WidgetTester tester, {
      String? userId = _userA,
      ActiveFilter active = _F.allChats,
      double width = 1400,
    }) async {
      // По умолчанию все семь чипов на экране: ленивый ряд не строит невидимые.
      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Scaffold(
            body: ChatListFilterRow(
              activeFilter: active,
              onSelected: selected.add,
              store: prefs,
              userId: userId,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<String> labelsByX(WidgetTester tester) {
      final chips = tester.widgetList<FilterChip>(find.byType(FilterChip));
      final entries = [
        for (final chip in chips)
          (
            (chip.label as Text).data!,
            tester.getTopLeft(find.byWidget(chip)).dx,
          ),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final e in entries) e.$1];
    }

    Future<void> longPressDrag(
      WidgetTester tester,
      String from,
      Offset target,
    ) async {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(from)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
      final start = tester.getCenter(find.text(from));
      const steps = 10;
      for (var i = 1; i <= steps; i++) {
        await gesture.moveTo(Offset.lerp(start, target, i / steps)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
    }

    setUp(() async {
      selected = [];
    });

    Future<void> loadRu(WidgetTester tester) =>
        tester.runAsync(() => L10n.delegate.load(const Locale('ru')));

    // AC:RL-chat-list-filter-reorder/2
    testWidgets(
      'AC-2: без сохранённого — порядок по умолчанию; с сохранённым — '
      'он, «Все» первая',
      (tester) async {
        await loadRu(tester);
        SharedPreferences.setMockInitialValues({});
        prefs = await SharedPreferences.getInstance();
        await pumpRow(tester);
        expect(labelsByX(tester), _defaultLabels);

        SharedPreferences.setMockInitialValues({
          filterOrderPrefsKey(_userA): ['unread', 'people', 'agents'],
        });
        prefs = await SharedPreferences.getInstance();
        await pumpRow(tester, userId: _userB);
        await pumpRow(tester);
        expect(labelsByX(tester), [
          'Все',
          'Новые',
          'Люди',
          'Агенты и боты',
          'Компании',
          'Группы',
          'Каналы',
        ]);
      },
    );

    // AC:RL-chat-list-filter-reorder/3
    testWidgets('AC-3: обычный тап выбирает вкладку и не двигает порядок', (
      tester,
    ) async {
      await loadRu(tester);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await pumpRow(tester);

      for (final label in ['Люди', 'Все', 'Каналы']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(selected, [_F.people, _F.allChats, _F.channels]);
      expect(labelsByX(tester), _defaultLabels);
      expect(prefs.getStringList(filterOrderPrefsKey(_userA)), isNull);
    });

    // AC:RL-chat-list-filter-reorder/4
    testWidgets('AC-4: зажатие + перетаскивание переставляет вкладку и '
        'сохраняет порядок этого аккаунта', (tester) async {
      await loadRu(tester);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await pumpRow(tester);

      // «Люди» — на место «Агентов и ботов» (левее их центра).
      await longPressDrag(
        tester,
        'Люди',
        tester.getTopLeft(find.text('Агенты и боты')) + const Offset(-4, 8),
      );

      expect(labelsByX(tester), [
        'Все',
        'Люди',
        'Агенты и боты',
        'Компании',
        'Группы',
        'Каналы',
        'Новые',
      ]);
      expect(prefs.getStringList(filterOrderPrefsKey(_userA)), [
        'people',
        'agents',
        'companies',
        'groups',
        'channels',
        'unread',
      ]);
      expect(selected, isEmpty, reason: 'перетаскивание — не выбор вкладки');

      // Вправо: «Агенты и боты» — за «Группы» (onReorder отдаёт индекс «после»).
      await longPressDrag(
        tester,
        'Агенты и боты',
        tester.getCenter(find.text('Группы')),
      );
      expect(labelsByX(tester), [
        'Все',
        'Люди',
        'Компании',
        'Группы',
        'Агенты и боты',
        'Каналы',
        'Новые',
      ]);
      expect(prefs.getStringList(filterOrderPrefsKey(_userA)), [
        'people',
        'companies',
        'groups',
        'agents',
        'channels',
        'unread',
      ]);

      // Перезапуск: новый виджет читает сохранённое.
      await tester.pumpWidget(const SizedBox());
      await pumpRow(tester);
      expect(labelsByX(tester).take(5), [
        'Все',
        'Люди',
        'Компании',
        'Группы',
        'Агенты и боты',
      ]);

      // Другой аккаунт — свой порядок (по умолчанию).
      await pumpRow(tester, userId: _userB);
      expect(labelsByX(tester), _defaultLabels);
      expect(prefs.getStringList(filterOrderPrefsKey(_userB)), isNull);
    });

    // AC:RL-chat-list-filter-reorder/5
    testWidgets('AC-5: «Все» не перетаскивается, и ничто не встаёт перед ней', (
      tester,
    ) async {
      await loadRu(tester);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await pumpRow(tester);

      expect(
        find.ancestor(
          of: find.text('Все'),
          matching: find.byType(ReorderableDelayedDragStartListener),
        ),
        findsNothing,
      );
      await longPressDrag(tester, 'Все', tester.getCenter(find.text('Группы')));
      expect(labelsByX(tester), _defaultLabels);

      // «Каналы» тащим к самому левому краю — дальше «Все» не встают.
      await longPressDrag(
        tester,
        'Каналы',
        tester.getTopLeft(find.text('Все')) + const Offset(-10, 8),
      );
      final labels = labelsByX(tester);
      expect(labels.first, 'Все');
      expect(labels[1], 'Каналы');
    });

    // AC:RL-chat-list-filter-reorder/6
    testWidgets('AC-6: узкий телефон (360 px) — без переполнения, «Все» на '
        'месте, хвост ряда доступен прокруткой', (tester) async {
      await loadRu(tester);
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      await pumpRow(tester, width: 360);

      expect(tester.takeException(), isNull);
      expect(find.text('Все'), findsOneWidget);
      // Свайп пальцем — серией мелких сдвигов, как живой жест.
      final swipe = await tester.startGesture(
        tester.getCenter(find.text('Агенты и боты')),
      );
      for (var i = 0; i < 40; i++) {
        await swipe.moveBy(const Offset(-20, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await swipe.up();
      await tester.pumpAndSettle();
      expect(find.text('Все'), findsOneWidget, reason: '«Все» не уезжает');
      expect(
        prefs.getStringList(filterOrderPrefsKey(_userA)),
        isNull,
        reason: 'свайп дольше задержки зажатия — прокрутка, не перестановка',
      );
      await tester.tap(find.text('Новые'));
      await tester.pumpAndSettle();
      expect(selected, [_F.unread]);
      expect(tester.takeException(), isNull);
    });
  });
}
