// ledger:RL-read-marker-ack-consistency
// ledger:RL-edited-message-read-cursor
// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/app_badge.dart';
import 'package:liza/utils/push_contract_session.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_event_list.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/channel_peek.dart';
import 'package:liza/utils/chat_scroll_geometry.dart';
import 'package:liza/utils/confirmed_read_state.dart';
import 'package:liza/utils/read_marker_logic.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/utils/screen_lock_state.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/unread_rooms_badge.dart';

import '../../utils/test_client.dart';

class _ReceiptApi extends FakeMatrixApi {
  _ReceiptApi({this.userId});
  final String? userId;
  final requests = <Map<String, dynamic>>[];
  final pending = <Completer<http.Response>>[];
  final tailRequests = <Uri>[];
  List<Map<String, dynamic>> serverTail = [];
  int tailStatus = 200;
  bool immediateReceipt = false;
  Map<String, Object?>? contractSync;
  void Function()? onReceipt;

  @override
  FutureOr<http.Response> mockIntercept(http.Request request) {
    if (contractSync != null && request.url.path.endsWith('/sync')) {
      return http.Response(
        jsonEncode(contractSync),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (userId != null &&
        request.url.path.endsWith('/login') &&
        request.method == 'POST') {
      return http.Response(
        jsonEncode({
          'user_id': userId,
          'access_token': 'test-only-token',
          'device_id': 'LIZA_TEST_SECOND',
          'home_server': 'example.invalid',
        }),
        200,
      );
    }
    if (request.url.path.endsWith('/messages')) {
      tailRequests.add(request.url);
      return http.Response(
        jsonEncode({
          'chunk': serverTail,
          'start': 'tail-start',
          'end': 'tail-end',
        }),
        tailStatus,
        headers: {'content-type': 'application/json'},
      );
    }
    if (request.url.path.endsWith('/read_markers')) {
      requests.add(jsonDecode(request.body) as Map<String, dynamic>);
      onReceipt?.call();
      final response = Completer<http.Response>();
      pending.add(response);
      if (immediateReceipt) response.complete(http.Response('{}', 200));
      return response.future;
    }
    return super.mockIntercept(request);
  }

  void answer(int index, {int status = 200}) => pending[index].complete(
    http.Response(
      status == 200 ? '{}' : '{"errcode":"M_UNKNOWN","error":"transient"}',
      status,
      headers: {'content-type': 'application/json'},
    ),
  );
}

class _MatrixState extends liza_matrix.MatrixState {
  _MatrixState(this.testClient);
  Client testClient;
  @override
  Client get client => testClient;
}

/// Подменены только тяжёлый запуск и экран. setReadMarker и dispose — реальные.
class _Controller extends ChatController {
  _Controller(this.initialTimeline);
  final Timeline initialTimeline;
  @override
  // ignore: must_call_super
  void initState() {
    sendingClient = widget.room.client;
    inputFocus = FocusNode();
    timeline = initialTimeline;
    readMarkerEventId = r'$before';
    initializeReadMarkerTracking();
  }

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 300, child: ChatEventList(controller: this));

  // История не относится к read-marker контракту; все события fixture уже тут.
  @override
  void requestHistory([dynamic _]) {}
}

class _Host extends ChatPageWithRoom {
  const _Host({
    required super.key,
    required super.room,
    required this.timeline,
  });
  final Timeline timeline;
  @override
  // ignore: no_logic_in_create_state
  ChatController createState() => _Controller(timeline);
}

Event _message(Room room, String id, int ts) => Event(
  eventId: id,
  senderId: '@bob:example.invalid',
  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
  type: EventTypes.Message,
  content: {'msgtype': 'm.text', 'body': id},
  room: room,
);

Event _edit(
  Event original, {
  String id = r'$edit',
  int ts = 3000,
  String body = 'отредактированное сообщение',
}) => Event(
  eventId: id,
  senderId: original.senderId,
  originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
  type: EventTypes.Message,
  room: original.room,
  content: {
    'msgtype': 'm.text',
    'body': '* $body',
    'm.new_content': <String, dynamic>{'msgtype': 'm.text', 'body': body},
    'm.relates_to': {
      'rel_type': RelationshipTypes.edit,
      'event_id': original.eventId,
    },
  },
);

void main() {
  late Client client;
  late _ReceiptApi api;
  late Room room;
  late Timeline timeline;
  late GlobalKey<ChatController> key;
  late List<MethodCall> badgeCalls;
  late _MatrixState matrixState;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    api = _ReceiptApi();
    client = await prepareTestClient(loggedIn: true, httpClient: api);
    client.backgroundSync = false;
    await client.abortSync();
    client.rooms.clear();
    matrixState = _MatrixState(client);
    AppBadge.bindPrimary(matrixState, () => client);
    room = Room(
      id: '!ack:example.invalid',
      client: client,
      membership: Membership.join,
    );
    room.notificationCount = 2;
    room.highlightCount = 1;
    room.setState(
      Event(
        eventId: r'$name',
        senderId: '@bob:example.invalid',
        stateKey: '',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
        type: EventTypes.RoomName,
        content: {'name': 'ACK чат'},
        room: room,
      ),
    );
    room.setState(
      Event(
        eventId: r'$bob-member',
        senderId: '@bob:example.invalid',
        stateKey: '@bob:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
        type: EventTypes.RoomMember,
        content: {'membership': 'join', 'displayname': 'Боб'},
        room: room,
      ),
    );
    client.rooms.add(room);
    final a = _message(room, r'$a', 2000);
    final before = _message(room, r'$before', 1000);
    room.lastEvent = a;
    key = GlobalKey<ChatController>();
    timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [a, before], nextBatch: ''),
      onUpdate: () => key.currentState?.updateView(),
    );
    badgeCalls = [];
    ScreenLockState.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_new_badger'), (
          call,
        ) async {
          badgeCalls.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.prodamus.laba.liza/apns'),
          (_) async => true,
        );
  });

  tearDown(() async {
    AppBadge.unbindPrimary(matrixState);
    for (final pending in api.pending) {
      if (!pending.isCompleted) pending.complete(http.Response('{}', 200));
    }
    await client.dispose(closeDatabase: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    AppLifecycleState lifecycle = AppLifecycleState.resumed,
    bool offstage = false,
    bool zeroViewport = false,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(lifecycle);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: matrixState,
          child: Scaffold(
            body: Column(
              children: [
                Offstage(
                  offstage: offstage,
                  child: SizedBox(
                    height: zeroViewport ? 0 : null,
                    child: _Host(key: key, room: room, timeline: timeline),
                  ),
                ),
                UnreadRoomsBadge(filter: (_) => true),
                ChatListItem(room, onTap: () {}),
                SizedBox(
                  height: 140,
                  width: 72,
                  child: CompactChatListColumn(
                    rooms: [room],
                    activeChat: null,
                    filterActive: false,
                    onTap: (_) {},
                    onContextAction: (_, _) {},
                    onExpand: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
  }

  Future<void> commitReadFixture(
    WidgetTester tester, {
    bool receipt = false,
  }) async {
    api.contractSync = {
      'next_batch': receipt ? 'receipt-ack' : 'wire-target',
      'rooms': {
        'join': {
          room.id: {
            if (!receipt)
              'timeline': {
                'events': [
                  {
                    'type': 'm.room.message',
                    'sender': '@bob:example.invalid',
                    'event_id': r'$a',
                    'origin_server_ts': 2000,
                    'content': {'msgtype': 'm.text', 'body': 'fixture'},
                  },
                ],
              },
            if (receipt)
              'ephemeral': {
                'events': [
                  {
                    'type': 'm.receipt',
                    'content': {
                      r'$a': {
                        'm.read.private': {
                          client.userID: {'ts': 3000},
                        },
                      },
                    },
                  },
                ],
              },
            'unread_notifications': {
              'notification_count': receipt ? 0 : 2,
              'highlight_count': receipt ? 0 : 1,
            },
          },
        },
      },
    };
    await tester.runAsync(() => client.oneShotSync(timeout: Duration.zero));
    api.contractSync = null;
    await flush(tester);
  }

  Future<void> installEdits(WidgetTester tester, List<Event> edits) async {
    await tester.runAsync(() async {
      for (final event in [...timeline.events.reversed, ...edits]) {
        await client.database.storeEventUpdate(
          room.id,
          event,
          EventUpdateType.timeline,
          client,
        );
      }
    });
    for (final edit in edits) {
      timeline.events.insert(0, edit);
      timeline.addAggregatedEvent(edit);
    }
    room.lastEvent = edits.last;
  }

  Future<void> echoRead(
    WidgetTester tester,
    String eventId, {
    bool hydrate = true,
  }) async {
    await tester.runAsync(
      () => client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'edited-own-read-$eventId',
          'rooms': {
            'join': {
              room.id: {
                'unread_notifications': {
                  'notification_count': 0,
                  'highlight_count': 0,
                },
                'ephemeral': {
                  'events': [
                    {
                      'type': 'm.receipt',
                      'content': {
                        eventId: {
                          'm.read.private': {
                            client.userID: {'ts': 9000},
                          },
                        },
                      },
                    },
                  ],
                },
                'account_data': {
                  'events': [
                    {
                      'type': 'm.fully_read',
                      'content': {'event_id': eventId},
                    },
                  ],
                },
              },
            },
          },
        }),
      ),
    );
    if (hydrate) {
      await tester.runAsync(() => UnseenOrderCache.reconcileRoom(room));
    }
  }

  double dotHeight(WidgetTester tester) => tester
      .getSize(
        find.descendant(
          of: find.byType(UnreadBubble).first,
          matching: find.byType(AnimatedContainer),
        ),
      )
      .height;

  Future<void> finishRequests(WidgetTester tester) async {
    // Paused binding не строит даже teardown-кадр; чтение в cleanup запрещено.
    ScreenLockState.update(true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var index = 0; index < api.pending.length; index++) {
      if (!api.pending[index].isCompleted) api.answer(index);
    }
    await flush(tester);
    await tester.pump(const Duration(milliseconds: 10));
    await flush(tester);
  }

  for (final publicReceipt in [false, true]) {
    for (final editCount in [1, 3]) {
      testWidgets(
        'edited cursor automatic actual frame clears count0 dot and survives three entries '
        '(public=$publicReceipt edits=$editCount)',
        (tester) async {
          await AppSettings.sendPublicReadReceipts.setItem(publicReceipt);
          final original = timeline.events.first;
          final edits = List.generate(
            editCount,
            (index) => _edit(
              original,
              id: '\$edit-$index',
              ts: 3000 + index,
              body: 'показанная редакция $index',
            ),
          );
          final shown = edits.last;
          await installEdits(tester, edits);
          await echoRead(tester, original.eventId);
          expect(original.getDisplayEvent(timeline).eventId, shown.eventId);
          expect(room.hasUnseenMessages, isTrue);
          await mount(tester);
          await flush(tester);
          expect(
            find.textContaining(
              'показанная редакция ${editCount - 1}',
              findRichText: true,
            ),
            findsWidgets,
          );
          // AC:RL-edited-message-read-cursor/1
          expect(
            api.requests,
            hasLength(1),
            reason: 'реальный кадр сам будит controller',
          );
          expect(api.requests.single['m.read.private'], shown.eventId);
          expect(api.requests.single['m.fully_read'], shown.eventId);
          expect(
            api.requests.single['m.read'],
            publicReceipt ? shown.eventId : isNull,
          );
          // AC:RL-edited-message-read-cursor/2
          expect(
            dotHeight(tester),
            14,
            reason: 'нет ACK — нет локального прочтения',
          );
          api.answer(0);
          await flush(tester);
          await tester.pumpAndSettle();
          expect(dotHeight(tester), 0);
          final title = find.descendant(
            of: find.byType(ChatListItem),
            matching: find.text('ACK чат'),
          );
          expect(tester.widget<Text>(title).style?.fontWeight, isNull);
          await echoRead(tester, shown.eventId);
          for (var entry = 0; entry < 3; entry++) {
            await tester.pumpWidget(const SizedBox.shrink());
            key = GlobalKey<ChatController>();
            await mount(tester);
            // AC:RL-edited-message-read-cursor/3
            expect(dotHeight(tester), 0, reason: 'повторный вход $entry');
            expect(tester.widget<Text>(title).style?.fontWeight, isNull);
            expect(
              api.requests,
              hasLength(1),
              reason:
                  'уже подтверждённая редакция не вызывает новый HTTP при входе',
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'edited cursor automatic count0 unknown order ignores misleading receipt clock',
    (tester) async {
      final original = timeline.events.first;
      final edit = _edit(original);
      await installEdits(tester, [edit]);
      await echoRead(tester, original.eventId, hydrate: false);
      expect(UnseenOrderCache.lookup(room), isNull);
      expect(
        room.hasNewMessages,
        isFalse,
        reason:
            'SDK timestamp heuristic считает original receipt новым из-за ts9000',
      );
      await mount(tester);
      await flush(tester);
      expect(
        find.textContaining('отредактированное сообщение', findRichText: true),
        findsWidgets,
      );
      // AC:RL-edited-message-read-cursor/1
      expect(
        api.requests.single['m.read.private'],
        edit.eventId,
        reason:
            'показанный edit требует exact read несмотря на count0/unknown/SDKfalse',
      );
      await finishRequests(tester);
    },
  );

  testWidgets('edited cursor SDK update waits for actual new frame', (
    tester,
  ) async {
    await mount(tester);
    final original = timeline.events.first;
    final edit = _edit(original);
    await tester.runAsync(
      () => client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'incoming-edit',
          'rooms': {
            'join': {
              room.id: {
                'timeline': {
                  'events': [edit.toJson()],
                },
                'unread_notifications': {
                  'notification_count': 0,
                  'highlight_count': 0,
                },
              },
            },
          },
        }),
      ),
    );
    expect(original.getDisplayEvent(timeline).eventId, edit.eventId);
    // AC:RL-edited-message-read-cursor/4
    expect(
      api.requests.where((r) => r['m.read.private'] == edit.eventId),
      isEmpty,
      reason: 'SDK update/build intent ещё не означает отрисованный edit',
    );
    for (var i = 0; i < api.pending.length; i++) {
      if (!api.pending[i].isCompleted) api.answer(i);
    }
    await flush(tester);
    expect(
      find.textContaining('отредактированное сообщение', findRichText: true),
      findsWidgets,
    );
    // AC:RL-edited-message-read-cursor/1
    expect(
      api.requests.last['m.read.private'],
      edit.eventId,
      reason: 'SDK→MessageContent→postframe→wire без прямого setReadMarker',
    );
    await finishRequests(tester);
  });

  for (final invalid in [
    'sender',
    'room',
    'type',
    'state-empty',
    'state-nonempty',
    'new-content-missing',
    'new-content-malformed',
    'new-content-encrypted',
    'redacted',
    'edit-of-edit',
    'inverted-ts',
    'equal-original-ts',
    'ambiguous-edit-ts',
    'intervening-message',
    'intervening-thread',
    'raw-reaction',
    'old-original',
    'active-thread',
    'history',
  ]) {
    testWidgets('edited cursor refuses invalid $invalid', (tester) async {
      final original = timeline.events.first;
      var edit = _edit(original);
      final json = edit.toJson();
      if (invalid == 'sender') json['sender'] = '@mallory:example.invalid';
      if (invalid == 'type') json['type'] = EventTypes.Sticker;
      if (invalid.startsWith('state-')) {
        json['state_key'] = invalid == 'state-empty' ? '' : 'state';
      }
      final content = json['content'] as Map<String, dynamic>;
      if (invalid == 'new-content-missing') content.remove('m.new_content');
      if (invalid == 'new-content-malformed') {
        content['m.new_content'] = {'body': 1};
      }
      if (invalid == 'new-content-encrypted') {
        content['m.new_content'] = {
          'body': 'ciphertext',
          'msgtype': MessageTypes.BadEncrypted,
        };
      }
      if (invalid == 'redacted') {
        json['unsigned'] = {
          'redacted_because': {
            'event_id': r'$redaction',
            'sender': original.senderId,
            'origin_server_ts': 4000,
            'type': 'm.room.redaction',
            'content': {},
          },
        };
      }
      if (invalid == 'edit-of-edit') {
        content['m.relates_to'] = {
          'rel_type': 'm.replace',
          'event_id': r'$previous-edit',
        };
      }
      if (invalid == 'inverted-ts') json['origin_server_ts'] = 1999;
      if (invalid == 'equal-original-ts') json['origin_server_ts'] = 2000;
      edit = Event.fromJson(
        json,
        invalid == 'room'
            ? Room(
                id: '!foreign:example.invalid',
                client: client,
                membership: Membership.join,
              )
            : room,
      );
      // Некорректный автор/room — предмет проверки relation, не сетевой поиск профиля.
      edit.room.setState(
        Event(
          eventId: r'$invalid-member',
          senderId: edit.senderId,
          stateKey: edit.senderId,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
          type: EventTypes.RoomMember,
          room: edit.room,
          content: {'membership': 'join', 'displayname': 'Тестовый участник'},
        ),
      );
      if (invalid == 'intervening-message' || invalid == 'intervening-thread') {
        final middle = _message(room, r'$unseen-middle', 2500);
        if (invalid == 'intervening-thread') {
          middle.content['m.relates_to'] = {
            'rel_type': 'm.thread',
            'event_id': r'$thread-root',
          };
        }
        timeline.events.insert(0, middle);
      }
      await installEdits(tester, [
        if (invalid == 'ambiguous-edit-ts') _edit(original, id: r'$equal-edit'),
        edit,
      ]);
      if (invalid == 'raw-reaction' || invalid == 'old-original') {
        final tail = _message(room, r'$unseen-tail', 4000);
        if (invalid == 'raw-reaction') {
          timeline.events.insert(
            0,
            Event.fromJson({
              ...tail.toJson(),
              'type': 'm.reaction',
              'content': {
                'm.relates_to': {
                  'rel_type': 'm.annotation',
                  'event_id': original.eventId,
                  'key': '👍',
                },
              },
            }, room),
          );
        } else {
          timeline.events.insert(0, tail);
        }
        room.lastEvent = timeline.events.first;
      }
      if (invalid == 'history') {
        timeline = Timeline(
          room: room,
          chunk: TimelineChunk(
            events: timeline.events,
            nextBatch: 'future-gap',
          ),
        );
      }
      if (invalid == 'active-thread') ScreenLockState.update(true);
      await mount(tester);
      if (invalid == 'active-thread') {
        key.currentState!.activeThreadId = r'$thread';
        ScreenLockState.update(false);
      }
      key.currentState!.setReadMarker();
      await flush(tester);
      // AC:RL-edited-message-read-cursor/5
      expect(
        api.requests.map((r) => r['m.read.private']),
        isNot(contains(edit.eventId)),
        reason: '$invalid не даёт права подтвердить скрытый edit',
      );
      expect(room.notificationCount, 2);
      await finishRequests(tester);
    });
  }

  for (final result in [
    'transient',
    'budget',
    'permanent',
    'late-ack',
    'resume',
  ]) {
    testWidgets(
      'edited cursor $result preserves exact target and newer unread',
      (tester) async {
        final original = timeline.events.first;
        final edit = _edit(original);
        await installEdits(tester, [edit]);
        await mount(tester);
        await flush(tester);
        expect(api.requests.single['m.read.private'], edit.eventId);
        if (result == 'resume') {
          api.answer(0, status: 503);
          await flush(tester);
        }
        final e3 = _message(room, r'$unread-e3', 4000);
        e3.content['body'] = List.filled(
          80,
          'новое непрочитанное E3',
        ).join('\n');
        timeline.events.insert(0, e3);
        room.lastEvent = e3;
        room.notificationCount = 3;
        // Обычный case ждёт HTTP-ответ до завершения прокрутки: deadline
        // начинается при дочитанной строке, не во время AnimatedSize layout.
        await mount(tester);
        final scroll = key.currentState!.scrollController;
        if (result == 'resume') {
          final offscreen = collectTagGeometry(scroll)!;
          expect(
            newestVisibleEventId(offscreen.tags, offscreen.viewport),
            isNot(original.eventId),
          );
          await tester.pump(const Duration(seconds: 1));
          await flush(tester);
          expect(
            api.requests,
            hasLength(1),
            reason: 'offscreen retry запрещён',
          );
        }
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final geometry = collectTagGeometry(scroll)!;
        final row = geometry.tags.firstWhere(
          (tag) => tag.eventId == original.eventId,
        );
        scroll.jumpTo(
          (scroll.position.pixels +
                  geometry.viewport.height / 2 -
                  row.rect.bottom)
              .clamp(
                scroll.position.minScrollExtent,
                scroll.position.maxScrollExtent,
              ),
        );
        await tester.pumpAndSettle();
        final readGeometry = collectTagGeometry(scroll)!;
        expect(
          newestVisibleEventId(readGeometry.tags, readGeometry.viewport),
          original.eventId,
          reason: 'fixture действительно дочитала original, но не e3',
        );
        expect(scroll.position.pixels, greaterThan(2));
        if (result != 'late-ack' && result != 'resume') {
          api.answer(0, status: result == 'permanent' ? 403 : 503);
          await flush(tester);
        }
        if (result == 'resume') {
          key.currentState!.setReadMarker(eventId: original.eventId);
        }
        if (result == 'late-ack') api.answer(0);
        await tester.pump(const Duration(seconds: 1));
        await flush(tester);
        // AC:RL-edited-message-read-cursor/6
        expect(
          api.requests.map((r) => r['m.read.private']),
          everyElement(edit.eventId),
        );
        expect(
          api.requests,
          hasLength(
            result == 'transient' || result == 'budget' || result == 'resume'
                ? 2
                : 1,
          ),
        );
        if (result == 'budget') {
          api.answer(1, status: 503);
          await flush(tester);
          for (final delay in [3, 10]) {
            final before = api.requests.length;
            await tester.pump(Duration(milliseconds: delay * 1000 - 1));
            await flush(tester);
            expect(api.requests, hasLength(before));
            await tester.pump(const Duration(milliseconds: 1));
            await flush(tester);
            expect(api.requests, hasLength(before + 1));
            expect(api.requests.last['m.read.private'], edit.eventId);
            api.answer(api.requests.length - 1, status: 503);
            await flush(tester);
          }
          await tester.pump(const Duration(seconds: 30));
          await flush(tester);
          expect(api.requests, hasLength(4));
        } else if (result == 'transient' || result == 'resume') {
          api.answer(1);
          await flush(tester);
        }
        // AC:RL-edited-message-read-cursor/7
        expect(room.notificationCount, 3);
        expect(room.highlightCount, 1);
        expect(key.currentState!.readMarkerEventId, r'$before');
        expect(
          find.text(L10n.of(key.currentContext!).readUpToHere),
          findsOneWidget,
          reason: 'реальный разделитель непрочитанного сохранён',
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('edited cursor count-only generation invalidates old ACK', (
    tester,
  ) async {
    final edit = _edit(timeline.events.first);
    await installEdits(tester, [edit]);
    await mount(tester);
    await flush(tester);
    expect(api.requests.single['m.read.private'], edit.eventId);
    await tester.runAsync(
      () => client.handleSync(
        SyncUpdate.fromJson({
          'next_batch': 'new-count-same-edit',
          'rooms': {
            'join': {
              room.id: {
                'unread_notifications': {
                  'notification_count': 3,
                  'highlight_count': 1,
                },
              },
            },
          },
        }),
      ),
    );
    api.answer(0);
    await flush(tester);
    // AC:RL-edited-message-read-cursor/7
    expect(room.notificationCount, 3);
    expect(room.highlightCount, 1);
    await finishRequests(tester);
  });

  testWidgets('edited cursor timeout retains dot until exact retry ACK', (
    tester,
  ) async {
    final original = timeline.events.first;
    final edit = _edit(original);
    await installEdits(tester, [edit]);
    await echoRead(tester, original.eventId);
    await mount(tester);
    await flush(tester);
    expect(api.requests.single['m.read.private'], edit.eventId);
    await tester.pump(const Duration(seconds: 30));
    await flush(tester);
    // AC:RL-edited-message-read-cursor/2
    expect(dotHeight(tester), 14);
    expect(api.requests, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    // AC:RL-edited-message-read-cursor/6
    expect(api.requests, hasLength(2));
    expect(api.requests.last['m.read.private'], edit.eventId);
    api.answer(1);
    await flush(tester);
    await tester.pumpAndSettle();
    expect(dotHeight(tester), 0);
    await finishRequests(tester);
  });

  for (final reply in [false, true]) {
    testWidgets(
      'edited cursor requires actual bottom of long ${reply ? 'reply' : 'message'}',
      (tester) async {
        final original = timeline.events.first;
        if (reply) {
          original.content['m.relates_to'] = {
            'm.in_reply_to': {'event_id': r'$before'},
          };
        }
        final edit = _edit(
          original,
          body: List.filled(80, 'длинная показанная редакция').join('\n'),
        );
        if (reply) {
          (edit.content['m.new_content']
                  as Map<String, dynamic>)['m.relates_to'] =
              original.content['m.relates_to'];
        }
        await installEdits(tester, [edit]);
        ScreenLockState.update(true);
        await mount(tester);
        final scroll = key.currentState!.scrollController;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        ScreenLockState.update(false);
        await mount(tester);
        final geometry = collectTagGeometry(scroll)!;
        final row = geometry.tags.firstWhere(
          (tag) => tag.eventId == original.eventId,
        );
        expect(row.rect.top, lessThan(geometry.viewport.height));
        expect(row.rect.bottom, greaterThan(geometry.viewport.height));
        key.currentState!.setReadMarker();
        await flush(tester);
        // AC:RL-edited-message-read-cursor/8
        expect(
          api.requests.where((r) => r['m.read.private'] == edit.eventId),
          isEmpty,
        );
        for (var i = 0; i < api.pending.length; i++) {
          if (!api.pending[i].isCompleted) api.answer(i);
        }
        await flush(tester);
        scroll.jumpTo(0);
        await mount(tester);
        await flush(tester);
        final bottomGeometry = collectTagGeometry(scroll)!;
        final bottom = bottomGeometry.tags
            .firstWhere((tag) => tag.eventId == original.eventId)
            .rect
            .bottom;
        expect(bottom, greaterThan(0));
        expect(bottom, lessThanOrEqualTo(bottomGeometry.viewport.height + .5));
        // AC:RL-edited-message-read-cursor/9
        expect(api.requests.last['m.read.private'], edit.eventId);
        await finishRequests(tester);
      },
    );
  }

  for (final gate in [
    'locked',
    'inactive',
    'paused',
    'hidden',
    'detached',
    'not-joined',
    'offstage',
    'zero-height',
  ]) {
    testWidgets(
      'edited cursor respects actual $gate gate before full promotion',
      (tester) async {
        final edit = _edit(timeline.events.first);
        await installEdits(tester, [edit]);
        HumanInputTracker.reset();
        ScreenLockState.update(true);
        if (gate == 'not-joined') room.membership = Membership.leave;
        await mount(
          tester,
          offstage: gate == 'offstage',
          zeroViewport: gate == 'zero-height',
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.values.firstWhere(
            (value) => value.name == gate,
            orElse: () => AppLifecycleState.resumed,
          ),
        );
        if (gate != 'locked') ScreenLockState.update(false);
        key.currentState!.setReadMarker();
        await flush(tester);
        // AC:RL-edited-message-read-cursor/10
        expect(
          api.requests.where((r) => r['m.read.private'] == edit.eventId),
          isEmpty,
        );
        expect(room.notificationCount, 2);
        await finishRequests(tester);
        ScreenLockState.reset();
      },
    );
  }

  for (final change in [
    'dispose',
    'thread',
    'room',
    'client-same-user',
    'client-other-user',
  ]) {
    testWidgets(
      'edited cursor late ACK after $change cannot clear abandoned state',
      (tester) async {
        final edit = _edit(timeline.events.first);
        await installEdits(tester, [edit]);
        await mount(tester);
        await flush(tester);
        expect(api.requests.single['m.read.private'], edit.eventId);
        if (change == 'dispose') {
          await tester.pumpWidget(const SizedBox.shrink());
        }
        if (change == 'thread') {
          key.currentState!.activeThreadId = r'$new-thread';
        }
        if (change.startsWith('client-')) {
          final secondApi = _ReceiptApi(
            userId: change == 'client-same-user'
                ? client.userID
                : '@second:example.invalid',
          );
          late Client second;
          await tester.runAsync(() async {
            second = await prepareTestClient(
              loggedIn: true,
              httpClient: secondApi,
              clientName: 'Liza Edited Cursor Second',
            );
            second.backgroundSync = false;
            await second.abortSync();
            second.rooms.clear();
          });
          addTearDown(second.dispose);
          second.rooms.add(
            Room(id: room.id, client: second, membership: Membership.join)
              ..notificationCount = 7,
          );
          matrixState.testClient = second;
          await mount(tester);
          expect(secondApi.requests, isEmpty);
        }
        if (change == 'room') {
          client.rooms[0] = Room(
            id: room.id,
            client: client,
            membership: Membership.join,
          )..notificationCount = 7;
        }
        api.answer(0);
        await flush(tester);
        // AC:RL-edited-message-read-cursor/11
        expect(room.notificationCount, 2);
        if (change.startsWith('client-')) {
          expect(matrixState.client.rooms.single.notificationCount, 7);
        }
        if (change == 'room') expect(client.rooms.single.notificationCount, 7);
        await finishRequests(tester);
      },
    );
  }

  testWidgets('partial transient failure retries same exact target', (
    tester,
  ) async {
    final session = PushContractSession(
      client,
      changed: () {},
      isPrimaryAccount: () => true,
      isActiveAccount: () => true,
      leased: () => true,
      lifecycle: () => 'resumed',
    )..enabled = true;
    addTearDown(session.dispose);
    await commitReadFixture(tester);
    await mount(tester);
    List targets() =>
        session.capture('macos', '12', 0, 0)!.envelope.json['read_targets']
            as List;
    key.currentState!.setReadMarker(eventId: r'$before');
    await flush(tester);
    expect(api.requests.single['m.read.private'], r'$before');
    expect(targets(), isEmpty);
    api.answer(0, status: 503);
    await flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/1
    expect(
      api.requests,
      hasLength(2),
      reason: 'ошибка не подтверждает optimistic floor',
    );
    expect(api.requests.last['m.fully_read'], r'$before');
    expect(targets(), isEmpty);
    api.answer(1);
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/6
    // ledger:RL-push-causal-contract AC:RL-push-causal-contract/6
    expect(targets().single['event_id'], r'$before');
    expect(targets().single['kind'], 'partial');
    expect(room.notificationCount, 2);
    expect(key.currentState!.readMarkerEventId, r'$before');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'реальный полный read ACK сохраняет цель при независимом commit SDK в полёте',
    (tester) async {
      final contract = PushContractSession(
        client,
        changed: () {},
        isActiveAccount: () => true,
        isPrimaryAccount: () => true,
        leased: () => true,
        lifecycle: () => 'resumed',
      )..enabled = true;
      addTearDown(contract.dispose);
      await commitReadFixture(tester);
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      expect(api.requests.single['m.read.private'], r'$a');
      expect(
        contract.capture('macos', '12', 0, 0)!.envelope.json['read_targets'],
        isEmpty,
      );
      final sequence = contract.syncSequence;
      await commitReadFixture(tester, receipt: true);
      await flush(tester);
      expect(contract.syncSequence, greaterThan(sequence));
      api.answer(0);
      await flush(tester);
      final targets =
          contract.capture('macos', '12', 0, 0)!.envelope.json['read_targets']
              as List;
      expect(targets.single['event_id'], r'$a');
      expect(targets.single['kind'], 'full'); // AC:RL-push-causal-contract/6
      final accepted = contract.capture('macos', '12', 0, 0)!.envelope;
      expect(
        contract.acknowledge(accepted, {
          'schema': 1,
          'batch_id': accepted.id,
          'accepted': true,
          'results': [],
        }),
        true,
      );
      expect(
        contract.capture('macos', '12', 0, 0)!.envelope.json['read_targets'],
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final outcome in ['success', 'budget']) {
    testWidgets(
      'failed full A may retry as partial A while new B is outside viewport ($outcome)',
      (tester) async {
        await mount(tester);
        key.currentState!.setReadMarker();
        await flush(tester);
        expect(api.requests.single['m.fully_read'], r'$a');
        api.answer(0, status: 503);
        await flush(tester);
        final b = Event(
          eventId: r'$outside-b',
          senderId: '@bob:example.invalid',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(4000),
          type: EventTypes.Message,
          room: room,
          content: {
            'msgtype': 'm.text',
            'body': List.filled(80, 'непрочитанное сообщение B').join('\n'),
          },
        );
        timeline.events.insert(0, b);
        room.lastEvent = b;
        room.notificationCount = 3;
        await mount(tester);
        final scroll = key.currentState!.scrollController;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        var geometry = collectTagGeometry(scroll)!;
        final aTag = geometry.tags.firstWhere((tag) => tag.eventId == r'$a');
        // reverse-лента: доводим реальный низ A до середины viewport.
        scroll.jumpTo(
          (scroll.position.pixels +
                  geometry.viewport.height / 2 -
                  aTag.rect.bottom)
              .clamp(
                scroll.position.minScrollExtent,
                scroll.position.maxScrollExtent,
              ),
        );
        await tester.pumpAndSettle();
        geometry = collectTagGeometry(scroll)!;
        expect(
          newestVisibleEventId(geometry.tags, geometry.viewport),
          r'$a',
          reason: 'реальная геометрия: A дочитано, B нет',
        );
        expect(scroll.position.pixels, greaterThan(2));
        await tester.pump(const Duration(seconds: 1));
        await flush(tester);
        key.currentState!.setReadMarker(eventId: r'$a');
        await flush(tester);
        // AC:RL-read-marker-ack-consistency/1 AC:RL-read-marker-ack-consistency/8
        expect(
          api.requests,
          hasLength(2),
          reason:
              'старый full-kind не запрещает новое допустимое partial намерение на тот же A',
        );
        expect(api.requests.map((r) => r['m.fully_read']), everyElement(r'$a'));
        expect(api.requests.last['m.read.private'], r'$a');
        api.answer(1, status: outcome == 'success' ? 200 : 503);
        await flush(tester);
        if (outcome == 'budget') {
          // Downgrade сохраняет уже потраченную попытку: остались паузы 3 и 10.
          for (var index = 2; index <= 3; index++) {
            await tester.pump(
              Duration(milliseconds: (index == 2 ? 3000 : 10000) - 1),
            );
            await flush(tester);
            expect(
              api.requests,
              hasLength(index),
              reason: 'downgrade не обнуляет backoff',
            );
            await tester.pump(const Duration(milliseconds: 1));
            await flush(tester);
            expect(api.requests, hasLength(index + 1));
            expect(api.requests.last['m.fully_read'], r'$a');
            api.answer(index, status: 503);
            await flush(tester);
          }
          await tester.pump(const Duration(seconds: 30));
          key.currentState!.setReadMarker(eventId: r'$a');
          await flush(tester);
          // AC:RL-read-marker-ack-consistency/8
          expect(
            api.requests,
            hasLength(4),
            reason: 'full→partial не выдаёт новый бюджет',
          );
        }
        // AC:RL-read-marker-ack-consistency/6
        expect(room.notificationCount, 3);
        expect(room.highlightCount, 1);
        expect(key.currentState!.readMarkerEventId, r'$before');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('A request then B arrival then ACK A preserves B', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    expect(api.requests.single['m.fully_read'], r'$a');
    final b = _message(room, r'$b', 3000);
    timeline.events.insert(0, b);
    room.lastEvent = b;
    room.notificationCount = 3;
    api.answer(0);
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/3
    expect(room.notificationCount, 3, reason: 'ACK A не покрывает B');
    expect(room.highlightCount, 1);
    expect(key.currentState!.readMarkerEventId, r'$before');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('full ACK updates real navigation badge without next sync', (
    tester,
  ) async {
    await mount(tester);
    final number = find.descendant(
      of: find.byType(UnreadRoomsBadge),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(number).data, '1');
    final bubble = find.descendant(
      of: find.byType(UnreadBubble),
      matching: find.text('2'),
    );
    expect(bubble, findsNWidgets(2));
    final title = find.descendant(
      of: find.byType(ChatListItem),
      matching: find.text('ACK чат'),
    );
    expect(tester.widget<Text>(title).style?.fontWeight, FontWeight.w500);
    var syncEvents = 0;
    final subscription = client.onSync.stream.listen((_) => syncEvents++);
    addTearDown(subscription.cancel);
    key.currentState!.setReadMarker();
    await flush(tester);
    api.answer(0);
    await flush(tester);
    expect(room.notificationCount, 0);
    // AC:RL-read-marker-ack-consistency/4
    expect(
      tester.widget<Text>(number).data,
      '0',
      reason: 'ACK обязан оповестить смонтированный прод-виджет',
    );
    expect(
      bubble,
      findsNothing,
      reason: 'число в реальной строке тоже обновляется',
    );
    expect(tester.widget<Text>(title).style?.fontWeight, isNull);
    expect(
      syncEvents,
      0,
      reason: 'ACK не маскируется под серверный SyncUpdate',
    );
    expect(
      badgeCalls.map((c) => c.method),
      contains('removeBadge'),
      reason: 'AppBadge передал нулевое число платформе',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final timestamp in [2000, 500]) {
    testWidgets('new ID with equal or inverted timestamp $timestamp is sent', (
      tester,
    ) async {
      await mount(tester);
      key.currentState!.setReadMarker(eventId: r'$before');
      await flush(tester);
      api.answer(0);
      await flush(tester);
      final newer = _message(
        room,
        r'$newer',
        timestamp == 2000 ? 1000 : timestamp,
      );
      timeline.events.insert(1, newer);
      key.currentState!.setReadMarker(eventId: newer.eventId);
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/9
      expect(api.requests, hasLength(2));
      expect(api.requests.last['m.read.private'], newer.eventId);
      api.answer(1);
      await flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final gate in [
    'background',
    'lock',
    'membership',
    'context',
    'dispose',
  ]) {
    testWidgets('retry rechecks $gate gate', (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker(eventId: r'$before');
      await flush(tester);
      api.answer(0, status: 503);
      await flush(tester);
      switch (gate) {
        case 'background':
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
        case 'lock':
          ScreenLockState.update(true);
        case 'membership':
          room.membership = Membership.leave;
        case 'context':
          timeline.allowNewEvent = false;
        case 'dispose':
          await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump(const Duration(seconds: 20));
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/7
      expect(api.requests, hasLength(1), reason: 'недопустимое чтение: $gate');
      ScreenLockState.reset();
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('permanent HTTP 403 is not automatically retried', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker(eventId: r'$before');
    await flush(tester);
    api.answer(0, status: 403);
    await flush(tester);
    await tester.pump(const Duration(minutes: 1));
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/8
    expect(api.requests, hasLength(1));
    expect(room.notificationCount, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('bounded retries survive repeated ordinary updateView calls', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    for (var i = 0; i < 4; i++) {
      expect(api.requests, hasLength(i + 1));
      api.answer(i, status: 503);
      await flush(tester);
      for (var n = 0; n < 5; n++) {
        key.currentState!.updateView();
        await flush(tester);
      }
      if (i < 3) {
        await tester.pump(Duration(milliseconds: [1, 3, 10][i] * 1000 - 1));
        await flush(tester);
        // AC:RL-read-marker-ack-consistency/8
        expect(
          api.requests,
          hasLength(i + 1),
          reason: 'до deadline retry запрещён',
        );
        await tester.pump(const Duration(milliseconds: 1));
        await flush(tester);
        expect(
          api.requests,
          hasLength(i + 2),
          reason: 'на deadline retry разрешён',
        );
      }
    }
    await tester.pump(const Duration(minutes: 1));
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/8
    expect(
      api.requests,
      hasLength(4),
      reason: 'initial + 3 retries, updateView не выдаёт новый бюджет',
    );
    final newer = _message(room, r'$fresh-after-budget', 5000);
    timeline.events.insert(0, newer);
    room.lastEvent = newer;
    key.currentState!.setReadMarker();
    await flush(tester);
    expect(
      api.requests,
      hasLength(5),
      reason: 'исчерпанный A не блокирует новое намерение B',
    );
    expect(api.requests.last['m.fully_read'], newer.eventId);
    api.answer(4);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('public receipt preference never removes private exact target', (
    tester,
  ) async {
    await AppSettings.sendPublicReadReceipts.setItem(false);
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/2
    expect(api.requests.single['m.fully_read'], r'$a');
    expect(api.requests.single['m.read.private'], r'$a');
    expect(api.requests.single.containsKey('m.read'), isFalse);
    api.answer(0);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'coordinator delivers newer intent queued during partial request',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker(eventId: r'$before');
      await flush(tester);
      key.currentState!.setReadMarker(eventId: r'$a');
      expect(api.requests, hasLength(1));
      api.answer(0);
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/8
      expect(api.requests, hasLength(2));
      expect(api.requests.last['m.fully_read'], r'$a');
      api.answer(1);
      await flush(tester);
      expect(room.notificationCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('delayed retry A cannot replace latest queued intent C', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    api.answer(0, status: 503);
    await flush(tester);
    final b = _message(room, r'$b', 3000);
    room.lastEvent = b;
    timeline.events.insert(0, b);
    key.currentState!.setReadMarker();
    await flush(tester);
    expect(api.requests.last['m.fully_read'], r'$b');
    final c = _message(room, r'$c', 4000);
    room.lastEvent = c;
    timeline.events.insert(0, c);
    key.currentState!.setReadMarker();
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    api.answer(1);
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/8
    expect(api.requests, hasLength(3), reason: 'timer A не стирает pending C');
    expect(api.requests.last['m.fully_read'], r'$c');
    api.answer(2);
    await flush(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('raw thread tail never becomes main timeline receipt target', (
    tester,
  ) async {
    timeline.events.insert(
      0,
      Event(
        eventId: r'$thread-reply',
        senderId: '@bob:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(3000),
        type: EventTypes.Message,
        room: room,
        content: {
          'msgtype': 'm.text',
          'body': 'thread reply',
          'm.relates_to': {'rel_type': 'm.thread', 'event_id': r'$root'},
        },
      ),
    );
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/10
    expect(
      api.requests.single['m.fully_read'],
      r'$a',
      reason: 'скрытый thread event не был просмотрен',
    );
    api.answer(0);
    await flush(tester);
    expect(room.notificationCount, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('unknown explicit event does not become an acknowledged read', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker(eventId: r'$unknown');
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/2
    expect(api.requests, isEmpty);
    expect(room.notificationCount, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('full marker selects synced ID behind local unsent echo', (
    tester,
  ) async {
    final local = _message(room, r'$local', 4000)..status = EventStatus.error;
    timeline.events.insert(0, local);
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/2
    expect(api.requests.single['m.fully_read'], r'$a');
    expect(api.requests.single['m.read.private'], r'$a');
    api.answer(0);
    await flush(tester);
    expect(room.notificationCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final evidence in ['same', 'different', 'empty', 'error']) {
    testWidgets(
      'positive count-only sync requires server-tail proof: $evidence',
      (tester) async {
        await mount(tester);
        key.currentState!.setReadMarker();
        await flush(tester);
        api.answer(0);
        await flush(tester);
        expect(room.notificationCount, 0);
        api.serverTail = [
          if (evidence == 'same' || evidence == 'different')
            {
              'event_id': evidence == 'same' ? r'$a' : r'$unseen',
              'sender': '@bob:example.invalid',
              'origin_server_ts': 2000,
              'type': EventTypes.Message,
              'content': {'msgtype': 'm.text', 'body': 'server-tail'},
            },
        ];
        if (evidence == 'error') api.tailStatus = 503;
        await tester.runAsync(
          () => client.handleSync(
            SyncUpdate(
              nextBatch: 'count-only',
              rooms: RoomsUpdate(
                join: {
                  room.id: JoinedRoomUpdate(
                    unreadNotifications: UnreadNotificationCounts(
                      notificationCount: 2,
                      highlightCount: 1,
                    ),
                  ),
                },
              ),
            ),
          ),
        );
        await flush(tester);
        // Пока серверный хвост не проверен, прежний ACK не скрывает новый count.
        expect(room.notificationCount, 2);
        expect(api.tailRequests, hasLength(1));
        expect(api.tailRequests.single.queryParameters['dir'], 'b');
        expect(api.tailRequests.single.queryParameters['limit'], '1');
        expect(
          api.tailRequests.single.queryParameters.containsKey('from'),
          isFalse,
        );
        expect(api.requests, hasLength(2));
        api.answer(1);
        await flush(tester);
        // AC:RL-read-marker-ack-consistency/5
        expect(room.notificationCount, evidence == 'same' ? 0 : 2);
        final numbers = find.descendant(
          of: find.byType(UnreadRoomsBadge),
          matching: find.byType(Text),
        );
        expect(
          tester.widget<Text>(numbers).data,
          evidence == 'same' ? '0' : '1',
        );
        for (var i = 0; i < 5; i++) {
          key.currentState!.updateView();
          await flush(tester);
        }
        expect(
          api.tailRequests,
          hasLength(1),
          reason: 'сверка конечна даже при неизвестном результате',
        );
        expect(api.requests, hasLength(2));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final mode in [
    'manual',
    'invite',
    'mute',
    'mentions',
    'mentions-highlight',
  ]) {
    testWidgets('ACK projection preserves $mode semantics', (tester) async {
      if (mode == 'manual') {
        room.roomAccountData['m.marked_unread'] = BasicEvent(
          type: 'm.marked_unread',
          content: {'unread': true},
        );
      }
      if (mode == 'invite') room.membership = Membership.invite;
      if (mode == 'mute' || mode.startsWith('mentions')) {
        client.accountData['m.push_rules'] = BasicEvent(
          type: 'm.push_rules',
          content: {
            'global': {
              mode == 'mute' ? 'override' : 'room': [
                {
                  'rule_id': room.id,
                  'default': false,
                  'enabled': true,
                  'conditions': [
                    {
                      'kind': 'event_match',
                      'key': 'room_id',
                      'pattern': room.id,
                    },
                  ],
                  'actions': mode == 'mute' ? [] : ['dont_notify'],
                },
              ],
            },
          },
        );
        room.highlightCount = mode == 'mentions-highlight' ? 1 : 0;
      }
      await mount(tester);
      final number = find.descendant(
        of: find.byType(UnreadRoomsBadge),
        matching: find.byType(Text),
      );
      final initiallyVisible = mode != 'mute' && mode != 'mentions';
      expect(tester.widget<Text>(number).data, initiallyVisible ? '1' : '0');
      key.currentState!.setReadMarker();
      await flush(tester);
      if (mode == 'invite') {
        expect(api.requests, isEmpty, reason: 'membership gate');
      } else {
        api.answer(0);
        await flush(tester);
      }
      // AC:RL-read-marker-ack-consistency/10
      expect(
        tester.widget<Text>(number).data,
        mode == 'manual' || mode == 'invite' ? '1' : '0',
      );
      if (mode == 'manual') expect(room.markedUnread, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'raw reaction cannot hide unknown positive count behind old own receipt',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      api.answer(0);
      await flush(tester);
      room.roomAccountData[LatestReceiptState.eventType] = BasicEvent(
        type: LatestReceiptState.eventType,
        content: {
          'global': {
            'latest': {'e': r'$a', 'ts': 2000},
            'others': <String, dynamic>{},
          },
        },
      );
      await tester.runAsync(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: 'unknown-count',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  unreadNotifications: UnreadNotificationCounts(
                    notificationCount: 2,
                    highlightCount: 0,
                  ),
                ),
              },
            ),
          ),
        ),
      );
      await flush(tester);
      expect(api.requests, hasLength(2));
      api.answer(1);
      await flush(tester);
      await tester.runAsync(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: 'raw-reaction',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  unreadNotifications: UnreadNotificationCounts(
                    notificationCount: 2,
                    highlightCount: 0,
                  ),
                  timeline: TimelineUpdate(
                    events: [
                      MatrixEvent(
                        eventId: r'$raw-reaction',
                        senderId: '@bob:example.invalid',
                        originServerTs: DateTime.fromMillisecondsSinceEpoch(
                          3000,
                        ),
                        type: EventTypes.Reaction,
                        content: {
                          'm.relates_to': {
                            'rel_type': 'm.annotation',
                            'event_id': r'$a',
                            'key': '👍',
                          },
                        },
                      ),
                    ],
                    limited: false,
                  ),
                ),
              },
            ),
          ),
        ),
      );
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/10
      expect(room.notificationCount, 2);
      final number = find.descendant(
        of: find.byType(UnreadRoomsBadge),
        matching: find.byType(Text),
      );
      expect(
        tester.widget<Text>(number).data,
        '1',
        reason: 'невидимая реакция не доказывает покрытие unknown count',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final outcome in ['ack', 'retry']) {
    testWidgets('old $outcome cannot change newly active account', (
      tester,
    ) async {
      final secondApi = _ReceiptApi(userId: '@second:example.invalid');
      late Client second;
      await tester.runAsync(() async {
        second = await prepareTestClient(
          loggedIn: true,
          httpClient: secondApi,
          clientName: 'Liza Second Test',
        );
        second.backgroundSync = false;
        await second.abortSync();
        second.rooms.clear();
      });
      addTearDown(second.dispose);
      expect(second.userID, isNot(client.userID));
      final foreignRoom =
          Room(id: room.id, client: second, membership: Membership.join)
            ..notificationCount = 7
            ..highlightCount = 2;
      second.rooms.add(foreignRoom);
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      expect(api.requests, hasLength(1));
      matrixState.testClient = second;
      await mount(tester);
      api.answer(0, status: outcome == 'ack' ? 200 : 503);
      await flush(tester);
      await tester.pump(const Duration(seconds: 20));
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/11
      expect(foreignRoom.notificationCount, 7);
      expect(foreignRoom.highlightCount, 2);
      expect(room.notificationCount, 2);
      expect(api.requests, hasLength(1));
      expect(secondApi.requests, isEmpty);
      expect(badgeCalls, isEmpty);
      final number = find.descendant(
        of: find.byType(UnreadRoomsBadge),
        matching: find.byType(Text),
      );
      expect(tester.widget<Text>(number).data, '1');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final change in ['dispose', 'thread', 'room']) {
    testWidgets('ACK after $change cannot update abandoned read context', (
      tester,
    ) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      if (change == 'dispose') await tester.pumpWidget(const SizedBox.shrink());
      if (change == 'thread') key.currentState!.activeThreadId = r'$thread';
      if (change == 'room') {
        final replacement = Room(
          id: room.id,
          client: client,
          membership: Membership.join,
        )..notificationCount = 7;
        client.rooms[0] = replacement;
      }
      api.answer(0);
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/11
      expect(room.notificationCount, 2);
      expect(badgeCalls, isEmpty);
      if (change == 'room') expect(client.rooms.single.notificationCount, 7);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'automatic count-only reconciliation retries its failed HTTP receipt',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      api.answer(0);
      await flush(tester);
      api.serverTail = [
        {
          'event_id': r'$a',
          'sender': '@bob:example.invalid',
          'origin_server_ts': 2000,
          'type': EventTypes.Message,
          'content': {'msgtype': 'm.text', 'body': 'A'},
        },
      ];
      await tester.runAsync(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: 'count-retry',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  unreadNotifications: UnreadNotificationCounts(
                    notificationCount: 2,
                    highlightCount: 1,
                  ),
                ),
              },
            ),
          ),
        ),
      );
      await flush(tester);
      expect(
        api.requests,
        hasLength(2),
        reason: 'prod subscriber сам начинает сверку',
      );
      api.answer(1, status: 503);
      await flush(tester);
      expect(
        room.notificationCount,
        2,
        reason: 'GET без ACK не является прочтением',
      );
      await tester.pump(const Duration(seconds: 3));
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/5
      expect(api.requests, hasLength(3));
      api.answer(2);
      await flush(tester);
      expect(room.notificationCount, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'replacement timeline with same target can resume failed delivery',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      api.answer(0, status: 503);
      await flush(tester);
      final old = timeline;
      timeline = buildPeekTimeline(room, List.of(old.events));
      old.cancelSubscriptions();
      key.currentState!.timeline = timeline;
      key.currentState!.updateView();
      await flush(tester);
      await tester.pump(const Duration(seconds: 1));
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/8
      expect(
        api.requests,
        hasLength(2),
        reason: 'контекст сменился, но допустимый A не потерян',
      );
      api.answer(1);
      await flush(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real incoming SDK sync auto update uses same read coverage generation',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      api.answer(0);
      await flush(tester);
      await tester.runAsync(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: 'incoming-b',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  unreadNotifications: UnreadNotificationCounts(
                    notificationCount: 1,
                    highlightCount: 0,
                  ),
                  timeline: TimelineUpdate(
                    events: [
                      MatrixEvent(
                        eventId: r'$incoming',
                        senderId: '@bob:example.invalid',
                        originServerTs: DateTime.fromMillisecondsSinceEpoch(
                          4000,
                        ),
                        type: EventTypes.Message,
                        content: {'msgtype': 'm.text', 'body': 'B по SDK sync'},
                      ),
                    ],
                    limited: false,
                  ),
                ),
              },
            ),
          ),
        ),
      );
      await flush(tester);
      expect(
        api.requests,
        hasLength(2),
        reason: 'реальный Timeline.onUpdate вызывает production updateView',
      );
      expect(api.requests.last['m.fully_read'], r'$incoming');
      api.answer(1);
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/4
      expect(
        room.notificationCount,
        0,
        reason: 'snapshot не устаревает от своего же sync',
      );
      expect(find.text('B по SDK sync'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (
    var repetition = 0;
    repetition <
        const int.fromEnvironment('ACK_RACE_REPETITIONS', defaultValue: 1);
    repetition++
  ) {
    testWidgets(
      'fast HTTP ACK before final same-batch onSync does not restore unread dot ($repetition)',
      (tester) async {
        await mount(tester);
        key.currentState!.setReadMarker();
        await flush(tester);
        api.answer(0);
        await flush(tester);
        final order = <String>[];
        final trace = <String>[];
        final confirmed = ConfirmedReadState.forClient(client);
        String state() =>
            'last=${room.lastEvent?.eventId} count=${room.notificationCount} '
            'highlight=${room.highlightCount} covers=${confirmed.covers(room)} '
            'unknown=${confirmed.hasUnknownCoverage(room)} '
            'roomSame=${identical(client.getRoomById(room.id), room)} '
            'user=${client.userID} raw=${timeline.events.first.eventId} '
            'requests=${api.requests.map((r) => r['m.fully_read']).toList()}';
        trace.add('initial ${state()}');
        api.onReceipt = () => trace.add('HTTP ${state()}');
        void onRevision() {
          trace.add('revision ${state()}');
          if (room.lastEvent?.eventId == r'$fast-b' &&
              room.notificationCount == 0 &&
              confirmed.covers(room)) {
            order.add('ack');
          }
        }

        confirmed.revision.addListener(onRevision);
        final subscription = client.onSync.stream.listen((sync) {
          trace.add('sync=${sync.nextBatch} ${state()}');
          if (sync.nextBatch == 'slow-batch') order.add('sync');
        });
        addTearDown(() {
          confirmed.revision.removeListener(onRevision);
          return subscription.cancel();
        });
        api.immediateReceipt = true;
        await tester.runAsync(
          () => client.handleSync(
            SyncUpdate(
              nextBatch: 'slow-batch',
              rooms: RoomsUpdate(
                join: {
                  room.id: JoinedRoomUpdate(
                    unreadNotifications: UnreadNotificationCounts(
                      notificationCount: 1,
                      highlightCount: 0,
                    ),
                    timeline: TimelineUpdate(
                      events: [
                        MatrixEvent(
                          eventId: r'$fast-b',
                          senderId: '@bob:example.invalid',
                          originServerTs: DateTime.fromMillisecondsSinceEpoch(
                            4000,
                          ),
                          type: EventTypes.Message,
                          content: {
                            'msgtype': 'm.text',
                            'body': 'быстрый ACK B',
                          },
                        ),
                      ],
                      limited: false,
                    ),
                  ),
                  '!other-batch:example.invalid': JoinedRoomUpdate(
                    timeline: TimelineUpdate(
                      events: [
                        for (var i = 0; i < 40; i++)
                          MatrixEvent(
                            eventId: '\$other-$i',
                            senderId: '@bob:example.invalid',
                            originServerTs: DateTime.fromMillisecondsSinceEpoch(
                              5000 + i,
                            ),
                            type: EventTypes.Message,
                            content: {
                              'msgtype': 'm.text',
                              'body': 'другая комната $i',
                            },
                          ),
                      ],
                      limited: false,
                    ),
                  ),
                },
              ),
            ),
          ),
        );
        await flush(tester);
        expect(order, contains('ack'), reason: trace.join('\n'));
        expect(order, contains('sync'));
        expect(
          order.indexOf('ack'),
          lessThan(order.indexOf('sync')),
          reason:
              'обязательное предусловие: ACK реально опередил финальный onSync',
        );
        // AC:RL-read-marker-ack-consistency/4
        expect(room.notificationCount, 0);
        expect(
          room.hasUnseenMessages,
          isFalse,
          reason: '${trace.join('\n')}\nfinal ${state()}',
        );
        final title = find.descendant(
          of: find.byType(ChatListItem),
          matching: find.text('ACK чат'),
        );
        expect(tester.widget<Text>(title).style?.fontWeight, isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'separate sync replaying same raw A with positive count remains unknown',
    (tester) async {
      await mount(tester);
      key.currentState!.setReadMarker();
      await flush(tester);
      api.answer(0);
      await flush(tester);
      room.roomAccountData[LatestReceiptState.eventType] = BasicEvent(
        type: LatestReceiptState.eventType,
        content: {
          'global': {
            'latest': {'e': r'$a', 'ts': 2000},
            'others': <String, dynamic>{},
          },
        },
      );
      await tester.runAsync(
        () => client.handleSync(
          SyncUpdate(
            nextBatch: 'separate-same-a',
            rooms: RoomsUpdate(
              join: {
                room.id: JoinedRoomUpdate(
                  unreadNotifications: UnreadNotificationCounts(
                    notificationCount: 2,
                    highlightCount: 0,
                  ),
                  timeline: TimelineUpdate(
                    events: [
                      MatrixEvent(
                        eventId: r'$a',
                        senderId: '@bob:example.invalid',
                        originServerTs: DateTime.fromMillisecondsSinceEpoch(
                          2000,
                        ),
                        type: EventTypes.Message,
                        content: {'msgtype': 'm.text', 'body': r'$a'},
                      ),
                    ],
                    limited: false,
                  ),
                ),
              },
            ),
          ),
        ),
      );
      await flush(tester);
      // AC:RL-read-marker-ack-consistency/5
      expect(room.notificationCount, 2);
      expect(room.hasUnseenMessages, isTrue);
      final number = find.descendant(
        of: find.byType(UnreadRoomsBadge),
        matching: find.byType(Text),
      );
      expect(tester.widget<Text>(number).data, '1');
      if (api.requests.length == 2) {
        api.answer(1);
        await flush(tester);
        expect(
          room.notificationCount,
          2,
          reason: 'empty GET не доказывает server tail',
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('history SDK sync does not replace live unread coverage tail', (
    tester,
  ) async {
    await mount(tester);
    room.prev_batch = 'history-from';
    api.serverTail = [
      {
        'event_id': r'$historic',
        'sender': '@bob:example.invalid',
        'origin_server_ts': 500,
        'type': EventTypes.Message,
        'content': {'msgtype': 'm.text', 'body': 'старое сообщение'},
      },
    ];
    // SDK сам формирует history SyncUpdate(nextBatch:'', direction:b).
    await tester.runAsync(() => room.requestHistory(historyCount: 1));
    expect(api.tailRequests.single.queryParameters['from'], 'history-from');
    await flush(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    expect(api.requests.single['m.fully_read'], r'$a');
    api.answer(0);
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/4
    expect(
      room.notificationCount,
      0,
      reason: 'history page не является новым live tail',
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final change in ['thread', 'gap', 'raw']) {
    testWidgets('$change with unchanged preview cannot clear room count', (
      tester,
    ) async {
      await mount(tester);
      if (change == 'thread') key.currentState!.activeThreadId = r'$thread';
      if (change == 'gap') timeline.allowNewEvent = false;
      if (change == 'raw') {
        timeline.events.insert(
          0,
          Event(
            eventId: r'$reaction',
            senderId: '@bob:example.invalid',
            originServerTs: DateTime.fromMillisecondsSinceEpoch(4000),
            type: EventTypes.Reaction,
            content: {
              'm.relates_to': {
                'rel_type': 'm.annotation',
                'event_id': r'$a',
                'key': '👍',
              },
            },
            room: room,
          ),
        );
      }
      key.currentState!.setReadMarker(eventId: r'$a');
      await flush(tester);
      if (api.requests.isNotEmpty) {
        api.answer(0);
        await flush(tester);
      }
      // AC:RL-read-marker-ack-consistency/10
      expect(room.notificationCount, 2);
      expect(key.currentState!.readMarkerEventId, r'$before');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('HTTP timeout then retry then B then late ACK A preserves B', (
    tester,
  ) async {
    await mount(tester);
    key.currentState!.setReadMarker();
    await flush(tester);
    await tester.pump(const Duration(seconds: 30));
    await flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await flush(tester);
    expect(api.requests, hasLength(2));
    final b = _message(room, r'$b', 3000);
    room.lastEvent = b;
    timeline.events.insert(0, b);
    room.notificationCount = 3;
    api.answer(0);
    api.answer(1);
    await flush(tester);
    // AC:RL-read-marker-ack-consistency/11
    expect(room.notificationCount, 3);
    expect(key.currentState!.readMarkerEventId, r'$before');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
