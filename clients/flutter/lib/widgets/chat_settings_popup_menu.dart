import 'dart:async';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/company_deletion.dart';
import 'package:liza/utils/company_membership.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'matrix.dart';

enum ChatPopupMenuActions {
  details,
  mute,
  unmute,
  leave,
  deleteCompanyViaSupport,
  search,
  mcp,
  block,
  unblock,
}

class ChatSettingsPopupMenu extends StatefulWidget {
  final Room room;
  final bool displayChatDetails;

  const ChatSettingsPopupMenu(this.room, this.displayChatDetails, {super.key});

  @override
  ChatSettingsPopupMenuState createState() => ChatSettingsPopupMenuState();
}

class ChatSettingsPopupMenuState extends State<ChatSettingsPopupMenu> {
  StreamSubscription? notificationChangeSub;

  @override
  void dispose() {
    notificationChangeSub?.cancel();
    super.dispose();
  }

  /// Что на самом деле произойдёт по пункту выхода — из этого берутся ПОДПИСЬ
  /// пункта, заголовок диалога, его тело и надпись кнопки (LABA-2540: раньше
  /// они расходились между собой — «Удалить чат» → «переместится в архив» →
  /// «Покинуть» → `leave()`).
  LeaveActionKind _leaveKind(BuildContext context) =>
      leaveActionKindFor(context, widget.room);

