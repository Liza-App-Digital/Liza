// ignore_for_file: depend_on_referenced_packages
// ledger:RL-bot-api-interactive-client
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matrix/matrix.dart';
import 'package:geolocator/geolocator.dart';
import 'package:matrix/src/models/timeline_chunk.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/utils/bot_interactive_markup.dart';
import 'package:liza/utils/bot_interactive_keyboard_state.dart';
import 'package:liza/widgets/interactive_bot_composer.dart';
import '../../utils/test_client.dart';

class _HeldLocation extends GeolocatorPlatform {
  final position = Completer<Position>();
  bool requested = false;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) {
    requested = true;
    return position.future;
  }
}

class _KeyboardStateApi extends FakeMatrixApi {
  final values = <String, Map<String, dynamic>>{};
  final writes = <Map<String, dynamic>>[];
  bool failWrites = false;
  Completer<void>? holdRead;
  int reads = 0;
  @override
  Future<http.Response> mockIntercept(http.Request request) async {
    if (!request.url.path.endsWith(
      '/account_data/${BotInteractiveKeyboardState.eventType}',
    )) {
      return super.mockIntercept(request);
    }
    final key = '${request.headers['authorization']}:${request.url.path}';
    if (request.method == 'GET') {
      reads++;
      await holdRead?.future;
      final content = values[key];
      return http.Response(
        jsonEncode(
          content ?? {'errcode': 'M_NOT_FOUND', 'error': 'No fixture data'},
        ),
        content == null ? 404 : 200,
      );
    }
    final content = jsonDecode(request.body) as Map<String, dynamic>;
    writes.add(content);
    if (failWrites) {
      return http.Response('{"errcode":"M_UNKNOWN","error":"offline"}', 503);
    }
    values[key] = content;
    return http.Response('{}', 200);
  }
}

