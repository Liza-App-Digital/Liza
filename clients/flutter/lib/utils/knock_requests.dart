import 'package:matrix/matrix.dart';

import 'package:liza/utils/chat_topology.dart';

/// Сколько участников ждут одобрения. Чистая функция — тестируется без клиента.
int countKnocking(Iterable<Membership> memberships) =>
    memberships.where((m) => m == Membership.knock).length;

/// Заявки в комнате. getParticipants() по умолчанию уже включает
/// Membership.knock. ВНИМАНИЕ: при room.partial==true состояние может не
/// содержать knock-членов до requestParticipants() — см. KnockRequestBadge,
/// который подтягивает участников явно перед подсчётом.
int knockRequestCount(Room room) =>
    countKnocking(room.getParticipants().map((u) => u.membership));

/// Порог «может рассматривать заявки»: max(модератор, invite).
///
/// Не ниже модератора — у старой компании (space) invite:0, и гейт по одному
/// invite показал бы бейдж ВСЕМ участникам (нарушение приватности заявки). Не
/// ниже invite — при «приглашают только админы» (invite:99) модератор не
/// может одобрить заявку, значит и видеть её незачем (задача 13). Та же формула
/// в серверном knock_notify (`review_threshold`).
int knockReviewThreshold(int? inviteThreshold) {
  final invite = inviteThreshold ?? 0;
  return invite > moderatorPowerLevel ? invite : moderatorPowerLevel;
}

/// Показывать счётчик только тем, кто реально может рассматривать заявки:
/// PL >= [knockReviewThreshold].
bool canReviewKnockRequests(Room room) =>
    room.membership == Membership.join &&
    room.ownPowerLevel >=
        knockReviewThreshold(
          room
              .getState(EventTypes.RoomPowerLevels)
              ?.content
              .tryGet<int>('invite'),
        );
