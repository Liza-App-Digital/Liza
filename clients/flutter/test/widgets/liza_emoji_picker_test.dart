// ledger:RL-emoji-history-search
// guard.render:real-widget
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/emoji_history_store.dart';
import 'package:liza/widgets/liza_emoji_picker.dart';

void main() {
  late SharedPreferences prefs;
  late EmojiHistoryStore history;
  final selected = <String>[];

  Widget scene({
    EmojiHistoryStore? store,
    Locale locale = const Locale('ru'),
    Key? boundaryKey,
    String? fontFamily,
    double width = 360,
    Widget? picker,
  }) => MaterialApp(
    locale: locale,
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    theme: ThemeData(fontFamily: fontFamily),
    home: Scaffold(
      body: Center(
        child: RepaintBoundary(
          key: boundaryKey,
          child: Material(
            color: Colors.white,
            child: SizedBox(
              width: width,
              height: 320,
              child:
                  picker ??
                  LizaEmojiPicker(
                    history: store ?? history,
                    onEmojiSelected: (_, emoji) => selected.add(emoji.emoji),
                  ),
            ),
          ),
        ),
      ),
    ),
  );

  Finder cell(String emoji) => find.byWidgetPredicate(
    (widget) => widget is EmojiCell && widget.emoji.emoji == emoji,
  );

  setUpAll(() async {
    await L10n.delegate.load(const Locale('ru'));
    await L10n.delegate.load(const Locale('en'));
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    history = EmojiHistoryStore(
      prefs,
      '@alice:example.invalid',
      EmojiUsage.text,
    );
    selected.clear();
  });

  testWidgets(
    'AC:RL-emoji-history-search/4 поиск ru/en, пустой результат и очистка',
    (tester) async {
      final search = find.byKey(const ValueKey('emoji-search'));
      for (final locale in [const Locale('ru'), const Locale('en')]) {
        await tester.pumpWidget(scene(locale: locale));
        await tester.pumpAndSettle();
        expect(cell('😀'), findsOneWidget);
        for (final query in [
          ('сердце', '❤️'),
          ('  HeArT  ', '❤️'),
          ('  СеРдЦе  ', '❤️'),
          ('кот', '🐈'),
          ('cat', '🐈'),
          ('😺', '😺'),
          ('ёж', '🦔'),
          ('еж', '🦔'),
        ]) {
          await tester.enterText(search, query.$1);
          await tester.pumpAndSettle();
          expect(
            cell(query.$2),
            findsOneWidget,
            reason: '${locale.languageCode}: ${query.$1}',
          );
          expect(find.byType(DefaultCategoryView), findsNothing);
        }
        await tester.enterText(search, 'no-such-emoji-qwerty');
        await tester.pumpAndSettle();
        expect(
          find.text(L10n.of(tester.element(search)).emojiSearchNoResults),
          findsOneWidget,
        );
        expect(find.byType(EmojiCell), findsNothing);
        final emptyRect = tester.getRect(
          find.text(L10n.of(tester.element(search)).emojiSearchNoResults),
        );
        final resultsRect = tester.getRect(find.byType(PageView));
        expect(emptyRect.center.dy, closeTo(resultsRect.center.dy, 1));
        expect(emptyRect.top - resultsRect.top, greaterThanOrEqualTo(8));
        expect(resultsRect.bottom - emptyRect.bottom, greaterThanOrEqualTo(8));
        await tester.tap(find.byKey(const ValueKey('emoji-search-clear')));
        await tester.pumpAndSettle();
        expect(cell('😀'), findsOneWidget);
        expect(find.byType(DefaultCategoryView), findsOneWidget);
        expect(tester.widget<TextField>(search).controller!.text, isEmpty);
        expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
      }
      expect(selected, isEmpty);
      expect(history.ranked(), isEmpty);
    },
  );

  testWidgets(
    'AC:RL-emoji-history-search/5 exact tone/ZWJ/flag callback один раз без записи',
    (tester) async {
      const exact = ['👍🏽', '👨‍👩‍👧', '🇷🇺'];
      for (final emoji in exact.reversed) {
        await history.record(emoji);
      }
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      for (final emoji in exact) {
        await tester.tap(cell(emoji));
        await tester.pump();
      }
      expect(selected, exact);
      expect(history.ranked(), exact);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AC:RL-emoji-history-search/5 skin tone overlay сохраняет выбор',
    (tester) async {
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('emoji-search')), '👍');
      await tester.pumpAndSettle();
      expect(tester.widget<EmojiCell>(cell('👍')).emoji.hasSkinTone, isTrue);
      await tester.longPress(cell('👍'));
      await tester.pumpAndSettle();
      expect(cell('👍🏽'), findsOneWidget);
      await tester.tap(cell('👍🏽'));
      await tester.pumpAndSettle();
      expect(selected, ['👍🏽']);
      expect(history.ranked(), isEmpty);
      expect(cell('👍🏽'), findsNothing);
    },
  );

  testWidgets(
    'AC:RL-emoji-history-search/2 snapshot, A→B→A и смена назначения/языка',
    (tester) async {
      await history.record('👍🏽');
      final other = EmojiHistoryStore(
        prefs,
        '@bob:example.invalid',
        EmojiUsage.text,
      );
      final reaction = EmojiHistoryStore(
        prefs,
        history.userId,
        EmojiUsage.reaction,
      );
      await other.record('🇷🇺');
      await reaction.record('👨‍👩‍👧');
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      expect(cell('👍🏽'), findsOneWidget);
      final openedConfig = tester
          .widget<EmojiPicker>(find.byType(EmojiPicker))
          .config;
      expect(openedConfig.checkPlatformCompatibility, isTrue);
      expect(
        openedConfig.categoryViewConfig.recentTabBehavior,
        RecentTabBehavior.NONE,
      );
      await history.record('😺');
      await tester.pumpWidget(scene());
      await tester.pumpAndSettle();
      expect(
        identical(
          tester.widget<EmojiPicker>(find.byType(EmojiPicker)).config.emojiSet,
          openedConfig.emojiSet,
        ),
        isTrue,
      );
      expect(
        cell('😺'),
        findsNothing,
        reason: 'снимок не прыгает при использовании',
      );
      await tester.enterText(
        find.byKey(const ValueKey('emoji-search')),
        'heart',
      );
      await tester.pumpAndSettle();
      await tester.pumpWidget(scene(store: other));
      await tester.pumpAndSettle();
      expect(cell('🇷🇺'), findsOneWidget);
      expect(cell('👍🏽'), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(scene(store: reaction));
      await tester.pumpAndSettle();
      expect(cell('👨‍👩‍👧'), findsOneWidget);
      expect(cell('🇷🇺'), findsNothing);
      await tester.pumpWidget(scene(locale: const Locale('en')));
      await tester.pumpAndSettle();
      expect(cell('👍🏽'), findsOneWidget);
      expect(cell('😺'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
        'Search emoji',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'AC:RL-emoji-history-search/7 категория→немедленный поиск, фокус, narrow, lifecycle',
    (tester) async {
      await tester.pumpWidget(scene(width: 240));
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('emoji-search'));
      await tester.tap(find.byType(Tab).at(2));
      await tester.pump(const Duration(milliseconds: 10));
      await tester.enterText(search, 'cat');
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull);
      for (final query in ['c', 'ca', 'cat', '', 'heart', '😺']) {
        await tester.enterText(search, query);
        await tester.pump(const Duration(milliseconds: 10));
        expect(tester.widget<TextField>(search).focusNode!.hasFocus, isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpAndSettle();
      await tester.tap(cell('😺'));
      expect(selected, ['😺']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(scene(width: 240));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(search).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('AC:RL-emoji-history-search/7 PNG реального wrapper', (
    tester,
  ) async {
    final out = Platform.environment['EMOJI_QA_OUT'];
    String? fontFamily;
    if (out != null) {
      for (final entry in {
        'EmojiQaText': '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
        'Apple Color Emoji': '/System/Library/Fonts/Apple Color Emoji.ttc',
        'MaterialIcons':
            '/opt/homebrew/share/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      }.entries) {
        if (!File(entry.value).existsSync()) continue;
        final loader = FontLoader(entry.key)
          ..addFont(
            Future.value(
              File(entry.value).readAsBytesSync().buffer.asByteData(),
            ),
          );
        await tester.runAsync(loader.load);
      }
      fontFamily = 'EmojiQaText';
    }
    for (final emoji in ['👍🏽', '❤️', '😺', '🔥', '🇷🇺', '👨‍👩‍👧']) {
      await history.record(emoji);
    }
    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      scene(boundaryKey: boundaryKey, fontFamily: fontFamily),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LizaEmojiPicker), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (out != null) {
      Future<void> capture(String path) async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(path).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<({int width, int height, List<int> bytes})> raster(
        String path,
      ) async {
        final codec = await ui.instantiateImageCodec(
          File(path).readAsBytesSync(),
        );
        final frame = await codec.getNextFrame();
        final image = frame.image;
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!.buffer.asUint8List();
        final result = (
          width: image.width,
          height: image.height,
          bytes: bytes.toList(),
        );
        image.dispose();
        codec.dispose();
        return result;
      }

      Future<List<int>> gridPixels(String path, double gridTop) async {
        final image = await raster(path);
        final start = gridTop.round() * image.width * 4;
        return image.bytes.sublist(start, start + 3 * 36 * 2 * image.width * 4);
      }

      await tester.runAsync(() => capture(out));
      await tester.enterText(
        find.byKey(const ValueKey('emoji-search')),
        'сердце',
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => capture(out.replaceFirst('.png', '-search.png')),
      );
      final localGridTop =
          (tester.getTopLeft(find.byType(GridView)).dy -
              tester.getTopLeft(find.byKey(boundaryKey)).dy) *
          2;
      final localPixels = (await tester.runAsync(
        () => gridPixels(out.replaceFirst('.png', '-search.png'), localGridTop),
      ))!;
      final searchConfig = tester
          .widget<EmojiPicker>(find.byType(EmojiPicker))
          .config;
      final searchCell = tester.getRect(cell('💑').first);
      await tester.enterText(
        find.byKey(const ValueKey('emoji-search')),
        'qwertyxyz',
      );
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => capture(out.replaceFirst('.png', '-empty.png')),
      );
      final empty = find.text(
        L10n.of(tester.element(find.byType(TextField))).emojiSearchNoResults,
      );
      final emptyRect = tester.getRect(empty);
      final resultsRect = tester.getRect(find.byType(PageView));
      final boundaryRect = tester.getRect(find.byKey(boundaryKey));
      final emptyLocal = emptyRect.shift(-boundaryRect.topLeft);
      final resultsLocal = resultsRect.shift(-boundaryRect.topLeft);
      final emptyRaster = (await tester.runAsync(
        () => raster(out.replaceFirst('.png', '-empty.png')),
      ))!;
      var pixelLeft = emptyRaster.width;
      var pixelRight = -1;
      var pixelTop = emptyRaster.height;
      var pixelBottom = -1;
      for (
        var y = (resultsLocal.top * 2).ceil();
        y < (resultsLocal.bottom * 2).floor();
        y++
      ) {
        for (var x = 0; x < emptyRaster.width; x++) {
          final offset = (y * emptyRaster.width + x) * 4;
          if (emptyRaster.bytes[offset] < 100 &&
              emptyRaster.bytes[offset + 1] < 100 &&
              emptyRaster.bytes[offset + 2] < 100 &&
              emptyRaster.bytes[offset + 3] > 200) {
            if (x < pixelLeft) pixelLeft = x;
            if (x > pixelRight) pixelRight = x;
            if (y < pixelTop) pixelTop = y;
            if (y > pixelBottom) pixelBottom = y;
          }
        }
      }
      expect(pixelBottom, greaterThan(pixelTop));
      expect(
        (pixelTop + pixelBottom) / 2,
        closeTo(emptyLocal.center.dy * 2, 8),
      );
      expect(pixelTop - resultsLocal.top * 2, greaterThan(16));
      expect(resultsLocal.bottom * 2 - pixelBottom, greaterThan(16));
      final diagnostics = <String, Object>{
        'boundary': {
          'top': boundaryRect.top,
          'width': boundaryRect.width,
          'height': boundaryRect.height,
          'pixelRatio': 2,
        },
        'emptyLocal': {
          'top': emptyLocal.top,
          'bottom': emptyLocal.bottom,
          'centerY': emptyLocal.center.dy,
        },
        'resultsLocal': {
          'top': resultsLocal.top,
          'bottom': resultsLocal.bottom,
          'centerY': resultsLocal.center.dy,
        },
        'paintedEmptyPixels': {
          'left': pixelLeft,
          'top': pixelTop,
          'right': pixelRight,
          'bottom': pixelBottom,
        },
        'empty': {
          'top': emptyRect.top,
          'bottom': emptyRect.bottom,
          'centerY': emptyRect.center.dy,
        },
        'results': {
          'top': resultsRect.top,
          'bottom': resultsRect.bottom,
          'centerY': resultsRect.center.dy,
        },
        'searchCoupleCell': {
          'width': searchCell.width,
          'height': searchCell.height,
        },
      };
      for (final explicitApple in [false, true]) {
        await tester.pumpWidget(
          scene(
            boundaryKey: boundaryKey,
            fontFamily: fontFamily,
            picker: EmojiPicker(
              config: Config(
                height: null,
                locale: searchConfig.locale,
                emojiSet: searchConfig.emojiSet,
                emojiTextStyle: explicitApple
                    ? const TextStyle(fontFamily: 'Apple Color Emoji')
                    : null,
                emojiViewConfig: searchConfig.emojiViewConfig,
                categoryViewConfig: searchConfig.categoryViewConfig,
                bottomActionBarConfig: searchConfig.bottomActionBarConfig,
                skinToneConfig: searchConfig.skinToneConfig,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => capture(
            out.replaceFirst(
              '.png',
              explicitApple ? '-stock-apple-search.png' : '-stock-search.png',
            ),
          ),
        );
        final rect = tester.getRect(cell('💑').first);
        diagnostics[explicitApple ? 'stockAppleCell' : 'stockCell'] = {
          'width': rect.width,
          'height': rect.height,
        };
        final stockGridTop =
            (tester.getTopLeft(find.byType(GridView)).dy -
                tester.getTopLeft(find.byKey(boundaryKey)).dy) *
            2;
        final stockPath = out.replaceFirst(
          '.png',
          explicitApple ? '-stock-apple-search.png' : '-stock-search.png',
        );
        final stockPixels = (await tester.runAsync(
          () => gridPixels(stockPath, stockGridTop),
        ))!;
        var mismatches = 0;
        for (var i = 0; i < localPixels.length; i++) {
          if (localPixels[i] != stockPixels[i]) mismatches++;
        }
        diagnostics[explicitApple
                ? 'stockApplePixelMismatches'
                : 'stockPixelMismatches'] =
            mismatches;
        if (!explicitApple) {
          expect(
            mismatches,
            0,
            reason:
                'Результаты рисуются пиксельно тем же EmojiCell, что stock picker',
          );
        }
      }
      File(out.replaceFirst('.png', '-geometry.json')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(diagnostics),
      );
    }
  });
}
