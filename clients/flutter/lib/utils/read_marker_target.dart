import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

/// Строка, показанная версия и сетевой cursor — разные сущности у правки.
class ReadMarkerTarget {
  final String visibleRowId;
  final String displayedVersionId;
  final String cursorId;
  final String? displayedFingerprint;

  const ReadMarkerTarget({
    required this.visibleRowId,
    required this.displayedVersionId,
    required this.cursorId,
    this.displayedFingerprint,
  });

  bool get isEdit => cursorId != visibleRowId;
}

/// Снимок содержимого, а не ссылка на изменяемый SDK Event. Смена расшифровки
/// или redaction при прежнем ID отзывает доказательство прошлого кадра.
String readVersionFingerprint(Event event) => jsonEncode(event.toJson());

/// Timeline.onUpdate также вызывается при начале/неудаче history-запроса.
/// Только реальное изменение данных отзывает отрицательный order cache.
class TimelineReadDataVersion {
  List<String>? _events;

  bool update(Timeline timeline) {
    final events = timeline.events.map(readVersionFingerprint).toList();
    final previous = _events;
    _events = events;
    return previous != null &&
        !const ListEquality<String>().equals(previous, events);
  }
}

bool _validReplacement(Event original, Event edit) {
  final content = edit.content['m.new_content'];
  return identical(edit.room, original.room) &&
      identical(edit.room.client, original.room.client) &&
      edit.senderId == original.senderId &&
      edit.type == original.type &&
      edit.type == EventTypes.Message &&
      edit.stateKey == null &&
      edit.status.isSynced &&
      !edit.redacted &&
      edit.relationshipType == RelationshipTypes.edit &&
      edit.relationshipEventId == original.eventId &&
      edit.originServerTs.isAfter(original.originServerTs) &&
      content is Map<String, dynamic> &&
      content['body'] is String &&
      content['msgtype'] is String &&
      content['msgtype'] != MessageTypes.BadEncrypted &&
      content['msgtype'] != EventTypes.Encrypted &&
      // Replacement нового replacement или thread — другой вид доказательства.
      (content['m.relates_to'] is! Map ||
          !{
            RelationshipTypes.edit,
            RelationshipTypes.thread,
          }.contains((content['m.relates_to'] as Map)['rel_type']));
}

/// Узкое разрешение: между оригиналом и cursor только его валидные правки.
/// Для первого намерения cursor обязан быть raw/preview. Retry сохраняет
/// прежний cursor; новые события перед ним не превращаются в прочитанные.
ReadMarkerTarget? editedReadMarkerTarget({
  required Event original,
  required Timeline timeline,
  required String displayedVersionId,
  required String displayedFingerprint,
  String? retryCursorId,
}) {
  if (!timeline.allowNewEvent ||
      timeline.isFragmentedTimeline ||
      timeline.isRequestingFuture ||
      timeline.isRequestingHistory ||
      !identical(timeline.room, original.room) ||
      original.type != EventTypes.Message ||
      original.stateKey != null ||
      original.redacted ||
      !original.status.isSynced ||
      {
        RelationshipTypes.edit,
        RelationshipTypes.thread,
      }.contains(original.relationshipType)) {
    return null;
  }
  final cursorId = retryCursorId ?? displayedVersionId;
  if (cursorId == original.eventId || cursorId != displayedVersionId) {
    return null;
  }
  final raw = timeline.events.firstWhereOrNull((e) => e.status.isSynced);
  if (retryCursorId == null &&
      (raw?.eventId != cursorId ||
          original.room.lastEvent?.eventId != cursorId)) {
    return null;
  }
  final cursorIndex = timeline.events.indexWhere((e) => e.eventId == cursorId);
  final originalIndex = timeline.events.indexWhere(
    (e) => e.eventId == original.eventId,
  );
  if (cursorIndex < 0 || originalIndex <= cursorIndex) return null;
  final cursor = timeline.events[cursorIndex];
  for (var i = cursorIndex; i < originalIndex; i++) {
    if (!_validReplacement(original, timeline.events[i])) return null;
  }
  final edits = original.aggregatedEvents(timeline, RelationshipTypes.edit);
  // SDK 4.1 не имеет определённого tie-break для одинаковых timestamp.
  if (edits.where((e) => e.originServerTs == cursor.originServerTs).length !=
      1) {
    return null;
  }
  final display = original.getDisplayEvent(timeline);
  if (!_validReplacement(original, cursor) ||
      display.eventId != cursorId ||
      !const DeepCollectionEquality().equals(
        cursor.content['m.new_content'],
        display.content,
      ) ||
      readVersionFingerprint(display) != displayedFingerprint) {
    return null;
  }
  return ReadMarkerTarget(
    visibleRowId: original.eventId,
    displayedVersionId: display.eventId,
    cursorId: cursorId,
    displayedFingerprint: displayedFingerprint,
  );
}
