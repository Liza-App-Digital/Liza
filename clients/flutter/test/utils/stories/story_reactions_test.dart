// ignore_for_file: depend_on_referenced_packages

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:liza/utils/stories/story_reactions.dart';
import 'package:liza/utils/stories/story_seen_logic.dart';

// ledger:RL-stories-reactions
//
// LABA-2616: автор не видел реакции на свою сторис. Сервер их хранит, а лента
// автора теряет после limited sync (SDK стирает фрагмент в БД, догрузка
// истории сторис-комнаты фильтрует только m.room.message). Источник для
// автора — лента ∪ /relations без снятых.

const _roomId = '!stories:example.invalid';
const _author = '@alice:example.invalid';

/// Клиент, у которого /relations отвечает заданным снимком (FakeMatrixApi
/// на этот путь всегда отдаёт пустой chunk).
class _RelationsClient extends Client {
  _RelationsClient(super.clientName, {required super.database})
    : super(httpClient: FakeMatrixApi());

  final relations = <String, List<List<MatrixEvent>>>{};
  final requested = <(String, String?)>[];

  @override
  Future<GetRelatingEventsWithRelTypeAndEventTypeResponse>
  getRelatingEventsWithRelTypeAndEventType(
    String roomId,
    String eventId,
    String relType,
    String eventType, {
    String? from,
    String? to,
    int? limit,
    Direction? dir,
    bool? recurse,
  }) async {
    requested.add((eventId, from));
    final pages = relations[eventId] ?? const [];
    final page = from == null ? 0 : int.parse(from);
    return GetRelatingEventsWithRelTypeAndEventTypeResponse(
      chunk: page < pages.length ? pages[page] : const [],
      nextBatch: page + 1 < pages.length ? '${page + 1}' : null,
    );
  }
}

MatrixEvent _story(String id, int ts) => MatrixEvent.fromJson({
  'type': EventTypes.Message,
  'content': {
    'msgtype': 'm.image',
    'body': 'Story',
    'com.liza.story': {'expires_ts': ts + 3600000, 'overlays': []},
  },
  'sender': _author,
  'event_id': id,
  'origin_server_ts': ts,
});

MatrixEvent _reaction(String id, String sender, String target, String key) =>
    MatrixEvent.fromJson({
      'type': EventTypes.Reaction,
      'content': {
        'm.relates_to': {
          'rel_type': RelationshipTypes.reaction,
          'event_id': target,
          'key': key,
        },
      },
      'sender': sender,
      'event_id': id,
      'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
    });

MatrixEvent _member(String id, String userId) => MatrixEvent.fromJson({
  'type': EventTypes.RoomMember,
  'state_key': userId,
  'content': {'membership': 'join'},
  'sender': userId,
  'event_id': id,
  'origin_server_ts': DateTime.now().millisecondsSinceEpoch,
});

StoryReaction _r(String sender, String target, String key) =>
    (sender: sender, target: target, key: key);

