// ledger:RL-edited-message-read-cursor
// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/models/timeline_chunk.dart';

import 'package:liza/utils/read_marker_target.dart';

import 'test_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Client client;
  late Room room;
  late Event original;
  final timelines = <Timeline>[];

  setUp(() async {
    client = await prepareTestClient(loggedIn: true);
    client.backgroundSync = false;
    await client.abortSync();
    room = Room(id: '!target:example.invalid', client: client);
    original = Event(
      eventId: r'$original',
      senderId: '@bob:example.invalid',
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1000),
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Text, 'body': 'исходное'},
      room: room,
    );
  });
  tearDown(() async {
    for (final timeline in timelines) {
      timeline.cancelSubscriptions();
    }
    timelines.clear();
    await client.dispose(closeDatabase: true);
  });

  Event edit({String id = r'$edit', int ts = 2000}) => Event(
    eventId: id,
    senderId: original.senderId,
    originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    type: EventTypes.Message,
    content: {
      'msgtype': MessageTypes.Text,
      'body': '* редакция',
      'm.new_content': <String, dynamic>{
        'msgtype': MessageTypes.Text,
        'body': 'редакция',
      },
      'm.relates_to': {
        'rel_type': RelationshipTypes.edit,
        'event_id': original.eventId,
      },
    },
    room: room,
  );

  Timeline timelineOf(List<Event> events) {
    room.lastEvent = events.first;
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: events),
    );
    timelines.add(timeline);
    return timeline;
  }

  ReadMarkerTarget? target(Timeline timeline, {String? retry}) {
    final display = original.getDisplayEvent(timeline);
    return editedReadMarkerTarget(
      original: original,
      timeline: timeline,
      displayedVersionId: display.eventId,
      displayedFingerprint: readVersionFingerprint(display),
      retryCursorId: retry,
    );
  }

  test('single/chain: cursor равен точной SDK display редакции', () {
    final first = edit();
    final latest = edit(id: r'$latest', ts: 3000);
    for (final edits in [
      [first],
      [latest, first],
    ]) {
      final plan = target(timelineOf([...edits, original]));
      expect(plan?.visibleRowId, original.eventId);
      expect(plan?.displayedVersionId, edits.first.eventId);
      expect(plan?.cursorId, edits.first.eventId);
    }
  });

  test('валидная смена msgtype не запрещена', () {
    final replacement = edit();
    replacement.content['m.new_content'] = {
      'msgtype': MessageTypes.Notice,
      'body': 'редакция notice',
    };
    expect(target(timelineOf([replacement, original])), isNotNull);
  });

  test(
    'Timeline data version ignores no-op but detects same-ID content/order',
    () {
      final timeline = timelineOf([edit(), original]);
      final version = TimelineReadDataVersion();
      expect(version.update(timeline), isFalse);
      expect(version.update(timeline), isFalse);
      timeline.isRequestingHistory = true;
      expect(version.update(timeline), isFalse);
      timeline.isRequestingHistory = false;
      expect(version.update(timeline), isFalse);
      original.content['body'] = 'расшифрованный текст прежнего ID';
      expect(version.update(timeline), isTrue);
      expect(version.update(timeline), isFalse);
      timeline.events.insert(0, timeline.events.removeLast());
      expect(version.update(timeline), isTrue);
      expect(version.update(timeline), isFalse);
    },
  );

  for (final invalid in [
    'sender',
    'room',
    'type',
    'empty-state-key',
    'missing-new-content',
    'malformed-new-content',
    'missing-body',
    'missing-msgtype',
    'undecryptable',
    'redacted',
    'inverted-ts',
    'edit-of-edit',
    'new-content-thread',
  ]) {
    test('не повышает cursor: $invalid', () {
      var replacement = edit();
      switch (invalid) {
        case 'sender':
          replacement.senderId = '@mallory:example.invalid';
        case 'room':
          replacement = Event.fromJson(
            replacement.toJson(),
            Room(id: '!other:example.invalid', client: client),
          );
        case 'type':
          replacement.type = EventTypes.Sticker;
        case 'empty-state-key':
          replacement.stateKey = '';
        case 'missing-new-content':
          replacement.content.remove('m.new_content');
        case 'malformed-new-content':
          replacement.content['m.new_content'] = 'строка';
        case 'missing-body':
          replacement.content['m.new_content'] = {'msgtype': 'm.text'};
        case 'missing-msgtype':
          replacement.content['m.new_content'] = {'body': 'редакция'};
        case 'undecryptable':
          replacement.type = EventTypes.Encrypted;
        case 'redacted':
          replacement.unsigned = {
            'redacted_because': {
              'event_id': r'$redaction',
              'type': EventTypes.Redaction,
              'sender': original.senderId,
              'content': <String, dynamic>{},
              'origin_server_ts': 4000,
            },
          };
        case 'inverted-ts':
          replacement = edit(ts: 500);
        case 'edit-of-edit':
          original.content['m.relates_to'] = {
            'rel_type': RelationshipTypes.edit,
            'event_id': r'$older',
          };
        case 'new-content-thread':
          (replacement.content['m.new_content'] as Map)['m.relates_to'] = {
            'rel_type': RelationshipTypes.thread,
            'event_id': r'$thread',
          };
      }
      expect(target(timelineOf([replacement, original])), isNull);
    });
  }

  test('equal-ts, поздняя старая редакция и изменённый fingerprint', () {
    final replacement = edit();
    final equal = edit(id: r'$equal');
    expect(target(timelineOf([equal, replacement, original])), isNull);
    final older = edit(id: r'$lateOld', ts: 1500);
    expect(target(timelineOf([older, replacement, original])), isNull);
    final timeline = timelineOf([replacement, original]);
    final display = original.getDisplayEvent(timeline);
    final fingerprint = readVersionFingerprint(display);
    (replacement.content['m.new_content'] as Map)['body'] = 'другой текст';
    expect(
      editedReadMarkerTarget(
        original: original,
        timeline: timeline,
        displayedVersionId: display.eventId,
        displayedFingerprint: fingerprint,
      ),
      isNull,
    );
  });

  test(
    'непокрытые message/thread/reaction между original и edit запрещены',
    () {
      for (final relation in [
        null,
        RelationshipTypes.thread,
        RelationshipTypes.reaction,
      ]) {
        final intervening = Event(
          eventId: r'$unseen',
          senderId: original.senderId,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(1500),
          type: EventTypes.Message,
          content: {
            'msgtype': MessageTypes.Text,
            'body': 'непокрытое',
            if (relation != null)
              'm.relates_to': {'rel_type': relation, 'event_id': r'$thread'},
          },
          room: room,
        );
        expect(target(timelineOf([edit(), intervening, original])), isNull);
      }
    },
  );

  test(
    'retry после e3 сохраняет cursor; смена display запрещает старый retry',
    () {
      final replacement = edit();
      final timeline = timelineOf([replacement, original]);
      final next = Event.fromJson(
        original.toJson()..['event_id'] = r'$e3',
        room,
      );
      timeline.events.insert(0, next);
      room.lastEvent = next;
      expect(target(timeline), isNull);
      expect(
        target(timeline, retry: replacement.eventId)?.cursorId,
        replacement.eventId,
      );
      final newer = edit(id: r'$newEdit', ts: 4000);
      timeline.events.insert(0, newer);
      timeline.addAggregatedEvent(newer);
      expect(target(timeline, retry: replacement.eventId), isNull);
    },
  );

  test(
    'history/fragment/requesting и несовпадение preview запрещают promotion',
    () {
      final timeline = timelineOf([edit(), original]);
      timeline.allowNewEvent = false;
      expect(target(timeline), isNull);
      timeline.allowNewEvent = true;
      timeline.isFragmentedTimeline = true;
      expect(target(timeline), isNull);
      timeline.isFragmentedTimeline = false;
      timeline.isRequestingHistory = true;
      expect(target(timeline), isNull);
      timeline.isRequestingHistory = false;
      room.lastEvent = original;
      expect(target(timeline), isNull);
    },
  );
}
