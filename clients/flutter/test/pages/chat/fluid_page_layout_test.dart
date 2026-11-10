import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/widgets/layouts/two_column_layout.dart';

import '../../utils/test_client.dart';

/// Страж свёртки списка чатов под открытой HTML-страницей: на РЕАЛЬНОМ
/// `MiniAppOverlay` + `TwoColumnLayout` (контент страницы подменён — WebView
/// в widget-тесте не поднимается).
/// ledger:RL-liza-liquid-page
void main() {
  late Client client;
  late Room room;
  final manager = MiniAppManager.instance;
  final defaultIsTablet = MiniAppOverlay.isTablet;
  var homeInits = 0;
  var contentInits = 0;
  final composer = TextEditingController();

  setUpAll(() async {
    client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!chat:example.invalid', client: client);
  });

  setUp(() {
    manager.closeAll();
    manager.windowsSupported = false;
    manager.panelFilled.value = false;
    manager.chatListCompactable.value = true;
    MiniAppOverlay.isTablet = (_) => false;
    homeInits = 0;
    contentInits = 0;
    composer.clear();
    MiniAppOverlay.debugContentBuilder = (context, app) => _Probe(
      key: ValueKey('content-${app.appId}'),
      onInit: () => contentInits++,
    );
  });

  tearDown(() {
    manager.closeAll();
    manager.chatListCompactable.value = false;
    MiniAppOverlay.isTablet = defaultIsTablet;
    MiniAppOverlay.debugContentBuilder = null;
  });

  Event pageEvent() => Event.fromJson({
    'type': 'm.room.message',
    'event_id': r'$page',
    'sender': '@bot:example.invalid',
    'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    'room_id': room.id,
    'content': {'msgtype': 'm.file', 'body': 'Страница: Цвета'},
  }, room);

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        locale: const Locale('ru'),
        builder: (context, child) => MiniAppOverlay(child: child!),
        home: _Home(onInit: () => homeInits++, composer: composer),
      ),
    );
    await tester.pumpAndSettle();
  }

  double listWidth(WidgetTester tester) =>
      tester.getSize(find.byKey(const ValueKey('list-column'))).width;

  testWidgets(
    'колонка списка: 72 px под страницей, полная — до, после, при растягивании',
    (tester) async {
      // AC:RL-liza-liquid-page/9
      await pumpHost(tester);
      final full = LizaThemes.columnWidth + LizaThemes.navRailWidth;
      final compact = LizaThemes.navRailWidth + 1 + kCompactChatListWidth;
      expect(listWidth(tester), full);

      manager.openPage(pageEvent(), title: 'Цвета');
      await tester.pumpAndSettle();
      expect(listWidth(tester), compact);

      manager.expandChatList();
      await tester.pumpAndSettle();
      expect(
        listWidth(tester),
        full,
        reason: 'ручное растягивание не затирается',
      );

      manager.collapseChatList();
      await tester.pumpAndSettle();
      expect(listWidth(tester), compact);

      manager.closeAll();
      await tester.pumpAndSettle();
      expect(
        listWidth(tester),
        full,
        reason: 'закрытие страницы возвращает список',
      );
    },
  );

  testWidgets(
    'обычный miniApp список не сворачивает (AC-33 пересмотрен только для страницы)',
    (tester) async {
      // AC:RL-liza-liquid-page/9
      await pumpHost(tester);
      manager.open(
        appUrl: 'https://shop.example.invalid/',
        appId: 'shop',
        appName: 'Магазин',
        room: room,
      );
      await tester.pumpAndSettle();
      expect(
        listWidth(tester),
        LizaThemes.columnWidth + LizaThemes.navRailWidth,
      );
    },
  );

  testWidgets(
    'смена активного приложения на не-страницу сбрасывает ручное растягивание',
    (tester) async {
      // AC:RL-liza-liquid-page/9
      await pumpHost(tester);
      manager.openPage(pageEvent(), title: 'Цвета');
      await tester.pumpAndSettle();
      manager.expandChatList();
      manager.closeAll();
      await tester.pumpAndSettle();
      manager.openPage(pageEvent(), title: 'Цвета');
      await tester.pumpAndSettle();
      expect(
        listWidth(tester),
        LizaThemes.navRailWidth + 1 + kCompactChatListWidth,
        reason: 'новая страница снова сворачивает список',
      );
    },
  );

  testWidgets(
    'композер принимает ввод при открытой странице (side и на всю ширину)',
    (tester) async {
      // AC:RL-liza-liquid-page/10
      await pumpHost(tester);
      manager.openPage(pageEvent(), title: 'Цвета');
      await tester.pumpAndSettle();
      for (final filled in [false, true]) {
        manager.panelFilled.value = filled;
        await tester.pumpAndSettle();
        composer.clear();
        await tester.enterText(
          find.byKey(const ValueKey('composer')),
          'привет',
        );
        expect(composer.text, 'привет', reason: 'filled=$filled');
      }
    },
  );

  testWidgets(
    'смена раскладки не пересоздаёт ни контент страницы, ни Router (×1)',
    (tester) async {
      // AC:RL-liza-liquid-page/11
      await pumpHost(tester);
      manager.openPage(pageEvent(), title: 'Цвета');
      await tester.pumpAndSettle();
      manager.expandChatList();
      await tester.pumpAndSettle();
      manager.collapseChatList();
      manager.panelFilled.value = true;
      await tester.pumpAndSettle();
      manager.panelFilled.value = false;
      await tester.pumpAndSettle();
      expect(contentInits, 1);
      expect(homeInits, 1);
    },
  );
}

class _Probe extends StatefulWidget {
  final VoidCallback onInit;
  const _Probe({super.key, required this.onInit});
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Home extends StatefulWidget {
  final VoidCallback onInit;
  final TextEditingController composer;
  const _Home({required this.onInit, required this.composer});
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => TwoColumnLayout(
    compactable: true,
    mainView: const SizedBox.expand(key: ValueKey('list-column')),
    sideView: Align(
      alignment: Alignment.bottomCenter,
      child: SizedBox(
        width: 300,
        child: TextField(
          key: const ValueKey('composer'),
          controller: widget.composer,
        ),
      ),
    ),
  );
}
