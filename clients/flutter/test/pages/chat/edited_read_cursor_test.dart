// ledger:RL-edited-message-read-cursor
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/widgets/matrix.dart' as liza_matrix;
import 'package:liza/widgets/read_version_witness.dart';

import '../../utils/test_client.dart';

class _MatrixState extends liza_matrix.MatrixState {
  _MatrixState(this.testClient);
  final Client testClient;
  @override
  Client get client => testClient;
}

void main() {
  late Client client;
  late Room room;
  late Event original;
  late Timeline timeline;
  late ScrollController scroll;
  late List<ReadVersionEvidence> frames;
  late List<SchedulerPhase> phases;
  late ValueNotifier<Widget> body;
  var primed = false;

  Event edit(String id, String body, int timestamp) => Event(
    eventId: id,
    senderId: original.senderId,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(timestamp),
    type: EventTypes.Message,
    room: room,
    content: {
      'msgtype': 'm.text',
      'body': '* $body',
      'm.new_content': <String, dynamic>{'msgtype': 'm.text', 'body': body},
      'm.relates_to': {'rel_type': 'm.replace', 'event_id': original.eventId},
    },
  );

  void aggregate(Event event) {
    timeline.events.insert(0, event);
    timeline.addAggregatedEvent(event);
    room.lastEvent = event;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    await client.abortSync();
    client.rooms.clear();
    room = Room(
      id: '!witness:example.invalid',
      client: client,
      membership: Membership.join,
    );
    client.rooms.add(room);
    room.setState(
      Event(
        eventId: r'$bob-member',
        senderId: '@bob:example.invalid',
        stateKey: '@bob:example.invalid',
        originServerTs: DateTime.fromMillisecondsSinceEpoch(1),
        type: EventTypes.RoomMember,
        room: room,
        content: {'membership': 'join', 'displayname': 'Боб'},
      ),
    );
    original = Event(
      eventId: r'$original',
      senderId: '@bob:example.invalid',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      type: EventTypes.Message,
      room: room,
      content: {'msgtype': 'm.text', 'body': 'original'},
    );
    timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [original], nextBatch: ''),
    );
    scroll = ScrollController();
    frames = [];
    phases = [];
    body = ValueNotifier(const SizedBox.shrink());
    primed = false;
  });

  tearDown(() async {
    scroll.dispose();
    body.dispose();
    timeline.cancelSubscriptions();
    await client.dispose(closeDatabase: true);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool offstage = false,
    VoidCallback? beforeFrame,
  }) async {
    if (!primed) {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ru'),
          localizationsDelegates: L10n.localizationsDelegates,
          supportedLocales: L10n.supportedLocales,
          home: Provider<liza_matrix.MatrixState>.value(
            value: _MatrixState(client),
            child: Scaffold(
              body: ValueListenableBuilder<Widget>(
                valueListenable: body,
                builder: (_, child, _) => child,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      primed = true;
    }
    if (beforeFrame != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => beforeFrame());
    }
    body.value = Offstage(
      offstage: offstage,
      child: Message(
        original,
        timeline: timeline,
        scrollController: scroll,
        colors: const [],
        onSelect: (_) {},
        onInfoTab: (_) {},
        scrollToEventId: (_) {},
        onSwipe: () {},
        onEdit: () {},
        onMention: () {},
        enterThread: (_) {},
        onReadVersion: (evidence) {
          frames.add(evidence);
          phases.add(SchedulerBinding.instance.schedulerPhase);
        },
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'actual edited Message evidence belongs to completed frame and expires on dispose',
    (tester) async {
      aggregate(edit(r'$edit', 'версия первого кадра', 2000));
      expect(frames, isEmpty);
      await mount(tester);
      expect(
        find.textContaining('версия первого кадра', findRichText: true),
        findsWidgets,
      );
      // AC:RL-edited-message-read-cursor/12
      expect(frames, hasLength(1));
      expect(phases.single, SchedulerPhase.postFrameCallbacks);
      expect(frames.single.visibleRowId, original.eventId);
      expect(frames.single.displayedVersionId, r'$edit');
      expect(frames.single.isCurrent(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(frames.single.isCurrent(), isFalse);
    },
  );

  testWidgets(
    'edit between actual Message build and frame invalidates old version',
    (tester) async {
      aggregate(edit(r'$edit1', 'первая редакция', 2000));
      await mount(
        tester,
        beforeFrame: () {
          aggregate(edit(r'$edit2', 'вторая редакция', 3000));
        },
      );
      expect(
        find.textContaining('первая редакция', findRichText: true),
        findsWidgets,
      );
      // AC:RL-edited-message-read-cursor/13
      expect(
        frames,
        isEmpty,
        reason: 'старый кадр не подтверждает пришедшую редакцию',
      );
      await mount(tester);
      expect(
        find.textContaining('вторая редакция', findRichText: true),
        findsWidgets,
      );
      expect(frames.single.displayedVersionId, r'$edit2');
      expect(frames.single.isCurrent(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'same event ID with changed decrypted content invalidates actual Message proof',
    (tester) async {
      final displayed = edit(r'$edit', 'до обновления содержимого', 2000);
      aggregate(displayed);
      await mount(tester);
      final oldEvidence = frames.single;
      expect(oldEvidence.isCurrent(), isTrue);
      (displayed.content['m.new_content'] as Map<String, dynamic>)['body'] =
          'после обновления содержимого';
      // AC:RL-edited-message-read-cursor/14
      expect(oldEvidence.isCurrent(), isFalse);
      await mount(tester);
      expect(
        find.textContaining('после обновления содержимого', findRichText: true),
        findsWidgets,
      );
      expect(frames.last.displayedVersionId, oldEvidence.displayedVersionId);
      expect(
        frames.last.displayedFingerprint,
        isNot(oldEvidence.displayedFingerprint),
      );
      expect(frames.last.isCurrent(), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Offstage actual Message cannot witness edit until onstage', (
    tester,
  ) async {
    aggregate(edit(r'$edit', 'скрытая редакция', 2000));
    await mount(tester, offstage: true);
    // AC:RL-edited-message-read-cursor/15
    expect(frames, isEmpty);
    expect(
      find.textContaining('скрытая редакция', findRichText: true),
      findsNothing,
    );
    await mount(tester);
    expect(
      find.textContaining('скрытая редакция', findRichText: true),
      findsWidgets,
    );
    expect(frames.single.displayedVersionId, r'$edit');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final custom in [
    'com.liza.widget',
    'com.liza.poll',
    'com.liza.gallery',
  ]) {
    testWidgets(
      'actual Message custom $custom without renderer proof is fail-closed',
      (tester) async {
        final displayed = edit(r'$edit', 'нестандартная редакция', 2000);
        (displayed.content['m.new_content'] as Map<String, dynamic>)[custom] = {
          'unknown': true,
          if (custom == 'com.liza.gallery') 'id': 'album',
        };
        aggregate(displayed);
        await mount(tester);
        // AC:RL-edited-message-read-cursor/16
        expect(frames, isEmpty);
        expect(find.byType(ReadVersionWitness), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
