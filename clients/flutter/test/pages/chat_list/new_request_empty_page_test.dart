// ignore_for_file: depend_on_referenced_packages
// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/2 AC:RL-empty-panel-new-request/3
// AC:RL-empty-panel-new-request/4 AC:RL-empty-panel-new-request/5
// AC:RL-empty-panel-new-request/6 AC:RL-empty-panel-new-request/7
// AC:RL-empty-panel-new-request/8 AC:RL-empty-panel-new-request/10
// AC:RL-empty-panel-new-request/11 AC:RL-empty-panel-new-request/12
// AC:RL-empty-panel-new-request/13 AC:RL-empty-panel-new-request/14
// AC:RL-empty-panel-new-request/15 AC:RL-empty-panel-new-request/16
// guard.render:real-widget
//
// Пустая правая панель на компьютере (задача 14): РЕАЛЬНЫЙ NewRequestEmptyPage
// в ru-локали (ловит и дыру intl_ru). Отправка идёт по настоящей воронке
// sendNewLizaRequest → createLizaRequestRoom → ensureDirectChat; клиент считает
// startDirectChat. С 22.10 (видео Надежды) — без барьер-диалога и без ожидания
// Лизы: чат открывается сразу, вопрос в нём первым сообщением.
//
// Red-proof:
//   RP-1 (AC-3): кнопка без проверки `trim().isEmpty` → на «   » активна, красный.
//   RP-2 (AC-5): убрать проверку `_sending` в _send → второй Enter создаёт
//     второй запрос — `calls` красный.
//   RP-3 (AC-4): `FocusNode()` без onKeyEvent → Enter не создаёт комнату.
//   RP-4 (AC-8): показывать поле при read-only → `update_read_only_bar` не найден.
//   RP-5 (AC-6): вернуть ожидание join Лизы → комната без Лизы, переход и PUT
//     не наступают — красный; вернуть showFutureLoadingDialog → AlertDialog найден.
//   RP-6 (AC-6): не ставить `first_message` → маркер без флага, красный.
//   RP-7 (AC-13): убрать лимит кругов (`_loopsLeft--`) → кадры планируются
//     бесконечно, красный.
//   RP-8 (AC-14): плашка без проверки `_sending` → плашка + Enter = 2 запроса.
//   RP-9 (AC-12): `active` без учёта текста → подсказка меняется под набором.
//
// С 23.10 (видео Надежды): бегущие примеры в поле, три плашки, морф перед
// переходом. Сам кроссфейд маршрута — new_request_transition_test.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/new_request_empty_page.dart';
import 'package:liza/utils/new_request_transition.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/matrix.dart';

