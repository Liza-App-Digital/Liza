import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/events/gallery.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/typing_indicators.dart';
import 'package:liza/utils/account_config.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/gallery_read_receipts.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/widgets/matrix.dart';

/// На desktop/web оборачивает сообщение в [SelectionArea] (выделение текста
/// мышью), но с пустым `contextMenuBuilder` — нативное меню выделения не
/// показываем, правый клик уходит в наш Liza-поповер. На mobile выделение в
/// пузыре не нужно (копирование — через поповер), поэтому возвращаем сообщение
/// как есть, без [SelectionArea] (иначе long-press вызывал бы лупу/ОС-меню).
Widget _selectableMessage({required bool selectable, required Widget child}) {
  if (!selectable) return child;
  return SelectionArea(
    contextMenuBuilder: (context, selectableRegionState) =>
        const SizedBox.shrink(),
    child: child,
  );
}

class ChatEventList extends StatelessWidget {
  final ChatController controller;

  const ChatEventList({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final timeline = controller.timeline;

    if (timeline == null) {
      return const Center(child: CupertinoActivityIndicator());
    }
    final theme = Theme.of(context);

    final colors = [theme.secondaryBubbleColor, theme.bubbleColor];

    final horizontalPadding = LizaThemes.isColumnMode(context) ? 8.0 : 0.0;

    final events = timeline.events.filterByVisibleInGui(
      threadId: controller.activeThreadId,
    );
    final animateInEventIndex = controller.animateInEventIndex;

    // create a map of eventId --> index to greatly improve performance of
    // ListView's findChildIndexCallback
    final thisEventsKeyMap = <String, int>{};
    for (var i = 0; i < events.length; i++) {
      thisEventsKeyMap[events[i].eventId] = i;
    }

    // Альбомы (media-v-format.md §8.5): в ленте рисуется только anchor — он
    // рендерит сетку всех элементов через `GalleryBubble`, остальные члены
    // скрыты. Аватарка прочтения и отсечка «Непрочитанное», севшие на скрытый
    // член, переносятся на anchor (см. mergeGalleryReadReceipts).
    final gallerySkipToAnchor = galleryAnchorMap(events);
    final readMarkerRowId =
        gallerySkipToAnchor[controller.readMarkerEventId] ??
        controller.readMarkerEventId;

    final hasWallpaper =
        controller.room.client.applicationAccountConfig.wallpaperUrl != null;

    // Один раз на rebuild, не на сообщение: до какого originServerTs дочитал
    // хотя бы один собеседник — управляет галочками done/done_all.
    // Боты/ИИ ставят ✓✓ только квитанцией: их сообщения-статусы и реакции
    // прочтением не считаются (заявка №60, чат обращения поддержки).
    final isAutomated = Matrix.of(context).isBotOrAiUser;
    final readUpToTs = controller.room.readUpToTs(
      timeline,
      isAutomated: isAutomated,
    );

    // Аватарки «прочитал до сюда»: eventId сообщения → участники, чья граница
    // прочтения стоит на нём (под собственным сообщением участника аватарка не
    // выводится — см. getReadReceiptsPerMessage). Считаем один раз на rebuild,
    // в Message отдаём готовый список по eventId.
    // Ремап аватарок прочтения со скрытых членов галереи на их anchor: иначе
    // граница прочтения, севшая на новейший (скрытый) член альбома, теряется —
    // аватарке негде отрисоваться (баг «отправил скрины — своя аватарка
    // моргнула и скрылась»).
    final seenByPerMessage = mergeGalleryReadReceipts(
      controller.room.getReadReceiptsPerMessage(
        timeline,
        isAutomated: isAutomated,
      ),
      gallerySkipToAnchor,
    );

    return ListView.custom(
      padding: EdgeInsets.only(
        top: 16,
        bottom: 8,
        left: horizontalPadding,
        right: horizontalPadding,
      ),
      reverse: true,
      controller: controller.scrollController,
      keyboardDismissBehavior: PlatformInfos.isIOS
          ? ScrollViewKeyboardDismissBehavior.onDrag
          : ScrollViewKeyboardDismissBehavior.manual,
      childrenDelegate: SliverChildBuilderDelegate(
        (BuildContext context, int i) {
          // Footer to display typing indicator and read receipts:
          if (i == 0) {
            if (timeline.canRequestFuture) {
              return Center(
                child: TextButton.icon(
                  onPressed: timeline.isRequestingFuture
                      ? null
                      : controller.requestFuture,
                  icon: timeline.isRequestingFuture
                      ? CircularProgressIndicator.adaptive(strokeWidth: 2)
                      : const Icon(Icons.arrow_downward_outlined),
                  label: Text(L10n.of(context).loadMore),
                ),
              );
            }
            // Общий футер «прочитали» убран: аватарки теперь стоят на
            // конкретных сообщениях (seenByPerMessage), а в футере остаётся
            // только индикатор набора текста.
            return TypingIndicators(controller);
          }

          // Request history button or progress indicator:
          if (i == events.length + 1) {
            if (controller.activeThreadId != null ||
                !timeline.canRequestHistory) {
              return const SizedBox.shrink();
            }
            return Builder(
              builder: (context) {
                final visibleIndex = timeline.events.lastIndexWhere(
                  (event) => !event.isCollapsedState && event.isVisibleInGui,
                );
                if (visibleIndex > timeline.events.length - 50) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    controller.requestHistory,
                  );
                }
                return Center(
                  child: TextButton.icon(
                    onPressed: timeline.isRequestingHistory
                        ? null
                        : controller.requestHistory,
                    icon: timeline.isRequestingHistory
                        ? CircularProgressIndicator.adaptive(strokeWidth: 2)
                        : const Icon(Icons.arrow_upward_outlined),
                    label: Text(L10n.of(context).loadMore),
                  ),
                );
              },
            );
          }
          i--;

          // The message at this index:
          final event = events[i];

          // Не-anchor событие альбома — строка скрыта, сетку рисует
          // anchor (media-v-format.md §8.5).
          if (gallerySkipToAnchor.containsKey(event.eventId)) {
            return SizedBox.shrink(key: ValueKey(event.eventId));
          }

          final animateIn =
              animateInEventIndex != null &&
              timeline.events.length > animateInEventIndex &&
              event == timeline.events[animateInEventIndex];

          final nextEvent = i + 1 < events.length ? events[i + 1] : null;
          final previousEvent = i > 0 ? events[i - 1] : null;

          // Collapsed state event
          final canExpand =
              event.isCollapsedState &&
              nextEvent?.isCollapsedState == true &&
              previousEvent?.isCollapsedState != true;
          final isCollapsed =
              event.isCollapsedState &&
              previousEvent?.isCollapsedState == true &&
              !controller.expandedEventIds.contains(event.eventId);

          return AutoScrollTag(
            key: ValueKey(event.eventId),
            index: i,
            controller: controller.scrollController,
            // На desktop/web сохраняем выделение текста мышью (Ctrl+C по
            // фрагменту), но нативное контекстное меню глушим — правый клик
            // открывает наш Liza-поповер. На mobile выделение в пузыре
            // отключаем (long-press → поповер, без лупы/ОС-меню); копирование
            // даёт пункт «Копировать» поповера.
            // Владелец защищённого канала (isContentProtected) запретил вынос
            // контента — SelectionArea даёт Ctrl+C в обход всего контекстного
            // меню целиком, поэтому в защищённом канале выделение не даём
            // никому, кроме админа (тот же геттер, что и в контекстном меню).
            child: _selectableMessage(
              selectable:
                  !PlatformInfos.isMobile && !event.room.isContentProtected,
              child: Message(
                event,
                bubbleKey: controller.bubbleKeyOf(event.eventId),
                onContextMenu: controller.onMessageContextMenu,
                animateIn: animateIn,
                resetAnimateIn: () {
                  controller.animateInEventIndex = null;
                },
                onSwipe: () => controller.replyAction(replyTo: event),
                onInfoTab: controller.showEventInfo,
                onMention: () => controller.sendController.text +=
                    '${event.senderFromMemoryOrFallback.mention} ',
                highlightMarker:
                    controller.scrollToEventIdMarker == event.eventId,
                onSelect: controller.onSelectMessage,
                scrollToEventId: (String eventId) =>
                    controller.scrollToEventId(eventId),
                longPressSelect: controller.selectedEvents.isNotEmpty,
                selected: controller.selectedEvents.any(
                  (e) => e.eventId == event.eventId,
                ),
                selectedEventIds: controller.selectedEvents
                    .map((e) => e.eventId)
                    .toSet(),
                onEdit: () => controller.editSelectedEventAction(),
                timeline: timeline,
                readUpToTs: readUpToTs,
                seenByUsers: seenByPerMessage[event.eventId] ?? const [],
                displayReadMarker: i > 0 && readMarkerRowId == event.eventId,
                nextEvent: nextEvent,
                previousEvent: previousEvent,
                wallpaperMode: hasWallpaper,
                scrollController: controller.scrollController,
                colors: colors,
                isCollapsed: isCollapsed,
                enterThread: controller.activeThreadId == null
                    ? controller.enterThread
                    : null,
                onExpand: canExpand
                    ? () => controller.expandEventsFrom(
                        event,
                        !controller.expandedEventIds.contains(event.eventId),
                      )
                    : null,
                // Плашка комментариев теперь рисуется ВНУТРИ пузыря поста
                // (Message), поэтому данные обсуждения передаём туда.
                discussionEvents: controller.discussionEvents,
                onMembershipGained: controller.reloadDiscussionEvents,
              ),
            ),
          );
        },
        childCount: events.length + 2,
        findChildIndexCallback: (key) =>
            controller.findChildIndexCallback(key, thisEventsKeyMap),
        // На desktop/web сообщение под SelectionArea. Keep-alive (его просит
        // InkWell с hover/focus-подсветкой, Swipeable на анимации) держит
        // ушедшее за экран сообщение примонтированным, но SliverList его не
        // раскладывает. Новый Text в нём (перестройка по sync: квитанции,
        // реакции) регистрируется в SelectionArea без layout, и сортировка
        // selectables падает «RenderBox was not laid out: RenderParagraph»,
        // оставляя делегат в рваном состоянии → следом RangeError в
        // remove/getSelectionGeometry (GlitchTip #2067/#2101/#2068/#2009).
        // На mobile SelectionArea нет — там keep-alive не трогаем.
        addAutomaticKeepAlives: PlatformInfos.isMobile,
      ),
    );
  }
}
