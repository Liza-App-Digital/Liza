import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/miniapp_member_block.dart';
import 'package:liza/utils/stories/active_stories_provider.dart';
import 'package:liza/utils/stories/stories_seen_store.dart';
import 'package:liza/widgets/permission_slider_dialog.dart';
import 'adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'adaptive_dialogs/show_text_input_dialog.dart';
import 'adaptive_dialogs/user_dialog.dart';
import 'avatar.dart';
import 'future_loading_dialog.dart';
import 'matrix.dart';
import 'member_action_scope.dart';
import 'member_power_level_actions.dart';
import 'user_identifier.dart';

void showMemberActionsPopupMenu({
  required BuildContext context,
  required User user,
  void Function()? onMention,
}) async {
  final theme = Theme.of(context);
  final displayname = user.calcDisplayname();
  final isMe = user.room.client.userID == user.id;

  // В чатах-магазинах (mini App) владелец/модератор может «удалить из магазина»
  // так, чтобы участник не вернулся по ранее выданной ссылке. Пункт для
  // приглашённого (ещё не вступившего) называется «Отозвать приглашение».
  final isStore = isMiniAppStoreRoom(user.room);
  final canRemoveFromStore = isStore && user.canBan && !isMe;
  final isPendingInvite = user.membership == Membership.invite;

  // Скрытие участника из ВИТРИНЫ списка (LABA-2381): только владелец/админ
  // (PL>=99), не над собой и не в личном чате (там нет «списка участников»).
  // Скрытие косметическое: членство/сообщения/права не меняются.
  final canHide = user.room.canHideMembers && !isMe && !user.room.isDirectChat;
  final isHidden = user.room.hiddenMemberIds.contains(user.id);

  // «Передать владение» — только владельцу (PL 100), по механике ВК.
  final canTransferOwnership = canTransferOwnershipTo(
    ownPowerLevel: user.room.ownPowerLevel,
    callerId: user.room.client.userID ?? '',
    targetId: user.id,
    targetPowerLevel: user.powerLevel,
    targetJoined: user.membership == Membership.join,
    isDirectChat: user.room.isDirectChat,
  );

  // Формулировки прав/kick/ban/unban зависят от типа комнаты: канал/чат
  // остаются как раньше, а для пространств различаем корневую компанию
  // (isCompanySpace) и суб-пространство — заказчик потребовал разный текст
  // («в компании» vs «в пространстве»), чтобы не путать пользователей.
  // Ветвление — в чистой функции scopedMemberActionLabel, покрытой юнит-
  // тестом напрямую (см. member_action_scope.dart).
  T scoped<T>(T chat, T channel, T company, T space) => scopedMemberActionLabel(
    isChannel: user.room.isChannel,
    isSpace: user.room.isSpace,
    isCompany: isCompanySpace(
      space: user.room,
      allRooms: user.room.client.rooms,
    ),
    chat: chat,
    channel: channel,
    company: company,
    space: space,
  );

  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

  final button = context.findRenderObject() as RenderBox;

  final position = RelativeRect.fromRect(
    Rect.fromPoints(
      button.localToGlobal(const Offset(0, -65), ancestor: overlay),
      button.localToGlobal(
        button.size.bottomRight(Offset.zero) + const Offset(-50, 0),
        ancestor: overlay,
      ),
    ),
    Offset.zero & overlay.size,
  );

  final action = await showMenu<_MemberActions>(
    context: context,
    position: position,
    items: <PopupMenuEntry<_MemberActions>>[
      PopupMenuItem(
        value: _MemberActions.info,
        child: Row(
          spacing: 12.0,
          children: [
            Avatar(
              name: displayname,
              mxContent: user.avatarUrl,
              presenceUserId: user.id,
              presenceBackgroundColor: theme.colorScheme.surfaceContainer,
              storyRing: Matrix.of(context).isAiUser(user.id)
                  ? null
                  : ActiveStoriesProvider.instance.ringForUser(
                      user.id,
                      Matrix.of(context).client,
                      StoriesSeenStore(
                        Matrix.of(context).store,
                        scope: Matrix.of(context).client.userID,
                      ),
                    ),
            ),
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 128),
                  child: Text(
                    displayname,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 128),
                  child: Text(
                    userIdentifier(
                      user.id,
                      handles: Matrix.of(context).userHandleService,
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const PopupMenuDivider(),
      if (onMention != null)
        PopupMenuItem(
          value: _MemberActions.mention,
          child: Row(
            children: [
              const Icon(Icons.alternate_email_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).mention),
            ],
          ),
        ),
      if (user.membership == Membership.knock)
        PopupMenuItem(
          value: _MemberActions.approve,
          child: Row(
            children: [
              const Icon(Icons.how_to_reg_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).approve),
            ],
          ),
        ),
      PopupMenuItem(
        enabled: canChangeMemberPowerLevel(
          callerId: user.room.client.userID ?? '',
          targetId: user.id,
          sdkAllows:
              user.room.canChangePowerLevel && user.canChangeUserPowerLevel,
        ),
        value: _MemberActions.setRole,
        child: Row(
          children: [
            const Icon(Icons.admin_panel_settings_outlined),
            const SizedBox(width: 18),
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                Text(
                  scoped(
                    L10n.of(context).chatPermissions,
                    L10n.of(context).channelPermissions,
                    L10n.of(context).companyPermissions,
                    L10n.of(context).spacePermissions,
                  ),
                ),
                Text(
                  // Численный уровень пользователю ничего не говорит —
                  // оставляем только роль (спек 2026-07-30 §1.4).
                  user.powerLevel < moderatorPowerLevel
                      ? L10n.of(context).userLevel
                      : user.powerLevel < adminPowerLevel
                      ? L10n.of(context).moderatorLevel
                      : isOwnerLevel(user.powerLevel)
                      ? L10n.of(context).roomOwner
                      : L10n.of(context).adminLevel,
                  style: const TextStyle(fontSize: 10),
                ),
              ],
            ),
          ],
        ),
      ),
      if (canTransferOwnership)
        PopupMenuItem(
          value: _MemberActions.transferOwnership,
          child: Row(
            children: [
              const Icon(Icons.workspace_premium_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).transferOwnership),
            ],
          ),
        ),
      if (user.canKick)
        PopupMenuItem(
          value: _MemberActions.kick,
          child: Row(
            children: [
              Icon(
                Icons.person_remove_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 18),
              Text(
                scoped(
                  L10n.of(context).kickFromChat,
                  L10n.of(context).kickFromChannel,
                  L10n.of(context).kickFromCompany,
                  L10n.of(context).kickFromSpace,
                ),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
        ),
      if (user.canBan && user.membership != Membership.ban)
        PopupMenuItem(
          value: _MemberActions.ban,
          child: Row(
            children: [
              Icon(
                Icons.block_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 18),
              Text(
                scoped(
                  L10n.of(context).banFromChat,
                  L10n.of(context).banFromChannel,
                  L10n.of(context).banFromCompany,
                  L10n.of(context).banFromSpace,
                ),
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
        ),
      if (user.canBan && user.membership == Membership.ban)
        PopupMenuItem(
          value: _MemberActions.unban,
          child: Row(
            children: [
              const Icon(Icons.warning),
              const SizedBox(width: 18),
              Text(
                scoped(
                  L10n.of(context).unbanFromChat,
                  L10n.of(context).unbanFromChannel,
                  L10n.of(context).unbanFromCompany,
                  L10n.of(context).unbanFromSpace,
                ),
              ),
            ],
          ),
        ),
      if (canRemoveFromStore)
        PopupMenuItem(
          value: _MemberActions.removeFromStore,
          child: Row(
            children: [
              Icon(
                Icons.no_accounts_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 18),
              Text(
                isPendingInvite
                    ? L10n.of(context).revokeInvitation
                    : L10n.of(context).removeFromStore,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
        ),
      if (canHide)
        PopupMenuItem(
          value: _MemberActions.hideToggle,
          child: Row(
            children: [
              Icon(
                isHidden
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              const SizedBox(width: 18),
              Text(
                isHidden
                    ? L10n.of(context).returnToMemberList
                    : L10n.of(context).hideFromMemberList,
              ),
            ],
          ),
        ),
      if (!isMe)
        PopupMenuItem(
          value: _MemberActions.report,
          child: Row(
            children: [
              Icon(
                Icons.gavel_outlined,
                color: theme.colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 18),
              Text(
                L10n.of(context).reportUser,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ],
          ),
        ),
    ],
  );
  if (action == null) return;
  // Якорь меню — строка участника или аватар в ленте: за время диалога его
  // пересобирает список, и Navigator.of по мёртвому context бросает null check
  // (GlitchTip #92). Поэтому mounted проверяем после КАЖДОГО await.
  if (!context.mounted) return;

  switch (action) {
    case _MemberActions.mention:
      onMention?.call();
      return;
    case _MemberActions.setRole:
      final power = await showPermissionChooser(
        context,
        currentLevel: user.powerLevel,
        // Админа назначает только владелец, админ — не выше модератора.
        maxLevel: assignableRoleMaxLevel(user.room.ownPowerLevel),
        isChannel: user.room.isChannel,
      );
      if (power == null) return;
      if (!context.mounted) return;
      if (power >= adminPowerLevel) {
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).makeAdminDescription,
        );
        if (consent != OkCancelResult.ok) return;
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => promoteMemberToAdmin(user.room, user.id),
        );
        return;
      }
      await showFutureLoadingDialog(
        context: context,
        future: () => user.setPower(power),
      );
      return;
    case _MemberActions.transferOwnership:
      final consent = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).transferOwnership,
        message: L10n.of(context).transferOwnershipDescription(displayname),
        okLabel: L10n.of(context).transferOwnership,
        cancelLabel: L10n.of(context).cancel,
        isDestructive: true,
      );
      if (consent != OkCancelResult.ok) return;
      if (!context.mounted) return;
      await showFutureLoadingDialog(
        context: context,
        future: () => transferRoomOwnership(user.room, user.id),
      );
      return;
    case _MemberActions.approve:
      await showFutureLoadingDialog(
        context: context,
        future: () => user.room.invite(user.id),
      );
      return;
    case _MemberActions.kick:
      if (await showOkCancelAlertDialog(
            context: context,
            title: L10n.of(context).areYouSure,
            okLabel: L10n.of(context).yes,
            cancelLabel: L10n.of(context).no,
            message: user.room.isChannel
                ? L10n.of(context).kickUserDescriptionChannel
                : L10n.of(context).kickUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => user.kick(),
        );
      }
      return;
    case _MemberActions.ban:
      if (await showOkCancelAlertDialog(
            context: context,
            title: L10n.of(context).areYouSure,
            okLabel: L10n.of(context).yes,
            cancelLabel: L10n.of(context).no,
            message: user.room.isChannel
                ? L10n.of(context).banUserDescriptionChannel
                : L10n.of(context).banUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () async {
            await user.ban();
            // В магазине бан синхронизируем с blocklist auth-proxy, иначе
            // забаненный вернётся по invite-ссылке (ветку miniapp_invite
            // Matrix-бан не закрывает).
            if (isMiniAppStoreRoom(user.room)) {
              await blockStoreMember(
                room: user.room,
                userId: user.id,
                status: MemberBlockStatus.banned,
                displayName: user.calcDisplayname(),
              );
            }
          },
        );
      }
      return;
    case _MemberActions.removeFromStore:
      if (await showOkCancelAlertDialog(
            context: context,
            title: L10n.of(context).areYouSure,
            okLabel: L10n.of(context).yes,
            cancelLabel: L10n.of(context).no,
            message: isPendingInvite
                ? L10n.of(context).revokeInvitationDescription
                : L10n.of(context).removeFromStoreDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () async {
            // Ban (не kick): при пороге invite=0 в чате магазина kick позволил
            // бы любому участнику позвать удалённого обратно.
            await user.ban();
            await blockStoreMember(
              room: user.room,
              userId: user.id,
              status: isPendingInvite
                  ? MemberBlockStatus.inviteRevoked
                  : MemberBlockStatus.removed,
              displayName: user.calcDisplayname(),
            );
          },
        );
      }
      return;
    case _MemberActions.report:
      final reason = await showTextInputDialog(
        context: context,
        title: L10n.of(context).whyDoYouWantToReportThis,
        okLabel: L10n.of(context).report,
        cancelLabel: L10n.of(context).cancel,
        hintText: L10n.of(context).reason,
      );
      if (reason == null || reason.isEmpty) return;
      if (!context.mounted) return;

      final result = await showFutureLoadingDialog(
        context: context,
        future: () => user.room.client.reportUser(user.id, reason),
      );
      if (result.error != null) return;
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).contentHasBeenReported)),
      );
      return;
    case _MemberActions.hideToggle:
      await showFutureLoadingDialog(
        context: context,
        future: () => user.room.setMemberHidden(user.id, hidden: !isHidden),
      );
      return;
    case _MemberActions.info:
      await UserDialog.show(
        context: context,
        profile: Profile(
          userId: user.id,
          displayName: user.displayName,
          avatarUrl: user.avatarUrl,
        ),
      );
      return;
    case _MemberActions.unban:
      if (await showOkCancelAlertDialog(
            context: context,
            title: L10n.of(context).areYouSure,
            okLabel: L10n.of(context).yes,
            cancelLabel: L10n.of(context).no,
            message: user.room.isChannel
                ? L10n.of(context).unbanUserDescriptionChannel
                : L10n.of(context).unbanUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () async {
            await user.unban();
            if (isMiniAppStoreRoom(user.room)) {
              await unblockStoreMember(room: user.room, userId: user.id);
            }
          },
        );
      }
  }
}

enum _MemberActions {
  info,
  mention,
  setRole,
  transferOwnership,
  kick,
  ban,
  removeFromStore,
  approve,
  unban,
  report,
  hideToggle,
}
