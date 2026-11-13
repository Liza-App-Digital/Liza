// ledger:RL-chat-details-capsules
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/chat_capsules_section.dart';

import '../../utils/test_client.dart';

void main() {
  late Room room;

  setUpAll(() async {
    final client = await prepareTestClient(loggedIn: true);
    room = Room(id: '!group:example.org', client: client);
  });

  Widget wrap(
    ChatCapsulesLoader loader, {
    ChatCapsuleActionRunner runAction = postChatCapsuleAction,
  }) => MaterialApp(
    localizationsDelegates: L10n.localizationsDelegates,
    supportedLocales: L10n.supportedLocales,
    locale: const Locale('ru'),
    home: Scaffold(
      body: SingleChildScrollView(
        child: ChatCapsulesSection(
          room: room,
          loader: loader,
          runAction: runAction,
        ),
      ),
    ),
  );

  Map<String, dynamic> row(String id, [Map<String, bool>? actions]) => {
    'id': id,
    'title': 'Капсула $id',
    'actions': ?actions,
  };

  ChatCapsules capsules(List<Map<String, dynamic>> rows) =>
      parseChatCapsules({'app_id': 'capsules', 'capsules': rows})!;

  /// Реальный [postChatCapsuleAction] поверх MockClient: проверяем и путь, и
  /// разбор статуса, а не подменённый результат.
  ChatCapsuleActionRunner mockRunner(
    List<http.Request> sent,
    http.Response Function() respond,
  ) =>
      (room, id, action) => postChatCapsuleAction(
        room,
        id,
        action,
        httpClient: MockClient((req) async {
          sent.add(req);
          return respond();
        }),
      );

  Future<void> openMenu(WidgetTester tester, String title) async {
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(ListTile, title),
        matching: find.byIcon(Icons.more_horiz),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'капсулы чата показаны списком со ссылкой на все [AC:RL-chat-details-capsules/1]',
    (tester) async {
      final items = [
        for (var i = 1; i <= 7; i++)
          ChatCapsule(
            id: 'c$i',
            title: 'Планёрка $i',
            startedAt: DateTime.utc(2026, 10, 28, 7),
            durationSec: 2110,
          ),
      ];
      await tester.pumpWidget(
        wrap((_) async => ChatCapsules('capsules', items)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Капсулы созвонов'), findsOneWidget);
      expect(find.text('Планёрка 1'), findsOneWidget);
      expect(find.text('Планёрка 5'), findsOneWidget);
      // Больше пяти не показываем — остальные в мини-аппе.
      expect(find.text('Планёрка 6'), findsNothing);
      expect(find.text('Все капсулы чата (7)'), findsOneWidget);
      expect(find.textContaining('36 мин'), findsNWidgets(5));
    },
  );

  testWidgets(
    'капсул нет — раздел есть, с пустым текстом [AC:RL-chat-details-capsules/2]',
    (tester) async {
      await tester.pumpWidget(
        wrap((_) async => const ChatCapsules('capsules', [])),
      );
      await tester.pumpAndSettle();
      expect(find.text('Капсул в этом чате пока нет.'), findsOneWidget);
      expect(find.text('Все капсулы чата (0)'), findsOneWidget);
    },
  );

  testWidgets(
    'капсулы выключены или нет почты — раздела нет [AC:RL-chat-details-capsules/3]',
    (tester) async {
      await tester.pumpWidget(wrap((_) async => null));
      await tester.pumpAndSettle();
      expect(find.text('Капсулы созвонов'), findsNothing);
    },
  );

  test('разбор ответа liza-bot-api [AC:RL-chat-details-capsules/3]', () {
    final ok = parseChatCapsules({
      'app_id': 'capsules',
      'capsules': [
        {
          'id': 'c1',
          'title': 'Планёрка',
          'started_at': '2026-10-28T07:00:00Z',
          'duration_sec': 2110,
        },
        {'title': 'без id'},
        'мусор',
      ],
    })!;
    expect(ok.items.map((c) => c.id), ['c1']);
    expect(ok.items.single.startedAt, DateTime.utc(2026, 10, 28, 7));
    expect(
      parseChatCapsules({
        'app_id': 'capsules',
        'capsules': [],
        'reason': 'no_email',
      }),
      isNull,
    );
    expect(parseChatCapsules({'capsules': []}), isNull);
  });

  test(
    'разбор actions: только true, без поля — пусто [AC:RL-chat-details-capsules/5]',
    () {
      final data = capsules([
        row('a', {
          'publish': true,
          'unpublish': false,
          'archive': true,
          'restore': false,
        }),
        row('b'),
      ]);
      expect(data.items[0].actions, {
        ChatCapsuleAction.publish,
        ChatCapsuleAction.archive,
      });
      expect(data.items[1].actions, isEmpty);
    },
  );

  testWidgets(
    'меню капсулы показывает ровно разрешённые действия [AC:RL-chat-details-capsules/5]',
    (tester) async {
      final data = capsules([
        row('a', {
          'publish': true,
          'unpublish': false,
          'archive': true,
          'restore': false,
        }),
        row('b', {
          'publish': false,
          'unpublish': true,
          'archive': false,
          'restore': true,
        }),
        row('c', {
          'publish': false,
          'unpublish': false,
          'archive': false,
          'restore': false,
        }),
        row('d'),
      ]);
      await tester.pumpWidget(wrap((_) async => data));
      await tester.pumpAndSettle();
      // Меню только у капсул, где есть хоть одно действие; старый сервер — без меню.
      expect(find.byIcon(Icons.more_horiz), findsNWidgets(2));
      for (final t in ['Капсула c', 'Капсула d']) {
        expect(
          find.descendant(
            of: find.widgetWithText(ListTile, t),
            matching: find.byIcon(Icons.more_horiz),
          ),
          findsNothing,
        );
      }

      await openMenu(tester, 'Капсула a');
      expect(find.text('Опубликовать'), findsOneWidget);
      expect(find.text('В архив'), findsOneWidget);
      expect(find.text('Снять с публикации'), findsNothing);
      expect(find.text('Вернуть из архива'), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await openMenu(tester, 'Капсула b');
      expect(find.text('Снять с публикации'), findsOneWidget);
      expect(find.text('Вернуть из архива'), findsOneWidget);
      expect(find.text('Опубликовать'), findsNothing);
      expect(find.text('В архив'), findsNothing);
    },
  );

  testWidgets(
    'действие шлёт POST на путь с room_id, после 2xx список перезапрошен [AC:RL-chat-details-capsules/6]',
    (tester) async {
      for (final (label, action, status) in [
        ('Опубликовать', 'publish', 204),
        ('Снять с публикации', 'unpublish', 200),
        ('Вернуть из архива', 'restore', 204),
      ]) {
        var loads = 0;
        final sent = <http.Request>[];
        await tester.pumpWidget(
          wrap((_) async {
            loads++;
            return capsules([
              row('c 1', {
                'publish': true,
                'unpublish': true,
                'archive': false,
                'restore': true,
              }),
            ]);
          }, runAction: mockRunner(sent, () => http.Response('', status))),
        );
        await tester.pumpAndSettle();
        expect(loads, 1);

        await openMenu(tester, 'Капсула c 1');
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        expect(sent, hasLength(1), reason: action);
        final req = sent.single;
        expect(req.method, 'POST');
        expect(req.url.path, '/liza/chat-capsules/c%201/$action');
        expect(req.url.queryParameters, {'room_id': room.id});
        expect(req.headers['Authorization'], startsWith('Bearer '));
        expect(loads, 2, reason: 'после $status список перезапрошен');
        expect(find.byType(SnackBar), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    '«В архив» — только после подтверждения [AC:RL-chat-details-capsules/7]',
    (tester) async {
      final sent = <http.Request>[];
      await tester.pumpWidget(
        wrap(
          (_) async => capsules([
            row('a', {
              'publish': false,
              'unpublish': false,
              'archive': true,
              'restore': false,
            }),
          ]),
          runAction: mockRunner(sent, () => http.Response('', 204)),
        ),
      );
      await tester.pumpAndSettle();

      await openMenu(tester, 'Капсула a');
      await tester.tap(find.text('В архив'));
      await tester.pumpAndSettle();
      expect(find.text('Переместить капсулу в архив?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);

      await openMenu(tester, 'Капсула a');
      await tester.tap(find.text('В архив'));
      await tester.pumpAndSettle();
      expect(find.text('Переместить капсулу в архив?'), findsOneWidget);
      await tester.tap(find.text('В архив').last);
      await tester.pumpAndSettle();
      expect(sent.single.url.path, '/liza/chat-capsules/a/archive');
    },
  );

  testWidgets(
    'пока запрос идёт, меню заблокировано [AC:RL-chat-details-capsules/7]',
    (tester) async {
      var calls = 0;
      final gate = Completer<ChatCapsuleActionResult>();
      await tester.pumpWidget(
        wrap(
          (_) async => capsules([
            row('a', {
              'publish': true,
              'unpublish': false,
              'archive': false,
              'restore': false,
            }),
          ]),
          runAction: (_, _, _) {
            calls++;
            return gate.future;
          },
        ),
      );
      await tester.pumpAndSettle();
      await openMenu(tester, 'Капсула a');
      await tester.tap(find.text('Опубликовать'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byIcon(Icons.more_horiz), findsNothing);
      expect(calls, 1);
      gate.complete(const ChatCapsuleActionResult(ChatCapsuleActionStatus.ok));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_horiz), findsOneWidget);
    },
  );

  testWidgets(
    'ошибки — SnackBar: 403 «нет прав», 503 «недоступен», 409 detail [AC:RL-chat-details-capsules/8]',
    (tester) async {
      for (final (status, body, text) in [
        (403, '{"code":"forbidden","detail":"x"}', 'Недостаточно прав'),
        (503, '', 'Сервис капсул недоступен'),
        (502, 'Bad Gateway', 'Сервис капсул недоступен'),
        (
          409,
          '{"detail":"Капсула уже опубликована"}',
          'Капсула уже опубликована',
        ),
        (404, 'not json', 'Ой, что-то пошло не так…'),
      ]) {
        var loads = 0;
        await tester.pumpWidget(
          wrap(
            (_) async {
              loads++;
              return capsules([
                row('a', {
                  'publish': true,
                  'unpublish': false,
                  'archive': false,
                  'restore': false,
                }),
              ]);
            },
            runAction: mockRunner(
              [],
              () => http.Response.bytes(utf8.encode(body), status),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openMenu(tester, 'Капсула a');
        await tester.tap(find.text('Опубликовать'));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget, reason: '$status');
        expect(loads, 1, reason: 'на ошибке список не перезапрашиваем');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    '409 с detail-объектом: no_folder — про папку, иной code — message, без message — общий [AC:RL-chat-details-capsules/10]',
    (tester) async {
      for (final (body, text) in [
        ('{"detail":{"code":"no_folder"}}', 'У чата нет папки для публикации'),
        (
          '{"detail":{"code":"no_folder","message":"No main folder"}}',
          'У чата нет папки для публикации',
        ),
        (
          '{"detail":{"code":"already_published","message":"Уже в папке"}}',
          'Уже в папке',
        ),
        ('{"detail":{"code":"other"}}', 'Ой, что-то пошло не так…'),
        ('{"detail":{"message":42}}', 'Ой, что-то пошло не так…'),
      ]) {
        var loads = 0;
        await tester.pumpWidget(
          wrap(
            (_) async {
              loads++;
              return capsules([
                row('a', {
                  'publish': true,
                  'unpublish': false,
                  'archive': false,
                  'restore': false,
                }),
              ]);
            },
            runAction: mockRunner(
              [],
              () => http.Response.bytes(utf8.encode(body), 409),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openMenu(tester, 'Капсула a');
        await tester.tap(find.text('Опубликовать'));
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget, reason: body);
        expect(loads, 1, reason: 'на ошибке список не перезапрашиваем');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );

  testWidgets(
    'новые тела 2xx не разбираются — список перезапрошен; лишние ключи строки не мешают [AC:RL-chat-details-capsules/11]',
    (tester) async {
      Map<String, dynamic> richRow() => {
        'id': 'a',
        'title': 'Капсула a',
        'published': true,
        'folders': [
          {'id': 'f1', 'title': 'Основная'},
        ],
        'actions': {
          'publish': true,
          'unpublish': true,
          'archive': true,
          'restore': true,
          'unbind': true,
        },
      };
      final parsed = capsules([richRow()]);
      expect(parsed.items.single.actions, ChatCapsuleAction.values.toSet());

      for (final (label, body) in [
        (
          'Опубликовать',
          '{"capsule_id":"a","published":true,"folders":["f1"],"changed":true}',
        ),
        (
          'Снять с публикации',
          '{"capsule_id":"a","published":false,"folders":[],"changed":false}',
        ),
        (
          'В архив',
          '{"id":"a","archived":true,"archived_at":"2026-11-13T10:00:00Z","purge_at":"2026-12-13T10:00:00Z"}',
        ),
        (
          'Вернуть из архива',
          '{"id":"a","archived":false,"archived_at":null,"purge_at":null}',
        ),
      ]) {
        var loads = 0;
        final sent = <http.Request>[];
        await tester.pumpWidget(
          wrap(
            (_) async {
              loads++;
              return capsules([richRow()]);
            },
            runAction: mockRunner(
              sent,
              () => http.Response.bytes(utf8.encode(body), 200),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await openMenu(tester, 'Капсула a');
        // Ровно четыре пункта: unbind клиент не показывает.
        expect(find.byType(PopupMenuItem<ChatCapsuleAction>), findsNWidgets(4));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        if (label == 'В архив') {
          await tester.tap(find.text('В архив').last);
          await tester.pumpAndSettle();
        }
        expect(sent, hasLength(1), reason: label);
        expect(loads, 2, reason: '$label: после 2xx список перезапрошен');
        expect(find.byType(SnackBar), findsNothing, reason: label);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    },
  );
}