void main() {
  group('mergeStoryReactions / агрегат / строки листа', () {
    test('AC:RL-stories-reactions/1 реакция на сегмент видна в агрегате и в '
        'листе; AC:RL-stories-reactions/2 реакция на другой сегмент — нет', () {
      final merged = mergeStoryReactions(
        live: {r'$r1': _r('@b:x', r'$s1', '❤️')},
        server: {r'$r2': _r('@c:x', r'$s0', '😂')},
        redacted: const {},
      );
      expect(storyReactionsAggregate(merged, r'$s1'), {'❤️': 1});
      expect(storyReactionsAggregate(merged, r'$s0'), {'😂': 1});
      expect(storyReactorsOf(merged, r'$s1'), {'@b:x'});
      final rows = storyViewerRows(
        viewers: const ['@b:x'],
        reactions: merged,
        segmentId: r'$s1',
      );
      expect(rows.single.userId, '@b:x');
      expect(rows.single.keys, ['❤️']);
    });

    test('AC:RL-stories-reactions/3 B ❤️, C 😂, D без реакции → '
        '«❤️ 1 😂 1», в листе B и C сверху, D ниже без эмодзи', () {
      final merged = mergeStoryReactions(
        live: {r'$rb': _r('@b:x', r'$s1', '❤️')},
        server: {r'$rc': _r('@c:x', r'$s1', '😂')},
        redacted: const {},
      );
      expect(storyReactionsAggregate(merged, r'$s1'), {'❤️': 1, '😂': 1});
      final rows = storyViewerRows(
        viewers: const ['@d:x', '@b:x', '@c:x'],
        reactions: merged,
        segmentId: r'$s1',
      );
      expect(rows.map((r) => r.userId), ['@b:x', '@c:x', '@d:x']);
      expect(rows.map((r) => r.keys), [
        ['❤️'],
        ['😂'],
        <String>[],
      ]);
    });

    test('AC:RL-stories-reactions/4 смена реакции — у зрителя одна новая; '
        'снятие — зритель остаётся без эмодзи', () {
      // Смена: старая снята redact-ом, новая пришла по sync.
      final changed = mergeStoryReactions(
        live: {r'$new': _r('@b:x', r'$s1', '😂')},
        server: {r'$old': _r('@b:x', r'$s1', '❤️')},
        redacted: const {r'$old'},
      );
      expect(storyReactionsAggregate(changed, r'$s1'), {'😂': 1});
      // Снятие: реакции нет, receipt зритель уже прислал.
      final removed = mergeStoryReactions(
        live: const {},
        server: {r'$old': _r('@b:x', r'$s1', '❤️')},
        redacted: const {r'$old'},
      );
      expect(storyReactionsAggregate(removed, r'$s1'), isEmpty);
      final rows = storyViewerRows(
        viewers: const ['@b:x'],
        reactions: removed,
        segmentId: r'$s1',
      );
      expect(rows.single.keys, isEmpty);
    });

    test('AC:RL-stories-reactions/6 реакция из /relations и из ленты '
        'считается один раз', () {
      final reaction = _r('@b:x', r'$s1', '❤️');
      final merged = mergeStoryReactions(
        live: {r'$r1': reaction},
        server: {r'$r1': reaction},
        redacted: const {},
      );
      expect(storyReactionsAggregate(merged, r'$s1'), {'❤️': 1});
    });

    test('AC:RL-stories-reactions/6b снятая реакция из устаревшего снимка '
        'сервера не воскресает', () {
      final merged = mergeStoryReactions(
        live: const {},
        server: {r'$r1': _r('@b:x', r'$s1', '😂')},
        redacted: const {r'$r1'},
      );
      expect(merged, isEmpty);
    });
  });

  group('viewersInTimeline: реакция = просмотр', () {
    const timeline = [r'$join', r'$s1', r'$s0'];
    final positions = timelinePositions(timeline);
    const anchors = {r'$s0', r'$s1'};
    final excluded = {_author, '@ai:x'};

    Set<String> viewers(
      String segmentId,
      Map<String, String> receipts,
      Map<String, StoryReaction> reactions,
    ) => viewersInTimeline(
      positions: positions,
      segmentId: segmentId,
      anchorIds: anchors,
      viewerReceipts: receipts,
      reactors: storyReactorsOf(reactions, segmentId),
      isExcluded: excluded.contains,
    );

    test('AC:RL-stories-reactions/10 реакция без receipt — зритель '
        'засчитан, лист и 👁 читают одну функцию', () {
      final reactions = {r'$r': _r('@b:x', r'$s1', '❤️')};
      // receipt B ушёл на служебное событие — сам по себе не просмотр.
      final s1 = viewers(r'$s1', {'@b:x': r'$join'}, reactions);
      expect(s1, {'@b:x'});
      expect(
        viewersInTimeline(
          positions: positions,
          segmentId: r'$s1',
          anchorIds: anchors,
          viewerReceipts: const {'@b:x': r'$join'},
          reactors: storyReactorsOf(reactions, r'$s1'),
          isExcluded: excluded.contains,
        ).length,
        s1.length,
      );
      // Реакция на s1 не делает B зрителем s0.
      expect(viewers(r'$s0', {'@b:x': r'$join'}, reactions), isEmpty);
    });

    test('AC:RL-stories-reactions/7 зритель с другого homeserver '
        'учитывается', () {
      final reactions = {
        r'$r': _r(
          '@daniel.furman:synapse.liza.laba.prodamus.tech',
          r'$s1',
          '❤️',
        ),
      };
      expect(viewers(r'$s1', const {}, reactions), {
        '@daniel.furman:synapse.liza.laba.prodamus.tech',
      });
      expect(storyReactionsAggregate(reactions, r'$s1'), {'❤️': 1});
    });

    test('AC:RL-stories-reactions/9 автор и AI-боты не входят в зрителей', () {
      final reactions = {
        r'$a': _r(_author, r'$s1', '❤️'),
        r'$ai': _r('@ai:x', r'$s1', '👍'),
        r'$b': _r('@b:x', r'$s1', '😂'),
      };
      expect(viewers(r'$s1', {_author: r'$s1', '@ai:x': r'$s1'}, reactions), {
        '@b:x',
      });
    });
  });

  group('серверный снимок реакций (/relations)', () {
    late _RelationsClient client;

    setUp(() async {
      client = _RelationsClient(
        'reactions',
        database: await MatrixSdkDatabase.init(
          'reactions',
          database: await databaseFactoryFfi.openDatabase(':memory:'),
          sqfliteFactory: databaseFactoryFfi,
        ),
      );
      await client.checkHomeserver(Uri.parse('https://fakeserver.notexisting'));
      await client.login(
        LoginType.mLoginToken,
        identifier: AuthenticationUserIdentifier(user: _author),
        password: '1234',
      );
    });

    tearDown(() => client.dispose(closeDatabase: true));

    test('лента: снятая реакция и событие m.room.redaction попадают в '
        'снятые', () {
      final room = Room(id: _roomId, client: client);
      final live = Event.fromMatrixEvent(
        _reaction(r'$r1', '@b:x', r'$s1', '❤️'),
        room,
      );
      final redaction = Event.fromMatrixEvent(
        MatrixEvent.fromJson({
          'type': EventTypes.Redaction,
          'redacts': r'$r2',
          'content': <String, Object?>{},
          'sender': '@c:x',
          'event_id': r'$red',
          'origin_server_ts': 0,
        }),
        room,
      );
      final result = storyReactionsInTimeline([live, redaction]);
      expect(result.live.keys, [r'$r1']);
      expect(result.redacted, {r'$r2'});
    });

    test('AC:RL-stories-reactions/5 после limited sync лента автора без '
        'реакции, а /relations её возвращает', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final room = Room(id: _roomId, client: client);
      client.rooms = [...client.rooms, room];
      final reaction = _reaction(r'$r1', '@b:x', r'$s1', '❤️');
      await client.handleSync(
        SyncUpdate(
          nextBatch: 'b1',
          rooms: RoomsUpdate(
            join: {
              _roomId: JoinedRoomUpdate(
                timeline: TimelineUpdate(
                  events: [_story(r'$s1', now - 60000), reaction],
                ),
              ),
            },
          ),
        ),
      );
      // Офлайн накопилось больше sync-окна: сервер шлёт limited-ленту.
      await client.handleSync(
        SyncUpdate(
          nextBatch: 'b2',
          rooms: RoomsUpdate(
            join: {
              _roomId: JoinedRoomUpdate(
                timeline: TimelineUpdate(
                  limited: true,
                  prevBatch: 'gap',
                  events: [
                    for (var i = 0; i < 3; i++) _member('\$m$i', '@v$i:x'),
                  ],
                ),
              ),
            },
          ),
        ),
      );
      final timeline = await room.getTimeline();
      addTearDown(timeline.cancelSubscriptions);
      final inTimeline = storyReactionsInTimeline(timeline.events);
      // Прежний источник автора (только лента) реакцию потерял.
      expect(inTimeline.live, isEmpty);

      client.relations[r'$s1'] = [
        [reaction],
      ];
      final merged = mergeStoryReactions(
        live: inTimeline.live,
        server: await fetchStoryReactions(room, r'$s1'),
        redacted: inTimeline.redacted,
      );
      expect(storyReactionsAggregate(merged, r'$s1'), {'❤️': 1});
      expect(storyReactorsOf(merged, r'$s1'), {'@b:x'});
    });

    test('пагинация /relations по next_batch и кап страниц', () async {
      final room = Room(id: _roomId, client: client);
      client.relations[r'$s1'] = [
        for (var page = 0; page < 7; page++)
          [_reaction('\$r$page', '@u$page:x', r'$s1', '❤️')],
      ];
      final all = await fetchStoryReactions(room, r'$s1', maxPages: 10);
      expect(all.length, 7);
      client.requested.clear();
      final capped = await fetchStoryReactions(room, r'$s1');
      expect(capped.length, 5);
      expect(client.requested.map((r) => r.$2), [null, '1', '2', '3', '4']);
    });

    test('снятая реакция и реакция на чужой сегмент из ответа не '
        'берутся', () async {
      final room = Room(id: _roomId, client: client);
      client.relations[r'$s1'] = [
        [
          _reaction(r'$ok', '@b:x', r'$s1', '❤️'),
          _reaction(r'$other', '@c:x', r'$s0', '😂'),
          MatrixEvent.fromJson({
            'type': EventTypes.Reaction,
            'content': <String, Object?>{},
            'sender': '@d:x',
            'event_id': r'$gone',
            'origin_server_ts': 0,
            'unsigned': {
              'redacted_because': {
                'type': EventTypes.Redaction,
                'content': <String, Object?>{},
                'sender': '@d:x',
                'event_id': r'$red',
                'origin_server_ts': 0,
              },
            },
          }),
        ],
      ];
      final fetched = await fetchStoryReactions(room, r'$s1');
      expect(fetched.keys, [r'$ok']);
    });
  });
}
