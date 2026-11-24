// Liza News: аватарки «прочитал до сюда» скрыты только в комнате с флагом
// com.liza.chat.hide_read_receipts; во всех остальных комнатах — как раньше.
// Спека: docs/superpowers/specs/2026-09-16-liza-news-hide-read-receipts-design.md
//
// ledger:RL-liza-news-hide-read-receipts
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../../utils/test_client.dart';

// Message тянет клиента через Matrix.of(context); подменяем только геттер
// client, как в channel_peek_message_render_test.
class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);

  final Client _client;

  @override
  Client get client => _client;
}

const _bot = '@liza-news:example.invalid';

void main() {
  late Client client;

  Room buildRoom(String id, {Object? flag, String? chatType}) {
    final room = Room(id: id, client: client, membership: Membership.join);
    room.setState(
      StrippedStateEvent(
        type: EventTypes.RoomCreate,
        content: {
          'creator': _bot,
          if (chatType != null) 'com.liza.chat.type': chatType,
        },
        senderId: _bot,
        stateKey: '',
      ),
    );
    if (flag != null) {
      room.setState(
        StrippedStateEvent(
          type: hideReadReceiptsState,
          content: {'enabled': flag},
          senderId: _bot,
          stateKey: '',
        ),
      );
    }
    return room;
  }

  List<MessageReadReceipt> readers(Room room, int n) => [
    for (var i = 0; i < n; i++)
      MessageReadReceipt(User('@reader$i:example.invalid', room: room), i),
  ];

  // Рендерит ленту из [count] постов бота; ресипты — под постом [readAt].
  Future<Timeline> pumpFeed(
    WidgetTester tester,
    Room room, {
    required int count,
    required int readAt,
    required int readersCount,
  }) async {
    final events = [
      for (var i = count - 1; i >= 0; i--)
        Event(
          type: EventTypes.Message,
          eventId: '\$post$i',
          senderId: _bot,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1000 + i),
          content: {'msgtype': 'm.text', 'body': 'пост $i'},
          room: room,
        ),
    ];
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: events, nextBatch: ''),
    );
    final seen = readers(room, readersCount);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Provider<liza_matrix.MatrixState>.value(
          value: _TestMatrixState(client),
          child: Scaffold(
            body: ListView.builder(
              reverse: true,
              controller: scrollController,
              itemCount: timeline.events.length,
              itemBuilder: (context, i) {
                final event = timeline.events[i];
                return Message(
                  event,
                  timeline: timeline,
                  scrollController: scrollController,
                  colors: const [Colors.grey, Colors.blue],
                  seenByUsers: event.eventId == '\$post$readAt'
                      ? seen
                      : const [],
                  onSelect: (_) {},
                  onInfoTab: (_) {},
                  scrollToEventId: (_) {},
                  onSwipe: () {},
                  onMention: () {},
                  onEdit: () {},
                  enterThread: null,
                );
              },
            ),
          ),
        ),
      ),
    );
    // pumpAndSettle не сходится: живой Client крутит фоновые таймеры.
    await tester.pump(const Duration(milliseconds: 500));
    return timeline;
  }

  // Читатели вне room state догружают профиль (10 с таймаут) — гасим таймеры.
  Future<void> drainProfileTimeouts(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 11));
  }

  Future<void> initClient(WidgetTester tester) async {
    // runAsync — sqflite ffi внутри prepareTestClient делает реальный I/O.
    await tester.runAsync(() async {
      client = await prepareTestClient(loggedIn: true);
    });
    addTearDown(client.dispose);
  }

  group('Room.hideReadReceipts', () {
    testWidgets('true только при bool enabled == true', (tester) async {
      await initClient(tester);
      expect(buildRoom('!a:x').hideReadReceipts, isFalse);
      expect(buildRoom('!b:x', flag: false).hideReadReceipts, isFalse);
      expect(buildRoom('!c:x', flag: 'true').hideReadReceipts, isFalse);
      expect(buildRoom('!d:x', flag: 1).hideReadReceipts, isFalse);
      expect(buildRoom('!e:x', flag: true).hideReadReceipts, isTrue);
    });

    // AC:RL-liza-news-hide-read-receipts/5
    testWidgets(
      'флаг, лежащий в non-preload боксе (так его сохранила бы старая сборка), '
      'читается после postLoad — открытия таймлайна',
      (tester) async {
        await initClient(tester);
        final room = Room(id: '!news:example.invalid', client: client);
        expect(
          client.importantStateEvents.contains(hideReadReceiptsState),
          isFalse,
          reason: 'тип намеренно НЕ important — см. hideReadReceiptsState',
        );
        await tester.runAsync(() async {
          await client.database.storeEventUpdate(
            room.id,
            Event(
              type: hideReadReceiptsState,
              content: {'enabled': true},
              eventId: '\$flag',
              senderId: _bot,
              originServerTs: DateTime.now(),
              stateKey: '',
              room: room,
            ),
            EventUpdateType.state,
            client,
          );
          expect(room.partial, isTrue);
          expect(room.hideReadReceipts, isFalse);
          await room.postLoad();
        });
        expect(room.hideReadReceipts, isTrue);
      },
    );
  });

  group('SeenByAvatars на реальном Message', () {
    // AC:RL-liza-news-hide-read-receipts/1
    for (final c in const [
      (name: 'последний пост, 1 читатель', readAt: 0, n: 1),
      (name: 'последний пост, 12 читателей', readAt: 0, n: 12),
      (name: 'промежуточный пост, 3 читателя', readAt: 1, n: 3),
    ]) {
      testWidgets('комната с флагом: аватарок нет — ${c.name}', (tester) async {
        await initClient(tester);
        final room = buildRoom('!news:example.invalid', flag: true);
        await pumpFeed(
          tester,
          room,
          count: 3,
          readAt: c.readAt,
          readersCount: c.n,
        );
        expect(find.text('пост ${c.readAt}'), findsOneWidget);
        expect(find.byType(SeenByAvatars), findsNothing);
        // AC:RL-liza-news-hide-read-receipts/3 — «сколько» не всплывает
        // через канальный счётчик просмотров.
        expect(find.byType(ChannelPostStatsRow), findsNothing);
      });
    }

    // AC:RL-liza-news-hide-read-receipts/2
    for (final c in const [
      (name: 'без флага', flag: null),
      (name: 'enabled:false', flag: false),
      (name: 'enabled:"true" строкой', flag: 'true'),
    ]) {
      testWidgets('обычная комната: ровно один ряд аватарок — ${c.name}', (
        tester,
      ) async {
        await initClient(tester);
        final room = buildRoom('!group:example.invalid', flag: c.flag);
        await pumpFeed(tester, room, count: 3, readAt: 1, readersCount: 3);
        expect(find.byType(SeenByAvatars), findsOneWidget);
        await drainProfileTimeouts(tester);
      });
    }

    // AC:RL-liza-news-hide-read-receipts/3
    testWidgets('настоящий канал: как раньше — аватарок нет, статистика есть', (
      tester,
    ) async {
      await initClient(tester);
      final room = buildRoom(
        '!channel:example.invalid',
        chatType: channelChatType,
      );
      await pumpFeed(tester, room, count: 2, readAt: 0, readersCount: 3);
      expect(find.byType(SeenByAvatars), findsNothing);
      expect(find.byType(ChannelPostStatsRow), findsWidgets);
    });

    // AC:RL-liza-news-hide-read-receipts/6
    testWidgets(
      'флаг пришёл при открытом чате — аватарки исчезают на rebuild',
      (tester) async {
        await initClient(tester);
        final room = buildRoom('!news:example.invalid');
        await pumpFeed(tester, room, count: 2, readAt: 0, readersCount: 3);
        expect(find.byType(SeenByAvatars), findsOneWidget);

        room.setState(
          StrippedStateEvent(
            type: hideReadReceiptsState,
            content: {'enabled': true},
            senderId: _bot,
            stateKey: '',
          ),
        );
        // ChatView перестраивает ленту по onRoomState (chat_view.dart); здесь —
        // тот же rebuild тем же деревом.
        await pumpFeed(tester, room, count: 2, readAt: 0, readersCount: 3);
        expect(find.byType(SeenByAvatars), findsNothing);
        await drainProfileTimeouts(tester);
      },
    );
  });
}
