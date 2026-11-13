// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-inline-queries-client
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_inline.dart';
import 'test_client.dart';

void main() {
  Future<Client> setup(WidgetTester tester) async {
    late Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
    return client;
  }

  http.Response response(Object json) => http.Response(
    jsonEncode(json),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
  final content = {'msgtype': 'm.text', 'body': 'Выбранный результат'};

  testWidgets(
    'private query: debounce, выбор, whitelist, ненулевой event ID → ack',
    (tester) async {
      // AC:RL-bot-api-inline-queries-client/1
      final client = await setup(tester);
      final requests = <http.Request>[];
      final sends = <Map<String, dynamic>>[];
      final api = BotInteractiveApi(
        client,
        transport: MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path.endsWith('/descriptor')) {
            return response({'registered': true, 'mxid': '@shop:hs'});
          }
          if (path.endsWith('/query')) {
            return response({
              'query_id': 'q',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(minutes: 1))
                      .millisecondsSinceEpoch /
                  1000,
            });
          }
          if (path.endsWith('/select')) {
            return response({
              'selection_id': 'abcdefghijklmnop',
              'content': {
                ...content,
                'sender': '@spoof:hs',
                'com.liza.inline_selection': 'abcdefghijklmnop',
              },
            });
          }
          if (path.endsWith('/q')) {
            return response({
              'status': 'answered',
              'results': [
                {'id': 'r', 'title': 'Выбор', 'content': content},
              ],
            });
          }
          return response({'ok': true});
        }),
      );
      final controller = BotInlineController(
        api: api,
        roomId: '!room:hs',
        send: (c, txid) async {
          sends.add(c);
          return r'$sent';
        },
      );
      controller.update('@shop a');
      controller.update('@shop ab');
      await tester.pump(const Duration(milliseconds: 349));
      expect(requests, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      await tester.pump();
      expect(
        controller.results,
        hasLength(1),
        reason:
            'failed=${controller.failed} loading=${controller.loading} requests=${requests.map((r) => r.url.path).toList()}',
      );
      expect(sends, isEmpty);
      final chosen = controller.choose(controller.results.single);
      await tester.pump();
      await tester.pump();
      expect(await chosen, isTrue);
      expect(sends.single, {
        ...content,
        'com.liza.inline_selection': 'abcdefghijklmnop',
      });
      expect(
        requests.where((r) => r.url.path.endsWith('/query')),
        hasLength(1),
      );
      expect(
        jsonDecode(
          requests.firstWhere((r) => r.url.path.endsWith('/query')).body,
        )['query'],
        'ab',
      );
      expect(requests.where((r) => r.url.path.endsWith('/ack')), hasLength(1));
      controller.dispose();
    },
  );

  testWidgets(
    'бот без inline-подписки: запроса нет, индикатор гаснет, отправка свободна',
    (tester) async {
      // Смоук @liza 13.11: «@Liza текст» в начале строки крутил индикатор и не отправлялся.
      final client = await setup(tester);
      final requests = <http.Request>[];
      final api = BotInteractiveApi(
        client,
        transport: MockClient((request) async {
          requests.add(request);
          return response({
            'registered': true,
            'mxid': '@liza:hs',
            'supports_inline_queries': false,
          });
        }),
      );
      final controller = BotInlineController(
        api: api,
        roomId: '!room:hs',
        send: (c, txid) async => r'$sent',
      );
      controller.update('@liza скажи что-нибудь');
      expect(controller.loading, isTrue);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      await tester.pump();
      expect(controller.loading, isFalse);
      expect(controller.recognisedBot, isFalse);
      expect(controller.results, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/query')), isEmpty);
      controller.dispose();
    },
  );

  testWidgets('stale создание и dispose отменяют query; никакой отправки', (
    tester,
  ) async {
    // AC:RL-bot-api-inline-queries-client/2
    final client = await setup(tester);
    final gate = Completer<http.Response>();
    final requests = <http.Request>[];
    var sends = 0;
    final api = BotInteractiveApi(
      client,
      transport: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/descriptor')) {
          return response({'registered': true, 'mxid': '@shop:hs'});
        }
        if (request.url.path.endsWith('/query')) return gate.future;
        return response({'ok': true});
      }),
    );
    final controller = BotInlineController(
      api: api,
      roomId: '!room:hs',
      send: (_, txid) async {
        sends++;
        return r'$sent';
      },
    );
    controller.update('@shop a');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    controller.update('обычный текст');
    gate.complete(
      response({
        'query_id': 'old',
        'expires_at':
            DateTime.now()
                .add(const Duration(minutes: 1))
                .millisecondsSinceEpoch /
            1000,
      }),
    );
    await tester.pump();
    await tester.pump();
    expect(
      requests.where((r) => r.url.path.endsWith('/old/cancel')),
      hasLength(1),
    );
    expect(controller.results, isEmpty);
    expect(sends, 0);
    controller.dispose();
  });

  testWidgets('null event ID никогда не выдаёт chosen ack', (tester) async {
    // AC:RL-bot-api-inline-queries-client/3
    final client = await setup(tester);
    final paths = <String>[];
    final api = BotInteractiveApi(
      client,
      transport: MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.endsWith('/descriptor')) {
          return response({'registered': true, 'mxid': '@shop:hs'});
        }
        if (r.url.path.endsWith('/query')) {
          return response({
            'query_id': 'q',
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 1))
                    .millisecondsSinceEpoch /
                1000,
          });
        }
        if (r.url.path.endsWith('/select')) {
          return response({'selection_id': 's', 'content': content});
        }
        if (r.url.path.endsWith('/q')) {
          return response({
            'status': 'answered',
            'results': [
              {'id': 'r', 'title': 'Выбор', 'content': content},
            ],
          });
        }
        return response({'ok': true});
      }),
    );
    final controller = BotInlineController(
      api: api,
      roomId: '!room:hs',
      send: (_, txid) async => null,
    );
    controller.update('@shop a');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final chosen = controller.choose(controller.results.single);
    await tester.pump();
    expect(await chosen, isFalse);
    expect(paths.any((p) => p.endsWith('/ack')), isFalse);
    controller.dispose();
    await tester.pump();
  });
  testWidgets(
    'старый select, чужой result и смена токена не отправляют сообщение',
    (tester) async {
      // AC:RL-bot-api-inline-queries-client/4
      final client = await setup(tester);
      final gate = Completer<http.Response>();
      var sends = 0;
      final api = BotInteractiveApi(
        client,
        transport: MockClient((r) async {
          if (r.url.path.endsWith('/descriptor')) {
            return response({'registered': true, 'mxid': '@shop:hs'});
          }
          if (r.url.path.endsWith('/query')) {
            return response({
              'query_id': 'q',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(minutes: 1))
                      .millisecondsSinceEpoch /
                  1000,
            });
          }
          if (r.url.path.endsWith('/select')) return gate.future;
          if (r.url.path.endsWith('/q')) {
            return response({
              'status': 'answered',
              'results': [
                {'id': 'r', 'title': 'Выбор', 'content': content},
              ],
            });
          }
          return response({'ok': true});
        }),
      );
      final controller = BotInlineController(
        api: api,
        roomId: '!room:hs',
        send: (_, txid) async {
          sends++;
          return r'$sent';
        },
      );
      controller.update('@shop a');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(
        await controller.choose(BotInlineResult('foreign', 'Чужой', content)),
        isFalse,
      );
      final chosen = controller.choose(controller.results.single);
      await tester.pump();
      controller.update('другой текст');
      gate.complete(response({'selection_id': 's', 'content': content}));
      await tester.pump();
      expect(await chosen, isFalse);
      expect(sends, 0);
      client.accessToken = 'new-session';
      expect(api.isCurrent, isFalse);
      expect(
        await controller.choose(BotInlineResult('r', 'Выбор', content)),
        isFalse,
      );
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'повтор null-send и ACK: один select, стабильный txid, без дубля',
    (tester) async {
      // AC:RL-bot-api-inline-queries-client/6
      final client = await setup(tester);
      var selects = 0;
      var acks = 0;
      final txids = <String>[];
      final api = BotInteractiveApi(
        client,
        transport: MockClient((r) async {
          final path = r.url.path;
          if (path.endsWith('/descriptor')) {
            return response({'registered': true, 'mxid': '@shop:hs'});
          }
          if (path.endsWith('/query')) {
            return response({
              'query_id': 'q',
              'expires_at':
                  DateTime.now()
                      .add(const Duration(minutes: 1))
                      .millisecondsSinceEpoch /
                  1000,
            });
          }
          if (path.endsWith('/q')) {
            return response({
              'status': 'answered',
              'results': [
                {'id': 'r', 'title': 'Выбор', 'content': content},
              ],
            });
          }
          if (path.endsWith('/select')) {
            if (++selects > 1) return http.Response('{}', 400);
            return response({'selection_id': 's', 'content': content});
          }
          if (path.endsWith('/ack') && ++acks == 1) {
            return http.Response('{}', 503);
          }
          return response({'ok': true});
        }),
      );
      final controller = BotInlineController(
        api: api,
        roomId: '!room:hs',
        send: (_, txid) async {
          txids.add(txid);
          return txids.length == 1 ? null : r'$sent';
        },
      );
      controller.update('@shop q');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      final result = controller.results.single;
      for (var attempt = 0; attempt < 3; attempt++) {
        final chosen = controller.choose(result);
        await tester.pump();
        await tester.pump();
        expect(await chosen, attempt == 2);
        if (attempt < 2) expect(controller.results.single, same(result));
      }
      expect(selects, 1);
      expect(txids, hasLength(2));
      expect(txids.toSet(), hasLength(1));
      expect(acks, 2);
      expect(controller.results, isEmpty);
      controller.dispose();
    },
  );

  testWidgets('завершение старой отправки не стирает новые результаты', (
    tester,
  ) async {
    // AC:RL-bot-api-inline-queries-client/6
    final client = await setup(tester);
    var queries = 0;
    final acknowledgements = <String>[];
    final sent = Completer<String?>();
    final api = BotInteractiveApi(
      client,
      transport: MockClient((r) async {
        if (r.url.path.endsWith('/descriptor')) {
          return response({'registered': true, 'mxid': '@shop:hs'});
        }
        if (r.url.path.endsWith('/query')) {
          return response({
            'query_id': 'q${++queries}',
            'expires_at':
                DateTime.now()
                    .add(const Duration(minutes: 1))
                    .millisecondsSinceEpoch /
                1000,
          });
        }
        if (r.url.path.endsWith('/select')) {
          return response({'selection_id': 's', 'content': content});
        }
        if (r.method == 'GET') {
          return response({
            'status': 'answered',
            'results': [
              {
                'id': 'r$queries',
                'title': 'Выбор $queries',
                'content': content,
              },
            ],
          });
        }
        if (r.url.path.endsWith('/ack')) {
          acknowledgements.add(r.url.path);
        }
        return response({'ok': true});
      }),
    );
    final controller = BotInlineController(
      api: api,
      roomId: '!room:hs',
      send: (_, txid) => sent.future,
    );
    controller.update('@shop old');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    final old = controller.choose(controller.results.single);
    await tester.pump();
    controller.update('@shop new');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(controller.results.single.id, 'r2');
    sent.complete(r'$old');
    await tester.pump();
    expect(await old, isFalse);
    expect(controller.results.single.id, 'r2');
    expect(controller.failed, isFalse);
    expect(acknowledgements.single, endsWith('/q1/ack'));
    controller.dispose();
    await tester.pump();
  });

  for (final invalidation in ['account', 'dispose']) {
    testWidgets(
      'pending send после $invalidation не подтверждает и не повторяется',
      (tester) async {
        // AC:RL-bot-api-inline-queries-client/6
        final client = await setup(tester);
        final sent = Completer<String?>();
        final cancel = Completer<http.Response>();
        var cancelling = false;
        var sends = 0;
        var acks = 0;
        final api = BotInteractiveApi(
          client,
          transport: MockClient((r) async {
            if (r.url.path.endsWith('/descriptor')) {
              return response({'registered': true, 'mxid': '@shop:hs'});
            }
            if (r.url.path.endsWith('/query')) {
              return response({
                'query_id': 'q',
                'expires_at':
                    DateTime.now()
                        .add(const Duration(minutes: 1))
                        .millisecondsSinceEpoch /
                    1000,
              });
            }
            if (r.url.path.endsWith('/select')) {
              return response({'selection_id': 's', 'content': content});
            }
            if (r.method == 'GET') {
              return response({
                'status': 'answered',
                'results': [
                  {'id': 'r', 'title': 'Выбор', 'content': content},
                ],
              });
            }
            if (r.url.path.endsWith('/cancel')) {
              cancelling = true;
              return cancel.future;
            }
            if (r.url.path.endsWith('/ack')) {
              acks++;
            }
            return response({'ok': true});
          }),
        );
        final controller = BotInlineController(
          api: api,
          roomId: '!room:hs',
          send: (_, txid) {
            sends++;
            return sent.future;
          },
        );
        controller.update('@shop q');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump();
        final pending = controller.choose(controller.results.single);
        await tester.pump();
        if (invalidation == 'account') {
          client.accessToken = 'new-token';
        } else {
          controller.dispose();
          await tester.pump();
        }
        if (invalidation == 'dispose') {
          expect(cancelling, isTrue);
          expect(
            api.isCurrent,
            isTrue,
            reason: 'cancel ещё удерживает открытый API',
          );
        }
        sent.complete(r'$sent');
        await tester.pump();
        expect(await pending, isFalse);
        final acksBeforeCancel = acks;
        cancel.complete(response({'ok': true}));
        await tester.pump();
        expect(sends, 1);
        expect(
          acksBeforeCancel,
          0,
          reason:
              'dispose запрещает ACK немедленно, даже пока cancel ждёт HTTP',
        );
        expect(acks, 0);
        if (invalidation == 'account') {
          controller.dispose();
          await tester.pump();
        }
      },
    );
  }
}
