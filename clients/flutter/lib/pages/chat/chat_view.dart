import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:badges/badges.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/chat_app_bar_list_tile.dart';
import 'package:liza/pages/chat/chat_app_bar_title.dart';
import 'package:liza/pages/chat/chat_event_list.dart';
import 'package:liza/pages/chat/company_subscribe_banner.dart';
import 'package:liza/pages/chat/encryption_button.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/pages/chat/pinned_events.dart';
import 'package:liza/pages/chat/reply_display.dart';
import 'package:liza/utils/account_config.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/secure_screen.dart';
import 'package:liza/utils/update_policy.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/utils/url_launcher.dart';
import 'package:liza/widgets/chat_settings_popup_menu.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/mxc_image.dart';
import 'package:liza/widgets/unread_rooms_badge.dart';
import 'package:liza/widgets/update_read_only_bar.dart';
import '../../utils/stream_extension.dart';
import 'chat_emoji_picker.dart';
import 'chat_input_row.dart';

enum _EventContextAction { info, report }

/// Показывать ли стрелку «назад» в шапке чата в КОЛОНОЧНОМ режиме (LABA-2543).
///
/// В колоночном режиме `leading` обычно `null`: слева стоит `ChatList`, возврат
/// не нужен. Для архивного чата эта посылка ложна — список архива рисуется в
/// ПРАВОЙ колонке (`routes.dart` → `/rooms/archive`), и без стрелки из
/// архивного чата в него не вернуться совсем.
///
/// Предикат по СОСТОЯНИЮ комнаты, а не по маршруту: архивная комната приезжает
/// и на `/rooms/<id>` — `getRoomById` сканирует `_archivedRooms`, поэтому
/// matrix.to-ссылка минует префикс `/rooms/archive/`. Ложных срабатываний нет:
/// синтетическая peek-комната с `membership: leave` до `ChatView` не доходит —
/// `ChannelPeekPage` рисует собственный AppBar.
@visibleForTesting
bool showArchiveBackButton({
  required bool isColumnMode,
  required bool selectMode,
  required bool hasActiveThread,
  required bool isArchived,
}) =>
    isColumnMode && !selectMode && !hasActiveThread && isArchived;

class ChatView extends StatelessWidget {
  final ChatController controller;

  const ChatView(this.controller, {super.key});

