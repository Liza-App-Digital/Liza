// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/utils/stories/deleted_stories_store.dart';
import 'package:liza/utils/stories/stories_extension.dart';

import 'test_client.dart';

// ledger:RL-stories-delete-persists
//
// LABA-2618: удалённая автором сторис возвращалась при повторном открытии
// вьюера, а повторное «Удалить» слало PUT redact снова. Корень на проде не
// установлен — воспроизводим СОСТОЯНИЕ: PUT redact прошёл, а локальная копия
// события осталась нередактированной. FakeMatrixApi так и ведёт себя: на PUT
// отвечает 200, но m.room.redaction через sync не проталкивает.
void main() {
  late Client client;
  late SharedPreferences prefs;
  late List<String> reports;
  const roomId = '!myStories:example.invalid';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    client = await prepareTestClient(loggedIn: true);
    reports = [];
    reportResurrectedStory = reports.add;
    resetResurrectedStoryReports();
  });

  tearDown(() async {
    await client.dispose(closeDatabase: true);
  });

  MatrixEvent storyJson(String id, int ts) => MatrixEvent.fromJson({
    'type': 'm.room.message',
    'content': {
      'msgtype': 'm.image',
      'body': 'Story',
      'com.liza.story': {'expires_ts': ts + 3600000, 'overlays': []},
    },
    'sender': client.userID,
    'status': EventStatus.synced.intValue,
    'event_id': id,
    'origin_server_ts': ts,
  });

  Future<Room> roomWithStories(List<String> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final room = Room(id: roomId, client: client);
    client.rooms = [...client.rooms, room];
    await client.handleSync(
      SyncUpdate(
        nextBatch: 'batch1',
        rooms: RoomsUpdate(
          join: {
            roomId: JoinedRoomUpdate(
              timeline: TimelineUpdate(
                events: [
                  for (var i = 0; i < ids.length; i++)
                    storyJson(ids[i], now - 60000 + i * 1000),
                ],
              ),
            ),
          },
        ),
      ),
    );
    return room;
  }

  int redactPuts() => FakeMatrixApi.calledEndpoints.entries
      .where((e) => e.key.contains('/redact/'))
      .fold(0, (sum, e) => sum + e.value.length);

  DeletedStoriesStore store({String? scope, int Function()? now}) =>
      DeletedStoriesStore(prefs, scope: scope ?? client.userID, now: now);

  group('isActiveStoryEvent', () {
    test('AC:RL-stories-delete-persists/1 — «ожившая» копия удалённой '
        'сторис (полный content, не redacted) отсекается по списку '
        'удалённых', () async {
      final room = await roomWithStories([r'$s1']);
      final event = (await client.activeStoriesOf(room)).single;
      final now = DateTime.now().millisecondsSinceEpoch;

      expect(event.redacted, isFalse);
      // Прежний фильтр (без списка удалённых) такую копию пропускал.
      expect(isActiveStoryEvent(event, nowMs: now), isTrue);
      expect(
        isActiveStoryEvent(event, nowMs: now, deletedIds: {r'$s1'}),
        isFalse,
      );
    });

    test('redacted-событие отсекается явно', () async {
      final room = await roomWithStories([r'$s1']);
      final event = (await client.activeStoriesOf(room)).single;
      event.setRedactionEvent(
        Event(
          type: EventTypes.Redaction,
          eventId: r'$r1',
          content: {'redacts': r'$s1'},
          redacts: r'$s1',
          senderId: client.userID!,
          originServerTs: DateTime.now(),
          room: room,
        ),
      );
      expect(
        isActiveStoryEvent(event, nowMs: DateTime.now().millisecondsSinceEpoch),
        isFalse,
      );
    });

    test('AC:RL-stories-delete-persists/4 — без удалённых (зритель) '
        'активная сторис видна как прежде', () async {
      final room = await roomWithStories([r'$s1', r'$s2']);
      final active = await client.activeStoriesOf(room);
      expect(active.map((e) => e.eventId), [r'$s1', r'$s2']);
    });
  });

  group('удаление', () {
    test('AC:RL-stories-delete-persists/1 — после удаления сторис не '
        'возвращается при повторном открытии, хотя локальная копия так и '
        'осталась нередактированной', () async {
      final room = await roomWithStories([r'$s1', r'$s2']);
      final deleted = store();
      final target = (await client.activeStoriesOf(
        room,
        deleted: deleted,
      )).first;

      await client.deleteStory(target, deleted: deleted);

      // Повторное открытие вьюера = новый activeStoriesWithTimeline.
      final reopened = await client.activeStoriesOf(room, deleted: store());
      expect(reopened.map((e) => e.eventId), [r'$s2']);
    });

    test('AC:RL-stories-delete-persists/3 — повторное удаление той же '
        'сторис не шлёт второй PUT redact', () async {
      final room = await roomWithStories([r'$s1']);
      final deleted = store();
      final target = (await client.activeStoriesOf(room)).single;

      await client.deleteStory(target, deleted: deleted);
      // «Ожившая» копия того же события — как 07.09 на проде.
      final again = (await client.activeStoriesOf(room)).single;
      await client.deleteStory(again, deleted: deleted);
      await client.deleteStory(again, deleted: store());

      expect(redactPuts(), 1);
    });

    test('AC:RL-stories-delete-persists/2 — удалённая считается уже '
        'удалённой (пункт «Удалить» скрыт по этому предикату)', () async {
      final room = await roomWithStories([r'$s1']);
      final deleted = store();
      final target = (await client.activeStoriesOf(room)).single;

      expect(client.isStoryAlreadyDeleted(target, deleted), isFalse);
      await client.deleteStory(target, deleted: deleted);
      expect(client.isStoryAlreadyDeleted(target, deleted), isTrue);
    });

    test('AC:RL-stories-delete-persists/7 — упавший PUT не помечает '
        'сторис удалённой', () async {
      final room = await roomWithStories([r'$s1']);
      final deleted = store();
      final target = (await client.activeStoriesOf(room)).single;
      // FakeMatrixApi отвечает 404 на запрос к неизвестному origin → PUT
      // redact падает.
      FakeMatrixApi.currentApi!.servers.clear();

      await expectLater(
        client.deleteStory(target, deleted: deleted),
        throwsA(anything),
      );
      expect(deleted.contains(r'$s1'), isFalse);
    });
  });

  group('датчик [stories-resurrected]', () {
    test('AC:RL-stories-delete-persists/6 — отсечение «ожившей» копии '
        'репортится ровно один раз на событие', () async {
      final room = await roomWithStories([r'$s1']);
      var now = DateTime.now().millisecondsSinceEpoch;
      final deleted = store(now: () => now);
      final target = (await client.activeStoriesOf(room)).single;
      await client.deleteStory(target, deleted: deleted);

      // Сразу после PUT редакция ещё не доехала по sync — это не «воскрешение».
      await client.activeStoriesOf(room, deleted: deleted);
      expect(reports, isEmpty);

      now += DeletedStoriesStore.settleMs + 1;
      await client.activeStoriesOf(room, deleted: deleted);
      await client.activeStoriesOf(room, deleted: deleted);

      expect(reports, hasLength(1));
      expect(reports.single, startsWith('[stories-resurrected] '));
      expect(reports.single, isNot(contains(r'$s1')));
    });

    test(
      'нормально отредактированная удалённая сторис датчик не будит',
      () async {
        final room = await roomWithStories([r'$s1']);
        final event = (await client.activeStoriesOf(room)).single;
        event.setRedactionEvent(
          Event(
            type: EventTypes.Redaction,
            eventId: r'$r1',
            content: {'redacts': r'$s1'},
            redacts: r'$s1',
            senderId: client.userID!,
            originServerTs: DateTime.now(),
            room: room,
          ),
        );
        expect(isResurrectedStoryEvent(event, {r'$s1'}), isFalse);
      },
    );
  });

  group('DeletedStoriesStore', () {
    test('AC:RL-stories-delete-persists/8 — изоляция по аккаунту', () async {
      await store(scope: '@alice:a').add(r'$s1');
      expect(store(scope: '@alice:a').contains(r'$s1'), isTrue);
      expect(store(scope: '@bob:b').contains(r'$s1'), isFalse);
    });

    test('AC:RL-stories-delete-persists/8 — записи старше 25 ч '
        'выбрасываются', () async {
      var now = 1000000000000;
      final s = store(now: () => now);
      await s.add(r'$old');
      now += DeletedStoriesStore.ttlMs - 1;
      expect(s.contains(r'$old'), isTrue);
      now += 2;
      expect(s.contains(r'$old'), isFalse);
      await s.add(r'$new');
      expect(
        prefs.getStringList('com.liza.stories.deleted.${client.userID}'),
        hasLength(1),
      );
    });
  });
}
