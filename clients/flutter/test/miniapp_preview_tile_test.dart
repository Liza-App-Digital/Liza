// ledger:RL-miniapp-chat-preview
// AC:RL-miniapp-chat-preview/1 AC:RL-miniapp-chat-preview/2
// AC:RL-miniapp-chat-preview/3 AC:RL-miniapp-chat-preview/4
// AC:RL-miniapp-chat-preview/5 AC:RL-miniapp-chat-preview/6
// AC:RL-miniapp-chat-preview/7
// guard.render:real-widget
//
// Превью mini App в ответе: РЕАЛЬНЫЙ MiniAppLaunchContent / MiniAppPreviewTile.
//
// Red-proof:
//   RP-1 (AC-1): size не квадрат (width != height) → красный.
//   RP-2 (AC-2): flex 9/1 заменить на 1/1 → плашка не ~10%, красный.
//   RP-3 (AC-5): убрать ветку `previews.isNotEmpty` в build → плитка не
//     находится на кейсах 1/3/legacy.
//   RP-4 (AC-6): убрать `take(maxPreviews)` → «1 / 12» вместо «1 / 8».
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/mini_app_launch_content.dart';
import 'utils/test_client.dart';

Future<void> _drainMxcRetryTimers(WidgetTester tester) async {
  // Размонтируем дерево: висящий retry-таймер MxcImage увидит !mounted и
  // не заведёт следующий.
  await tester.pumpWidget(const SizedBox.shrink());
  // AsyncCache профиля (matrix SDK) держит 1-часовой stale-таймер.
  for (final s in const [3, 31, 3601]) {
    await tester.pump(Duration(seconds: s));
  }
}

void main() {
  Future<Event> makeEvent(
    WidgetTester tester,
    Map<String, Object?> extra,
  ) async {
    final client = (await tester.runAsync(prepareTestClient))!;
    final room = Room(id: '!r:test', client: client);
    return Event(
      content: {
        'msgtype': 'com.liza.miniapp.launch',
        'app_name': 'Красные платья',
        'app_url': 'https://store.example',
        'button_text': 'Открыть',
        ...extra,
      },
      type: EventTypes.Message,
      eventId: r'$e',
      senderId: '@bot:test',
      originServerTs: DateTime(2026, 11, 3),
      room: room,
    );
  }

  Future<void> pumpCard(WidgetTester tester, Event event) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: MiniAppLaunchContent(event: event, textColor: Colors.black),
        ),
      ),
    );
    // Deferred-локализация ru приходит future'ами — даём кадры.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'плитка: квадрат, ~90/10, название, свайп не открывает, тап открывает',
    (tester) async {
      final event = await makeEvent(tester, const {});
      var opened = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MiniAppPreviewTile(
              event: event,
              previews: [for (var i = 0; i < 3; i++) Uri.parse('mxc://t/$i')],
              appName: 'Красные платья',
              loading: false,
              onOpen: () => opened++,
            ),
          ),
        ),
      );

      // AC-1: квадрат
      final size = tester.getSize(find.byType(MiniAppPreviewTile));
      expect(size.width, MiniAppPreviewTile.size);
      expect(size.height, MiniAppPreviewTile.size);

      // AC-2: карусель ~90% высоты, плашка ~10%
      final carousel = tester.getSize(find.byType(PageView));
      expect(carousel.height / size.height, closeTo(0.9, 0.01));
      final bar = tester.getRect(find.text('Красные платья'));
      final tile = tester.getRect(find.byType(MiniAppPreviewTile));
      expect(bar.top, greaterThanOrEqualTo(tile.top + tile.height * 0.9 - 1));

      // AC-3: название в плашке
      expect(find.text('Красные платья'), findsOneWidget);

      // AC-4: карусель листается, свайп не открывает
      expect(find.text('1 / 3'), findsOneWidget);
      await tester.drag(find.byType(PageView), const Offset(-200, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('2 / 3'), findsOneWidget);
      expect(opened, 0, reason: 'свайп не должен открывать mini App');

      // AC-5: тап открывает
      await tester.tap(find.text('Красные платья'));
      expect(opened, 1);

      await _drainMxcRetryTimers(tester);
    },
  );

  testWidgets('кейсы 1 / 3 / 12 превью и legacy app_preview', (tester) async {
    final one = await makeEvent(tester, {
      'app_previews': ['mxc://t/1'],
    });
    await pumpCard(tester, one);
    expect(find.byType(MiniAppPreviewTile), findsOneWidget);
    expect(
      find.textContaining(' / '),
      findsNothing,
      reason: 'одно превью — без счётчика',
    );
    await _drainMxcRetryTimers(tester);

    final three = await makeEvent(tester, {
      'app_previews': ['mxc://t/1', 'mxc://t/2', 'mxc://t/3'],
    });
    await pumpCard(tester, three);
    expect(find.byType(MiniAppPreviewTile), findsOneWidget);
    expect(find.text('1 / 3'), findsOneWidget);
    await _drainMxcRetryTimers(tester);

    // AC-6: не больше maxPreviews; не-mxc отбрасываются
    final many = await makeEvent(tester, {
      'app_previews': [
        'https://evil.example/x.png',
        for (var i = 0; i < 12; i++) 'mxc://t/$i',
      ],
    });
    await pumpCard(tester, many);
    expect(find.text('1 / 8'), findsOneWidget);
    await _drainMxcRetryTimers(tester);

    final legacy = await makeEvent(tester, {'app_preview': 'mxc://t/old'});
    await pumpCard(tester, legacy);
    expect(find.byType(MiniAppPreviewTile), findsOneWidget);
    await _drainMxcRetryTimers(tester);
  });

  testWidgets('без превью — прежняя карточка с кнопкой', (tester) async {
    final none = await makeEvent(tester, const {});
    await pumpCard(tester, none);
    // AC-7
    expect(find.byType(MiniAppPreviewTile), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('Открыть'), findsOneWidget);
    await _drainMxcRetryTimers(tester);
  });
}
