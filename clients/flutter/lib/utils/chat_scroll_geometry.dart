import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:liza/pages/chat/events/gallery.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/utils/read_marker_logic.dart';

/// Прямоугольники смонтированных тегов ленты в координатах viewport'а
/// (`localToGlobal` относительно viewport'а — Flutter сам учитывает
/// reverse-направление). eventId — из `ValueKey` тега: индексы `tagMap`
/// сдвигаются между вставкой события и rebuild'ом. `null` — viewport'а ещё
/// нет (ранний кадр).
({List<VisibleTag> tags, Size viewport})? collectTagGeometry(
  AutoScrollController controller,
) {
  RenderBox? viewport;
  final tags = <VisibleTag>[];
  for (final entry in controller.tagMap.entries) {
    final key = entry.value.widget.key;
    if (key is! ValueKey<String>) continue;
    final ctx = entry.value.context;
    if (!ctx.mounted) continue;
    final box = ctx.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) continue;
    if (viewport == null) {
      try {
        final RenderObject vp = RenderAbstractViewport.of(box);
        if (vp is! RenderBox) return null;
        viewport = vp;
      } catch (_) {
        return null;
      }
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: viewport);
    tags.add((index: entry.key, eventId: key.value, rect: origin & box.size));
  }
  if (viewport == null) return null;
  return (tags: tags, viewport: viewport.size);
}

/// Индекс строки ленты, к которой крутить ради [eventId]. Индекс тега =
/// индекс события в ленте (`AutoScrollTag(index: i)` в chat_event_list.dart);
/// унаследованный из FluffyChat `eventIndex + 1` центрировал соседа СТАРШЕ
/// цели. Скрытый член альбома своей строки не имеет — целимся в anchor.
/// Скрытое событие (правка, state) — по ленте с ним как исключением: его
/// место займёт ближайшая старшая видимая строка. `-1` — события в ленте нет.
int scrollTargetIndex(List<Event> events, String eventId, {String? threadId}) {
  final targetId =
      galleryAnchorMap(
        events.filterByVisibleInGui(threadId: threadId),
      )[eventId] ??
      eventId;
  final target = events.firstWhereOrNull((e) => e.eventId == targetId);
  if (target == null) return -1;
  return events
      .filterByVisibleInGui(exceptionEventId: targetId, threadId: threadId)
      .indexOf(target);
}

const int _dividerAlignAttempts = 3;

/// Доводит прокрутку так, чтобы низ строки [rowId] (там рисуется отсечка
/// «Непрочитанное») встал на [unreadDividerViewportFraction] высоты экрана от
/// верха. `scrollToIndex` лишь монтирует строку и центрирует её — длинное
/// прочитанное сообщение по центру уводило отсечку за нижний край (Саша Н.,
/// 2026-10-28). Строка могла ещё не разложиться за один кадр (ленивая сборка
/// длинной ленты) — несколько попыток. [isAlive] — экран ещё открыт.
Future<void> alignRowBottomToDivider(
  AutoScrollController controller,
  String rowId, {
  required bool Function() isAlive,
}) async {
  var found = false;
  for (var attempt = 0; attempt < _dividerAlignAttempts; attempt++) {
    await WidgetsBinding.instance.endOfFrame;
    if (!isAlive() || !controller.hasClients) return;
    final geometry = collectTagGeometry(controller);
    final row = geometry?.tags.firstWhereOrNull((t) => t.eventId == rowId);
    if (geometry == null || row == null) continue;
    found = true;
    final position = controller.position;
    final target = dividerScrollPixels(
      pixels: position.pixels,
      dividerBottom: row.rect.bottom,
      viewportHeight: geometry.viewport.height,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < 1) return;
    controller.jumpTo(target);
  }
  if (!found) {
    Logs().w(
      'alignRowBottomToDivider: строки $rowId нет на экране за '
      '$_dividerAlignAttempts кадра — отсечка там, где оставил scrollToIndex',
    );
  }
}