  List<Widget> _appBarActions(BuildContext context) {
    if (controller.selectMode) {
      return [
        if (controller.canEditSelectedEvents)
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: L10n.of(context).edit,
            onPressed: controller.editSelectedEventAction,
          ),
        // if (controller.selectedEvents.length == 1 &&
        //     controller.activeThreadId == null &&
        //     controller.room.canSendDefaultMessages)
        //   IconButton(
        //     icon: const Icon(Icons.message_outlined),
        //     tooltip: L10n.of(context).replyInThread,
        //     onPressed: () => controller.enterThread(
        //       controller.selectedEvents.single.eventId,
        //     ),
        //   ),
        if (controller.canSaveSelectedEvents &&
            !controller.room.isContentProtected)
          IconButton(
            icon: const Icon(Icons.download_outlined),
            tooltip: L10n.of(context).downloadFile,
            onPressed: () => controller.saveSelectedFiles(context),
          ),
        if (controller.canCopySelectedEvents &&
            !controller.room.isContentProtected)
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: L10n.of(context).copyToClipboard,
            onPressed: controller.copyEventsAction,
          ),
        if (controller.canRedactSelectedEvents)
          IconButton(
            icon: const Icon(Icons.delete_outlined),
            tooltip: L10n.of(context).redactMessage,
            onPressed: controller.redactEventsAction,
          ),
        if (controller.selectedEvents.length == 1)
          PopupMenuButton<_EventContextAction>(
            useRootNavigator: true,
            onSelected: (action) {
              switch (action) {
                case _EventContextAction.info:
                  controller.showEventInfo();
                  controller.clearSelectedEvents();
                  break;
                case _EventContextAction.report:
                  controller.reportEventAction();
                  break;
              }
            },
            itemBuilder: (context) => [
              if (controller.canPinSelectedEvents)
                PopupMenuItem(
                  onTap: controller.pinEvent,
                  value: null,
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.push_pin_outlined),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).pinMessage),
                    ],
                  ),
                ),
              if (controller.canCopyMessageLink(
                controller.selectedEvents.single,
              ))
                PopupMenuItem(
                  onTap: controller.copyMessageLinkAction,
                  value: null,
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.link),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          L10n.of(context).copyMessageLink,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              // Диалог показывает СЫРОЙ JSON события выделяемым текстом
              // (`event_info_dialog.dart` → SelectableText(prettyJson)), то есть
              // это полноценный путь выноса тела сообщения. В контекстном меню
              // пункт уже закрыт ролью разработчика
              // (`message_context_menu.dart`), а здесь оставался открытым всем —
              // участник защищённого чата копировал текст в три тапа
              // (LABA-2541). Гейт тот же самый, чтобы обе точки входа не
              // разъезжались.
              if (Matrix.of(context).isCurrentUserDeveloper)
                PopupMenuItem(
                  value: _EventContextAction.info,
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.info_outlined),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).messageInfo),
                    ],
                  ),
                ),
              if (controller.selectedEvents.single.status.isSent)
                PopupMenuItem(
                  value: _EventContextAction.report,
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.shield_outlined, color: Colors.red),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).reportMessage),
                    ],
                  ),
                ),
            ],
          ),
      ];
    } else if (!controller.room.isArchived) {
      return [
        // Публикация истории канала — только admin/moderator (PL>=100), как и
        // остальное управление каналом (см. chat_details_view.dart).
        if (controller.room.isChannel && controller.room.ownPowerLevel >= 100)
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: L10n.of(context).addChannelStory,
            onPressed: controller.addChannelStory,
          ),
        if (AppSettings.experimentalVoip.value &&
            Matrix.of(context).voipPlugin != null &&
            controller.room.isDirectChat &&
            !UpdatePolicyController.readOnly)
          IconButton(
            onPressed: controller.onPhoneButtonTap,
            icon: const Icon(Icons.call_outlined),
            tooltip: L10n.of(context).placeCall,
            visualDensity: PlatformInfos.isMobile
                ? VisualDensity.compact
                : null,
          ),
        Builder(
          builder: (context) {
            final callUrl =
                controller.room.getState('io.element.call_link')?.content['url']
                    as String?;
            if (callUrl == null || callUrl.isEmpty) {
              return const SizedBox.shrink();
            }
            return IconButton(
              icon: const Icon(Icons.phone_outlined),
              tooltip: L10n.of(context).joinCall,
              onPressed: () => UrlLauncher(context, callUrl).launchUrl(),
              visualDensity: PlatformInfos.isMobile
                  ? VisualDensity.compact
                  : null,
            );
          },
        ),
        EncryptionButton(controller.room),
        ChatSettingsPopupMenu(controller.room, true),
      ];
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (controller.room.membership == Membership.invite) {
      showFutureLoadingDialog(
        context: context,
        future: () => controller.room.join(),
        exceptionContext: ExceptionContext.joinRoom,
      );
    }
    final bottomSheetPadding = LizaThemes.isColumnMode(context) ? 16.0 : 8.0;
    final scrollUpBannerEventId = controller.scrollUpBannerEventId;

    final accountConfig = Matrix.of(context).client.applicationAccountConfig;

    // Защита экрана от скриншотов в канале с запретом копирования. Обёртка
    // стоит на ВСЕХ чатах, а не только на каналах: у обычного чата
    // `isContentProtected == false`, страж ничего не включает, зато при
    // переходе «защищённый канал → обычный чат» флаг гарантированно снимается
    // тем же механизмом, что и при выходе в список чатов.
    return SecureScreenGuard(
      enabled: controller.room.isContentProtected,
      child: ValueListenableBuilder<ActiveVoiceRecording?>(
        valueListenable: VoiceRecordingGuard.notifier,
        builder: (context, activeRecording, child) => PopScope(
          canPop:
              controller.selectedEvents.isEmpty &&
              !controller.showEmojiPicker &&
              controller.activeThreadId == null &&
              activeRecording == null,
          onPopInvokedWithResult: (pop, _) async {
            if (pop) return;
            if (controller.selectedEvents.isNotEmpty) {
              controller.clearSelectedEvents();
            } else if (controller.showEmojiPicker) {
              controller.emojiPickerAction();
            } else if (controller.activeThreadId != null) {
              controller.closeThread();
            } else if (activeRecording != null) {
              final canLeave = await VoiceRecordingGuard.confirmLeave(context);
              if (canLeave && context.mounted) context.pop();
            }
          },
          child: child!,
        ),
        child: StreamBuilder(
          stream: controller.room.client.onRoomState.stream
              .where((update) => update.roomId == controller.room.id)
              .rateLimit(const Duration(seconds: 1)),
          builder: (context, snapshot) => FutureBuilder(
            future: controller.loadTimelineFuture,
            builder: (BuildContext context, snapshot) {
              var appbarBottomHeight = 0.0;
              final activeThreadId = controller.activeThreadId;
              final isColumnMode = LizaThemes.isColumnMode(context);
              final showArchiveBack = showArchiveBackButton(
                isColumnMode: isColumnMode,
                selectMode: controller.selectMode,
                hasActiveThread: activeThreadId != null,
                isArchived: controller.isArchived,
              );
              if (activeThreadId != null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              if (controller.room.pinnedEventIds.isNotEmpty &&
                  activeThreadId == null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              if (scrollUpBannerEventId != null && activeThreadId == null) {
                appbarBottomHeight += ChatAppBarListTile.fixedHeight;
              }
              return Scaffold(
                appBar: AppBar(
                  actionsIconTheme: IconThemeData(
                    color: controller.selectedEvents.isEmpty
                        ? null
                        : theme.colorScheme.onTertiaryContainer,
                  ),
                  backgroundColor: controller.selectedEvents.isEmpty
                      ? controller.activeThreadId != null
                            ? theme.colorScheme.secondaryContainer
                            : null
                      : theme.colorScheme.tertiaryContainer,
                  automaticallyImplyLeading: false,
                  leading: controller.selectMode
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: controller.clearSelectedEvents,
                          tooltip: L10n.of(context).close,
                          color: theme.colorScheme.onTertiaryContainer,
                        )
                      : activeThreadId != null
                      ? IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: controller.closeThread,
                          tooltip: L10n.of(context).backToMainChat,
                          color: theme.colorScheme.onSecondaryContainer,
                        )
                      : isColumnMode
                      ? (showArchiveBack
                            ? Center(
                                child: BackButton(
                                  // maybePop, а не context.go: уважает PopScope
                                  // (выделение/эмодзи/тред/запись голоса) и
                                  // сохраняет State страницы `Archive` — её кэш
                                  // переживает возврат, повторного loadArchive
                                  // не будет. `go` — только когда попать некуда
                                  // (холодный deep-link).
                                  onPressed: () async {
                                    if (await Navigator.maybePop(context)) {
                                      return;
                                    }
                                    if (context.mounted) {
                                      context.go('/rooms/archive');
                                    }
                                  },
                                ),
                              )
                            : null)
                      : StreamBuilder<Object>(
                          stream: Matrix.of(context).client.onSync.stream.where(
                            (syncUpdate) => syncUpdate.hasRoomUpdate,
                          ),
                          builder: (context, _) => UnreadRoomsBadge(
                            filter: (r) => r.id != controller.roomId,
                            badgePosition: BadgePosition.topEnd(end: 8, top: 4),
                            child: const Center(child: BackButton()),
                          ),
                        ),
                  // 24dp — компенсация ОТСУТСТВИЯ leading в колоночном режиме;
                  // под появившейся стрелкой «в архив» их надо снять.
                  titleSpacing: isColumnMode && !showArchiveBack ? 24 : 0,
                  title: ChatAppBarTitle(controller),
                  actions: _appBarActions(context),
                  bottom: PreferredSize(
                    preferredSize: Size.fromHeight(appbarBottomHeight),
                    child: Column(
                      mainAxisSize: .min,
                      children: [
                        PinnedEvents(controller),
                        if (activeThreadId != null)
                          SizedBox(
                            height: ChatAppBarListTile.fixedHeight,
                            child: Center(
                              child: TextButton.icon(
                                onPressed: () =>
                                    controller.scrollToEventId(activeThreadId),
                                icon: const Icon(Icons.message),
                                label: Text(L10n.of(context).replyInThread),
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      theme.colorScheme.onSecondaryContainer,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (scrollUpBannerEventId != null &&
                            activeThreadId == null)
                          ChatAppBarListTile(
                            leading: IconButton(
                              color: theme.colorScheme.onSurfaceVariant,
                              icon: const Icon(Icons.close),
                              tooltip: L10n.of(context).close,
                              onPressed: () {
                                controller.discardScrollUpBannerEventId();
                                controller.setReadMarker();
                              },
                            ),
                            title: L10n.of(context).jumpToLastReadMessage,
                            trailing: TextButton(
                              onPressed: () {
                                controller.scrollToEventId(
                                  scrollUpBannerEventId,
                                );
                                controller.discardScrollUpBannerEventId();
                              },
                              child: Text(L10n.of(context).jump),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                floatingActionButton:
                    controller.showScrollDownButton &&
                        controller.selectedEvents.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 56.0),
                        child: FloatingActionButton(
                          onPressed: controller.scrollDown,
                          heroTag: null,
                          mini: true,
                          backgroundColor: theme.colorScheme.surface,
                          foregroundColor: theme.colorScheme.onSurface,
                          child: const Icon(Icons.arrow_downward_outlined),
                        ),
                      )
                    : null,
                body: DropTarget(
                  onDragDone: controller.onDragDone,
                  onDragEntered: controller.onDragEntered,
                  onDragExited: controller.onDragExited,
                  child: Stack(
                    children: <Widget>[
                      if (accountConfig.wallpaperUrl != null)
                        Opacity(
                          opacity: accountConfig.wallpaperOpacity ?? 0.5,
                          child: ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: accountConfig.wallpaperBlur ?? 0.0,
                              sigmaY: accountConfig.wallpaperBlur ?? 0.0,
                            ),
                            child: MxcImage(
                              cacheKey: accountConfig.wallpaperUrl.toString(),
                              uri: accountConfig.wallpaperUrl,
                              fit: BoxFit.cover,
                              height: MediaQuery.sizeOf(context).height,
                              width: MediaQuery.sizeOf(context).width,
                              isThumbnail: false,
                              placeholder: (_) => Container(),
                            ),
                          ),
                        ),
                      SafeArea(
                        child: Column(
                          children: <Widget>[
                            CompanySubscribeBanner(room: controller.room),
                            Expanded(
                              child: GestureDetector(
                                onTap: controller.clearSingleSelectedEvent,
                                child: ChatEventList(controller: controller),
                              ),
                            ),
                            if (controller.showScrollDownButton)
                              Divider(height: 1, color: theme.dividerColor),
                            if (controller.room.isExtinct)
                              Container(
                                margin: EdgeInsets.all(bottomSheetPadding),
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  icon: const Icon(Icons.chevron_right),
                                  label: Text(L10n.of(context).enterNewChat),
                                  onPressed: controller.goToNewRoomAction,
                                ),
                              )
                            else if (showUpdateReadOnlyBar(controller.room))
                              const UpdateReadOnlyBar()
                            else if (controller.room.canSendDefaultMessages &&
                                controller.room.membership == Membership.join)
                              Container(
                                margin: EdgeInsets.all(bottomSheetPadding),
                                constraints: const BoxConstraints(
                                  maxWidth: LizaThemes.maxTimelineWidth,
                                ),
                                alignment: Alignment.center,
                                child: Material(
                                  clipBehavior: Clip.hardEdge,
                                  color: controller.selectedEvents.isNotEmpty
                                      ? theme.colorScheme.tertiaryContainer
                                      : theme.colorScheme.surfaceContainerHigh,
                                  borderRadius: const BorderRadius.all(
                                    Radius.circular(24),
                                  ),
                                  child:
                                      controller.room.isAbandonedDMRoom == true
                                      ? Row(
                                          mainAxisAlignment: .spaceEvenly,
                                          children: [
                                            TextButton.icon(
                                              style: TextButton.styleFrom(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                                foregroundColor:
                                                    theme.colorScheme.error,
                                              ),
                                              icon: const Icon(
                                                Icons.archive_outlined,
                                              ),
                                              onPressed: controller.leaveChat,
                                              label: Text(
                                                L10n.of(context).leave,
                                              ),
                                            ),
                                            TextButton.icon(
                                              style: TextButton.styleFrom(
                                                padding: const EdgeInsets.all(
                                                  16,
                                                ),
                                              ),
                                              icon: const Icon(
                                                Icons.forum_outlined,
                                              ),
                                              onPressed:
                                                  controller.recreateChat,
                                              label: Text(
                                                L10n.of(context).reopenChat,
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          mainAxisSize: .min,
                                          children: [
                                            ReplyDisplay(controller),
                                            ChatInputRow(controller),
                                            ChatEmojiPicker(controller),
                                          ],
                                        ),
                                ),
                              ),
                            // Резерв снизу под свёрнутую плашку miniApp, чтобы
                            // она не перекрывала поле ввода (плашка — глобальный
                            // overlay у bottom:0, см. MiniAppOverlay).
                            AnimatedBuilder(
                              animation: MiniAppManager.instance,
                              builder: (context, _) {
                                final manager = MiniAppManager.instance;
                                final reserve =
                                    manager.hasApps && !manager.isExpanded;
                                return SizedBox(
                                  height: reserve
                                      ? kMiniAppCollapsedBarHeight
                                      : 0,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      if (controller.dragging)
                        Container(
                          color: theme.scaffoldBackgroundColor.withAlpha(230),
                          alignment: Alignment.center,
                          child: const Icon(Icons.upload_outlined, size: 100),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
