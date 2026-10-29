// ledger:RL-read-receipt-viewport-based
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_event_list.dart';
import 'package:liza/utils/channel_peek.dart';
import 'package:liza/utils/chat_scroll_geometry.dart';
import 'package:liza/utils/formatting_text_controller.dart';
import 'package:liza/utils/read_marker_logic.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;

import '../../utils/test_client.dart';

// Саша Н., 2026-10-28: «отсечка непрочитанных пропала» / «стала после первого
// непрочитанного». Открытие центрировало соседа СТАРШЕ m.fully_read
// (scrollToIndex(eventIndex + 1)), длинное прочитанное сообщение уводило
// отсечку за нижний край, а 1 px верхушки первого непрочитанного засчитывался
// как «увидено». Здесь — реальная лента (ChatEventList) и реальные
// scrollTargetIndex / alignRowBottomToDivider / newestVisibleEventId, тот же
// путь, что в ChatController._tryLoadTimeline.

class _TestMatrixState extends liza_matrix.MatrixState {
  _TestMatrixState(this._client);
  final Client _client;
  @override
  Client get client => _client;
}

class _FakeChatController extends Fake implements ChatController {
  _FakeChatController(this.room, this.timeline, this.readMarkerEventId);

  @override
  final Room room;
  @override
  Timeline? timeline;
  @override
  String? activeThreadId;
  @override
  int? animateInEventIndex;
  @override
  String readMarkerEventId;
  @override
  String? scrollToEventIdMarker;
  @override
  final AutoScrollController scrollController = AutoScrollController();
  @override
  List<Event> selectedEvents = [];
  @override
  final Set<String> expandedEventIds = {};

  @override
  final FormattingTextEditingController sendController =
      FormattingTextEditingController();
  @override
  List<Map<String, dynamic>> get discussionEvents => const [];

  final _bubbleKeys = <String, GlobalKey>{};
  @override
  GlobalKey bubbleKeyOf(String eventId) =>
      _bubbleKeys.putIfAbsent(eventId, GlobalKey.new);

  @override
  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    if (key is! ValueKey<String>) return null;
    final index = thisEventsKeyMap[key.value];
    return index == null ? null : index + 1;
  }

  @override
  void requestHistory([dynamic _]) {}
  @override
  void requestFuture() {}
  @override
  Future<void> reloadDiscussionEvents() async {}
  @override
  void onMessageContextMenu(Event event) {}
  @override
  void onSelectMessage(Event event) {}
  @override
  void showEventInfo([Event? event]) {}
  @override
  void replyAction({Event? replyTo}) {}
  @override
  void editSelectedEventAction() {}
  @override
  void enterThread(String eventId) {}
  @override
  void expandEventsFrom(Event event, bool expand) {}
  @override
  Future<void> scrollToEventId(
    String eventId, {
    bool highlightEvent = true,
    int retryDepth = 0,
  }) async {}

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      '_FakeChatController';
}

const _viewport = Size(400, 800);
final _long = List.filled(60, 'длинная строка ответа Лизы,').join(' ');

/// 40 сообщений, E0 — старейшее. [longIds] — длиннее экрана.
List<MatrixEvent> _raw(Set<String> longIds) => [
  for (var i = 39; i >= 0; i--)
    MatrixEvent(
      type: EventTypes.Message,
      eventId: 'E$i',
      senderId: '@author:example.invalid',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000 + i * 60000),
      content: {
        'msgtype': 'm.text',
        'body': longIds.contains('E$i') ? '$_long E$i' : 'сообщение E$i',
      },
    ),
];

Future<T> _drive<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  future.then((v) {
    value = v;
    done = true;
  });
  for (var i = 0; i < 400 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue, reason: 'прокрутка не завершилась');
  return value;
}

