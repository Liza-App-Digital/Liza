// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-interactive-client
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_draft.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/bot_interactive_picker.dart';
import 'package:liza/widgets/interactive_bot_menu.dart';
import 'package:liza/widgets/interactive_query_result_dialog.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/widgets/interactive_bot_permissions.dart';
import '../../utils/test_client.dart';

Widget app(Widget child) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

http.Response response(Object data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
void main() {
  tearDown(() => BotInteractiveApi.transportFactory = http.Client.new);
  Future<(Client, Room)> setup(WidgetTester tester) async {
    late Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
    client.rooms.clear();
    final room = Room(
      id: '!group:hs',
      client: client,
      membership: Membership.join,
    );
    client.rooms.add(room);
    return (client, room);
  }

  testWidgets(
    'групповое меню: выбор бота, scoped команды, адресованная вставка без отправки',
    (tester) async {
      // AC:RL-bot-api-interactive-client/6
      final (client, room) = await setup(tester);
      final requests = <Uri>[];
      BotInteractiveApi.transportFactory = () => MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.endsWith('/room')) {
          return response({
            'bots': [
              {'registered': true, 'mxid': '@shop:hs'},
              {'registered': true, 'mxid': '@help:hs'},
            ],
          });
        }
        return response({
          'menu_button': {'type': 'commands'},
          'commands': [
            {'command': 'leave', 'description': 'Команда бота'},
          ],
        });
      });
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        app(
          InteractiveBotMenu(
            room: room,
            controller: controller,
            onChanged: (_) {},
            onOpenApp: (_) async {},
          ),
        ),
      );
      await settle(tester);
      await tester.tap(find.byIcon(Icons.menu));
      await settle(tester);
      await tester.tap(find.text('@shop:hs'));
      await settle(tester);
      await settle(tester);
      expect(find.text('/leave'), findsOneWidget);
      await tester.tap(find.text('/leave'));
      await settle(tester);
      expect(controller.text, '/leave@shop ');
      expect(
        BotInteractiveDraft.selectedCommand(client, room.id, '/leave@shop arg'),
        isTrue,
      );
      expect(
        BotInteractiveDraft.selectedCommand(client, '!other:hs', '/leave@shop'),
        isFalse,
      );
      final menu = requests.singleWhere((r) => r.path.endsWith('/menu'));
      expect(menu.queryParameters, {'mxid': '@shop:hs', 'room_id': room.id});
      await tester.pumpWidget(app(const SizedBox()));
    },
  );

  testWidgets(
    'prepared request_chat: явный выбор → submit; cancel без submit',
    (tester) async {
      // AC:RL-bot-api-interactive-client/7
      final (client, room) = await setup(tester);
      client.rooms.add(
        Room(id: '!other:hs', client: client, membership: Membership.join),
      );
      final submitted = <Map<String, dynamic>>[];
      BotInteractiveApi.transportFactory = () => MockClient((request) async {
        if (request.url.path.contains('/prepared/')) {
          return response({
            'kind': 'prepared_keyboard',
            'query_id': 'q',
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 1))
                    .millisecondsSinceEpoch /
                1000,
            'button': {
              'text': 'Группа',
              'request_chat': {'request_id': 1, 'chat_is_channel': false},
            },
          });
        }
        if (request.url.path.endsWith('/submit')) {
          submitted.add(jsonDecode(request.body) as Map<String, dynamic>);
        }
        return response({'ok': true});
      });
      late BuildContext context;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await settle(tester);
      var future = handlePreparedBotRequest(
        context: context,
        client: client,
        room: room,
        preparedId: 'p',
        sessionId: 'session',
        isCurrent: () => true,
      );
      await settle(tester);
      expect(submitted, isEmpty);
      await tester.tap(find.text('!other:hs'));
      await settle(tester);
      await tester.tap(find.text(L10n.of(context).send));
      await settle(tester);
      expect(await future, isTrue);
      expect(submitted.single['selection'], {'chat_id': '!other:hs'});
      submitted.clear();
      future = handlePreparedBotRequest(
        context: context,
        client: client,
        room: room,
        preparedId: 'p2',
        sessionId: 'session',
        isCurrent: () => true,
      );
      await settle(tester);
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect(await future, isFalse);
      expect(submitted, isEmpty);
    },
  );

  testWidgets(
    'права приглашения: пресеты владельца 0/50/99, отмена не выбирает уровень',
    (tester) async {
      // AC:RL-bot-api-interactive-client/8
      // AC:RL-bot-api-interactive-client/13
      final (client, room) = await setup(tester);
      room.setState(
        Event(
          type: EventTypes.RoomPowerLevels,
          content: {
            'users': {client.userID: 100},
            'state_default': 50,
          },
          eventId: r'$pl',
          senderId: client.userID!,
          originServerTs: DateTime.now(),
          stateKey: '',
          room: room,
        ),
      );
      late BuildContext context;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (c) {
              context = c;
              return const SizedBox();
            },
          ),
        ),
      );
      await settle(tester);
      final bot = RegisteredBot.parse({
        'registered': true,
        'mxid': '@shop:hs',
        'default_administrator_rights': {
          'group': {'can_manage_chat': true},
          'channel': {'can_manage_chat': false},
        },
      })!;
      final initialPowers = Map.of(
        room.getState(EventTypes.RoomPowerLevels)!.content,
      );
      var future = chooseBotInvitePermissions(
        context: context,
        room: room,
        botMxid: '@shop:hs',
        bot: bot,
        isCurrent: () => true,
      );
      await settle(tester);
      final strings = L10n.of(context);
      expect(find.text(strings.botRequestsPermissions), findsOneWidget);
      expect(find.text(strings.normalUser), findsOneWidget);
      expect(find.text(strings.moderator), findsOneWidget);
      expect(find.text(strings.admin), findsOneWidget);
      await tester.tap(find.text(strings.normalUser));
      await settle(tester);
      expect(await future, 0);
      expect(room.getState(EventTypes.RoomPowerLevels)!.content, initialPowers);
      room.setState(
        Event(
          type: EventTypes.RoomCreate,
          content: {'com.liza.chat.type': channelChatType},
          eventId: r'$channel',
          senderId: client.userID!,
          originServerTs: DateTime.now(),
          stateKey: '',
          room: room,
        ),
      );
      expect(room.isChannel, isTrue);
      future = chooseBotInvitePermissions(
        context: context,
        room: room,
        botMxid: '@shop:hs',
        bot: bot,
        isCurrent: () => true,
      );
      await settle(tester);
      expect(find.text(strings.botRequestsPermissions), findsNothing);
      Navigator.of(context, rootNavigator: true).pop();
      await settle(tester);
      expect(await future, isNull);
      expect(room.getState(EventTypes.RoomPowerLevels)!.content, initialPowers);
    },
  );

  testWidgets(
    'меню обновляет тот же Room после membership и временной ошибки',
    (tester) async {
      // AC:RL-bot-api-interactive-client/12
      final (_, room) = await setup(tester);
      var requests = 0;
      BotInteractiveApi.transportFactory = () => MockClient((r) async {
        requests++;
        if (requests == 2) return http.Response('{}', 503);
        return response({
          'bots': requests == 1
              ? []
              : [
                  {'registered': true, 'mxid': '@new:hs'},
                ],
        });
      });
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      Widget menu() => app(
        InteractiveBotMenu(
          room: room,
          controller: controller,
          onChanged: (_) {},
          onOpenApp: (_) async {},
        ),
      );
      await tester.pumpWidget(menu());
      await settle(tester);
      expect(find.byIcon(Icons.menu), findsNothing);
      room.setState(
        Event(
          type: EventTypes.RoomMember,
          content: {'membership': 'join'},
          eventId: r'$join',
          senderId: '@new:hs',
          stateKey: '@new:hs',
          originServerTs: DateTime.now(),
          room: room,
        ),
      );
      await tester.pumpWidget(menu());
      await settle(tester);
      expect(requests, 2);
      expect(find.byIcon(Icons.menu), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await settle(tester);
      expect(requests, 3);
      expect(find.byIcon(Icons.menu), findsOneWidget);
      await tester.pumpWidget(menu());
      await settle(tester);
      expect(requests, 3, reason: 'Обычный rebuild не создаёт HTTP запрос');
      await tester.pumpWidget(app(const SizedBox()));
    },
  );

  testWidgets('prepared/WebApp диалог сохраняет выбор для send и ACK retry', (
    tester,
  ) async {
    // AC:RL-bot-api-inline-queries-client/6
    final (client, _) = await setup(tester);
    var selects = 0;
    var acks = 0;
    final txids = <String>[];
    final content = {'msgtype': 'm.text', 'body': 'Результат'};
    final api = BotInteractiveApi(
      client,
      transport: MockClient((r) async {
        if (r.url.path.endsWith('/select')) {
          if (++selects > 1) return http.Response('{}', 400);
          return response({'selection_id': 's', 'content': content});
        }
        if (r.url.path.endsWith('/ack') && ++acks == 1) {
          return http.Response('{}', 503);
        }
        return response({'ok': true});
      }),
    );
    addTearDown(api.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    await settle(tester);
    final pending = showInteractiveConsent<bool>(
      context: context,
      isCurrent: () => true,
      builder: (_) => InteractiveQueryResultDialog(
        api: api,
        queryId: 'q',
        sessionId: 'session',
        results: [
          {'id': 'r', 'content': content},
        ],
        isCurrent: () => true,
        send: (_, txid) async {
          txids.add(txid);
          return txids.length == 1 ? null : r'$sent';
        },
      ),
    );
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('Результат'));
      await settle(tester);
      if (i < 2) {
        expect(find.text(L10n.of(context).tryToSendAgain), findsOneWidget);
      }
    }
    expect(await pending, isTrue);
    expect(selects, 1);
    expect(acks, 2);
    expect(txids.length, 2);
    expect(txids.toSet(), hasLength(1));
  });
}