void main() {
  // Базу открываем вне fake-async testWidgets: реальный I/O sqflite там виснет.
  late DatabaseApi database;
  late SharedPreferences store;
  setUpAll(() async {
    database = await MatrixSdkDatabase.init(
      'new-request-panel-test',
      database: await databaseFactoryFfi.openDatabase(':memory:'),
      sqfliteFactory: databaseFactoryFfi,
    );
    SharedPreferences.setMockInitialValues({});
    store = await SharedPreferences.getInstance();
  });

  tearDown(() {
    UpdatePolicyController.current.value = UpdatePolicy.none;
    NewRequestTransition.reset();
  });

  Future<_PanelClient> pumpPanel(
    WidgetTester tester, {
    String? displayName,
    bool disableAnimations = false,
  }) async {
    final client = _PanelClient(database, displayName);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: disableAnimations),
            child: Provider<MatrixState>.value(
              value: _TestMatrix(client, store),
              child: const NewRequestEmptyPage(),
            ),
          ),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (_, state) => Text('room ${state.pathParameters['roomid']}'),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        routerConfig: router,
      ),
    );
    // Deferred-локализация ru и профиль приходят future'ами — даём кадры.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    return client;
  }

  IconButton sendButton(WidgetTester tester) =>
      tester.widget<IconButton>(find.byKey(const Key('new_request_send')));

  String greeting(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const Key('new_request_greeting'))).data!;

  String hint(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const Key('new_request_typewriter')))
      .data!;

  double hintOpacity(WidgetTester tester) => tester
      .widget<Opacity>(
        find
            .ancestor(
              of: find.byKey(const Key('new_request_typewriter')),
              matching: find.byType(Opacity),
            )
            .first,
      )
      .opacity;

  /// Высота блока, сворачиваемого морфом (ClipRect вокруг AnimatedAlign).
  double collapsedHeight(WidgetTester tester, Key key) => tester
      .getSize(
        find
            .ancestor(of: find.byKey(key), matching: find.byType(ClipRect))
            .first,
      )
      .height;

  const ruExamples = [
    'Сгенерируй 5 идей постов для блога психолога',
    'Напиши поздравление коллеге с днём рождения',
    'Составь план поездки в Казань на выходные',
    'Объясни простыми словами, что такое нейросеть',
    'Напиши вежливый ответ на жалобу клиента',
  ];
  const ruPresets = [
    'Найди 3 рецепта лёгкого ужина',
    'Подбери топ-3 ноутбука для работы',
    'Придумай шутку про понедельник',
  ];

  /// Середина паузы `i`-го примера, отсчёт от старта первого.
  Duration midHold(int i) {
    var t = Duration.zero;
    for (var k = 0; k < i; k++) {
      t += NewRequestTypewriter.cycleOf(ruExamples[k]);
    }
    return t +
        NewRequestTypewriter.typeStep * ruExamples[i].length +
        NewRequestTypewriter.hold ~/ 2;
  }

  /// Подвести часы к моменту `at` от старта анимации (старт — кадр после
  /// pumpPanel, поэтому точное время не важно: точки берём в середине пауз).
  Future<void> pumpTo(WidgetTester tester, Duration at, Duration now) async {
    var left = at - now;
    while (left > Duration.zero) {
      // Шаг — кадр: каждый следующий пример стартует со следующего кадра.
      final step = left > const Duration(milliseconds: 20)
          ? const Duration(milliseconds: 20)
          : left;
      await tester.pump(step);
      left -= step;
    }
  }

  group('AC-2: обращение по имени', () {
    test('первое слово; email, пусто, пробелы, null — без имени', () {
      expect(greetingFirstName('Иван Петров'), 'Иван');
      expect(greetingFirstName('  Надежда  Розенталь '), 'Надежда');
      expect(greetingFirstName('Иван'), 'Иван');
      expect(greetingFirstName('ivan@mail.ru'), isNull);
      expect(greetingFirstName('@ivan:liza.ru'), isNull);
      expect(greetingFirstName(''), isNull);
      expect(greetingFirstName('   '), isNull);
      expect(greetingFirstName(null), isNull);
    });

    testWidgets('ru: «Какую задачу решим, Надежда?» и без имени', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        displayName: 'Надежда Розенталь',
        disableAnimations: true,
      );
      expect(greeting(tester), 'Какую задачу решим, Надежда?');
      expect(find.text('Напишите, что нужно сделать.'), findsOneWidget);
      // Без анимаций подсказка — первый пример целиком.
      expect(hint(tester), ruExamples.first);
    });

    testWidgets('ru: имени нет (не залогинен / email)', (tester) async {
      await pumpPanel(tester, displayName: 'nadya@prodamus.ru');
      expect(greeting(tester), 'Какую задачу решим?');
    });
  });

  testWidgets('AC-3: кнопка неактивна на пустом и пробелах', (tester) async {
    await pumpPanel(tester, displayName: 'Иван');
    expect(sendButton(tester).onPressed, isNull);
    for (final blank in ['   ', '\n', ' \n ']) {
      await tester.enterText(find.byType(TextField), blank);
      await tester.pump();
      expect(sendButton(tester).onPressed, isNull, reason: '«$blank»');
    }
    await tester.enterText(find.byType(TextField), 'план на неделю');
    await tester.pump();
    expect(sendButton(tester).onPressed, isNotNull);
  });

  testWidgets(
    'AC-4/AC-5/AC-6: Shift+Enter не шлёт; два Enter → один «Новый запрос» '
    'без диалога и без ожидания Лизы: вопрос отправлен один раз, чат открыт, '
    'поле очищено',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      final created = client.hold();
      await tester.enterText(find.byType(TextField), '  план на неделю ');
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(client.calls, 0);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      // Пока сервер создаёт комнату — спиннер на кнопке, барьер-диалога нет.
      expect(find.byKey(const Key('new_request_sending')), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(sendButton(tester).onPressed, isNull);

      created.complete();
      await tester.pump();
      await tester.pump();
      expect(client.calls, 1);
      expect(client.marker, {
        'placeholder': 'Новый запрос',
        'first_message': true,
      });
      // Лиза ещё не вступила — вопрос всё равно ушёл и чат открыт.
      expect(client.room?.sent, ['план на неделю']);
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(store.getString('draft_$_requestRoomId'), isNull);
    },
  );

  testWidgets(
    'AC-7: комната ещё не пришла в sync — вопрос в черновике чата, чат открыт',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      client.syncRoom = false;
      await tester.enterText(find.byType(TextField), 'план на неделю');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(client.calls, 1);
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(store.getString('draft_$_requestRoomId'), 'план на неделю');
      await store.remove('draft_$_requestRoomId');
    },
  );

  testWidgets(
    'AC-10: чат не создан — сообщение об ошибке, текст в поле, кнопка снова активна',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      client.fail = true;
      await tester.enterText(find.byType(TextField), 'план на неделю');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Ой, что-то пошло не так…'), findsOneWidget);
      expect(find.text('room $_requestRoomId'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'план на неделю',
      );
      expect(sendButton(tester).onPressed, isNotNull);
    },
  );

  group('AC-11/12/13: бегущие примеры в поле', () {
    testWidgets(
      '∀ 5 примеров по порядку, текст растёт и убывает, круг замкнут',
      (tester) async {
        await pumpPanel(tester, displayName: 'Иван');
        // pumpPanel уже прокрутил 300 мс.
        var now = const Duration(milliseconds: 300);
        for (var i = 0; i < ruExamples.length; i++) {
          final at = midHold(i);
          await pumpTo(tester, at, now);
          now = at;
          expect(hint(tester), ruExamples[i], reason: 'пример $i');
          expect(hintOpacity(tester), 1);
        }
        // Второй круг начинается снова с первого примера.
        final second =
            midHold(ruExamples.length - 1) +
            NewRequestTypewriter.cycleOf(ruExamples.last) -
            NewRequestTypewriter.typeStep * ruExamples.last.length -
            NewRequestTypewriter.hold ~/ 2 +
            midHold(0);
        await pumpTo(tester, second, now);
        expect(hint(tester), ruExamples.first);

        // Печать: длина не убывает до полной; стирание: не растёт до нуля.
        final third = second + NewRequestTypewriter.hold;
        await pumpTo(tester, third, second);
        final lengths = <int>[];
        for (var k = 0; k < 120; k++) {
          await tester.pump(const Duration(milliseconds: 20));
          lengths.add(hint(tester).length);
        }
        final erased = lengths.indexOf(0);
        expect(erased, greaterThan(0), reason: 'стирание дошло до нуля');
        for (var k = 1; k <= erased; k++) {
          expect(lengths[k], lessThanOrEqualTo(lengths[k - 1]));
        }
        final restart = lengths.indexWhere((l) => l > 0, erased);
        expect(restart, greaterThan(erased), reason: 'следующий пример начат');
        for (var k = restart + 1; k < lengths.length; k++) {
          expect(lengths[k], greaterThanOrEqualTo(lengths[k - 1]));
        }
      },
    );

    testWidgets('стоит под набором; при пустом поле снова идёт', (
      tester,
    ) async {
      await pumpPanel(tester, displayName: 'Иван');
      await tester.enterText(find.byType(TextField), 'мой вопрос');
      await tester.pump();
      expect(hintOpacity(tester), 0);
      final frozen = hint(tester);
      await tester.pump(const Duration(seconds: 3));
      expect(hint(tester), frozen);
      expect(tester.binding.hasScheduledFrame, isFalse);

      await tester.enterText(find.byType(TextField), '');
      await tester.pump();
      expect(hintOpacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 500));
      expect(hint(tester), isNot(frozen));
    });

    testWidgets('disableAnimations — первый пример целиком, без кадров', (
      tester,
    ) async {
      await pumpPanel(tester, displayName: 'Иван', disableAnimations: true);
      await tester.pump(const Duration(seconds: 5));
      expect(hint(tester), ruExamples.first);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });

    testWidgets('после 2 кругов встаёт на первом примере', (tester) async {
      await pumpPanel(tester, displayName: 'Иван');
      final loop = ruExamples.fold(
        Duration.zero,
        (t, e) => t + NewRequestTypewriter.cycleOf(e),
      );
      await pumpTo(
        tester,
        loop * NewRequestTypewriter.loops + const Duration(seconds: 1),
        const Duration(milliseconds: 300),
      );
      expect(hint(tester), ruExamples.first);
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  });

  group('AC-14: плашки-пресеты', () {
    for (var i = 0; i < 3; i++) {
      testWidgets('тап по плашке $i — запрос с её текстом, чат открыт', (
        tester,
      ) async {
        final client = await pumpPanel(tester, displayName: 'Иван');
        expect(
          tester
              .widget<ActionChip>(find.byKey(Key('new_request_preset_$i')))
              .label,
          isA<Text>().having((t) => t.data, 'data', ruPresets[i]),
        );
        await tester.tap(find.byKey(Key('new_request_preset_$i')));
        for (var k = 0; k < 5; k++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(client.calls, 1);
        expect(client.marker?['first_message'], true);
        expect(client.room?.sent, [ruPresets[i]]);
        expect(find.text('room $_requestRoomId'), findsOneWidget);
      });
    }

    testWidgets('плашка + Enter → один запрос; плашки гаснут на отправке', (
      tester,
    ) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      final created = client.hold();
      await tester.enterText(find.byType(TextField), 'свой вопрос');
      await tester.pump();
      await tester.tap(find.byKey(const Key('new_request_preset_0')));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(
        tester
            .widget<ActionChip>(find.byKey(const Key('new_request_preset_1')))
            .onPressed,
        isNull,
      );
      created.complete();
      for (var k = 0; k < 5; k++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(client.calls, 1);
      expect(client.room?.sent, [ruPresets[0]]);
      // Набранное до тапа по плашке не стирается.
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'свой вопрос',
      );
    });
  });

  testWidgets(
    'AC-15: отправка — шапка и плашки свёрнуты, вопрос пузырём, диалога нет',
    (tester) async {
      final client = await pumpPanel(tester, displayName: 'Иван');
      final created = client.hold();
      const header = Key('new_request_header');
      const bubble = Key('new_request_bubble');
      expect(collapsedHeight(tester, header), greaterThan(0));
      expect(collapsedHeight(tester, bubble), 0);

      await tester.enterText(find.byType(TextField), 'придумай шутку');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      for (var k = 0; k < 5; k++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.byType(AlertDialog), findsNothing);
      }
      expect(collapsedHeight(tester, header), 0);
      expect(collapsedHeight(tester, const Key('new_request_preset_0')), 0);
      expect(collapsedHeight(tester, bubble), greaterThan(0));
      expect(
        find.descendant(
          of: find.byKey(bubble),
          matching: find.text('придумай шутку'),
        ),
        findsOneWidget,
      );
      created.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('room $_requestRoomId'), findsOneWidget);
      expect(
        NewRequestTransition.durationFor(_requestRoomId),
        NewRequestTransition.fade,
      );
    },
  );

  testWidgets('AC-16: ошибка — экран возвращается, текст плашки в поле', (
    tester,
  ) async {
    final client = await pumpPanel(tester, displayName: 'Иван');
    client.fail = true;
    await tester.tap(find.byKey(const Key('new_request_preset_2')));
    for (var k = 0; k < 8; k++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Ой, что-то пошло не так…'), findsOneWidget);
    expect(collapsedHeight(tester, const Key('new_request_bubble')), 0);
    expect(
      collapsedHeight(tester, const Key('new_request_header')),
      greaterThan(0),
    );
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      ruPresets[2],
    );
    expect(NewRequestTransition.durationFor(_requestRoomId), Duration.zero);
  });

  testWidgets('AC-15: чат открыт поверх панели — свёрнутое не принимает тапов; '
      'возврат на панель — морф сброшен, примеры идут заново', (tester) async {
    final client = _PanelClient(database, 'Иван');
    // Как в приложении: чат — дочерний маршрут, панель живёт под ним.
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Provider<MatrixState>.value(
            value: _TestMatrix(client, store),
            child: const NewRequestEmptyPage(),
          ),
          routes: [
            GoRoute(
              path: 'rooms/:roomid',
              builder: (_, state) => ColoredBox(
                color: Colors.white,
                child: Text('room ${state.pathParameters['roomid']}'),
              ),
            ),
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        routerConfig: router,
      ),
    );
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final created = client.hold();
    await tester.tap(find.byKey(const Key('new_request_preset_0')));
    await tester.pump();
    created.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('room $_requestRoomId'), findsOneWidget);
    // Панель ещё в дереве под чатом (offstage): плашки выключены.
    final chip = find.byKey(
      const Key('new_request_preset_1'),
      skipOffstage: false,
    );
    expect(tester.widget<ActionChip>(chip).onPressed, isNull);
    expect(client.calls, 1);

    router.go('/');
    for (var k = 0; k < 5; k++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(collapsedHeight(tester, const Key('new_request_bubble')), 0);
    expect(
      collapsedHeight(tester, const Key('new_request_header')),
      greaterThan(0),
    );
    expect(
      tester
          .widget<ActionChip>(find.byKey(const Key('new_request_preset_1')))
          .onPressed,
      isNotNull,
    );
    expect(tester.binding.hasScheduledFrame, isTrue, reason: 'примеры идут');
  });

  testWidgets('AC-16: ошибка плашки не затирает набранный текст', (
    tester,
  ) async {
    final client = await pumpPanel(tester, displayName: 'Иван');
    client.fail = true;
    await tester.enterText(find.byType(TextField), 'мой черновик');
    await tester.pump();
    await tester.tap(find.byKey(const Key('new_request_preset_1')));
    for (var k = 0; k < 8; k++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Ой, что-то пошло не так…'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'мой черновик',
    );
  });

  testWidgets('AC-8: режим чтения — плашка обновления вместо поля', (
    tester,
  ) async {
    UpdatePolicyController.current.value = const UpdatePolicy(
      stage: UpdateStage.hard,
    );
    final client = await pumpPanel(tester, displayName: 'Иван');
    expect(find.byKey(const Key('update_read_only_bar')), findsOneWidget);
    expect(find.byKey(const Key('new_request_field')), findsNothing);
    expect(find.byKey(const Key('new_request_preset_0')), findsNothing);
    expect(client.calls, 0);
  });
}

