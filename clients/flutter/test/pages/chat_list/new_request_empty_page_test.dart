// ignore_for_file: depend_on_referenced_packages
// ledger:RL-empty-panel-new-request
// AC:RL-empty-panel-new-request/2 AC:RL-empty-panel-new-request/3
// AC:RL-empty-panel-new-request/4 AC:RL-empty-panel-new-request/5
// AC:RL-empty-panel-new-request/6 AC:RL-empty-panel-new-request/7
// AC:RL-empty-panel-new-request/8 AC:RL-empty-panel-new-request/10
// AC:RL-empty-panel-new-request/11 AC:RL-empty-panel-new-request/12
// AC:RL-empty-panel-new-request/13 AC:RL-empty-panel-new-request/14
// AC:RL-empty-panel-new-request/15 AC:RL-empty-panel-new-request/16
// AC:RL-empty-panel-new-request/19 AC:RL-empty-panel-new-request/20
// AC:RL-empty-panel-new-request/21 AC:RL-empty-panel-new-request/23
// AC:RL-empty-panel-new-request/24 AC:RL-empty-panel-new-request/25
// AC:RL-new-request-content-server/3
// ledger:RL-new-request-responsive
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
//   RP-10 (AC-19): подпись плашки `Text(preset)` без softWrap/maxLines → на
//     узкой панели обрезана, красный.
//
// С 23.10 (видео Надежды): бегущие примеры в поле, три плашки, морф перед
// переходом. Сам кроссфейд маршрута — new_request_transition_test.dart.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/l10n/l10n_en.dart';
import 'package:liza/pages/chat_list/new_request_empty_page.dart';
import 'package:liza/utils/new_request_texts.dart';
import 'package:liza/utils/new_request_transition.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/widgets/matrix.dart';

