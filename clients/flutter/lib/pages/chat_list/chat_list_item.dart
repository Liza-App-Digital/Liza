import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_web_view.dart';
import 'package:liza/pages/chat_list/knock_request_badge.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/bot_miniapp_registry.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/widgets/mini_app_open_pill.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/forced_list_artifact.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/utils/strip_matrix_mentions.dart';
// import 'package:liza/utils/unread_diagnostics.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/hover_builder.dart';
import '../../config/themes.dart';
import '../../utils/date_time_extension.dart';
import '../../utils/stories/active_stories_provider.dart';
import '../../utils/stories/open_user_stories.dart';
import '../../utils/stories/stories_seen_store.dart';
import '../../widgets/avatar.dart';
import '../../widgets/matrix.dart';
import '../../widgets/story_avatar_ring.dart';
import '../../widgets/user_role_badge.dart';

enum ArchivedRoomAction { delete, rejoin }

/// Какое событие показать превью в списке чатов.
///
/// `room.lastEvent` отдаёт СЫРОЙ хвост таймлайна: в канале туда попадают смена
/// аватара, вступления и надгробия удалённых постов. Liza в превью канала
/// показывает последний ПОСТ, поэтому служебные события пропускаем.
///
/// Список подаётся в порядке от свежего к старому (как `timeline.events`).
Event? previewEventFrom(List<Event> events) {
  for (final event in events) {
    if (event.isHiddenChannelStateEvent) continue;
    if (event.isRedactedChannelPost) continue;
    if (event.isRedactedBotDraft) continue;
    // Пост Liza News для других платформ: его текст не должен утечь в превью.
    if (event.isHiddenByNewsAudience) continue;
    return event;
  }
  return null;
}

class ChatListItem extends StatelessWidget {
  final Room room;
  final Room? space;
  final bool activeChat;
  final void Function(BuildContext context)? onLongPress;
  final void Function()? onForget;
  final void Function() onTap;
  final String? filter;

