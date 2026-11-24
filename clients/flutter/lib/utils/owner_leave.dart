import 'package:flutter/widgets.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/company_deletion.dart';
import 'package:liza/utils/company_membership.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';

/// Чем закончилась попытка выхода единственного владельца.
///
/// [notHandled] — случай не про передачу владения (не владелец, есть второй
/// владелец, личка…): вызывающий идёт по своей обычной ветке выхода.
/// Навигацию после [left] делает вызывающий — у каждой точки выхода она своя.
enum OwnerLeaveOutcome { notHandled, left, cancelled, failed }

/// Подходит ли вид выхода для передачи владения: канал, группа, пространство.
///
/// Не подходят: личка (владельца нет), чат обсуждения канала (его ведёт
/// сервер channel_sync), отказ от приглашения, своя компания (из корня выйти
/// нельзя — `PROTECTED_MEMBERSHIPS`), отписка от чужой компании.
bool ownerHandoffApplies(LeaveActionKind kind, Room room) => switch (kind) {
  LeaveActionKind.leaveChannel || LeaveActionKind.leaveSpace => true,
  LeaveActionKind.leaveChat => !room.isDirectChat && !room.isChannelDiscussion,
  _ => false,
};

/// Выход с передачей владения, если уходит ЕДИНСТВЕННЫЙ владелец (PL 100).
///
/// Надежда 15.10 про группу и пространство: «Да. Я бы сделала так же» — как в
/// канале. Преемник — [pickOwnerSuccessor]. Передача — одно событие
/// `m.room.power_levels` ([handOverOwnershipOnLeave]) строго ДО `leave`: после
/// выхода прав на power_levels уже нет. Провал передачи → `leave` не идёт.
///
/// Участники не загрузились → [OwnerLeaveOutcome.failed]: обычный выход оставил
/// бы комнату без владельца, а неполный список — передачу не тому.
Future<OwnerLeaveOutcome> handleSoleOwnerLeave(
  BuildContext context,
  Room room,
) async {
  final kind = leaveActionKindFor(context, room);
  if (!ownerHandoffApplies(kind, room)) return OwnerLeaveOutcome.notHandled;
  // Не владелец и в комнате явно есть кто-то ещё (счётчики sync-summary; нет
  // счётчика — считаем «есть») — тяжёлую загрузку участников не делаем.
  if (!isOwnerLevel(room.ownPowerLevel) &&
      (kind != LeaveActionKind.leaveChat || _mayHaveOthers(room))) {
    return OwnerLeaveOutcome.notHandled;
  }

  final l10n = L10n.of(context);
  final myId = room.client.userID;
  final loaded = await showFutureLoadingDialog(
    context: context,
    future: room.requestParticipants,
  );
  if (!context.mounted) return OwnerLeaveOutcome.cancelled;
  final participants = loaded.result;
  // Список не загрузился — НЕ обычный выход: единственный владелец ушёл бы без
  // передачи (ошибку уже показал loading-диалог, пусть повторит).
  if (participants == null) return OwnerLeaveOutcome.failed;

  final joined = participants
      .where((u) => u.membership == Membership.join)
      .toList();

  // Последний участник группы: чат удаляется (leave → forget), иначе пустая
  // комната копится на сервере. «Кто-то ещё» = любой join/invite/knock, включая
  // ботов, скрытых и пользователей других серверов: сомнение → обычный выход.
  if (kind == LeaveActionKind.leaveChat &&
      myId != null &&
      isLastMemberOfGroup(
        myId: myId,
        others: participants.map((u) => (u.id, u.membership)),
      )) {
    return _confirmAndRun(
      context,
      title: leaveActionLabel(l10n, kind),
      message: l10n.lastMemberLeaveDeletesChatMessage,
      action: () async {
        await room.leave();
        await room.forget();
      },
    );
  }

  final owners = joined.where((u) => isOwnerLevel(u.powerLevel)).toList();
  if (owners.length != 1 || owners.first.id != myId) {
    return OwnerLeaveOutcome.notHandled;
  }

  final hidden = room.hiddenMemberIds;
  final successorId = pickOwnerSuccessor(
    joined
        .where(
          (u) =>
              u.id != myId &&
              !isServiceAccountId(u.id) &&
              !hidden.contains(u.id),
        )
        .map((u) => OwnerSuccessorCandidate(u.id, u.powerLevel)),
  );

  final title = leaveActionLabel(l10n, kind);
  final String message;
  final Future<void> Function() action;
  if (successorId != null) {
    final name = room
        .unsafeGetUserFromMemoryOrFallback(successorId)
        .calcDisplayname();
    message = room.isChannel
        ? l10n.channelLeaveSoleAdminMessage(name)
        : l10n.ownerLeaveHandoverMessage(name);
    action = () async {
      await handOverOwnershipOnLeave(room, successorId);
      await room.leave();
    };
  } else if (room.isChannel) {
    // Канал без кандидатов удаляется у единственного участника (п.7).
    message = l10n.channelLeaveSoleMemberMessage;
    action = () async {
      await room.leave();
      await room.forget();
    };
  } else {
    // Группу «у всех» не удаляем: обычный выход, без forget.
    message = l10n.ownerLeaveLastMemberMessage;
    action = room.leave;
  }

  return _confirmAndRun(
    context,
    title: title,
    message: message,
    action: action,
  );
}

Future<OwnerLeaveOutcome> _confirmAndRun(
  BuildContext context, {
  required String title,
  required String message,
  required Future<void> Function() action,
}) async {
  final confirmed = await showOkCancelAlertDialog(
    context: context,
    title: title,
    message: message,
    okLabel: title,
    cancelLabel: L10n.of(context).cancel,
    isDestructive: true,
  );
  if (confirmed != OkCancelResult.ok || !context.mounted) {
    return OwnerLeaveOutcome.cancelled;
  }
  final result = await showFutureLoadingDialog(
    context: context,
    future: action,
  );
  return result.error == null
      ? OwnerLeaveOutcome.left
      : OwnerLeaveOutcome.failed;
}

/// В комнате по счётчикам sync-summary есть кто-то кроме меня. Нет счётчика —
/// «да»: ложное «я один» ведёт к удалению, ложное «есть другие» — к обычному
/// выходу.
bool _mayHaveOthers(Room room) {
  final joined = room.summary.mJoinedMemberCount;
  if (joined == null) return true;
  return joined > 1 || (room.summary.mInvitedMemberCount ?? 0) > 0;
}

/// Я последний в группе: никого, кроме меня, со статусом join/invite/knock.
bool isLastMemberOfGroup({
  required String myId,
  required Iterable<(String, Membership)> others,
}) => others.every(
  (m) =>
      m.$1 == myId ||
      (m.$2 != Membership.join &&
          m.$2 != Membership.invite &&
          m.$2 != Membership.knock),
);