class _PanelClient extends Client {
  _PanelClient(DatabaseApi database, this.displayName)
    : super('new-request-panel-test', database: database);

  final String? displayName;
  int calls = 0;
  Map<String, Object?>? marker;
  bool syncRoom = true;
  bool fail = false;
  Completer<void>? _hold;

  /// Задержать ответ сервера на создание комнаты до `complete()`.
  Completer<void> hold() => _hold = Completer<void>();

  @override
  String? get userID => '@ivan:liza.local';

  @override
  Future<Profile> fetchOwnProfile({
    bool getFromRooms = true,
    bool cache = true,
  }) async => Profile(userId: userID!, displayName: displayName);

  @override
  Future<String> startDirectChat(
    String mxid, {
    bool? enableEncryption,
    List<StateEvent>? initialState,
    bool waitForSync = true,
    Map<String, dynamic>? powerLevelContentOverride,
    CreateRoomPreset? preset = CreateRoomPreset.trustedPrivateChat,
    bool skipExistingChat = false,
  }) async {
    calls++;
    marker = initialState
        ?.firstWhere((s) => s.type == 'com.liza.assistant.request')
        .content;
    await _hold?.future;
    if (fail) throw Exception('M_LIMIT_EXCEEDED');
    // Как на проде сразу после createRoom: Лиза только приглашена, не вступила.
    final created = room = _RecordingRoom(this);
    if (syncRoom) rooms.add(created);
    return created.id;
  }

  _RecordingRoom? room;
}

const _requestRoomId = '!request:server';

class _RecordingRoom extends Room {
  _RecordingRoom(Client client)
    : super(id: _requestRoomId, client: client, membership: Membership.join);

  final sent = <String>[];

  @override
  Future<String?> sendTextEvent(
    String message, {
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    bool parseMarkdown = true,
    bool parseCommands = true,
    String msgtype = MessageTypes.Text,
    String? threadRootEventId,
    String? threadLastEventId,
    StringBuffer? commandStdout,
    bool addMentions = true,
    bool displayPendingEvent = true,
  }) async {
    sent.add(message);
    return r'$sent';
  }
}

/// `sendNewLizaRequest` берёт `Matrix.of(context).client` и `.store`; в тесте
/// смонтированного Matrix нет.
class _TestMatrix extends MatrixState {
  _TestMatrix(this.testClient, this.testStore);
  final Client testClient;
  final SharedPreferences testStore;

  @override
  Client get client => testClient;

  @override
  SharedPreferences get store => testStore;
}
