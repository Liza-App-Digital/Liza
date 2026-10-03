import 'package:matrix/matrix.dart';

/// Реакция зрителя на сегмент сторис: кто, на какой сегмент, какой эмодзи.
typedef StoryReaction = ({String sender, String target, String key});

/// Строка листа «Просмотры»: зритель и эмодзи его реакций на сегмент.
typedef StoryViewerRow = ({String userId, List<String> keys});

/// Действующая реакция из события или null (не реакция, снята, без эмодзи).
StoryReaction? storyReactionOf(Event event) {
  if (event.type != EventTypes.Reaction || event.redacted) return null;
  final relates = event.content.tryGetMap<String, Object?>('m.relates_to');
  if (relates?.tryGet<String>('rel_type') != RelationshipTypes.reaction) {
    return null;
  }
  final target = relates?.tryGet<String>('event_id');
  final key = relates?.tryGet<String>('key');
  if (target == null || key == null) return null;
  return (sender: event.senderId, target: target, key: key);
}

/// Реакции и снятия, которые видны в загруженной ленте комнаты.
({Map<String, StoryReaction> live, Set<String> redacted})
storyReactionsInTimeline(Iterable<Event> events) {
  final live = <String, StoryReaction>{};
  final redacted = <String>{};
  for (final e in events) {
    if (e.type == EventTypes.Redaction) {
      if (e.redacts case final id?) redacted.add(id);
    } else if (e.type == EventTypes.Reaction) {
      final reaction = storyReactionOf(e);
      if (reaction == null) {
        redacted.add(e.eventId);
      } else {
        live[e.eventId] = reaction;
      }
    }
  }
  return (live: live, redacted: redacted);
}

/// Единый источник реакций сторис для автора (LABA-2616): лента ∪ снимок
/// сервера по `event_id`. Снятые реакции вычитаются из обоих источников —
/// снимок мог быть получен до redact и не должен её воскрешать.
Map<String, StoryReaction> mergeStoryReactions({
  required Map<String, StoryReaction> live,
  required Map<String, StoryReaction> server,
  required Set<String> redacted,
}) => {
  for (final entry in server.entries)
    if (!redacted.contains(entry.key)) entry.key: entry.value,
  for (final entry in live.entries)
    if (!redacted.contains(entry.key)) entry.key: entry.value,
};

/// emoji -> число реакций на сегмент [segmentId].
Map<String, int> storyReactionsAggregate(
  Map<String, StoryReaction> reactions,
  String segmentId,
) {
  final result = <String, int>{};
  for (final r in reactions.values) {
    if (r.target != segmentId) continue;
    result[r.key] = (result[r.key] ?? 0) + 1;
  }
  return result;
}

/// Отреагировавшие на сегмент [segmentId].
Set<String> storyReactorsOf(
  Map<String, StoryReaction> reactions,
  String segmentId,
) => {
  for (final r in reactions.values)
    if (r.target == segmentId) r.sender,
};

/// Строки листа «Просмотры»: отреагировавшие сверху, порядок внутри групп —
/// как в [viewers].
List<StoryViewerRow> storyViewerRows({
  required Iterable<String> viewers,
  required Map<String, StoryReaction> reactions,
  required String segmentId,
}) {
  final keys = <String, List<String>>{};
  for (final r in reactions.values) {
    if (r.target != segmentId) continue;
    final list = keys.putIfAbsent(r.sender, () => []);
    if (!list.contains(r.key)) list.add(r.key);
  }
  final rows = [
    for (final userId in viewers)
      (userId: userId, keys: keys[userId] ?? const <String>[]),
  ];
  final reacted = rows.where((r) => r.keys.isNotEmpty);
  final rest = rows.where((r) => r.keys.isEmpty);
  return [...reacted, ...rest];
}

/// Реакции на сегмент с сервера (`/relations`). Лента автора теряет реакции
/// после limited sync: SDK стирает её фрагмент в БД, а догрузка истории
/// сторис-комнаты фильтрует только `m.room.message`.
Future<Map<String, StoryReaction>> fetchStoryReactions(
  Room room,
  String segmentId, {
  int maxPages = 5,
}) async {
  final result = <String, StoryReaction>{};
  String? from;
  for (var page = 0; page < maxPages; page++) {
    final resp = await room.client.getRelatingEventsWithRelTypeAndEventType(
      room.id,
      segmentId,
      RelationshipTypes.reaction,
      EventTypes.Reaction,
      from: from,
      limit: 100,
    );
    for (final event in resp.chunk) {
      final reaction = storyReactionOf(Event.fromMatrixEvent(event, room));
      if (reaction != null && reaction.target == segmentId) {
        result[event.eventId] = reaction;
      }
    }
    from = resp.nextBatch;
    if (from == null) return result;
  }
  Logs().w('Story reactions: hit $maxPages pages cap for $segmentId');
  return result;
}