void main() {
  // Базу открываем вне fake-async testWidgets: реальный I/O sqflite там виснет.
  late DatabaseApi database;
  late SharedPreferences store;
  setUpAll(() async {
    final roots = <Directory>[
      if (Platform.environment['FLUTTER_ROOT'] case final root?)
        Directory(root),
      for (
        var root = File(Platform.resolvedExecutable).absolute.parent;
        root.path != root.parent.path;
        root = root.parent
      )
        root,
    ];
    final font = roots
        .map(
          (root) => File(
            '${root.path}/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          ),
        )
        .firstWhere((file) => file.existsSync());
    await (FontLoader('NewRequestResponsiveRoboto')..addFont(
          Future.value(ByteData.sublistView(await font.readAsBytes())),
        ))
        .load();
    // Deferred-библиотеки загружаем вне fakeAsync, иначе смена языка может
    // оставить MaterialApp на ожидании реального I/O.
    await lookupL10n(const Locale('ru'));
    await lookupL10n(const Locale('en'));
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
    NewRequestTexts.instance.current = null;
  });

  Future<_PanelClient> pumpPanel(
    WidgetTester tester, {
    String? displayName,
    bool disableAnimations = false,
    double textScale = 1.0,
    bool showBackButton = false,
    EdgeInsets? safeInsets,
    EdgeInsets? viewInsets,
    Locale locale = const Locale('ru'),
    String? fontFamily,
    double? panelWidth,
    Brightness brightness = Brightness.light,
    bool usePlatformTextScale = false,
    Key? repaintBoundaryKey,
  }) async {
    final client = _PanelClient(database, displayName);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              textScaler: usePlatformTextScale
                  ? MediaQuery.textScalerOf(context)
                  : TextScaler.linear(textScale),
              viewPadding: safeInsets,
              viewInsets: viewInsets,
              padding: safeInsets == null
                  ? null
                  : EdgeInsets.fromLTRB(
                      safeInsets.left,
                      safeInsets.top,
                      safeInsets.right,
                      (safeInsets.bottom - (viewInsets?.bottom ?? 0)).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
            ),
            child: Provider<MatrixState>.value(
              value: _TestMatrix(client, store),
              child: Align(
                child: SizedBox(
                  width: panelWidth,
                  child: repaintBoundaryKey == null
                      ? NewRequestEmptyPage(showBackButton: showBackButton)
                      : RepaintBoundary(
                          key: repaintBoundaryKey,
                          child: NewRequestEmptyPage(
                            showBackButton: showBackButton,
                          ),
                        ),
                ),
              ),
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
        locale: locale,
        theme: fontFamily == null && brightness == Brightness.light
            ? null
            : ThemeData(fontFamily: fontFamily, brightness: brightness),
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
    'Закажи стиральный порошок для всех типов белья',
    'Закупи продукты на неделю для семьи из 3 человек',
    'Организуй доставку воды на дом, предупреди консьержа',
    'У кота закончился сухой корм, закажи доставку',
    'Отправь цветы жене на работу',
    'Закажи пиццу на большую компанию',
  ];
  const ruPresets = [
    'Закажи суши на двоих',
    'Хочу горячий кофе! Привези поскорее',
    'Купи молоко, яйца и хлеб',
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

  // 27.10, Надежда: у Романа подписи плашек «не влезают, обрезаются». RawChip
  // держит подпись в одну строку; панель бывает уже порога колонок (mini App
  // сбоку). Тестовый шрифт — глиф 1em, самая длинная подпись ~490 px: узкие
  // ширины гарантированно требуют переноса, AC-21 сторожит широкую сторону.
  // 340/381/570 попадают в окно среза RawChip (текст влез в ширину плашки,
  // но не в ширину − поля) для плашек 0/2/1.
  group('AC-19/20/21: плашки на любой ширине и масштабе', () {
    RenderParagraph label(WidgetTester tester, int i) =>
        tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(Key('new_request_preset_$i')),
            matching: find.text(ruPresets[i]),
          ),
        );

    Future<void> pumpAt(WidgetTester tester, double width, double scale) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      addTearDown(tester.view.reset);
      await pumpPanel(tester, displayName: 'Иван', textScale: scale);
    }

    for (final width in [300.0, 340.0, 381.0, 500.0, 570.0, 900.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('ширина $width × масштаб $scale — подписи целиком', (
          tester,
        ) async {
          await pumpAt(tester, width, scale);
          expect(tester.takeException(), isNull);
          for (var i = 0; i < 3; i++) {
            final p = label(tester, i);
            expect(p.didExceedMaxLines, isFalse, reason: 'плашка $i');
            expect(p.debugHasOverflowShader, isFalse, reason: 'плашка $i');
            // Перенесённые строки не срезаны снизу высотой плашки.
            expect(
              p.getMinIntrinsicHeight(p.size.width),
              lessThanOrEqualTo(p.size.height + 0.5),
              reason: 'плашка $i',
            );
            final chip = tester.getRect(
              find.byKey(Key('new_request_preset_$i')),
            );
            expect(chip.left, greaterThanOrEqualTo(0), reason: 'плашка $i');
            expect(chip.right, lessThanOrEqualTo(width), reason: 'плашка $i');
          }
        });
      }
    }

    testWidgets('широкая панель — каждая подпись в одну строку, плашки равны', (
      tester,
    ) async {
      await pumpAt(tester, 900, 1.0);
      final heights = <double>{};
      for (var i = 0; i < 3; i++) {
        // Одна строка = подпись выложена на всю свою ширину без переноса.
        final p = label(tester, i);
        expect(
          p.size.width,
          greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5),
          reason: 'плашка $i',
        );
        heights.add(
          tester.getSize(find.byKey(Key('new_request_preset_$i'))).height,
        );
      }
      expect(heights, hasLength(1));
    });
  });

  group('responsive: реальный Roboto и серверные подписи', () {
    const screenshotPresets = [
      'Закажи суши на двоих',
      'Купи молоко, яйца и хлеб',
      'Хочу ароматный кофе',
    ];

    void viewport(WidgetTester tester, double width, [double height = 1000]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, height);
      addTearDown(tester.view.reset);
    }

    Future<_PanelClient> pumpResponsive(
      WidgetTester tester, {
      List<String> presets = screenshotPresets,
      double scale = 1,
      bool showBackButton = false,
      EdgeInsets? safeInsets,
      EdgeInsets? viewInsets,
      double? panelWidth,
      Locale locale = const Locale('ru'),
      Brightness brightness = Brightness.light,
      bool usePlatformTextScale = false,
      Key? repaintBoundaryKey,
    }) async {
      NewRequestTexts.instance.current = NewRequestContent(
        presets: presets,
        examples: const ['Пример запроса'],
      );
      return pumpPanel(
        tester,
        displayName: 'Иван',
        disableAnimations: true,
        textScale: scale,
        showBackButton: showBackButton,
        safeInsets: safeInsets,
        viewInsets: viewInsets,
        fontFamily: 'NewRequestResponsiveRoboto',
        panelWidth: panelWidth,
        locale: locale,
        brightness: brightness,
        usePlatformTextScale: usePlatformTextScale,
        repaintBoundaryKey: repaintBoundaryKey,
      );
    }

    Finder preset(int i) => find.byKey(Key('new_request_preset_$i'));

    void assertLabels(WidgetTester tester, List<String> texts, double scale) {
      final composer = tester.getRect(
        find.byKey(const Key('new_request_composer')),
      );
      for (final (i, text) in texts.indexed) {
        final label = find.descendant(of: preset(i), matching: find.text(text));
        expect(label, findsOneWidget, reason: 'порядок и полный текст $i');
        final paragraph = tester.renderObject<RenderParagraph>(label);
        expect(paragraph.text.toPlainText(), text);
        expect(paragraph.text.style!.fontFamily, 'NewRequestResponsiveRoboto');
        expect(
          paragraph.textScaler.scale(13),
          closeTo(13 * scale, 0.01),
          reason: 'системный масштаб сохранён',
        );
        expect(paragraph.didExceedMaxLines, isFalse, reason: 'подпись $i');
        expect(paragraph.debugHasOverflowShader, isFalse, reason: 'подпись $i');
        expect(
          paragraph.getMinIntrinsicHeight(paragraph.size.width),
          lessThanOrEqualTo(paragraph.size.height + 0.5),
          reason: 'ни одна строка $i не срезана снизу',
        );
        final chip = tester.getRect(preset(i));
        expect(chip.left, greaterThanOrEqualTo(composer.left - 0.5));
        expect(chip.right, lessThanOrEqualTo(composer.right + 0.5));
        // AC:RL-new-request-responsive/4
        expect(chip.width, greaterThanOrEqualTo(48));
        expect(chip.height, greaterThanOrEqualTo(48));
      }
      expect(preset(texts.length), findsNothing);
      expect(tester.takeException(), isNull);
    }

    for (final width in [360.0, 390.0, 430.0]) {
      testWidgets('2+1 на $width: полные строки, третья по центру поля', (
        tester,
      ) async {
        viewport(tester, width);
        await pumpResponsive(tester);
        assertLabels(tester, screenshotPresets, 1);
        final first = tester.getRect(preset(0));
        final second = tester.getRect(preset(1));
        final third = tester.getRect(preset(2));
        // AC:RL-new-request-responsive/1
        expect(first.top, closeTo(second.top, 0.5));
        expect(second.left, greaterThanOrEqualTo(first.right + 7.5));
        expect(third.top, greaterThanOrEqualTo(first.bottom + 7.5));
        expect(
          third.center.dx,
          closeTo(
            tester.getCenter(find.byKey(const Key('new_request_composer'))).dx,
            0.5,
          ),
        );
        for (final (i, text) in screenshotPresets.indexed) {
          final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: preset(i), matching: find.text(text)),
          );
          expect(
            paragraph.size.width,
            greaterThanOrEqualTo(
              paragraph.getMaxIntrinsicWidth(double.infinity) - 0.5,
            ),
            reason: 'подпись $i в одну строку с настоящим Roboto',
          );
        }
      });
    }

    for (final width in [300.0, 340.0, 381.0, 500.0, 570.0, 900.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('границы поля: $width × $scale', (tester) async {
          viewport(tester, width);
          await pumpResponsive(tester, scale: scale);
          // AC:RL-new-request-responsive/2
          assertLabels(tester, screenshotPresets, scale);
        });
      }
    }

    // Не перемножаем все оси: длинные данные атакуют узкую панель и scale 2,
    // обычные подписи выше проверяют всю матрицу ширин/масштабов.
    for (final count in [1, 2, 4, 5]) {
      for (final continuous in [false, true]) {
        for (final scale in [1.0, 2.0]) {
          testWidgets(
            '$count серверных, 80 символов, без пробелов=$continuous × $scale',
            (tester) async {
              viewport(tester, 300);
              final texts = List.generate(count, (i) {
                final fill = continuous ? 'Ж' * 80 : 'доставка продуктов ' * 5;
                return '$i${fill.substring(1, 80)}';
              });
              await pumpResponsive(tester, presets: texts, scale: scale);
              // AC:RL-new-request-responsive/3
              assertLabels(tester, texts, scale);
              for (var i = 1; i < texts.length; i++) {
                final previous = tester.getRect(preset(i - 1));
                final current = tester.getRect(preset(i));
                expect(
                  current.top >= previous.bottom ||
                      (current.top == previous.top &&
                          current.left > previous.left),
                  isTrue,
                  reason: 'серверный порядок $i',
                );
              }
            },
          );
        }
      }
    }

    for (final keyboard in [0.0, 300.0]) {
      testWidgets('AppBar + safe 47/34, клавиатура $keyboard', (tester) async {
        viewport(tester, 390, 844);
        await pumpResponsive(
          tester,
          showBackButton: true,
          safeInsets: const EdgeInsets.only(top: 47, bottom: 34),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        );
        // AC:RL-new-request-responsive/5
        final toolbar = tester.getRect(find.byType(AppBar));
        final logo = tester.getRect(find.byKey(const Key('new_request_logo')));
        expect(logo.top, greaterThanOrEqualTo(toolbar.bottom));
        final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
        expect(scaffold.extendBodyBehindAppBar, isFalse);
        await tester.ensureVisible(find.byKey(const Key('new_request_send')));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byKey(const Key('new_request_send'))).bottom,
          lessThanOrEqualTo(844 - keyboard - (keyboard == 0 ? 34 : 0) + 0.5),
        );
        expect(tester.takeException(), isNull);
      });
    }

    for (final size in [const Size(700, 320), const Size(300, 568)]) {
      testWidgets('прокрутка достигает последней плашки и отправки $size', (
        tester,
      ) async {
        viewport(tester, size.width, size.height);
        await pumpResponsive(tester, scale: 2, showBackButton: true);
        // AC:RL-new-request-responsive/5
        await tester.ensureVisible(preset(2));
        await tester.pumpAndSettle();
        expect(preset(2).hitTestable(), findsOneWidget);
        final last = tester.getRect(preset(2));
        expect(last.bottom, lessThanOrEqualTo(size.height + 0.5));
        await tester.ensureVisible(find.byKey(const Key('new_request_send')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('new_request_send')).hitTestable(),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets(
      'resize сохраняет controller, draft и single-flight исходного текста',
      (tester) async {
        viewport(tester, 390);
        final fullText =
            'Закажи ${List.filled(3, 'очень длинный товар').join(' ')}';
        final client = await pumpResponsive(
          tester,
          presets: [fullText, ...screenshotPresets],
        );
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller!;
        final state = tester.state(find.byType(NewRequestEmptyPage));
        await tester.enterText(find.byType(TextField), 'мой черновик');
        for (final width in [900.0, 340.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pump();
          // AC:RL-new-request-responsive/6
          expect(tester.state(find.byType(NewRequestEmptyPage)), same(state));
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller,
            same(controller),
          );
          expect(controller.text, 'мой черновик');
          expect(client.calls, 0);
        }
        final created = client.hold();
        await tester.ensureVisible(preset(0));
        await tester.tap(preset(0));
        await tester.pump();
        for (final width in [900.0, 340.0]) {
          tester.view.physicalSize = Size(width, 1000);
          await tester.pump();
          expect(tester.widget<ActionChip>(preset(1)).onPressed, isNull);
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          expect(client.calls, 1);
          expect(controller.text, 'мой черновик');
        }
        created.complete();
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(client.calls, 1);
        expect(client.room?.sent, [fullText]);
        expect(find.text('room $_requestRoomId'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('панель 340 внутри окна 1200 использует собственную ширину', (
      tester,
    ) async {
      viewport(tester, 1200);
      await pumpResponsive(tester, panelWidth: 340);
      // AC:RL-new-request-responsive/7
      assertLabels(tester, screenshotPresets, 1);
      final composer = tester.getRect(
        find.byKey(const Key('new_request_composer')),
      );
      expect(composer.width, lessThan(340));
      final first = tester.getRect(preset(0));
      final second = tester.getRect(preset(1));
      expect(first.center.dy, closeTo(second.center.dy, 0.5));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: preset(0),
          matching: find.text(screenshotPresets[0]),
        ),
      );
      expect(paragraph.text.style!.fontSize, lessThanOrEqualTo(13));
      expect(tester.getCenter(preset(2)).dx, closeTo(composer.center.dx, 0.5));
    });

    testWidgets('реальная en-локаль сохраняет ARB и границы при scale 2', (
      tester,
    ) async {
      viewport(tester, 340);
      await pumpResponsive(tester, scale: 2, locale: const Locale('en'));
      final l10n = L10nEn();
      assertLabels(tester, [
        l10n.newRequestPreset1,
        l10n.newRequestPreset2,
        l10n.newRequestPreset3,
      ], 2);
      expect(find.text(screenshotPresets.first), findsNothing);
    });

    testWidgets('короткая подпись учитывает touch 48 при выборе natural pair', (
      tester,
    ) async {
      viewport(tester, 300);
      final texts = ['Ш' * 18, 'А'];
      await pumpResponsive(tester, presets: texts);
      // AC:RL-new-request-responsive/2 AC:RL-new-request-responsive/4
      // Без max(48, naturalWidth) первая подпись + «А» формально вмещаются
      // в W268, но настоящий RawChip короткой подписи занимает минимум48.
      assertLabels(tester, texts, 1);
    });

    for (final (width, scale, enlarged) in [
      (390.0, 1.3, false),
      (390.0, 1.31, true),
      (390.0, 2.0, true),
      (390.0, 3.0, true),
      (584.0, 1.3, false),
      (584.0, 1.31, true),
      (585.0, 1.3, false),
      (585.0, 1.31, false),
      (900.0, 2.0, false),
    ]) {
      testWidgets('AC-9 enlarged: панель $width × $scale, flat=$enlarged', (
        tester,
      ) async {
        viewport(tester, width);
        final texts = [('доставка продуктов ' * 5).substring(0, 80), 'Кофе'];
        await pumpResponsive(tester, presets: texts, scale: scale);
        assertLabels(tester, texts, scale);
        final composer = tester.getRect(
          find.byKey(const Key('new_request_composer')),
        );
        if (width == 584 || width == 585) {
          expect(composer.width, closeTo(width - 64, 0.5));
        }
        for (final (i, text) in texts.indexed) {
          final chip = tester.widget<ActionChip>(preset(i));
          final label = find.descendant(
            of: preset(i),
            matching: find.text(text),
          );
          final renderedLabel = tester.renderObject<RenderParagraph>(label);
          // AC:RL-new-request-responsive/9
          if (enlarged) {
            expect(tester.widget<Text>(label).maxLines, 80);
            expect(chip.backgroundColor, Colors.transparent);
            expect(chip.disabledColor, Colors.transparent);
            expect(chip.side, BorderSide.none);
            expect(tester.widget<Text>(label).textAlign, TextAlign.start);
            expect(
              renderedLabel.text.style!.color,
              Theme.of(tester.element(preset(i))).colorScheme.primary,
            );
            final bounds = tester.getRect(preset(i));
            expect(bounds.left, closeTo(composer.left, 0.5));
            expect(bounds.right, closeTo(composer.right, 0.5));
            expect(
              renderedLabel.size.width,
              greaterThanOrEqualTo(composer.width - 20),
            );
            expect(
              tester.getRect(label).left,
              closeTo(composer.left + 8, 0.5),
              reason: 'начало подписи после внутреннего поля 8',
            );
            final firstGlyph = renderedLabel.getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 1),
            );
            expect(firstGlyph, hasLength(1));
            expect(firstGlyph.single.direction, TextDirection.ltr);
            expect(
              firstGlyph.single.left,
              closeTo(0, 1),
              reason: 'первый LTR-глиф у начала реального paragraph',
            );
            if (i > 0) {
              expect(
                bounds.top,
                greaterThanOrEqualTo(tester.getRect(preset(i - 1)).bottom),
              );
            }
          } else {
            expect(chip.backgroundColor, isNot(Colors.transparent));
            expect(chip.side, isNot(BorderSide.none));
            expect(tester.widget<Text>(label).textAlign, TextAlign.center);
          }
          await tester.ensureVisible(preset(i));
          await tester.pumpAndSettle();
          expect(preset(i).hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }

    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets(
        'AC-9 enlarged: platform scale, payload и single-flight $brightness',
        (tester) async {
          viewport(tester, 390);
          tester.platformDispatcher.textScaleFactorTestValue = 1;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final text = 'Ж' * 80;
          final client = await pumpResponsive(
            tester,
            presets: [text, 'Кофе'],
            brightness: brightness,
            usePlatformTextScale: true,
          );
          final state = tester.state(find.byType(NewRequestEmptyPage));
          final controller = tester
              .widget<TextField>(find.byType(TextField))
              .controller!;
          await tester.enterText(find.byType(TextField), 'черновик владельца');
          final created = client.hold();

          void assertState({required bool busy, required double scale}) {
            expect(tester.state(find.byType(NewRequestEmptyPage)), same(state));
            final field = tester.widget<TextField>(find.byType(TextField));
            expect(field.controller, same(controller));
            expect(controller.text, 'черновик владельца');
            expect(field.readOnly, busy);
            expect(client.calls, busy ? 1 : 0);
            expect(
              tester.widget<ActionChip>(preset(1)).onPressed,
              busy ? isNull : isNotNull,
            );
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: preset(1), matching: find.text('Кофе')),
            );
            expect(paragraph.textScaler.scale(13), closeTo(13 * scale, 0.01));
          }

          void assertResolvedBackground(int index) {
            final material = tester.widget<Material>(
              find.descendant(
                of: preset(index),
                matching: find.byType(Material),
              ),
            );
            final theme = Theme.of(tester.element(preset(index)));
            expect(theme.brightness, brightness);
            // RawChip рисует свой resolved background через Ink. Material.color
            // null сам по себе не доказывает прозрачность: canvas берёт цвет темы.
            if (material.color == null) {
              expect(material.type, MaterialType.canvas);
              final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
              expect(
                theme.canvasColor,
                scaffold.backgroundColor ?? theme.scaffoldBackgroundColor,
                reason: 'базовый Material совпадает с поверхностью страницы',
              );
            } else {
              expect(material.color, Colors.transparent);
            }
            final ink = tester.widget<Ink>(
              find.descendant(of: preset(index), matching: find.byType(Ink)),
            );
            expect(ink.decoration, isA<ShapeDecoration>());
            expect(
              (ink.decoration! as ShapeDecoration).color,
              Colors.transparent,
              reason:
                  'фактически resolved фон плашки, а не свойство ActionChip',
            );
          }

          // AC:RL-new-request-responsive/9
          assertState(busy: false, scale: 1);
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          assertState(busy: false, scale: 2);
          assertLabels(tester, [text, 'Кофе'], 2);
          assertResolvedBackground(1);
          await tester.ensureVisible(preset(0));
          await tester.tap(preset(0));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          assertState(busy: true, scale: 2);
          expect(
            tester.widget<ActionChip>(preset(1)).disabledColor,
            Colors.transparent,
          );
          assertResolvedBackground(1);
          for (final scale in [1.0, 2.0]) {
            tester.platformDispatcher.textScaleFactorTestValue = scale;
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            assertState(busy: true, scale: scale);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
            expect(client.calls, 1);
          }
          assertResolvedBackground(1);
          created.complete();
          for (var i = 0; i < 5; i++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(client.calls, 1);
          expect(client.room?.sent, [text]);
          expect(find.text('room $_requestRoomId'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final brightness in [Brightness.light, Brightness.dark]) {
      testWidgets('AC-9 pixels: focus и pressed различимы $brightness', (
        tester,
      ) async {
        viewport(tester, 390);
        const boundaryKey = Key('new_request_feedback_capture');
        final client = await pumpResponsive(
          tester,
          presets: const ['Кофе'],
          scale: 2,
          brightness: brightness,
          repaintBoundaryKey: boundaryKey,
        );
        final previousStrategy = FocusManager.instance.highlightStrategy;
        addTearDown(
          () => FocusManager.instance.highlightStrategy = previousStrategy,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        await tester.pumpAndSettle();
        final bounds = tester.getRect(preset(0));
        // Пустая область справа от короткой подписи, вдали от скругления.
        // Курсор поля, текст, логотип и весь прочий кадр не сравниваются.
        final region = Rect.fromCenter(
          center: Offset(bounds.right - 32, bounds.center.dy),
          width: 16,
          height: 12,
        );
        final paragraphRect = tester.getRect(
          find.descendant(of: preset(0), matching: find.text('Кофе')),
        );
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(of: preset(0), matching: find.text('Кофе')),
        );
        final textBox = paragraph
            .getBoxesForSelection(
              const TextSelection(baseOffset: 0, extentOffset: 4),
            )
            .single;
        expect(paragraphRect.left + textBox.right, lessThan(region.left));

        Future<List<int>> pixels() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundaryKey),
          );
          final localRegion = region.shift(
            -boundary.localToGlobal(Offset.zero),
          );
          final captured = await tester.runAsync(() async {
            final raster = await boundary.toImage(pixelRatio: 1);
            try {
              final bytes = (await raster.toByteData(
                format: ui.ImageByteFormat.rawRgba,
              ))!;
              return <int>[
                for (
                  var y = localRegion.top.round();
                  y < localRegion.bottom.round();
                  y++
                )
                  for (
                    var x = localRegion.left.round();
                    x < localRegion.right.round();
                    x++
                  )
                    for (var channel = 0; channel < 4; channel++)
                      bytes.getUint8((y * raster.width + x) * 4 + channel),
              ];
            } finally {
              raster.dispose();
            }
          });
          return captured!;
        }

        int changedPixels(List<int> before, List<int> after) {
          expect(after.length, before.length);
          var changed = 0;
          for (var offset = 0; offset < before.length; offset += 4) {
            if (List.generate(4, (channel) => channel).any(
              (channel) => before[offset + channel] != after[offset + channel],
            )) {
              changed++;
            }
          }
          return changed;
        }

        final idle = await pixels();
        expect(
          idle[3],
          255,
          reason: 'захвачена непрозрачная поверхность страницы',
        );
        final ink = find.descendant(of: preset(0), matching: find.byType(Ink));
        final focusNode = Focus.of(tester.element(ink));
        focusNode.requestFocus();
        await tester.pumpAndSettle();
        expect(focusNode.hasFocus, isTrue);
        expect(focusNode.hasPrimaryFocus, isTrue);
        expect(
          FocusManager.instance.highlightMode,
          FocusHighlightMode.traditional,
        );
        // AC:RL-new-request-responsive/9 — реальный растр feedback, не конфиг.
        final focusChanged = changedPixels(idle, await pixels());
        focusNode.unfocus();
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTouch;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(
          await pixels(),
          idle,
          reason: 'перед нажатием focus полностью погашен',
        );
        final gesture = await tester.startGesture(region.center);
        // TapGestureRecognizer даёт onTapDown после kPressTimeout;
        // только затем начинается рисование pressed-feedback.
        await tester.pump(kPressTimeout);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final pressedChanged = changedPixels(idle, await pixels());
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(client.calls, 0, reason: 'cancel не отправляет запрос');
        expect(
          focusChanged,
          greaterThan(96),
          reason:
              'focus pixels=$focusChanged, pressed pixels=$pressedChanged, '
              'idle RGBA=${idle.take(4).toList()}',
        );
        expect(
          pressedChanged,
          greaterThan(96),
          reason: 'pressed меняет пустую область без клавиатурного focus',
        );
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('AC-14: плашки-пресеты', () {
    for (var i = 0; i < 3; i++) {
      testWidgets('тап по плашке $i — запрос с её текстом, чат открыт', (
        tester,
      ) async {
        final client = await pumpPanel(tester, displayName: 'Иван');
        expect(
          find.descendant(
            of: find.byKey(Key('new_request_preset_$i')),
            matching: find.text(ruPresets[i]),
          ),
          findsOneWidget,
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

  testWidgets(
    'AC-23: серверные плашки заменяют ARB, число и порядок — как в ответе',
    (tester) async {
      NewRequestTexts.instance.current = const NewRequestContent(
        presets: ['Первая', 'Вторая', 'Третья', 'Четвёртая'],
        examples: ['Пример один', 'Пример два'],
      );
      await pumpPanel(tester, displayName: 'Иван');
      for (final (i, t) in [
        'Первая',
        'Вторая',
        'Третья',
        'Четвёртая',
      ].indexed) {
        expect(
          find.descendant(
            of: find.byKey(Key('new_request_preset_$i')),
            matching: find.text(t),
          ),
          findsOneWidget,
        );
      }
      expect(find.byKey(const Key('new_request_preset_4')), findsNothing);
      final typewriter = tester.widget<NewRequestTypewriter>(
        find.byType(NewRequestTypewriter),
      );
      expect(typewriter.examples, ['Пример один', 'Пример два']);
    },
  );

  testWidgets('AC-24: нет серверных текстов — плашки и примеры из ARB', (
    tester,
  ) async {
    await pumpPanel(tester, displayName: 'Иван');
    expect(find.byKey(const Key('new_request_preset_2')), findsOneWidget);
    expect(find.byKey(const Key('new_request_preset_3')), findsNothing);
    final typewriter = tester.widget<NewRequestTypewriter>(
      find.byType(NewRequestTypewriter),
    );
    expect(typewriter.examples.length, 6);
  });

  test('AC-24: парсер — мусор, не-ru, пусто и клампы → null/обрезка', () {
    expect(parseNewRequestContent(null), isNull);
    expect(parseNewRequestContent('x'), isNull);
    expect(
      parseNewRequestContent({
        'en': {
          'presets': ['A'],
        },
      }),
      isNull,
    );
    expect(
      parseNewRequestContent({
        'ru': {'presets': [], 'examples': []},
      }),
      isNull,
    );
    expect(
      parseNewRequestContent({
        'ru': {
          'presets': [1, null, '  '],
        },
      }),
      isNull,
    );
    final c = parseNewRequestContent({
      'ru': {
        'presets': ['а', 'А', 'б', 'в', 'г', 'д', 'е', 'x' * 81],
        'examples': [for (var i = 0; i < 20; i++) 'пример $i', 'y' * 141],
      },
    })!;
    expect(c.presets, ['а', 'б', 'в', 'г', 'д']);
    expect(c.examples.length, 10);
    expect(c.examples.every((e) => e.length <= 140), isTrue);
  });

  testWidgets('AC-25: en-локаль не показывает серверные русские тексты', (
    tester,
  ) async {
    NewRequestTexts.instance.current = const NewRequestContent(
      presets: ['Первая'],
      examples: ['Пример'],
    );
    final l10n = L10nEn();
    expect(newRequestPresets(l10n, NewRequestTexts.instance.current), [
      l10n.newRequestPreset1,
      l10n.newRequestPreset2,
      l10n.newRequestPreset3,
    ]);
    expect(
      newRequestExamples(l10n, NewRequestTexts.instance.current).first,
      l10n.newRequestExample1,
    );
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
