import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/main.dart' as app;
import 'package:liza/pages/chat/chat_view.dart';
import 'package:liza/pages/chat/input_bar.dart';
import 'package:liza/widgets/emoji_quick_reactions.dart';
import 'package:liza/widgets/liza_emoji_picker.dart';

import 'e2e_actor.dart';
import 'e2e_config.dart';
import 'liza_flows.dart';

Future<void> _capturePicker(WidgetTester tester) async {
  // Ближайшая граница именно маршрута picker: первый boundary всего приложения
  // снимает чат ПОД модальным окном и не доказывает видимость поиска.
  final finder = find.ancestor(
    of: find.byType(LizaEmojiPicker),
    matching: find.byType(RepaintBoundary),
  );
  final boundary = tester.renderObject<RenderRepaintBoundary>(finder.first);
  final image = await boundary.toImage(
    pixelRatio: tester.view.devicePixelRatio,
  );
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/liza-e2e-shots')
      ..createSync(recursive: true);
    File(
      '${dir.path}/emoji-history-search__reaction-search.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
  } finally {
    image.dispose();
  }
}

// ledger:RL-emoji-history-search — реальное приложение против локального стека.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('поиск в тексте и реакциях, затем персональная быстрая полоска', (
    tester,
  ) async {
    // Отдельное имя клиента даёт отдельный SQLite-файл. Параллельный ручной
    // flutter run использует свою БД; его приложение и данные не трогаем.
    final stamp = DateTime.now().microsecondsSinceEpoch;
    SharedPreferences.setMockInitialValues({
      'chat.fluffy.show_no_google': false,
      'im.fluffychat.store.clients': ['LizaEmojiE2E-$stamp'],
    });
    final actorA = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userA);
    final actorB = await E2eActor.login(E2eConfig.homeserver, E2eConfig.userB);
    final roomId = await actorB.createDirectChat(actorA.userId);
    await actorA.joinRoom(roomId);
    final inbound = 'emoji e2e $stamp';
    await actorB.sendText(roomId, inbound);
    final frameworkErrors = <String>[];
    var previousErrorHandler = FlutterError.onError;
    var handlerInstalled = false;

    try {
      app.main();
      await tester.ensureLizaHome();
      previousErrorHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        frameworkErrors.add(details.toString());
        previousErrorHandler?.call(details);
      };
      handlerInstalled = true;
      await tester.waitUntil(find.textContaining(inbound));
      await tester.tap(find.textContaining(inbound).first);
      await tester.waitUntil(find.byType(ChatView));

      await tester.tap(find.byIcon(Icons.emoji_emotions_outlined).first);
      await tester.waitUntil(find.byType(LizaEmojiPicker));
      final search = find.byKey(const ValueKey('emoji-search'));
      await tester.enterText(search, 'heart');
      await tester.waitUntil(find.text('❤️'));
      await tester.tap(find.text('❤️').first);
      await tester.pump(const Duration(milliseconds: 200));
      final composer = find.descendant(
        of: find.byType(InputBar),
        matching: find.byType(TextField),
      );
      expect(
        tester.widget<TextField>(composer.first).controller!.text,
        '❤️',
        reason: 'AC:RL-emoji-history-search/5 — одна вставка в живой композер',
      );
      await tester.tap(find.byIcon(Icons.keyboard_outlined).first);
      await tester.pump(const Duration(milliseconds: 300));

      final message = find.descendant(
        of: find.byType(ChatView),
        matching: find.textContaining(inbound, findRichText: true),
      );
      await tester.tap(message.first, buttons: kSecondaryMouseButton);
      await tester.waitUntil(find.byType(EmojiQuickReactions));
      await tester.tap(find.byIcon(Icons.add_reaction_outlined));
      await tester.waitUntil(find.byType(LizaEmojiPicker));
      await tester.enterText(search, 'огонь');
      await tester.waitUntil(find.text('🔥'));
      await tester.pump(const Duration(milliseconds: 300));
      await _capturePicker(tester);
      await tester.tap(find.text('🔥').first);
      await actorB.waitForEvent(
        roomId,
        (e) =>
            e.type == 'm.reaction' &&
            (e.content['m.relates_to'] as Map?)?['key'] == '🔥',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(message.first, buttons: kSecondaryMouseButton);
      await tester.waitUntil(find.byType(EmojiQuickReactions));
      expect(
        find.descendant(
          of: find.byType(EmojiQuickReactions),
          matching: find.text('🔥'),
        ),
        findsOneWidget,
        reason: 'AC:RL-emoji-history-search/3 — выбор попал в быструю полоску',
      );
      expect(
        frameworkErrors,
        isEmpty,
        reason: 'AC:RL-emoji-history-search/7 — без скрытых ошибок layout',
      );
    } finally {
      if (handlerInstalled) FlutterError.onError = previousErrorHandler;
      await actorA.leaveAndForget(roomId);
      await actorB.leaveAndForget(roomId);
      await actorB.logout();
      await actorA.logout();
    }
  });
}
