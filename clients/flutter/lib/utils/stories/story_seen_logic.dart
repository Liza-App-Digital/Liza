/// Чистая логика позиционной семантики "просмотрено" для сторисов.
/// Позиция = мой m.read receipt в отсортированном списке активных сегментов;
/// локальные отметки (StoriesSeenStore) дополняют её для мгновенного UI.
library;

int indexOfEvent(List<String> segmentIds, String? eventId) =>
    eventId == null ? -1 : segmentIds.indexOf(eventId);

bool segmentSeen({
  required int index,
  required int receiptIndex,
  required String segmentId,
  required bool Function(String) isLocallySeen,
}) =>
    index <= receiptIndex || isLocallySeen(segmentId);

int firstUnseenIndex({
  required List<String> segmentIds,
  required int receiptIndex,
  required bool Function(String) isLocallySeen,
}) {
  for (var i = 0; i < segmentIds.length; i++) {
    final seen = segmentSeen(
      index: i,
      receiptIndex: receiptIndex,
      segmentId: segmentIds[i],
      isLocallySeen: isLocallySeen,
    );
    if (!seen) return i;
  }
  return 0;
}

bool hasUnseenPositional({
  required List<String> segmentIds,
  required int receiptIndex,
  required bool Function(String) isLocallySeen,
}) {
  for (var i = 0; i < segmentIds.length; i++) {
    final seen = segmentSeen(
      index: i,
      receiptIndex: receiptIndex,
      segmentId: segmentIds[i],
      isLocallySeen: isLocallySeen,
    );
    if (!seen) return true;
  }
  return false;
}

/// eventId -> позиция в таймлайне (newest-first, порядок SDK: 0 — новейшее).
Map<String, int> timelinePositions(List<String> timelineIds) => {
  for (var i = 0; i < timelineIds.length; i++) timelineIds[i]: i,
};

/// Число зрителей сегмента [segmentId] по порядку таймлайна (LABA-2617).
///
/// Receipt — одна отметка «прочитал всё до этого события», поэтому зритель
/// засчитан, если его receipt-событие не старше сегмента. Сравниваем позиции
/// ([positions] из [timelinePositions]), а не `originServerTs`: у федеративных
/// авторов часы расходятся. Засчитываем только receipt на [anchorIds] —
/// сообщениях сторис-комнаты, включая удалённые: удаление сегмента, на котором стоит
/// receipt, не должно обнулять просмотры более ранних. Receipt на своей реакции
/// ([reactions]: eventId -> отправитель и целевой сегмент) засчитывает только
/// целевой сегмент — реакцию на старый могли поставить, когда вышли новые.
/// Receipt на служебных событиях (вход участника) — не просмотр: массовые
/// отметки старых клиентов дали бы ложных зрителей. Событие вне загруженного
/// таймлайна — зритель не засчитан.
int viewsCountInTimeline({
  required Map<String, int> positions,
  required String segmentId,
  required Set<String> anchorIds,
  required Map<String, String> viewerReceipts,
  Map<String, ({String sender, String target})> reactions = const {},
  required bool Function(String userId) isExcluded,
}) {
  final segmentPos = positions[segmentId];
  if (segmentPos == null) return 0;
  var count = 0;
  viewerReceipts.forEach((userId, eventId) {
    if (isExcluded(userId)) return;
    final reaction = reactions[eventId];
    final anchor = reaction != null && reaction.sender == userId
        ? reaction.target
        : eventId;
    if (!anchorIds.contains(anchor)) return;
    final pos = positions[anchor];
    if (pos == null) return;
    if (reaction != null ? anchor == segmentId : pos <= segmentPos) count++;
  });
  return count;
}