Future<_FakeChatController> _mount(
  WidgetTester tester, {
  required Set<String> longIds,
  required String readMarker,
}) async {
  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late final Client client;
  await tester.runAsync(() async {
    client = await prepareTestClient(loggedIn: true);
  });
  addTearDown(client.dispose);
  final room = buildPeekRoom(client, '!room:example.invalid');
  final timeline = buildPeekTimeline(
    room,
    peekEventsToTimeline(_raw(longIds), room),
  );
  addTearDown(timeline.cancelSubscriptions);
  final controller = _FakeChatController(room, timeline, readMarker);
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Provider<liza_matrix.MatrixState>.value(
        value: _TestMatrixState(client),
        child: Scaffold(body: ChatEventList(controller: controller)),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  return controller;
}

/// Путь открытия из `_tryLoadTimeline`: scrollToEventId → доводка.
Future<void> _openAtDivider(
  WidgetTester tester,
  _FakeChatController controller,
) async {
  final index = scrollTargetIndex(
    controller.timeline!.events,
    controller.readMarkerEventId,
  );
  await _drive(
    tester,
    controller.scrollController.scrollToIndex(
      index,
      preferPosition: AutoScrollPosition.middle,
    ),
  );
  await _drive(
    tester,
    alignRowBottomToDivider(
      controller.scrollController,
      controller.readMarkerEventId,
      isAlive: () => true,
    ),
  );
  await tester.pump();
}

void main() {
  for (final c in [
    (name: 'короткие', longIds: <String>{}),
    (name: 'прочитанное длиннее экрана', longIds: {'E20'}),
    (name: 'первое непрочитанное длиннее экрана', longIds: {'E21'}),
    (name: 'оба длиннее экрана (сценарий Саши)', longIds: {'E20', 'E21'}),
  ]) {
    testWidgets(
      'AC:RL-read-receipt-viewport-based/19 открытие (${c.name}): отсечка в '
      'верхней трети экрана, первое непрочитанное не засчитано, если не '
      'дочитано до низа',
      (tester) async {
        final controller = await _mount(
          tester,
          longIds: c.longIds,
          readMarker: 'E20',
        );
        await _openAtDivider(tester, controller);

        final divider = find.text('Непрочитанное');
        expect(divider, findsOneWidget);
        final top = tester.getTopLeft(divider).dy;
        expect(top, greaterThanOrEqualTo(0));
        expect(top, lessThan(_viewport.height / 3));

        final geometry = collectTagGeometry(controller.scrollController)!;
        final read = geometry.tags.firstWhere((t) => t.eventId == 'E20');
        expect(
          (read.rect.bottom - _viewport.height * unreadDividerViewportFraction)
              .abs(),
          lessThan(2),
          reason: 'низ строки m.fully_read (отсечка) — на 22 % от верха',
        );
        // Увидено — самое новое, чей низ на экране; всё новее него — нет.
        final seen = newestVisibleEventId(geometry.tags, geometry.viewport)!;
        final seenTag = geometry.tags.firstWhere((t) => t.eventId == seen);
        expect(seenTag.rect.bottom, lessThanOrEqualTo(_viewport.height + 0.5));
        for (final t in geometry.tags.where((t) => t.index < seenTag.index)) {
          expect(
            t.rect.bottom > _viewport.height + 0.5 || t.rect.height == 0,
            isTrue,
            reason: '${t.eventId} новее $seen и дочитан — не засчитан',
          );
        }
        if (c.longIds.contains('E21')) {
          expect(seen, 'E20', reason: 'видна лишь верхушка E21');
        }
      },
    );
  }

  testWidgets(
    'AC:RL-read-receipt-viewport-based/21 scrollTargetIndex центрирует саму '
    'цель, а не соседа старше',
    (tester) async {
      final controller = await _mount(tester, longIds: {'E9'}, readMarker: '');
      final index = scrollTargetIndex(controller.timeline!.events, 'E10');
      await _drive(
        tester,
        controller.scrollController.scrollToIndex(
          index,
          preferPosition: AutoScrollPosition.middle,
        ),
      );
      await tester.pump();
      final center = tester.getCenter(find.text('сообщение E10'));
      expect((center.dy - _viewport.height / 2).abs(), lessThan(80));
    },
  );

  test(
    'AC:RL-read-receipt-viewport-based/21 скрытый член альбома → индекс anchor; '
    'обычное событие → свой индекс в ленте',
    () async {
      final client = await prepareTestClient(loggedIn: true);
      addTearDown(client.dispose);
      final room = buildPeekRoom(client, '!room:example.invalid');
      MatrixEvent photo(String id, int i, int ts) => MatrixEvent(
        type: EventTypes.Message,
        eventId: id,
        senderId: '@author:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
        content: {
          'msgtype': 'm.image',
          'body': '$id.jpg',
          'url': 'mxc://example.invalid/$id',
          'com.liza.gallery': {'id': 'g1', 'i': i, 'n': 3},
        },
      );
      MatrixEvent text(String id, int ts) => MatrixEvent(
        type: EventTypes.Message,
        eventId: id,
        senderId: '@author:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
        content: {'msgtype': 'm.text', 'body': id},
      );
      // Новейшее первым, как в Timeline.events.
      final events = peekEventsToTimeline([
        text('T2', 6000),
        photo('P2', 2, 5000),
        photo('P1', 1, 4000),
        photo('P0', 0, 3000),
        text('T1', 2000),
      ], room);
      expect(scrollTargetIndex(events, 'T2'), 0);
      expect(scrollTargetIndex(events, 'P0'), 3);
      expect(
        scrollTargetIndex(events, 'P2'),
        3,
        reason: 'P2 скрыт → anchor P0',
      );
      expect(
        scrollTargetIndex(events, 'P1'),
        3,
        reason: 'P1 скрыт → anchor P0',
      );
      expect(scrollTargetIndex(events, 'T1'), 4);
      expect(scrollTargetIndex(events, 'нет'), -1);
    },
  );
}