class _PhoneApi extends FakeMatrixApi {
  List<Map<String, dynamic>> identifiers = [];
  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (request.url.path.endsWith('/account/3pid')) {
      return http.Response(
        jsonEncode({'threepids': identifiers}),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return super.mockIntercept(request);
  }
}

Widget app(Widget child) => MaterialApp(
  locale: const Locale('ru'),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  // Мок-HTTP не отвечает в fake-async: дожидаемся 5-секундного таймаута restore.
  await tester.pump(const Duration(seconds: 6));
  await tester.pump();
}

/// Фоновый restore() личной клавиатуры держит 5-секундный таймаут чтения.
Future<void> unmount(WidgetTester tester) async {
  await tester.pumpWidget(app(const SizedBox()));
  await tester.pump(const Duration(seconds: 6));
}

void main() {
  tearDown(() => BotInteractiveApi.transportFactory = http.Client.new);

  test(
    'typed markup отклоняет конфликтующие/неподдержанные действия и произвольный JSON',
    () {
      // AC:RL-bot-api-interactive-client/1
      expect(
        BotKeyboardButton.parse({
          'text': 'x',
          'request_contact': true,
          'request_location': true,
        }),
        isNull,
      );
      expect(
        BotKeyboardButton.parse({'text': {}, 'request_contact': true}),
        isNull,
      );
      expect(
        BotKeyboardButton.parse({
          'text': 'x',
          'request_managed_bot': {'request_id': 1},
        }),
        isNull,
      );
      expect(
        safeInlineContent({
          'msgtype': 'm.room.member',
          'body': 'x',
          'state_key': '@admin:hs',
        }),
        isNull,
      );
      expect(
        safeInlineContent({
          'msgtype': 'm.text',
          'body': 'ok',
          'sender': '@spoof:hs',
          'm.relates_to': {'event_id': 'bad'},
        }),
        {'msgtype': 'm.text', 'body': 'ok'},
      );
    },
  );

  testWidgets(
    'контакт: конкретный номер и получатель, выбор, отмена и отсутствие номера',
    (tester) async {
      // AC:RL-bot-api-interactive-client/2
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
      var outcome = requestBotContactFromPhones(
        context: context,
        recipient: '@shop:hs',
        loadPhones: () async => [
          '+79990000001',
          '+79990000002',
          'email@example.com',
        ],
        isCurrent: () => true,
      );
      await settle(tester);
      expect(find.textContaining('@shop:hs'), findsOneWidget);
      expect(find.text('+79990000001'), findsOneWidget);
      expect(find.text('+79990000002'), findsOneWidget);
      expect(find.text('email@example.com'), findsNothing);
      await tester.tap(find.text('+79990000002'));
      await settle(tester);
      final result = await outcome;
      expect(result.status, BotContactStatus.granted);
      expect(result.content?['com.liza.contact'], {
        'phone_number': '+79990000002',
        'first_name': 'Контакт',
      });
      outcome = requestBotContactFromPhones(
        context: context,
        recipient: '@shop:hs',
        loadPhones: () async => ['+79990000001'],
        isCurrent: () => true,
      );
      await settle(tester);
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect((await outcome).content, isNull);
      expect(
        (await requestBotContactFromPhones(
          context: context,
          recipient: '@shop:hs',
          loadPhones: () async => [],
          isCurrent: () => true,
        )).status,
        BotContactStatus.unavailable,
      );
    },
  );

  testWidgets(
    'контакт: stale после загрузки, смена контекста и TTL не дают ПДн',
    (tester) async {
      // AC:RL-bot-api-interactive-client/3
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
      var current = true;
      final gate = Completer<List<String>>();
      final delayed = requestBotContactFromPhones(
        context: context,
        recipient: '@shop:hs',
        loadPhones: () => gate.future,
        isCurrent: () => current,
      );
      current = false;
      gate.complete(['+79990000001']);
      await settle(tester);
      expect((await delayed).status, BotContactStatus.denied);
      expect(find.byType(AlertDialog), findsNothing);
      current = true;
      final open = requestBotContactFromPhones(
        context: context,
        recipient: '@shop:hs',
        loadPhones: () async => ['+79990000001'],
        isCurrent: () => current,
      );
      await settle(tester);
      current = false;
      await tester.pump(const Duration(milliseconds: 250));
      await settle(tester);
      expect((await open).content, isNull);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'источник контакта: account3PIDs msisdn; email не подставляется',
    (tester) async {
      // AC:RL-bot-api-interactive-client/2
      final api = _PhoneApi();
      late Client client;
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true, httpClient: api);
      });
      addTearDown(client.dispose);
      api.identifiers = [
        {
          'medium': 'email',
          'address': 'mail@example.com',
          'added_at': 1,
          'validated_at': 1,
        },
      ];
      final withoutPhone = await tester.runAsync(
        () => loadBotContactPhones(client),
      );
      expect(withoutPhone, isEmpty);
      api.identifiers.add({
        'medium': 'msisdn',
        'address': '79990000001',
        'added_at': 1,
        'validated_at': 1,
      });
      final phones = await tester.runAsync(() => loadBotContactPhones(client));
      expect(phones, ['79990000001']);
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
      final result = requestBotContactFromPhones(
        context: context,
        recipient: '@shop:hs',
        loadPhones: () async => phones!,
        isCurrent: () => true,
      );
      await settle(tester);
      expect(find.text('79990000001'), findsOneWidget);
      expect(find.text('mail@example.com'), findsNothing);
      await tester.tap(find.text('Отмена'));
      await settle(tester);
      expect((await result).content, isNull);
    },
  );

  Future<(Client, Room, TextEditingController)> setup(
    WidgetTester tester,
  ) async {
    late Client client;
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
    final room = Room(id: '!1234:fakeServer.notExisting', client: client);
    client.rooms.add(room);
    final text = TextEditingController();
    addTearDown(text.dispose);
    return (client, room, text);
  }

  Event keyboard(
    Room room,
    String id,
    Object markup, {
    String sender = '@shop:hs',
  }) => Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: sender,
    originServerTs: DateTime.now(),
    content: {
      'msgtype': 'm.text',
      'body': 'Choose',
      'com.liza.bot_markup': markup,
    },
  );

  testWidgets('реальный composer: реестр, replacement/remove и ForceReply', (
    tester,
  ) async {
    // AC:RL-bot-api-interactive-client/4
    final (_, room, text) = await setup(tester);
    BotInteractiveApi.transportFactory = () => MockClient(
      (request) async => http.Response(
        jsonEncode({
          'registered': request.url.queryParameters['mxid'] == '@shop:hs',
          'mxid': request.url.queryParameters['mxid'],
        }),
        200,
      ),
    );
    final replies = <Event>[];
    Timeline makeTimeline(List<Event> events) {
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: events),
      );
      addTearDown(timeline.cancelSubscriptions);
      return timeline;
    }

    Future<void> pump(List<Event> events) async {
      await tester.pumpWidget(
        app(
          InteractiveBotComposer(
            room: room,
            timeline: makeTimeline(events),
            controller: text,
            onForceReply: replies.add,
            onOpenApp: (_) async {},
            onSent: () {},
          ),
        ),
      );
      await settle(tester);
    }

    final request = keyboard(room, r'$k', {
      'keyboard': [
        [
          {'text': 'Телефон', 'request_contact': true},
        ],
      ],
    });
    await pump([request]);
    expect(find.widgetWithText(OutlinedButton, 'Телефон'), findsOneWidget);
    await pump([
      keyboard(room, r'$remove', {'remove_keyboard': true}),
      request,
    ]);
    expect(find.widgetWithText(OutlinedButton, 'Телефон'), findsNothing);
    await pump([
      keyboard(room, r'$spoof', {
        'keyboard': [
          ['Spoof'],
        ],
      }, sender: '@human:hs'),
    ]);
    expect(find.widgetWithText(OutlinedButton, 'Spoof'), findsNothing);
    await pump([
      keyboard(room, r'$reply', {'force_reply': true}),
    ]);
    expect(replies.map((e) => e.eventId), [r'$reply']);
    await unmount(tester);
  });

  for (final (status, remains) in [
    (EventStatus.error, true),
    (EventStatus.sending, true),
    (EventStatus.sent, false),
    (EventStatus.synced, false),
  ]) {
    testWidgets(
      'one_time reentry: ${status.name} ${remains ? "сохраняет" : "закрывает"} клавиатуру',
      (tester) async {
        // AC:RL-bot-api-interactive-client/18
        final (client, room, controller) = await setup(tester);
        BotInteractiveApi.transportFactory = () => MockClient(
          (_) async => http.Response(
            jsonEncode({'registered': true, 'mxid': '@shop:hs'}),
            200,
          ),
        );
        final request = keyboard(room, r'$one-time', {
          'keyboard': [
            [
              {'text': 'Повторить ответ'},
            ],
          ],
          'one_time_keyboard': true,
        });
        final reply = Event(
          room: room,
          eventId: r'$reply',
          type: EventTypes.Message,
          senderId: client.userID!,
          originServerTs: request.originServerTs.add(
            const Duration(seconds: 1),
          ),
          status: status,
          content: {
            'msgtype': 'm.text',
            'body': 'Повторить ответ',
            'm.relates_to': {
              'm.in_reply_to': {'event_id': request.eventId},
            },
          },
        );
        Future<void> mount(List<Event> events) async {
          final timeline = Timeline(
            room: room,
            chunk: TimelineChunk(events: events),
          );
          addTearDown(timeline.cancelSubscriptions);
          await tester.pumpWidget(
            app(
              InteractiveBotComposer(
                key: UniqueKey(),
                room: room,
                timeline: timeline,
                controller: controller,
                onForceReply: (_) {},
                onOpenApp: (_) async {},
                onSent: () {},
              ),
            ),
          );
          await settle(tester);
        }

        await mount([request]);
        expect(
          find.widgetWithText(OutlinedButton, 'Повторить ответ'),
          findsOneWidget,
        );
        await unmount(tester);
        await mount([reply, request]);
        expect(
          find.widgetWithText(OutlinedButton, 'Повторить ответ'),
          remains ? findsOneWidget : findsNothing,
        );
        await unmount(tester);
      },
    );
  }

  testWidgets(
    'one_time видит подтверждённый manual reply и error→sent без remount',
    (tester) async {
      // AC:RL-bot-api-interactive-client/18
      final (client, room, controller) = await setup(tester);
      BotInteractiveApi.transportFactory = () => MockClient(
        (_) async => http.Response(
          jsonEncode({'registered': true, 'mxid': '@shop:hs'}),
          200,
        ),
      );
      final request = keyboard(room, r'$manual', {
        'keyboard': [
          [
            {'text': 'Manual reply'},
          ],
        ],
        'one_time_keyboard': true,
      });
      Event answer(
        String id, {
        String? target,
        EventStatus status = EventStatus.synced,
      }) => Event(
        room: room,
        eventId: id,
        type: EventTypes.Message,
        senderId: client.userID!,
        originServerTs: request.originServerTs.add(const Duration(seconds: 1)),
        status: status,
        content: {
          'msgtype': 'm.text',
          'body': 'Ответ',
          if (target != null)
            'm.relates_to': {
              'm.in_reply_to': {'event_id': target},
            },
        },
      );
      Future<void> update(List<Event> events) async {
        final timeline = Timeline(
          room: room,
          chunk: TimelineChunk(events: events),
        );
        addTearDown(timeline.cancelSubscriptions);
        await tester.pumpWidget(
          app(
            InteractiveBotComposer(
              room: room,
              timeline: timeline,
              controller: controller,
              onForceReply: (_) {},
              onOpenApp: (_) async {},
              onSent: () {},
            ),
          ),
        );
        await settle(tester);
      }

      await update([request]);
      final state = tester.state(find.byType(InteractiveBotComposer));
      await update([answer(r'$unrelated'), request]);
      expect(
        find.widgetWithText(OutlinedButton, 'Manual reply'),
        findsOneWidget,
      );
      final reply = answer(
        r'$failed',
        target: request.eventId,
        status: EventStatus.error,
      );
      await update([reply, request]);
      expect(
        find.widgetWithText(OutlinedButton, 'Manual reply'),
        findsOneWidget,
      );
      reply.status = EventStatus.sent;
      await update([reply, request]);
      expect(tester.state(find.byType(InteractiveBotComposer)), same(state));
      expect(find.widgetWithText(OutlinedButton, 'Manual reply'), findsNothing);
      await unmount(tester);
    },
  );

  testWidgets(
    'private keyboard account_data: failed persist cache, retry, isolation and bounded merge',
    (tester) async {
      // AC:RL-bot-api-interactive-client/19
      final network = _KeyboardStateApi();
      late Client client;
      // Мок-HTTP отвечает только в реальном event loop, не в fake-async.
      await tester.runAsync(() async {
        client = await prepareTestClient(loggedIn: true, httpClient: network);
        addTearDown(client.dispose);
        final room = Room(id: '!consumed:hs', client: client);
        network.failWrites = true;
        final failed = BotInteractiveKeyboardState.remember(room, r'$accepted');
        expect(
          BotInteractiveKeyboardState.isConsumed(room, r'$accepted'),
          isTrue,
        );
        expect(await failed, isFalse);
        expect(
          BotInteractiveKeyboardState.isConsumed(room, r'$accepted'),
          isTrue,
        );
        network.failWrites = false;
        final retry = BotInteractiveKeyboardState.restore(room);
        await retry;
        expect(network.values.values.single['event_ids'], [r'$accepted']);
        expect(
          network.writes.every((body) => body.keys.single == 'event_ids'),
          isTrue,
        );
        final otherRoom = Room(id: '!other:hs', client: client);
        expect(
          BotInteractiveKeyboardState.isConsumed(otherRoom, r'$accepted'),
          isFalse,
        );
        client.accessToken = 'another-session';
        expect(
          BotInteractiveKeyboardState.isConsumed(room, r'$accepted'),
          isFalse,
          reason:
              'старый room account_data не переносится в новый session scope',
        );
        final clean = BotInteractiveKeyboardState.restore(room);
        await clean;
        expect(
          BotInteractiveKeyboardState.isConsumed(room, r'$accepted'),
          isFalse,
        );
        final seed = [for (var i = 0; i < 256; i++) '\$old-$i'];
        room.roomAccountData[BotInteractiveKeyboardState.eventType] =
            BasicEvent(
              type: BotInteractiveKeyboardState.eventType,
              content: {'event_ids': seed},
            );
        expect(BotInteractiveKeyboardState.isConsumed(room, seed.last), isTrue);
        network.holdRead = Completer<void>();
        final beforeReads = network.reads;
        final first = BotInteractiveKeyboardState.remember(room, r'$first');
        final second = BotInteractiveKeyboardState.remember(room, r'$second');
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(network.reads, beforeReads + 1, reason: 'слияния сериализованы');
        network.holdRead!.complete();
        expect(await first, isTrue);
        expect(await second, isTrue);
        final persisted = network.writes.last['event_ids'] as List;
        expect(persisted, hasLength(256));
        expect(persisted, containsAll([r'$first', r'$second']));
        expect(persisted, isNot(contains(seed.first)));
      });
    },
  );

  for (final leave in ['route', 'paused', 'inactive']) {
    testWidgets(
      'геолокация после согласия: $leave во время получения позиции',
      (tester) async {
        // AC:RL-bot-api-interactive-client/11
        final original = GeolocatorPlatform.instance;
        final platform = _HeldLocation();
        GeolocatorPlatform.instance = platform;
        addTearDown(() => GeolocatorPlatform.instance = original);
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
        final pending = requestBotLocation(
          context: context,
          recipient: '@shop:hs',
          isCurrent: () => true,
        );
        await settle(tester);
        await tester.tap(find.text(L10n.of(context).send));
        await settle(tester);
        expect(platform.requested, isTrue);
        if (leave == 'route') {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Другой экран')),
            ),
          );
        } else {
          tester.binding.handleAppLifecycleStateChanged(
            leave == 'paused'
                ? AppLifecycleState.paused
                : AppLifecycleState.inactive,
          );
        }
        await tester.pump(const Duration(milliseconds: 250));
        if (leave == 'paused') {
          // Возврат не оживляет ранее отменённый запрос.
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        platform.position.complete(
          Position(
            longitude: 37,
            latitude: 55,
            timestamp: DateTime.now(),
            accuracy: 10,
            altitude: 0,
            altitudeAccuracy: 0,
            heading: 0,
            headingAccuracy: 0,
            speed: 0,
            speedAccuracy: 0,
          ),
        );
        await tester.pump();
        final result = await pending;
        if (leave == 'inactive') {
          expect(result?['msgtype'], 'm.location');
        } else {
          expect(result, isNull);
        }
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(app(const SizedBox()));
      },
    );
  }
}
