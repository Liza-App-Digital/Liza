import 'package:matrix/matrix.dart';

import 'chat_topology.dart';

/// Собеседник из личного чата — строка экрана «Пригласить контакт».
class InviteContact {
  final String userId;
  final String? displayName;
  final Uri? avatarUrl;
  final bool isAi;

  /// Бот или ИИ (по любому из предикатов экрана): в конец списка, после людей.
  final bool isBotOrAi;

  const InviteContact({
    required this.userId,
    required this.displayName,
    required this.avatarUrl,
    required this.isAi,
    this.isBotOrAi = false,
  });
}

/// Кандидаты для «Пригласить контакт»: ОДНА строка на собеседника, сколько бы
/// личных комнат с ним ни было (каждый «Новый запрос» к Лизе — отдельный DM).
///
/// Отбор — как у частых собеседников ([isFrequentContactCandidateRoom]), но с
/// тремя отличиями: запрос к Лизе не отсекается (иначе при одних запросах Лиза
/// пропала бы из списка приглашаемых), вышедший из DM человек остаётся
/// (пригласить его можно), `ban` человека и `leave`/`ban` бота/ИИ скрываем
/// (мёртвый `@liza:synapse…` не должен забивать список). Из нескольких комнат
/// побеждает свежая по `latestEventReceivedTime`. Имя и аватар — из стейта
/// участника, без сети (`unsafeGetUserFromMemoryOrFallback` дёргает `requestUser`
/// на каждую комнату). Порядок: сначала люди — по числу сообщений за окно
/// ([activity], убывание) → свежесть DM → имя → userId; затем [lizaMxid] →
/// прочие ИИ → боты, внутри группы по имени → userId.
/// ledger:RL-invite-contacts-dedup-dm
List<InviteContact> inviteContactPeers(
  Iterable<Room> rooms, {
  required String lizaMxid,
  required bool Function(String userId) isAi,
  required bool Function(String userId) isBotOrAi,
  Map<String, int> activity = const {},
}) {
  final latest = <String, Room>{};
  for (final room in rooms) {
    if (room.membership != Membership.join || room.isSpace) continue;
    final peer = room.directChatMatrixID;
    if (peer == null || peer == room.client.userID) continue;
    if (room.lizaChatType != null || room.isHiddenChat) continue;
    final peerMembership = room
        .getState(EventTypes.RoomMember, peer)
        ?.content
        .tryGet<String>('membership');
    if (peerMembership == 'ban') continue;
    if (peerMembership == 'leave' && isBotOrAi(peer)) continue;
    final prev = latest[peer];
    if (prev != null &&
        !room.latestEventReceivedTime.isAfter(prev.latestEventReceivedTime)) {
      continue;
    }
    latest[peer] = room;
  }

  final contacts = <InviteContact>[];
  for (final entry in latest.entries) {
    final content = entry.value
        .getState(EventTypes.RoomMember, entry.key)
        ?.content;
    final name = content?.tryGet<String>('displayname');
    final avatar = content?.tryGet<String>('avatar_url');
    contacts.add(
      InviteContact(
        userId: entry.key,
        displayName: (name == null || name.trim().isEmpty) ? null : name,
        avatarUrl: avatar == null ? null : Uri.tryParse(avatar),
        isAi: isAi(entry.key),
        isBotOrAi: isBotOrAi(entry.key),
      ),
    );
  }

  // 0 — люди, 1 — Лиза, 2 — прочие ИИ, 3 — боты.
  int group(InviteContact c) {
    if (c.userId == lizaMxid) return 1;
    if (c.isAi) return 2;
    return c.isBotOrAi ? 3 : 0;
  }

  String sortName(InviteContact c) =>
      (c.displayName ?? c.userId.localpart ?? c.userId).toLowerCase();
  contacts.sort((a, b) {
    final byGroup = group(a).compareTo(group(b));
    if (byGroup != 0) return byGroup;
    if (group(a) == 0) {
      final byCount = (activity[b.userId] ?? 0).compareTo(
        activity[a.userId] ?? 0,
      );
      if (byCount != 0) return byCount;
      final byRecency = latest[b.userId]!.latestEventReceivedTime.compareTo(
        latest[a.userId]!.latestEventReceivedTime,
      );
      if (byRecency != 0) return byRecency;
    }
    final byName = sortName(a).compareTo(sortName(b));
    if (byName != 0) return byName;
    return a.userId.compareTo(b.userId);
  });
  return contacts;
}
