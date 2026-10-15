import 'package:flutter/material.dart';

import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_details/chat_details.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/channel_discussion.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/company_invite_gate.dart';
import 'package:liza/utils/miniapp_member_block.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/pages/chat_details/participant_list_item.dart';
import 'package:liza/pages/chat_details/invite_link_dialog.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/stories/active_stories_provider.dart';
import 'package:liza/utils/stories/open_user_stories.dart';
import 'package:liza/utils/stories/stories_seen_store.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/chat_settings_popup_menu.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/mxc_image_viewer.dart';
import '../../widgets/qr_code_viewer.dart';

class ChatDetailsView extends StatelessWidget {
  final ChatDetailsController controller;

  const ChatDetailsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detailsOnly = controller.widget.detailsOnly;

    final room = Matrix.of(context).client.getRoomById(controller.roomId!);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
        ),
      );
    }

    final directChatMatrixID = room.directChatMatrixID;
    final isAiDm =
        directChatMatrixID != null &&
        Matrix.of(context).isAiUser(directChatMatrixID);
    final roomAvatar = room.avatar;

    return StreamBuilder(
      stream: room.client.onRoomState.stream.where(
        (update) => update.roomId == room.id,
      ),
      builder: (context, snapshot) {
        // ВТОРАЯ витрина списка участников (превью топ-10). Скрытие
        // (LABA-2381) обязано действовать и здесь, иначе скрытый всплывёт мимо
        // фильтра экрана «Все участники» — фильтруем единым visibleParticipants.
        final allParticipants = room.getParticipants();
        var members = room.visibleParticipants(allParticipants).toList()
          ..sort((b, a) => a.powerLevel.compareTo(b.powerLevel));
        members = members.take(10).toList();
        // Вычитаем только реально состоящих скрытых (stale hidden id после kick
        // не должен занижать счётчик — см. chat_members_view).
        final currentMemberIds = allParticipants.map((u) => u.id).toSet();
        final hiddenForViewer = room.hiddenMemberIds
            .where(
              (id) =>
                  id != (room.client.userID ?? '') &&
                  currentMemberIds.contains(id),
            )
            .length;
        final rawMembersCount =
            (room.summary.mInvitedMemberCount ?? 0) +
            (room.summary.mJoinedMemberCount ?? 0);
        final actualMembersCount = (rawMembersCount - hiddenForViewer).clamp(
          0,
          rawMembersCount,
        );
        final canRequestMoreMembers = members.length < actualMembersCount;
        final canSeeMembers = room.canSeeSpaceMembers;
        final iconColor = theme.textTheme.bodyLarge!.color;
        final displayname = room.getLocalizedDisplayname(
          MatrixLocals(L10n.of(context)),
        );
        final powerLevelsContent = room
            .getState(EventTypes.RoomPowerLevels)
            ?.content;
        final inviteThreshold =
            (powerLevelsContent?.tryGet<int>('invite')) ?? 50;
        final canManageInviteLink = room.ownPowerLevel >= inviteThreshold;
        // В пространстве компании оба входа приглашения видны всем; без права
        // invite тап показывает плашку (задача 13, ensureCanInviteToSpace).
        final companySpace = isOwnCompanySpace(
          room,
          companyInstance: Matrix.of(
            context,
          ).singleSpaceService.isCompanyInstance,
        );
        // Раздел «Заблокированные/удалённые» — только владельцу/модератору
        // чата-магазина (mini App): управление блокировками по порогу ban.
        final banThreshold = (powerLevelsContent?.tryGet<int>('ban')) ?? 50;
        final canManageStoreBlocks =
            isMiniAppStoreRoom(room) && room.ownPowerLevel >= banThreshold;
        // Гости канала (без PL владельца) не должны видеть настройки, которые
        // им всё равно не дадут применить. Обычных чатов гейт не касается.
        final canEditChannelSettings =
            !room.isChannel || room.ownPowerLevel >= adminPowerLevel;
        return Scaffold(
          appBar: AppBar(
            leading:
                controller.widget.embeddedCloseButton ??
                const Center(child: BackButton()),
            elevation: theme.appBarTheme.elevation,
            actions: <Widget>[
              // У канала QR показываем ТОЛЬКО с коротким ником me.liza.ru:
              // matrix.to-ссылка подписчику бесполезна (решение пользователя —
              // лучше без кнопки, чем с нерабочей ссылкой). Обычные чаты
              // по-прежнему шарят canonicalAlias.
              if (room.isChannel
                  ? controller.channelHandle != null
                  : room.canonicalAlias.isNotEmpty)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: const Icon(Icons.qr_code_rounded),
                  onPressed: () => showQrCodeViewer(
                    context,
                    room.canonicalAlias,
                    inviteLink: controller.channelHandle?.url,
                  ),
                )
              else if (directChatMatrixID != null)
                IconButton(
                  tooltip: L10n.of(context).share,
                  icon: const Icon(Icons.qr_code_rounded),
                  onPressed: () async {
                    final targetId = directChatMatrixID;
                    final client = Matrix.of(context).client;
                    final result = await showFutureLoadingDialog(
                      context: context,
                      future: () async {
                        final info = await AuthProxyService().createUserInvite(
                          targetUserId: targetId,
                          accessToken: client.accessToken ?? '',
                        );
                        return info.url;
                      },
                    );
                    final url = result.result;
                    if (url == null) return;
                    if (!context.mounted) return;
                    showQrCodeViewer(context, targetId, inviteLink: url);
                  },
                ),
              if (controller.widget.embeddedCloseButton == null)
                ChatSettingsPopupMenu(room, false),
            ],
            title: Text(
              room.isChannel
                  ? L10n.of(context).channelDetails
                  : L10n.of(context).chatDetails,
            ),
            backgroundColor: theme.appBarTheme.backgroundColor,
          ),
          body: MaxWidthBody(
            child: ListView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              itemCount: detailsOnly || !canSeeMembers
                  ? 1
                  : members.length + 1 + (canRequestMoreMembers ? 1 : 0),
              itemBuilder: (BuildContext context, int i) => i == 0
                  ? Column(
                      crossAxisAlignment: .stretch,
                      children: <Widget>[
                        Row(
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(32.0),
                              child: Stack(
                                children: [
                                  Hero(
                                    tag:
                                        controller.widget.embeddedCloseButton !=
                                            null
                                        ? 'embedded_content_banner'
                                        : 'content_banner',
                                    child: Avatar(
                                      mxContent: room.avatar,
                                      name: displayname,
                                      size: Avatar.defaultSize * 2.5,
                                      onTap: roomAvatar != null
                                          ? () => showDialog(
                                              context: context,
                                              builder: (_) =>
                                                  MxcImageViewer(roomAvatar),
                                            )
                                          : null,
                                      isHexagonal:
                                          room.directChatMatrixID != null &&
                                          Matrix.of(
                                            context,
                                          ).isAiUser(room.directChatMatrixID!),
                                      storyRing:
                                          directChatMatrixID != null &&
                                              !Matrix.of(
                                                context,
                                              ).isAiUser(directChatMatrixID)
                                          ? ActiveStoriesProvider.instance
                                                .ringForUser(
                                                  directChatMatrixID,
                                                  Matrix.of(context).client,
                                                  StoriesSeenStore(
                                                    Matrix.of(context).store,
                                                    scope: Matrix.of(
                                                      context,
                                                    ).client.userID,
                                                  ),
                                                )
                                          : null,
                                      onStoryTap: directChatMatrixID != null
                                          ? () => openUserStories(
                                              context,
                                              directChatMatrixID,
                                            )
                                          : null,
                                    ),
                                  ),
                                  if (!room.isDirectChat &&
                                      room.canChangeStateEvent(
                                        EventTypes.RoomAvatar,
                                      ))
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: FloatingActionButton.small(
                                        onPressed: controller.setAvatarAction,
                                        heroTag: null,
                                        child: const Icon(
                                          Icons.camera_alt_outlined,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: .center,
                                crossAxisAlignment: .start,
                                children: [
                                  TextButton.icon(
                                    onPressed: () => room.isDirectChat
                                        ? null
                                        : room.canChangeStateEvent(
                                            EventTypes.RoomName,
                                          )
                                        ? controller.setDisplaynameAction()
                                        : LizaShare.share(
                                            displayname,
                                            context,
                                            copyOnly: true,
                                          ),
                                    icon: Icon(
                                      room.isDirectChat
                                          ? Icons.chat_bubble_outline
                                          : room.canChangeStateEvent(
                                              EventTypes.RoomName,
                                            )
                                          ? Icons.edit_outlined
                                          : Icons.copy_outlined,
                                      size: 16,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          theme.colorScheme.onSurface,
                                      iconColor: theme.colorScheme.onSurface,
                                    ),
                                    label: Text(
                                      room.isDirectChat
                                          ? L10n.of(context).directChat
                                          : displayname,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 18),
                                    ),
                                  ),
                                  TextButton.icon(
                                    // Число подписчиков видно всем (публичная
                                    // метрика), а кнопка становится неактивной
                                    // (переход к поимённому списку закрыт) для
                                    // тех, кому не разрешает canSeeMembers
                                    // (см. chat_topology.dart).
                                    onPressed:
                                        canSeeMembers && !room.isDirectChat
                                        ? () => context.push(
                                            '/rooms/${controller.roomId}/details/members',
                                          )
                                        : null,
                                    icon: const Icon(
                                      Icons.group_outlined,
                                      size: 14,
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          theme.colorScheme.secondary,
                                      iconColor: theme.colorScheme.secondary,
                                    ),
                                    label: Text(
                                      room.isChannel
                                          ? L10n.of(
                                              context,
                                            ).channelSubscribersCount(
                                              actualMembersCount,
                                            )
                                          : L10n.of(context).countParticipants(
                                              actualMembersCount,
                                            ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      //    style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (room.canChangeStateEvent(EventTypes.RoomTopic) ||
                            room.topic.isNotEmpty) ...[
                          Divider(color: theme.dividerColor),
                          ListTile(
                            title: Text(
                              room.isChannel
                                  ? L10n.of(context).channelDescription
                                  : isAiDm
                                  ? L10n.of(context).description
                                  : L10n.of(context).chatDescription,
                              style: TextStyle(
                                color: theme.colorScheme.secondary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            trailing:
                                (!isAiDm &&
                                    room.canChangeStateEvent(
                                      EventTypes.RoomTopic,
                                    ))
                                ? IconButton(
                                    onPressed: controller.setTopicAction,
                                    tooltip: room.isChannel
                                        ? L10n.of(context).setChannelDescription
                                        : L10n.of(context).setChatDescription,
                                    icon: const Icon(Icons.edit_outlined),
                                  )
                                : null,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: SelectableLinkify(
                              text: room.topic.isEmpty
                                  ? room.isChannel
                                        ? L10n.of(
                                            context,
                                          ).noChannelDescriptionYet
                                        : L10n.of(context).noChatDescriptionYet
                                  : room.topic,
                              textScaleFactor: MediaQuery.textScalerOf(
                                context,
                              ).scale(1),
                              options: const LinkifyOptions(humanize: false),
                              linkStyle: const TextStyle(
                                color: Colors.blueAccent,
                                decorationColor: Colors.blueAccent,
                              ),
                              style: TextStyle(
                                fontSize: 14,
                                fontStyle: room.topic.isEmpty
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                                color: theme.textTheme.bodyMedium!.color,
                                decorationColor:
                                    theme.textTheme.bodyMedium!.color,
                              ),
                              onOpen: (url) =>
                                  UrlLauncher(context, url.url).launchUrl(),
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                        // Ссылка на канал видна не только в настройках
                        // доступа — публичный канал с сохранённым ником
                        // показывает её и здесь, в деталях.
                        if (room.isChannel &&
                            isChannelPublic(room.joinRules?.text) &&
                            controller.channelHandle != null)
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.surfaceContainer,
                              foregroundColor: iconColor,
                              child: const Icon(Icons.link_outlined),
                            ),
                            title: Text(L10n.of(context).channelLink),
                            subtitle: Text(
                              controller.channelHandle!.url,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.copy_outlined),
                            onTap: () => LizaShare.share(
                              controller.channelHandle!.url,
                              context,
                            ),
                          ),
                        // В канале созвона не бывает: вещание односторонее,
                        // ссылка на встречу здесь только мусорит экран.
                        if (!room.isChannel)
                          _CallLinkSectionWrapper(
                            room: room,
                            controller: controller,
                          ),
                        if (!room.isDirectChat && !detailsOnly) ...[
                          Divider(color: theme.dividerColor),
                          if (canEditChannelSettings) ...[
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainer,
                                foregroundColor: iconColor,
                                child: const Icon(
                                  Icons.admin_panel_settings_outlined,
                                ),
                              ),
                              title: Text(L10n.of(context).accessAndVisibility),
                              subtitle: Text(
                                room.isChannel
                                    ? L10n.of(
                                        context,
                                      ).accessAndVisibilityDescriptionChannel
                                    : L10n.of(
                                        context,
                                      ).accessAndVisibilityDescription,
                              ),
                              onTap: () => context.push(
                                '/rooms/${room.id}/details/access',
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_outlined,
                              ),
                            ),
                            ListTile(
                              title: Text(
                                room.isChannel
                                    ? L10n.of(context).channelPermissions
                                    : L10n.of(context).chatPermissions,
                              ),
                              subtitle: Text(
                                L10n.of(context).whoCanPerformWhichAction,
                              ),
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainer,
                                foregroundColor: iconColor,
                                child: const Icon(Icons.tune_outlined),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_outlined,
                              ),
                              onTap: () => context.push(
                                '/rooms/${room.id}/details/permissions',
                              ),
                            ),
                          ],
                          if (canEditChannelSettings && canManageStoreBlocks)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainer,
                                foregroundColor: iconColor,
                                child: const Icon(Icons.block_outlined),
                              ),
                              title: Text(
                                L10n.of(context).blockedAndRemovedMembers,
                              ),
                              subtitle: Text(
                                L10n.of(
                                  context,
                                ).blockedAndRemovedMembersDescription,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_outlined,
                              ),
                              onTap: () => context.push(
                                '/rooms/${room.id}/details/blocked-members',
                              ),
                            ),
                          if (room.isChannel && room.hasComments)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.surfaceContainer,
                                foregroundColor: iconColor,
                                child: const Icon(Icons.forum_outlined),
                              ),
                              title: Text(
                                L10n.of(context).openChannelDiscussion,
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_outlined,
                              ),
                              onTap: controller.openDiscussionAction,
                            ),
                          if (room.isChannel &&
                              room.ownPowerLevel >= adminPowerLevel)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor: room.hasComments
                                    ? theme.colorScheme.errorContainer
                                    : theme.colorScheme.surfaceContainer,
                                foregroundColor: room.hasComments
                                    ? theme.colorScheme.onErrorContainer
                                    : iconColor,
                                child: const Icon(Icons.mode_comment_outlined),
                              ),
                              title: Text(
                                room.hasComments
                                    ? L10n.of(context).disableChannelComments
                                    : L10n.of(context).enableChannelComments,
                                style: room.hasComments
                                    ? TextStyle(color: theme.colorScheme.error)
                                    : null,
                              ),
                              onTap: room.hasComments
                                  ? controller.disableChannelComments
                                  : controller.enableChannelComments,
                            ),
                          if (room.isChannel &&
                              room.ownPowerLevel >= adminPowerLevel)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.errorContainer,
                                foregroundColor:
                                    theme.colorScheme.onErrorContainer,
                                child: const Icon(Icons.delete_outlined),
                              ),
                              title: Text(
                                L10n.of(context).deleteChannel,
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                              onTap: controller.deleteChannelAction,
                            ),
                        ],
                        if (!detailsOnly) ...[
                          Divider(color: theme.dividerColor),
                          // В ПРОСТРАНСТВЕ список участников = база юзеров
                          // компании: показываем только тем, кто может
                          // приглашать (админ/модератор). В обычном чате
                          // участники видны всем — это штатное поведение.
                          if (canSeeMembers)
                            ListTile(
                              title: Text(
                                room.isChannel
                                    ? L10n.of(context).channelSubscribersCount(
                                        actualMembersCount,
                                      )
                                    : L10n.of(
                                        context,
                                      ).countParticipants(actualMembersCount),
                                style: TextStyle(
                                  color: theme.colorScheme.secondary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              // Поиск участников по имени/логину — на странице
                              // «Участники» (там же бан/удаление через меню).
                              trailing: IconButton(
                                tooltip: L10n.of(context).searchByNameOrId,
                                icon: const Icon(Icons.search_outlined),
                                onPressed: () => context.push(
                                  '/rooms/${room.id}/details/members',
                                ),
                              ),
                              onTap: () => context.push(
                                '/rooms/${room.id}/details/members',
                              ),
                            ),
                          if (!room.isDirectChat &&
                              (room.canInvite || companySpace))
                            ListTile(
                              title: Text(L10n.of(context).inviteContact),
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                foregroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                radius: Avatar.defaultSize / 2,
                                child: const Icon(Icons.add_outlined),
                              ),
                              trailing: const Icon(
                                Icons.chevron_right_outlined,
                              ),
                              onTap: () {
                                if (!ensureCanInviteToSpace(context, room)) {
                                  return;
                                }
                                context.go('/rooms/${room.id}/invite');
                              },
                            ),
                          if (!room.isDirectChat &&
                              (canManageInviteLink || companySpace))
                            ListTile(
                              title: Text(L10n.of(context).getInviteLink),
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                foregroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                radius: Avatar.defaultSize / 2,
                                child: const Icon(Icons.link_outlined),
                              ),
                              onTap: () {
                                if (!ensureCanInviteToSpace(context, room)) {
                                  return;
                                }
                                // Токен для invite-ссылки берём у аккаунта,
                                // реально СОСТОЯЩЕГО в комнате (room.client) —
                                // в cross-HS бандле это может быть аккаунт с
                                // другого HS, видящий комнату федеративно. А
                                // server_name диалог берёт из room.id (домен
                                // хостящего HS) — это ортогонально выбору токена.
                                showDialog(
                                  context: context,
                                  builder: (_) => InviteLinkDialog(
                                    room: room,
                                    client: room.client,
                                    scaffoldMessenger: ScaffoldMessenger.of(
                                      context,
                                    ),
                                  ),
                                );
                              },
                            ),
                        ],
                      ],
                    )
                  : i < members.length + 1
                  ? ParticipantListItem(members[i - 1])
                  : ListTile(
                      title: Text(
                        L10n.of(context).loadCountMoreParticipants(
                          (actualMembersCount - members.length),
                        ),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: theme.scaffoldBackgroundColor,
                        child: const Icon(
                          Icons.group_outlined,
                          color: Colors.grey,
                        ),
                      ),
                      onTap: () => context.push(
                        '/rooms/${controller.roomId!}/details/members',
                      ),
                      trailing: const Icon(Icons.chevron_right_outlined),
                    ),
            ),
          ),
        );
      },
    );
  }
}