  const ChatListItem(
    this.room, {
    this.activeChat = false,
    required this.onTap,
    this.onLongPress,
    this.onForget,
    this.filter,
    this.space,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // ВРЕМЕННО (отключено): диагностика бага «свежий чат без индикатора
    // непрочитанного» (инцидент 2026-07-29). Раскомментировать вместе с
    // импортом unread_diagnostics.dart, чтобы включить сбор логов в сборке.
    // UnreadDiagnostics.maybeLog(room);

    final isMuted = room.pushRuleState != PushRuleState.notify;
    final typingText = room.getLocalizedTypingText(context);
    // В канале сырой lastEvent приносит служебный шум (смена аватара,
    // вступления) и надгробия удалённых постов — Liza показывает в превью
    // последний пост. Список чатов не подгружает таймлайн комнаты (он грузится
    // только при входе в чат), поэтому доступно единственное сырое событие
    // `room.lastEvent`; если оно служебное — превью останется пустым вместо
    // служебной строки. Для обычных чатов поведение не меняется.
    // Канальные проверки внутри previewEventFrom сами гейтятся isChannel, поэтому
    // для обычных чатов фильтр пропускает только адресный пост Liza News.
    final lastEvent = previewEventFrom([
      if (room.lastEvent != null) room.lastEvent!,
    ]);
    final ownMessage = lastEvent?.senderId == room.client.userID;
    final newsHiddenTail = room.hasNewsAudienceHiddenTail;
    final unread = room.isUnread && !newsHiddenTail;
    final directChatMatrixId = room.directChatMatrixID;
    final isDirectChat = directChatMatrixId != null;
    // Вычисляем один раз: используется и для условия тапа (баг №4 - Android
    // gesture arena конфликт), и как проп Avatar.storyRing ниже.
    final isAiDirectChat =
        directChatMatrixId != null &&
        Matrix.of(context).isAiUser(directChatMatrixId);
    final storyRing = directChatMatrixId != null && !isAiDirectChat
        ? ActiveStoriesProvider.instance.ringForUser(
            directChatMatrixId,
            Matrix.of(context).client,
            StoriesSeenStore(
              Matrix.of(context).store,
              scope: Matrix.of(context).client.userID,
            ),
          )
        : null;
    final hasActiveRing = storyRing != null && storyRing != StoryRingState.none;
    final hasNotifications = room.notificationCount > 0 && !newsHiddenTail;
    final backgroundColor = activeChat
        ? theme.colorScheme.secondaryContainer
        : null;
    // LABA-2242: удалённый бот (аккаунт деактивирован → вышел из DM) читается как
    // «Удалённый аккаунт» + серый призрак, а не штатное «Пустой чат (был …)».
    final isDeletedBot = isDeletedBotDm(room);
    final displayname = isDeletedBot
        ? L10n.of(context).deletedAccount
        : room.getLocalizedDisplayname(MatrixLocals(L10n.of(context)));
    final filter = this.filter;
    if (filter != null && !displayname.toLowerCase().contains(filter)) {
      return const SizedBox.shrink();
    }

    final needLastEventSender = lastEvent == null
        ? false
        : room.getState(EventTypes.RoomMember, lastEvent.senderId) == null;
    final space = this.space;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        borderRadius: BorderRadius.circular(AppConfig.borderRadius),
        clipBehavior: Clip.hardEdge,
        color: backgroundColor,
        child: GestureDetector(
          onSecondaryTapUp: (_) => onLongPress?.call(context),
          child: ListTile(
            visualDensity: const VisualDensity(vertical: -0.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            onLongPress: () {
              HapticFeedback.heavyImpact();
              onLongPress?.call(context);
            },
            leading: GestureDetector(
              behavior: HitTestBehavior.opaque,
              // Баг №4: раньше клик решался внутренним GestureDetector
              // Avatar (перехват из gesture arena) - на Android арена
              // иногда отдаёт тап внешнему детектору первой, и клик по
              // кольцу открывал чат вместо сторис. Теперь решение
              // принимается здесь заранее, конкурирующего детектора нет.
              onTap: hasActiveRing
                  ? () => openUserStories(context, directChatMatrixId!)
                  : onTap,
              onLongPress: () {
                HapticFeedback.heavyImpact();
                onLongPress?.call(context);
              },
              onSecondaryTapUp: (_) => onLongPress?.call(context),
              child: HoverBuilder(
                builder: (context, hovered) => AnimatedScale(
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  scale: hovered ? 1.1 : 1.0,
                  child: SizedBox(
                    width: Avatar.defaultSize,
                    height: Avatar.defaultSize,
                    child: Stack(
                      children: [
                        // У канала — только его собственная аватарка: вторая
                        // (аватар пространства) читается как «аватарка
                        // автора» и путает.
                        if (space != null && !room.isChannel)
                          Positioned(
                            top: 0,
                            left: 0,
                            child: Avatar(
                              border: BorderSide(
                                width: 2,
                                color:
                                    backgroundColor ??
                                    theme.colorScheme.surface,
                              ),
                              borderRadius: BorderRadius.circular(
                                AppConfig.borderRadius / 4,
                              ),
                              mxContent: space.avatar,
                              size: Avatar.defaultSize * 0.75,
                              name: space.getLocalizedDisplayname(),
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Avatar(
                            border: space == null
                                ? room.isSpace
                                      ? BorderSide(
                                          width: 1,
                                          color: theme.dividerColor,
                                        )
                                      : null
                                : BorderSide(
                                    width: 2,
                                    color:
                                        backgroundColor ??
                                        theme.colorScheme.surface,
                                  ),
                            borderRadius: room.isSpace
                                ? BorderRadius.circular(
                                    AppConfig.borderRadius / 4,
                                  )
                                : null,
                            mxContent: room.avatar,
                            size: space != null && !room.isChannel
                                ? Avatar.defaultSize * 0.75
                                : Avatar.defaultSize,
                            name: displayname,
                            presenceUserId: directChatMatrixId,
                            presenceBackgroundColor: backgroundColor,
                            isDeleted: isDeletedBot,
                            isHexagonal: isAiDirectChat && !isDeletedBot,
                            storyRing: storyRing,
                            // onStoryTap здесь не нужен: клик уже решается
                            // снаружи на уровне leading-GestureDetector
                            // (см. ниже) - баг №4, конфликт двух
                            // независимых GestureDetector на Android.
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            title: Row(
              children: <Widget>[
                Expanded(
                  child: Row(
                    mainAxisSize: .min,
                    children: [
                      Flexible(
                        child: Text(
                          displayname,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: TextStyle(
                            fontWeight: unread || room.hasNewMessages
                                ? FontWeight.w500
                                : null,
                          ),
                        ),
                      ),
                      if (directChatMatrixId != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: UserRoleBadge(
                            userId: directChatMatrixId,
                            fontSize: 9,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (isMuted)
                  const Padding(
                    padding: EdgeInsets.only(left: 4.0),
                    child: Icon(Icons.notifications_off_outlined, size: 16),
                  ),
                KnockRequestBadge(room: room),
                if (room.isFavourite &&
                    room.directChatMatrixID?.localpart != 'liza')
                  Padding(
                    padding: EdgeInsets.only(
                      right: hasNotifications ? 4.0 : 0.0,
                    ),
                    child: Icon(
                      Icons.push_pin,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                if (!room.isSpace && room.membership != Membership.invite)
                  Padding(
                    padding: const EdgeInsets.only(left: 4.0),
                    child: Text(
                      room.latestEventReceivedTime.localizedTimeShort(context),
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
              ],
            ),
            subtitle: Row(
              crossAxisAlignment: .start,
              mainAxisAlignment: .center,
              children: <Widget>[
                if (typingText.isEmpty &&
                    ownMessage &&
                    room.lastEvent?.status.isSending == true) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                  ),
                  const SizedBox(width: 4),
                ],
                AnimatedSize(
                  clipBehavior: Clip.hardEdge,
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  child: typingText.isNotEmpty
                      ? Padding(
                          padding: const EdgeInsets.only(right: 4.0),
                          child: Icon(
                            Icons.edit_outlined,
                            color: theme.colorScheme.secondary,
                            size: 16,
                          ),
                        )
                      // Бейдж «тред» — про то же событие, что и текст превью
                      // ниже (`lastEvent`), а не про сырой хвост таймлайна.
                      : lastEvent?.relationshipType == RelationshipTypes.thread
                      ? Container(
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: theme.colorScheme.outline,
                            ),
                            borderRadius: BorderRadius.circular(
                              AppConfig.borderRadius,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8.0),
                          margin: const EdgeInsets.only(right: 4.0),
                          child: Row(
                            mainAxisSize: .min,
                            children: [
                              Icon(
                                Icons.message_outlined,
                                size: 12,
                                color: theme.colorScheme.outline,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                L10n.of(context).thread,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.outline,
                                ),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  // Превью выравниваем по НИЗУ: когда справа стоит пилюля
                  // «Открыть» (бот с закреплённым mini App), она выше одной
                  // строки — так нижняя граница текста совпадает с нижней
                  // границей пилюли. Реактивно: при появлении пилюли строка
                  // перекомпоновывается, и Align сам опускает текст (без
                  // завязки на состояние реестра). Для строк без пилюли высота
                  // строки = высоте текста → Align — no-op (ничего не двигает).
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: room.isSpace && room.membership == Membership.join
                        ? Text(
                            L10n.of(context).countChats(
                              // Считаем только доступных юзеру детей (joined),
                              // иначе цифра вводит в заблуждение: пространство
                              // показывает все привязки, в т.ч. приватные без
                              // доступа, которые в самом списке скрыты.
                              // Сторис-комнаты (com.liza.stories) скрыты из
                              // списка, поэтому их тоже исключаем из счётчика.
                              room.spaceChildren
                                  .where(
                                    (c) =>
                                        c.roomId != null &&
                                        room.client
                                                .getRoomById(c.roomId!)
                                                ?.membership ==
                                            Membership.join &&
                                        room.client
                                                .getRoomById(c.roomId!)
                                                ?.isHiddenChat !=
                                            true,
                                  )
                                  .length,
                            ),
                            style: TextStyle(color: theme.colorScheme.outline),
                          )
                        : typingText.isNotEmpty
                        ? Text(
                            typingText,
                            style: TextStyle(color: theme.colorScheme.primary),
                            maxLines: 1,
                            softWrap: false,
                          )
                        : FutureBuilder(
                            key: ValueKey(
                              '${lastEvent?.eventId}_${lastEvent?.type}_${lastEvent?.redacted}',
                            ),
                            future: needLastEventSender
                                ? lastEvent.calcLocalizedBody(
                                    MatrixLocals(L10n.of(context)),
                                    hideReply: true,
                                    hideEdit: true,
                                    plaintextBody:
                                        !lastEvent.isForcedListArtifactBody,
                                    removeMarkdown:
                                        !lastEvent.isForcedListArtifactBody,
                                    withSenderNamePrefix:
                                        (!isDirectChat ||
                                        directChatMatrixId !=
                                            lastEvent.senderId),
                                  )
                                : null,
                            initialData: lastEvent?.calcLocalizedBodyFallback(
                              MatrixLocals(L10n.of(context)),
                              hideReply: true,
                              hideEdit: true,
                              plaintextBody:
                                  !lastEvent.isForcedListArtifactBody,
                              removeMarkdown:
                                  !lastEvent.isForcedListArtifactBody,
                              withSenderNamePrefix:
                                  (!isDirectChat ||
                                  directChatMatrixId != lastEvent.senderId),
                            ),
                            builder: (context, snapshot) => Text(
                              room.membership == Membership.invite
                                  ? room
                                            .getState(
                                              EventTypes.RoomMember,
                                              room.client.userID!,
                                            )
                                            ?.content
                                            .tryGet<String>('reason') ??
                                        (isDirectChat
                                            ? L10n.of(context).newChatRequest
                                            : L10n.of(context).inviteGroupChat)
                                  : stripMatrixMentions(
                                      snapshot.data ??
                                          L10n.of(context).noMessagesYet,
                                      room,
                                      handles: Matrix.of(
                                        context,
                                      ).userHandleService,
                                    ),
                              softWrap: false,
                              maxLines: room.notificationCount >= 1 ? 2 : 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: unread || room.hasNewMessages
                                    ? theme.colorScheme.onSurface
                                    : theme.colorScheme.outline,
                              ),
                            ),
                          ),
                  ),
                ),
                // Кнопка «Открыть» на строке чата с ботом, у которого закреплён
                // mini App (паритет с Liza). Наличие app приезжает из реестра
                // (/liza/mybots) — ValueListenableBuilder перерисует строку, когда
                // карта подгрузится.
                // Удалённый бот: пилюлю не показываем (реестр кэширует url до 45с
                // после обнуления bot_mxid — нажатие открыло бы устаревший mini App).
                if (isDirectChat && !isDeletedBot) _miniAppOpenPill(context),
                const SizedBox(width: 8),
                UnreadBubble(room: room),
              ],
            ),
            onTap: onTap,
            trailing: onForget == null
                ? room.membership == Membership.invite
                      ? IconButton(
                          tooltip: L10n.of(context).declineInvitation,
                          icon: const Icon(Icons.delete_forever_outlined),
                          color: theme.colorScheme.error,
                          onPressed: () async {
                            final consent = await showOkCancelAlertDialog(
                              context: context,
                              title: L10n.of(context).declineInvitation,
                              message: L10n.of(context).areYouSure,
                              okLabel: L10n.of(context).yes,
                              isDestructive: true,
                            );
                            if (consent != OkCancelResult.ok) return;
                            if (!context.mounted) return;
                            await showFutureLoadingDialog(
                              context: context,
                              future: room.leave,
                            );
                          },
                        )
                      : null
                : IconButton(
                    icon: const Icon(Icons.delete_outlined),
                    // Предохранитель от случайного тапа: forget() необратим
                    // без повторного join. useRootNavigator: false — экран
                    // «Архив» живёт во вложенном Navigator side-view на
                    // широких экранах (routes.dart, ShellRoute).
                    onPressed: () async {
                      final consent = await showOkCancelAlertDialog(
                        context: context,
                        useRootNavigator: false,
                        title: L10n.of(context).deleteChat,
                        message: L10n.of(context).forgetArchivedChatDescription,
                        okLabel: L10n.of(context).yes,
                        cancelLabel: L10n.of(context).cancel,
                        isDestructive: true,
                      );
                      if (consent != OkCancelResult.ok) return;
                      onForget!();
                    },
                  ),
          ),
        ),
      ),
    );
  }

  /// Пилюля «Открыть» на строке чата с ботом, у которого закреплён mini App.
  /// Показывается только когда реестр вернул конфиг для партнёра-бота DM;
  /// иначе — пусто. `ensureLoaded` дедуплицируется (один запрос на homeserver).
  Widget _miniAppOpenPill(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: BotMiniAppRegistry.instance.revision,
    builder: (context, _, _) {
      BotMiniAppRegistry.instance.ensureLoaded(room.client);
      final launch = BotMiniAppRegistry.instance.launchForRoom(room);
      // Владелец мог выключить плашку в списке чатов через BotFather.
      if (launch == null || !launch.listButtonEnabled) {
        return const SizedBox.shrink();
      }
      return MiniAppOpenPill(
        label: launch.listButtonLabel ?? L10n.of(context).chatInputOpen,
        onTap: () => _openMiniApp(context, launch),
      );
    },
  );

  Future<void> _openMiniApp(BuildContext context, MiniAppLaunch launch) =>
      MiniAppWebView.open(
        context: context,
        appUrl: launch.appUrl,
        appId: launch.appId,
        appName: launch.appName,
        room: room,
        appType: launch.appType,
        appStartPath: launch.appStartPath,
      );
}