  @override
  Widget build(BuildContext context) {
    notificationChangeSub ??= Matrix.of(context).client.onSync.stream
        .where(
          (syncUpdate) =>
              syncUpdate.accountData?.any(
                (accountData) => accountData.type == 'm.push_rules',
              ) ??
              false,
        )
        .listen((u) => setState(() {}));
    return Stack(
      alignment: Alignment.center,
      children: [
        const SizedBox.shrink(),
        PopupMenuButton<ChatPopupMenuActions>(
          useRootNavigator: true,
          padding: PlatformInfos.isMobile
              ? EdgeInsets.zero
              : const EdgeInsets.all(8),
          onSelected: (choice) async {
            switch (choice) {
              case ChatPopupMenuActions.leave:
                final router = GoRouter.of(context);
                // Выход единственного админа канала (п.7): назначить преемника
                // или удалить канал единственного участника. Возвращает true,
                // если случай обработан — обычный выход тогда не нужен.
                if (widget.room.isChannel &&
                    await _handleSoleAdminChannelLeave(router)) {
                  break;
                }
                if (!mounted) return;
                final leaveKind = _leaveKind(context);
                final leaveLabel = leaveActionLabel(
                  L10n.of(context),
                  leaveKind,
                );
                final confirmed = await showOkCancelAlertDialog(
                  context: context,
                  title: leaveLabel,
                  message: leaveActionMessage(L10n.of(context), leaveKind),
                  okLabel: leaveLabel,
                  cancelLabel: L10n.of(context).cancel,
                  isDestructive: true,
                );
                if (confirmed != OkCancelResult.ok) return;
                final result = await showFutureLoadingDialog(
                  context: context,
                  future: () => widget.room.leave(),
                );
                if (result.error == null) {
                  router.go('/rooms');
                }

                break;
              case ChatPopupMenuActions.deleteCompanyViaSupport:
                await requestCompanyDeletion(context, widget.room);
                break;
              case ChatPopupMenuActions.block:
                final userId = widget.room.directChatMatrixID;
                if (userId == null) break;
                final confirmed = await showOkCancelAlertDialog(
                  context: context,
                  title: L10n.of(context).chatBlockUser,
                  message: L10n.of(context).chatBlockUserWarning,
                  okLabel: L10n.of(context).chatBlockUser,
                  cancelLabel: L10n.of(context).cancel,
                  isDestructive: true,
                );
                if (confirmed == OkCancelResult.ok) {
                  await showFutureLoadingDialog(
                    context: context,
                    future: () => Matrix.of(context).client.ignoreUser(userId),
                  );
                }
                break;
              case ChatPopupMenuActions.unblock:
                final userId = widget.room.directChatMatrixID;
                if (userId == null) break;
                await showFutureLoadingDialog(
                  context: context,
                  future: () => Matrix.of(context).client.unignoreUser(userId),
                );
                break;
              case ChatPopupMenuActions.mute:
                await showFutureLoadingDialog(
                  context: context,
                  future: () =>
                      widget.room.setPushRuleState(PushRuleState.mentionsOnly),
                );
                break;
              case ChatPopupMenuActions.unmute:
                await showFutureLoadingDialog(
                  context: context,
                  future: () =>
                      widget.room.setPushRuleState(PushRuleState.notify),
                );
                break;
              case ChatPopupMenuActions.details:
                _showChatDetails();
                break;
              case ChatPopupMenuActions.search:
                context.go('/rooms/${widget.room.id}/search');
                break;
              case ChatPopupMenuActions.mcp:
                context.go(AppRoutes.settingsMcp);
                break;
            }
          },
          itemBuilder: (BuildContext context) => [
            if (widget.displayChatDetails)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.details,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded),
                    const SizedBox(width: 12),
                    Text(
                      widget.room.isChannel
                          ? L10n.of(context).channelDetails
                          : L10n.of(context).chatDetails,
                    ),
                  ],
                ),
              ),
            if (widget.room.pushRuleState == PushRuleState.notify)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.mute,
                child: Row(
                  children: [
                    const Icon(Icons.notifications_off_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).muteChat),
                  ],
                ),
              )
            else
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.unmute,
                child: Row(
                  children: [
                    const Icon(Icons.notifications_on_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).unmuteChat),
                  ],
                ),
              ),
            PopupMenuItem<ChatPopupMenuActions>(
              value: ChatPopupMenuActions.search,
              child: Row(
                children: [
                  const Icon(Icons.search_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).search),
                ],
              ),
            ),
            // Только в DM с ЖИВЫМ ассистентом Лизой. Гейт по полному mxid, а не
            // по `isAiUser`: роль `ai` носят и @gpt, @deepseek, @botfather,
            // @liza-news, @cup — пункт «MCP-подключения» всплыл бы у них всех.
            // `MatrixState.lizaMxid` — геттер, а не литерал: на локальном
            // стенде (`liza.local`) mxid другой.
            if (widget.room.directChatMatrixID == MatrixState.lizaMxid)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.mcp,
                child: Row(
                  children: [
                    const Icon(Icons.extension_outlined),
                    const SizedBox(width: 12),
                    Text(L10n.of(context).settingsMcpTitle),
                  ],
                ),
              ),
            // `hidden` — своё главное пространство: `single_space_guard`
            // отвечает на leave 403, поэтому кнопки быть не должно. Гейт есть
            // в chat_list и space_view, а здесь был потерян — при этом именно
            // сюда ведёт «Настройки» пространства (chat_details_view).
            // Админу своей компании вместо пустоты — заявка в поддержку
            // (LABA-2533): не корзина, ничего не удаляется на месте.
            if (_leaveKind(context) case final leaveKind
                when leaveKind == LeaveActionKind.deleteCompanyViaSupport)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.deleteCompanyViaSupport,
                child: Row(
                  children: [
                    const Icon(Icons.support_agent_outlined),
                    const SizedBox(width: 12),
                    Text(leaveActionLabel(L10n.of(context), leaveKind)),
                  ],
                ),
              )
            else if (_leaveKind(context) case final leaveKind
                when leaveKind != LeaveActionKind.hidden)
              PopupMenuItem<ChatPopupMenuActions>(
                value: ChatPopupMenuActions.leave,
                child: Row(
                  children: [
                    Icon(
                      leaveKind == LeaveActionKind.declineInvite
                          ? Icons.delete_outlined
                          : Icons.logout_outlined,
                    ),
                    const SizedBox(width: 12),
                    Text(leaveActionLabel(L10n.of(context), leaveKind)),
                  ],
                ),
              ),
            if (widget.room.directChatMatrixID case final userId?)
              if (Matrix.of(context).client.ignoredUsers.contains(userId))
                PopupMenuItem<ChatPopupMenuActions>(
                  value: ChatPopupMenuActions.unblock,
                  child: Row(
                    children: [
                      const Icon(Icons.block_outlined),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).chatUnblockUser),
                    ],
                  ),
                )
              else
                PopupMenuItem<ChatPopupMenuActions>(
                  value: ChatPopupMenuActions.block,
                  child: Row(
                    children: [
                      const Icon(Icons.block_outlined),
                      const SizedBox(width: 12),
                      Text(L10n.of(context).chatBlockUser),
                    ],
                  ),
                ),
          ],
        ),
      ],
    );
  }

  /// Выход из канала с передачей владения, если уходит ЕДИНСТВЕННЫЙ владелец
  /// (п.7; с 2026-10-14 «админ» здесь = владелец PL 100, см. ownerPowerLevel).
  ///
  /// `true` — случай канала обработан (преемник назначен ИЛИ канала
  /// единственного участника удалён), обычный выход не нужен. `false` — я не
  /// единственный админ, пусть отработает штатная ветка с подтверждением.
  ///
  /// setPower преемнику ОБЯЗАН доехать ДО leave: после выхода прав на
  /// `m.room.power_levels` уже нет (event_auth). Провал setPower всплывает в
  /// `result.error`, и `leave` НЕ выполняется — админ остаётся, канал цел.
  Future<bool> _handleSoleAdminChannelLeave(GoRouter router) async {
    final room = widget.room;
    final client = Matrix.of(context).client;
    final myId = client.userID;
    final l10n = L10n.of(context);

    // requestParticipants форсит полную загрузку: lazy-loaded список мог не
    // содержать всех, и «единственный админ» посчитался бы ложно.
    List<User> participants;
    try {
      participants = await room.requestParticipants();
    } catch (_) {
      participants = room.getParticipants();
    }
    if (!mounted) return true;

    final joined = participants
        .where((u) => u.membership == Membership.join)
        .toList();
    // «Единственный» считаем по владельцам (PL 100), а не по админам-99:
    // уход владельца при живых админах иначе оставил бы канал без того, кто
    // может снять админа. Преемником тогда станет админ с наибольшим PL.
    final owners = joined.where((u) => isOwnerLevel(u.powerLevel)).toList();
    final iAmSoleAdmin = owners.length == 1 && owners.first.id == myId;
    if (!iAmSoleAdmin) return false;

    final hidden = room.hiddenMemberIds;
    final successorId = pickChannelSuccessor(
      joined
          .where(
            (u) =>
                u.id != myId &&
                !isServiceAccountId(u.id) &&
                !hidden.contains(u.id),
          )
          .map((u) => ChannelSuccessorCandidate(u.id, u.powerLevel)),
    );

    if (successorId == null) {
      // Кандидатов нет → я единственный участник → канал будет удалён.
      final confirmed = await showOkCancelAlertDialog(
        context: context,
        title: l10n.channelLeave,
        message: l10n.channelLeaveSoleMemberMessage,
        okLabel: l10n.channelLeave,
        cancelLabel: l10n.cancel,
        isDestructive: true,
      );
      if (confirmed != OkCancelResult.ok || !mounted) return true;
      final result = await showFutureLoadingDialog(
        context: context,
        future: () async {
          await room.leave();
          await room.forget();
        },
      );
      if (result.error == null) router.go('/rooms');
      return true;
    }

    final successorName = room
        .unsafeGetUserFromMemoryOrFallback(successorId)
        .calcDisplayname();
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: l10n.channelLeave,
      message: l10n.channelLeaveSoleAdminMessage(successorName),
      okLabel: l10n.channelLeave,
      cancelLabel: l10n.cancel,
      isDestructive: true,
    );
    if (confirmed != OkCancelResult.ok || !mounted) return true;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        await room.setPower(successorId, ownerPowerLevel);
        await room.leave();
      },
    );
    if (result.error == null) router.go('/rooms');
    return true;
  }

  void _showChatDetails() {
    if (GoRouterState.of(context).uri.path.endsWith('/details')) {
      context.go('/rooms/${widget.room.id}');
    } else {
      context.go('/rooms/${widget.room.id}/details');
    }
  }
}
