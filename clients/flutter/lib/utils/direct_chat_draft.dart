import 'package:collection/collection.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/liza_dm.dart';

/// Чистое решение о цели навигации по правилу «чат/запрос — только с первым
/// сообщением» (тестируется без Client/виджета):
///
/// - передан `joinedRoomId` (есть присоединённый DM) → сразу реальная комната;
/// - иначе → ЧЕРНОВОЙ чат `/rooms/newchat/<userId>` (комната родится при
///   отправке первого сообщения).
String directChatTarget({required String userId, String? joinedRoomId}) {
  if (joinedRoomId != null) return '/rooms/$joinedRoomId';
  return '/rooms/newchat/${Uri.encodeComponent(userId)}';
}

/// Открывает личный чат с [userId]. Существующий ПРИСОЕДИНЁННЫЙ DM
/// (`membership == join`) открывает сразу; отсутствие DM ИЛИ только invite-DM
/// (мы ещё не приняли приглашение) → черновик. Боты, группы и redeem invite-
/// ссылки этот путь НЕ используют — им комната нужна сразу.
///
/// Спека: `docs/superpowers/specs/2026-09-03-direct-chat-draft-on-first-message-design.md`.
void openDirectChatOrDraft(
  GoRouter router,
  Client client,
  String userId, {
  Profile? profile,
}) {
  final existingId = client.getDirectChatFromUserId(userId);
  var existing = existingId == null ? null : client.getRoomById(existingId);
  // SDK берёт самый свежий DM — у Лизы это может быть чат-запрос; «Написать»
  // из профиля ведёт в основной чат с ней.
  if (existing != null && isLizaRequestRoom(existing)) {
    existing = findLizaAssistantDm(client, userId) ?? existing;
  }
  final joinedRoomId =
      (existing != null && existing.membership == Membership.join)
      ? existing.id
      : null;
  if (joinedRoomId != null) {
    router.go(directChatTarget(userId: userId, joinedRoomId: joinedRoomId));
  } else {
    router.go(directChatTarget(userId: userId), extra: profile);
  }
}

/// Живой личный чат с [partner], кроме брошенной комнаты [exclude] — куда вести
/// «Открыть чат заново» вместо повторного приглашения (LABA-2633: иначе
/// собеседник возвращается в брошенную комнату при живом новом DM, и у пары
/// становится два чата).
///
/// - `getDirectChatFromUserId` не годится: из нескольких DM он берёт самый
///   свежий по lastEvent и вернёт саму брошенную [exclude].
/// - Название обязано совпасть: mini App-чаты — тоже DM с `@liza` и отличаются
///   только `m.room.name`; без этого брошенный mini App-чат увёл бы в ассистента.
/// - Членство партнёра — из member-стейта, а не `unsafeGetUserFromMemoryOrFallback`
///   (при lazy members fallback-User врёт). Нет member-стейта партнёра (lazy
///   members, давно не открытый DM) — живость по summary.
/// - Свежепринятая комната может ещё не попасть в локальный m.direct — тогда
///   признак DM берём из `is_direct` своего member-события (сам или в
///   prev_content — приглашение было личным). Одного «без имени, вдвоём» мало:
///   так выглядит и обычная группа из двух.
///
/// Страж `RL-reopen-abandoned-dm-no-duplicate`.
Room? findLiveDirectChat(
  Client client,
  String partner, {
  required Room exclude,
}) {
  String nameOf(Room r) =>
      r.getState(EventTypes.RoomName)?.content.tryGet<String>('name') ?? '';
  String? membershipOf(Room r, String mxid) => r
      .getState(EventTypes.RoomMember, mxid)
      ?.content
      .tryGet<String>('membership');
  int memberCount(Room r) =>
      (r.summary.mJoinedMemberCount ?? 0) +
      (r.summary.mInvitedMemberCount ?? 0);

  final name = nameOf(exclude);
  final candidates = client.rooms.where((r) {
    if (r.id == exclude.id || r.isSpace || nameOf(r) != name) return false;
    final partnerMembership = membershipOf(r, partner);
    final own = r.getState(EventTypes.RoomMember, client.userID!);
    final invitedAsDirect =
        own?.content['is_direct'] == true ||
        (own is MatrixEvent && own.prevContent?['is_direct'] == true);
    final isDm =
        r.directChatMatrixID == partner ||
        (invitedAsDirect &&
            nameOf(r).isEmpty &&
            memberCount(r) == 2 &&
            partnerMembership != null);
    if (!isDm) return false;
    final meLive =
        r.membership == Membership.join ||
        (r.membership == Membership.invite && own?.senderId == partner);
    if (!meLive) return false;
    return partnerMembership == 'join' ||
        partnerMembership == 'invite' ||
        (partnerMembership == null &&
            r.membership == Membership.join &&
            memberCount(r) >= 2);
  }).toList();

  return candidates.sorted((a, b) {
    final byJoin =
        (b.membership == Membership.join ? 1 : 0) -
        (a.membership == Membership.join ? 1 : 0);
    if (byJoin != 0) return byJoin;
    final byTs = (b.lastEvent?.originServerTs ?? DateTime(0)).compareTo(
      a.lastEvent?.originServerTs ?? DateTime(0),
    );
    if (byTs != 0) return byTs;
    return a.id.compareTo(b.id);
  }).firstOrNull;
}

// Материализация черновика (ровно один `startDirectChat` при двойном тапе /
// текст+файл) — в общей воронке `Client.ensureDirectChat`
// (`utils/direct_chat_ensure.dart`), страж `RL-direct-chat-single-flight`.
