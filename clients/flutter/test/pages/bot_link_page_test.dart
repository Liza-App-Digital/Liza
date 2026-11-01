// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-deep-links
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/bot_link/bot_link_page.dart';
import 'package:liza/pages/bot_link/join_request_page.dart';
import 'package:liza/utils/bot_deep_link.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/widgets/matrix.dart';
import '../utils/test_client.dart';

class _MatrixWithClient extends MatrixState {
  final Client testClient;
  _MatrixWithClient(this.testClient);
  @override
  Client get client => testClient;
}

void main() {
  setUpAll(() async {
    for (final delegate in L10n.localizationsDelegates) {
      await delegate.load(const Locale('ru'));
    }
  });

  // AC:RL-bot-deep-links/7
  testWidgets(
    'поздний sync не вытесняет новый маршрут, busy очищается при возврате',
    (tester) async {
      late Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      addTearDown(client.dispose);
      final sync = Completer<bool>();
      var joined = 0;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => JoinRequestPage(
              roomId: '!private:example.test',
              joinRoom: (_, _) async {
                joined++;
              },
              awaitJoined: (_, _) => sync.future,
              apiFactory: (client) => BotInteractiveApi(
                client,
                transport: MockClient(
                  (_) async => http.Response(
                    '{"queries":[{"status":"consumed","outcome":"approve"}]}',
                    200,
                  ),
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Text('other route')),
          ),
          GoRoute(
            path: '/rooms/:id',
            builder: (_, _) => const Scaffold(body: Text('joined room')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _MatrixWithClient(client),
          child: MaterialApp.router(
            locale: const Locale('ru'),
            routerConfig: router,
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Вступить в чат'));
      await tester.pump();
      expect(joined, 1);
      unawaited(router.push('/other'));
      await tester.pumpAndSettle();
      sync.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('other route'), findsOneWidget);
      expect(find.text('joined room'), findsNothing);
      router.pop();
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Вступить в чат'),
      );
      expect(button.onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  // AC:RL-bot-deep-links/7
  testWidgets(
    'экран заявки опрашивает приватный HTTP и отменяет poll при dispose',
    (tester) async {
      late Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      addTearDown(client.dispose);
      var requests = 0;
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _MatrixWithClient(client),
          child: MaterialApp(
            locale: const Locale('ru'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: JoinRequestPage(
              roomId: '!private:example.test',
              apiFactory: (client) => BotInteractiveApi(
                client,
                transport: MockClient((request) async {
                  requests++;
                  expect(request.url.path, '/liza/interactive/join');
                  expect(
                    request.url.queryParameters['room_id'],
                    '!private:example.test',
                  );
                  expect(
                    request.headers['Authorization'],
                    'Bearer ${client.accessToken}',
                  );
                  return http.Response('{"queries":[]}', 200);
                }),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.text('Заявка на вступление'), findsOneWidget);
      expect(find.textContaining('Заявка отправлена'), findsOneWidget);
      expect(find.text('Пройти проверку бота'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      final before = requests;
      await tester.pump(const Duration(seconds: 3));
      expect(requests, before);
    },
  );
  // AC:RL-bot-deep-links/4
  testWidgets(
    'реальная страница показывает параметр и не создаёт DM до нажатия',
    (tester) async {
      late Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true);
      });
      addTearDown(client.dispose);
      final roomsBefore = client.rooms.map((room) => room.id).toList();
      final requests = <Uri>[];
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _MatrixWithClient(client),
          child: MaterialApp(
            locale: const Locale('ru'),
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: BotLinkPage(
              link: const BotDeepLink('shop_bot', parameter: 'order_123'),
              apiFactory: (client) => BotInteractiveApi(
                client,
                transport: MockClient((request) async {
                  requests.add(request.url);
                  return http.Response(
                    jsonEncode({
                      'registered': true,
                      'mxid': '@shop_bot:bots.liza.ru',
                      'name': 'Магазин',
                      'miniapps': <Object>[],
                    }),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  );
                }),
              ),
            ),
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(find.text('Магазин'), findsOneWidget);
      expect(find.textContaining('order_123'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Запустить'), findsOneWidget);
      expect(requests.length, 1);
      expect(client.rooms.map((room) => room.id).toList(), roomsBefore);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
