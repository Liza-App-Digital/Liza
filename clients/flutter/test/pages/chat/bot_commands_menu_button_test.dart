// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-commands-safety-menu
//
// Меню команд бота в композере (bot-api-compat-fixes, D11): кнопка меню рядом
// с полем ввода появляется, как только команды приехали; подсказки «/»
// появляются по приезду команд без ввода следующего символа; кэш команд живёт
// 5 минут — повторное открытие чата после этого перечитывает их. Реальные
// виджеты `InputBar` и `BotCommandsMenuButton`.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/bot_commands_menu_button.dart';
import 'package:liza/pages/chat/input_bar.dart';
import 'package:liza/utils/bot_commands_registry.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/test_client.dart';

const _bot = '@shop:bots.liza.ru';
const _botRoom = '!botdm:x';

http.Response _commands() => http.Response(
  jsonEncode({
    'commands': [
      {'command': 'shop', 'description': 'Магазин'},
      {'command': 'leave', 'description': 'Отписаться'},
    ],
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

/// Подсказки InputBar берут `Matrix.of(context).client`; в тесте нет
/// смонтированного Matrix — отдаём тестовый клиент.
class _MatrixWithClient extends MatrixState {
  final Client testClient;
  _MatrixWithClient(this.testClient);

  @override
  Client get client => testClient;
}

void main() {
  final requests = <Uri>[];
  Completer<void>? gate;

  setUp(() {
    requests.clear();
    gate = null;
    BotCommandsRegistry.instance.reset();
    BotCommandsRegistry.instance.httpClient = MockClient((req) async {
      requests.add(req.url);
      if (gate != null) await gate!.future;
      return _commands();
    });
  });

  Future<(Client, Room)> setup(WidgetTester tester) async {
    late final Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
    client.rooms.clear();
    client.rooms.add(Room(id: _botRoom, client: client));
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        _bot: [_botRoom],
      },
    );
    return (client, client.getRoomById(_botRoom)!);
  }

  Widget app(Widget child, {MatrixState? matrix}) => MaterialApp(
    locale: const Locale('ru'),
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    home: Provider<MatrixState>.value(
      value: matrix ?? MatrixState(),
      child: Scaffold(
        body: Align(alignment: Alignment.bottomCenter, child: child),
      ),
    ),
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('кнопка меню появляется, когда команды приехали; список; выбор '
      'вставляет «/команда »', (tester) async {
    // AC:RL-bot-commands-safety-menu/3
    final (client, room) = await setup(tester);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final changed = <String>[];
    await tester.pumpWidget(
      app(
        BotCommandsMenuButton(
          room: room,
          controller: controller,
          onChanged: changed.add,
        ),
      ),
    );
    // L10n грузится отложенно (deferred) — даём ей подняться.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.menu), findsNothing, reason: 'команд ещё нет');

    await BotCommandsRegistry.instance.load(client, _bot);
    await tester.pump();
    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.byTooltip('Команды бота'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('/shop'), findsOneWidget);
    expect(find.text('Магазин'), findsOneWidget);
    expect(find.text('/leave'), findsOneWidget);

    await tester.tap(find.text('/shop'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(controller.text, '/shop ');
    expect(controller.selection.baseOffset, '/shop '.length);
    expect(changed, ['/shop ']);
  });

  testWidgets('чат не с ботом / бот без команд → кнопки нет', (tester) async {
    // AC:RL-bot-commands-safety-menu/3
    final (client, _) = await setup(tester);
    final group = Room(id: '!group:x', client: client);
    client.rooms.add(group);
    BotCommandsRegistry.instance.httpClient = MockClient(
      (_) async => http.Response(jsonEncode({'commands': []}), 200),
    );
    await BotCommandsRegistry.instance.load(client, _bot);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            BotCommandsMenuButton(
              room: client.getRoomById(_botRoom)!,
              controller: controller,
            ),
            BotCommandsMenuButton(room: group, controller: controller),
          ],
        ),
      ),
    );
    // L10n грузится отложенно (deferred) — даём ей подняться.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byIcon(Icons.menu), findsNothing);
  });

  testWidgets('«/» набран до загрузки команд → подсказки бота появляются, '
      'когда команды приехали, без ввода следующего символа', (tester) async {
    // AC:RL-bot-commands-safety-menu/4
    final (client, room) = await setup(tester);
    gate = Completer<void>();
    BotCommandsRegistry.instance.ensureLoaded(client, _bot);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      app(
        InputBar(
          room: room,
          controller: controller,
          focusNode: focus,
          minLines: 1,
          maxLines: 4,
          keyboardType: TextInputType.multiline,
          autofocus: true,
          onSubmitted: (_) {},
          onChanged: (_) {},
          decoration: const InputDecoration(),
          suggestionEmojis: const [],
        ),
        matrix: _MatrixWithClient(client),
      ),
    );
    // L10n грузится отложенно (deferred) — даём ей подняться.
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(find.byType(TextField), '/');
    await settle(tester);
    expect(find.text('/shop'), findsNothing);

    gate!.complete();
    await settle(tester);
    expect(find.text('/shop'), findsOneWidget);
    expect(find.text('Магазин'), findsOneWidget);
    expect(controller.text, '/', reason: 'текст не менялся');
  });

  test(
    'кэш 5 мин: повторное открытие чата в пределах TTL не ходит в сеть, '
    'после — перечитывает команды (setMyCommands виден без перезапуска)',
    () async {
      // AC:RL-bot-commands-safety-menu/5
      final client = await prepareTestClient(loggedIn: true);
      addTearDown(() => client.dispose(closeDatabase: true));
      var now = DateTime(2026, 10, 5, 12);
      final reg = BotCommandsRegistry.instance..now = () => now;
      final revisions = <int>[];
      void onRevision() => revisions.add(reg.revision.value);
      reg.revision.addListener(onRevision);
      addTearDown(() => reg.revision.removeListener(onRevision));

      reg.ensureLoaded(client, _bot);
      await reg.loading(client, _bot);
      expect(requests, hasLength(1));
      expect(reg.hasCommand(client, _bot, 'shop'), isTrue);

      now = now.add(const Duration(minutes: 4, seconds: 59));
      reg.ensureLoaded(client, _bot);
      expect(reg.loading(client, _bot), isNull);
      expect(requests, hasLength(1));

      reg.httpClient = MockClient((req) async {
        requests.add(req.url);
        return http.Response(
          jsonEncode({
            'commands': [
              {'command': 'new', 'description': 'Новая'},
            ],
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      now = now.add(const Duration(seconds: 2));
      reg.ensureLoaded(client, _bot);
      await reg.loading(client, _bot);
      expect(requests, hasLength(2));
      expect(reg.hasCommand(client, _bot, 'new'), isTrue);
      expect(reg.hasCommand(client, _bot, 'shop'), isFalse);
      expect(
        revisions,
        hasLength(2),
        reason: 'каждая загрузка бампает revision',
      );
    },
  );
}
