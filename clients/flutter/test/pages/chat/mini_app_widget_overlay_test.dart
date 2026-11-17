import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/tg_widget/tg_widget_bubble.dart';

import '../../utils/test_client.dart';
import 'tg_widget/tg_widget_test_support.dart';

// ledger:RL-telegram-widgets
// AC:RL-telegram-widgets/13
void main() {
  final manager = MiniAppManager.instance;
  late Client client;
  late Room room;
  late FakeWidgetServer server;

  const bot = '@shop_bot:example.invalid';

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    client = await prepareTestClient(loggedIn: true);
    client.rooms.clear();
    room = Room(id: '!w:example.invalid', client: client);
    client.rooms.add(room);
    server = FakeWidgetServer(verifiedBots: {bot});
    resetTgWidgetGlobals(server);
    manager.closeAll();
    manager.windowsSupported = false;
  });

  tearDown(() async {
    manager.closeAll();
    tearDownTgWidgetGlobals();
    await client.dispose(closeDatabase: true);
  });

  Event widgetEvent() => Event(
    type: EventTypes.Message,
    eventId: r'$w',
    senderId: bot,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
    room: room,
    content: widgetContent(
      body: 'Карточка',
      block: widgetBlockJson(
        html: '<div>Кратко</div><div class="liza-more">Подробности</div>',
        sender: bot,
        botId: bot,
        roomId: room.id,
      ),
    ),
  );

  testWidgets('оверлей рисует развёрнутый виджет в панели', (tester) async {
    tester.view.physicalSize = const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => MiniAppOverlay(child: child!),
        home: const Scaffold(body: SizedBox.expand()),
      ),
    );
    await tester.pumpAndSettle();

    manager.openWidget(widgetEvent(), title: 'Карточка');
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 16));
    }

    await tester.pumpAndSettle();

    expect(find.text('Карточка'), findsWidgets);
    expect(
      find.byKey(const ValueKey('tg-widget-expanded-area')),
      findsOneWidget,
    );
    final state = tester.state<TgWidgetBubbleState>(
      find.byType(TgWidgetBubble, skipOffstage: false),
    );
    expect(state.phase, isNot(TgWidgetPhase.verifying));
    expect(FakeEngines.live, isNotEmpty);
  });
}