class _CallLinkSection extends StatelessWidget {
  final Room room;
  final ChatDetailsController controller;

  const _CallLinkSection({required this.room, required this.controller});

  @override
  Widget build(BuildContext context) {
    final callUrl =
        room.getState(ChatDetailsController.callLinkEventType)?.content['url']
            as String?;
    final hasCallLink = callUrl != null && callUrl.isNotEmpty;
    final canEdit = room.canChangeStateEvent(
      ChatDetailsController.callLinkEventType,
    );

    if (!hasCallLink && !canEdit) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(
            L10n.of(context).callLink,
            style: TextStyle(
              color: Theme.of(context).colorScheme.secondary,
              fontWeight: FontWeight.bold,
            ),
          ),
          trailing: canEdit
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      tooltip: L10n.of(context).setCallLink,
                      onPressed: controller.setCallLinkAction,
                    ),
                    if (hasCallLink)
                      IconButton(
                        icon: const Icon(Icons.delete_outlined),
                        tooltip: L10n.of(context).deleteCallLink,
                        onPressed: controller.deleteCallLinkAction,
                      ),
                  ],
                )
              : null,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: hasCallLink
              ? InkWell(
                  onTap: () => UrlLauncher(context, callUrl).launchUrl(),
                  child: Text(
                    callUrl,
                    style: const TextStyle(
                      color: Colors.blueAccent,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.blueAccent,
                    ),
                  ),
                )
              : Text(
                  L10n.of(context).noCallLinkYet,
                  style: TextStyle(
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                    color: Theme.of(context).textTheme.bodyMedium!.color,
                  ),
                ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}

// Shows call link section for all room types (including DMs)
class _CallLinkSectionWrapper extends StatelessWidget {
  final Room room;
  final ChatDetailsController controller;

  const _CallLinkSectionWrapper({required this.room, required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dmId = room.directChatMatrixID;
    if (dmId != null && Matrix.of(context).isAiUser(dmId)) {
      return const SizedBox.shrink();
    }
    final section = _CallLinkSection(room: room, controller: controller);
    // Check if section would render anything
    final callUrl =
        room.getState(ChatDetailsController.callLinkEventType)?.content['url']
            as String?;
    final hasCallLink = callUrl != null && callUrl.isNotEmpty;
    final canEdit = room.canChangeStateEvent(
      ChatDetailsController.callLinkEventType,
    );
    if (!hasCallLink && !canEdit) return const SizedBox.shrink();
    return Column(
      children: [
        Divider(color: theme.dividerColor),
        section,
      ],
    );
  }
}
