import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:liza/utils/push_client_resolver.dart';
import 'package:liza/utils/push_helper.dart';

/// Р5 (спека 2026-11-12-push-sync-industry-alignment): id уведомления Android
/// = хэш события, тег = room_id. Повтор того же события (ретрай Synapse, вторая
/// доставка FCM) заменяет то же уведомление, а не добавляет второе; снятие —
/// по тегу комнаты, тем же ключом, что у баннера Play Services.
///
/// sha256, а не `String.hashCode`: значение должно совпадать между процессами
/// и сборками. `client_name` в ключе — два своих аккаунта в одной комнате
/// получают одно событие с одним event_id. 0 занят баннером Play Services.
int pushEventNotificationId(String? clientName, String eventId) {
  final d = sha256.convert(utf8.encode('${clientName ?? ''}|$eventId')).bytes;
  final v = ((d[0] << 24) | (d[1] << 16) | (d[2] << 8) | d[3]) & 0x7fffffff;
  return v == 0 ? 1 : v;
}

typedef AndroidNotificationKey = ({int id, String? tag});

/// Владелец уведомления шторки: из payload, иначе неизвестен (баннер
/// Play Services или прежней сборки без payload).
String? _owner(ActiveNotification a) => a.payload == null
    ? null
    : LizaPushPayload.fromString(a.payload!).clientName;

/// Комната уведомления: payload, затем тег (новые и Play Services), затем
/// id прежней сборки (`pushNotificationId` / `roomId.hashCode`) по [roomIds].
String? androidNotificationRoom(
  ActiveNotification a, {
  String? ownClientName,
  Iterable<String> roomIds = const [],
}) {
  final fromPayload = a.payload == null
      ? null
      : LizaPushPayload.fromString(a.payload!).roomId;
  if (fromPayload != null && fromPayload.isNotEmpty) return fromPayload;
  if (a.tag != null && a.tag!.isNotEmpty) return a.tag;
  final id = a.id;
  if (id == null) return null;
  for (final r in roomIds) {
    if (pushNotificationId(ownClientName, r) == id || r.hashCode == id) {
      return r;
    }
  }
  return null;
}

/// Наше уведомление-переписка комнаты [roomId] своего аккаунта, которое
/// новое событие заменит (переписку MessagingStyle переносим из него). Баннер
/// Play Services (id 0) — не переписка, его не берём. Уведомление прежней
/// сборки (id по комнате, без тега) — берём: так оно не задвоится.
AndroidNotificationKey? androidRoomConversation({
  required List<ActiveNotification> active,
  required String ownClientName,
  required String roomId,
}) {
  final legacy = pushNotificationId(ownClientName, roomId);
  for (final a in active) {
    final id = a.id;
    if (id == null || id == 0) continue;
    final owner = _owner(a);
    if (owner != null && owner != ownClientName) continue;
    if (a.tag == roomId && owner == ownClientName) {
      return (id: id, tag: a.tag);
    }
    if (a.tag == null && id == legacy) return (id: id, tag: null);
  }
  return null;
}

/// Все уведомления комнаты [roomId] своего аккаунта: наши по тегу/payload,
/// прежней сборки по id, баннер Play Services (тег, без payload). Баннер без
/// владельца снимаем, только если [ownerlessIsOurs] — комната не принадлежит
/// другому залогиненному аккаунту.
List<AndroidNotificationKey> androidRoomNotificationsToCancel({
  required List<ActiveNotification> active,
  required String ownClientName,
  required String roomId,
  required bool ownerlessIsOurs,
}) {
  final result = <AndroidNotificationKey>[];
  for (final a in active) {
    final id = a.id;
    if (id == null) continue;
    final owner = _owner(a);
    if (owner != null && owner != ownClientName) continue;
    final room = androidNotificationRoom(
      a,
      ownClientName: ownClientName,
      roomIds: [roomId],
    );
    if (room != roomId) continue;
    if (owner == null && !ownerlessIsOurs) continue;
    result.add((id: id, tag: a.tag));
  }
  return result;
}
