import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:matrix/matrix.dart' as matrix;

import 'package:liza/utils/push_helper.dart';

/// Уведомление шторки, которое надо снять: [tag] нужен баннерам, нарисованным
/// Play Services из notification-блока Sygnal (их ключ — `tag=room_id`, id=0),
/// `cancel(id)` без тега их не находит.
typedef BannerToCancel = ({int id, String? tag});

/// Р2 (Android, спека 2026-11-12-push-sync-industry-alignment): какие
/// уведомления шторки уже прочитаны на другом устройстве.
///
/// Источник правды — сервер: `/notifications` отдаёт `read` по событию.
/// - Наш баннер (payload `client|room|event`) снимаем, если его событие
///   прочитано.
/// - Баннер Play Services (только тег = room_id, события не знаем) снимаем,
///   если прочитано САМОЕ СВЕЖЕЕ уведомление этой комнаты: ответ идёт от
///   новых к старым, а квитанция линейна — всё раньше тоже прочитано.
/// - Комнату пуша, который обрабатываем прямо сейчас, не трогаем.
/// - Чужой аккаунт (client_name в payload) не трогаем. Баннер без payload при
///   нескольких аккаунтах снимаем, только если его комната не принадлежит
///   другому аккаунту ([foreignRoomIds]; `null` — комнаты соседей неизвестны,
///   тогда не трогаем). Комната общая — владелец неразличим, не трогаем.
List<BannerToCancel> androidBannersToCancel({
  required List<ActiveNotification> active,
  required List<matrix.Notification> server,
  required String ownClientName,
  required int clientCount,
  String? currentRoomId,
  Set<String>? foreignRoomIds,
}) {
  final readEvents = <String>{};
  final latestReadByRoom = <String, bool>{};
  for (final n in server) {
    if (n.read) readEvents.add(n.event.eventId);
    latestReadByRoom.putIfAbsent(n.roomId, () => n.read);
  }
  if (readEvents.isEmpty) return const [];

  final result = <BannerToCancel>[];
  for (final a in active) {
    final id = a.id;
    if (id == null) continue;
    final payload = a.payload == null
        ? null
        : LizaPushPayload.fromString(a.payload!);
    final owner = payload?.clientName;
    if (owner != null && owner != ownClientName) continue;
    final roomId = payload?.roomId ?? a.tag;
    if (roomId == null || roomId == currentRoomId) continue;
    if (owner == null &&
        clientCount > 1 &&
        (foreignRoomIds == null || foreignRoomIds.contains(roomId))) {
      continue;
    }
    final eventId = payload?.eventId;
    final read = eventId != null
        ? readEvents.contains(eventId)
        : latestReadByRoom[roomId] == true;
    if (read) result.add((id: id, tag: a.tag));
  }
  return result;
}

const androidSweepTimeout = Duration(seconds: 3);

/// Проход на Android: один `GET /notifications`, таймаут 3 с. Любая ошибка →
/// не снимаем ничего (лишний баннер лучше потерянного). Возвращает число снятых.
Future<int> sweepReadAndroidBanners({
  required matrix.Client client,
  required FlutterLocalNotificationsPlugin plugin,
  required int clientCount,
  String? currentRoomId,
  List<matrix.Client> otherClients = const [],
  Duration timeout = androidSweepTimeout,
}) async {
  try {
    final active = await plugin.getActiveNotifications().timeout(timeout);
    if (active.isEmpty) return 0;
    final response = await client.getNotifications(limit: 50).timeout(timeout);
    final toCancel = androidBannersToCancel(
      active: active,
      server: response.notifications,
      ownClientName: client.clientName,
      clientCount: clientCount,
      currentRoomId: currentRoomId,
      foreignRoomIds: await foreignRoomIdsOf(otherClients, timeout: timeout),
    );
    for (final b in toCancel) {
      await plugin.cancel(b.id, tag: b.tag);
    }
    return toCancel.length;
  } catch (e) {
    matrix.Logs().v('[Push] Android read sweep skipped: $e');
    return 0;
  }
}

/// Комнаты других аккаунтов устройства. Хоть один не успел загрузить комнаты
/// из базы → `null` (владелец баннера без payload неизвестен — не трогаем).
Future<Set<String>?> foreignRoomIdsOf(
  List<matrix.Client> others, {
  Duration timeout = androidSweepTimeout,
}) async {
  final result = <String>{};
  for (final c in others) {
    try {
      await c.roomsLoading?.timeout(timeout);
    } catch (_) {
      return null;
    }
    if (c.prevBatch == null) return null;
    result.addAll(c.rooms.map((r) => r.id));
  }
  return result;
}
