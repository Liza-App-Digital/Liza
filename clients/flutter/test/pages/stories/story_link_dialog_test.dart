// Запасной путь «Копировать ссылку» на сторис (LABA-2615): браузер отверг
// запись в буфер → диалог со ссылкой, кнопка «Копировать» кладёт её в буфер.
//
// Реестр: tests/registry/RL-stories-link.md
// Дизайн: docs/superpowers/specs/2026-10-02-story-link-copy-web-gesture-laba2615-design.md
//
// ledger:RL-stories-link

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/stories/story_link_dialog.dart';

const _url = 'https://me.liza.ru/s/p_abc';

void main() {
  late List<String> clipboard;
  late bool rejectClipboard;

  setUp(() {
    clipboard = [];
    rejectClipboard = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            if (rejectClipboard) {
              throw PlatformException(code: 'copy_fail');
            }
            clipboard.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<Future<bool>> open(WidgetTester tester) async {
    late Future<bool> result;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => result = StoryLinkDialog.show(context, _url),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  testWidgets(
    'показывает ссылку, «Копировать» кладёт её в буфер и закрывает диалог '
    '[AC:RL-stories-link/6]',
    (tester) async {
      final result = await open(tester);
      expect(find.text(_url), findsOneWidget);

      await tester.tap(find.text('Копировать'));
      await tester.pumpAndSettle();

      expect(clipboard, [_url]);
      expect(find.byType(StoryLinkDialog), findsNothing);
      expect(await result, isTrue);
    },
  );

  testWidgets('буфер снова отказал - диалог остаётся, ссылку можно выделить '
      '[AC:RL-stories-link/6]', (tester) async {
    rejectClipboard = true;
    await open(tester);
    await tester.tap(find.text('Копировать'));
    await tester.pumpAndSettle();
    expect(find.byType(StoryLinkDialog), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('«Закрыть» - без записи в буфер', (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(clipboard, isEmpty);
    expect(await result, isFalse);
  });
}
