import 'dart:async';

import 'package:matrix/matrix.dart';

import '../chat_topology.dart';
import '../liza_dm.dart';
import '../miniapp_room.dart';
import '../user_role_service.dart';

/// Активность переписки с одним собеседником в личных чатах.
class DmActivity {
  const DmActivity({
    required this.userId,
    required this.roomId,
    required this.messageCount,
    required this.lastMessageTs,
  });

  final String userId;

  /// DM, который открывает тап по тайлу (самый свежий, если DM несколько).
  final String roomId;
  final int messageCount;

  /// Время последнего посчитанного сообщения, мс от эпохи.
  final int lastMessageTs;
}

/// Окно «частоты переписки».
const Duration frequentContactsWindow = Duration(days: 30);

/// Максимум частых собеседников в ленте.
const int frequentContactsLimit = 15;

const _messageTypes = {
  EventTypes.Message,
  EventTypes.Sticker,
  EventTypes.Encrypted,
};

/// Сообщения (в обе стороны) из [events], попавшие в окно [window] до [now].
/// Возвращает число и время самого свежего из них (0, если сообщений нет).
(int count, int lastTs) countRecentMessages(
  Iterable<Event> events, {
  required DateTime now,
  Duration window = frequentContactsWindow,
}) {
  final cutoff = now.subtract(window).millisecondsSinceEpoch;
  var count = 0;
  var lastTs = 0;
  for (final e in events) {
    if (!_messageTypes.contains(e.type) || e.redacted) continue;
    final ts = e.originServerTs.millisecondsSinceEpoch;
    if (ts < cutoff) continue;
    count++;
    if (ts > lastTs) lastTs = ts;
  }
  return (count, lastTs);
}

/// Бот ли [userId] для ленты частых: выделенный бот-хоумсервер или
/// AI-localpart. Роль `ai` из каталога проверяет вызывающий ([isBot] ниже).
bool isBotLikeMxid(String userId) {
  final domain = userId.contains(':') ? userId.split(':').last : '';
  return domain == botsHomeserver || UserRoleService.isRealAiLocalpart(userId);
}

/// Ранжирование частых собеседников: по убыванию числа сообщений, при
/// равенстве — свежее последнее сообщение первым, затем по mxid. Несколько
/// DM с одним человеком суммируются. Исключаются [excludedUserIds] (я, Лиза,
/// авторы уже показанных сторис), боты ([isBot]) и нулевая активность.
List<DmActivity> rankFrequentContacts(
  Iterable<DmActivity> activity, {
  required Set<String> excludedUserIds,
  required bool Function(String userId) isBot,
  int limit = frequentContactsLimit,
}) {
  final byUser = <String, DmActivity>{};
  for (final a in activity) {
    if (a.messageCount <= 0) continue;
    if (excludedUserIds.contains(a.userId) || isBot(a.userId)) continue;
    final prev = byUser[a.userId];
    if (prev == null) {
      byUser[a.userId] = a;
      continue;
    }
    final newer = a.lastMessageTs > prev.lastMessageTs ? a : prev;
    byUser[a.userId] = DmActivity(
      userId: a.userId,
      roomId: newer.roomId,
      messageCount: prev.messageCount + a.messageCount,
      lastMessageTs: newer.lastMessageTs,
    );
  }
  final ranked = byUser.values.toList()
    ..sort((a, b) {
      final byCount = b.messageCount.compareTo(a.messageCount);
      if (byCount != 0) return byCount;
      final byTs = b.lastMessageTs.compareTo(a.lastMessageTs);
      if (byTs != 0) return byTs;
      return a.userId.compareTo(b.userId);
    });
  return ranked.take(limit).toList();
}

/// DM-комнаты, годные в кандидаты частых: только `join`, не скрытые, не
/// сторис/каналы/запросы к Лизе, собеседник не вышел. Membership собеседника
/// читаем из стейта БЕЗ сети (`unsafeGetUserFromMemoryOrFallback` дёргает
/// `requestUser` — шторм запросов, см. RL-stories-bar-avatar).
bool isFrequentContactCandidateRoom(Room room) {
  if (room.membership != Membership.join || room.isSpace) return false;
  final peer = room.directChatMatrixID;
  if (peer == null || peer == room.client.userID) return false;
  if (room.lizaChatType != null) return false;
  if (room.isHiddenChat || isLizaRequestRoom(room)) return false;
  final peerMembership = room
      .getState(EventTypes.RoomMember, peer)
      ?.content
      .tryGet<String>('membership');
  return peerMembership != 'leave' && peerMembership != 'ban';
}

/// Собирает активность по личным чатам из ЛОКАЛЬНОЙ базы SDK, без сети.
/// Скан ограничен DM с активностью внутри окна, [maxRooms] самыми свежими и
/// [perRoomLimit] последними событиями каждого — лента висит в шапке списка
/// чатов, дорогой подсчёт ей не нужен.
Future<List<DmActivity>> collectDmActivity(
  Client client, {
  DateTime? now,
  int maxRooms = 60,
  int perRoomLimit = 100,
}) async {
  final at = now ?? DateTime.now();
  final cutoff = at.subtract(frequentContactsWindow);
  final rooms =
      client.rooms
          .where(isFrequentContactCandidateRoom)
          .where((r) => r.latestEventReceivedTime.isAfter(cutoff))
          .toList()
        ..sort(
          (a, b) =>
              b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime),
        );
  final result = <DmActivity>[];
  for (final room in rooms.take(maxRooms)) {
    final events = await client.database.getEventList(
      room,
      limit: perRoomLimit,
    );
    final (count, lastTs) = countRecentMessages(events, now: at);
    if (count == 0) continue;
    result.add(
      DmActivity(
        userId: room.directChatMatrixID!,
        roomId: room.id,
        messageCount: count,
        lastMessageTs: lastTs,
      ),
    );
  }
  return result;
}

/// In-memory кэш активности по аккаунту. Лента перестраивается на каждый sync
/// (дебаунс 3 с) — пересчёт по БД идёт не чаще [ttl] и не параллельно, а
/// повторный маунт ленты читает готовое.
class FrequentContactsCache {
  FrequentContactsCache._();

  static final FrequentContactsCache instance = FrequentContactsCache._();

  static const Duration ttl = Duration(minutes: 10);

  final Map<String, List<DmActivity>> _byAccount = {};
  final Map<String, DateTime> _computedAt = {};
  final Map<String, Future<List<DmActivity>>> _inFlight = {};

  /// Последний посчитанный результат для аккаунта (пусто, если ещё не считали).
  List<DmActivity> cached(String? accountId) =>
      _byAccount[accountId] ?? const [];

  /// Пересчитывает, если кэш старше [ttl]; иначе отдаёт готовое.
  Future<List<DmActivity>> refreshIfStale(
    Client client, {
    DateTime? now,
  }) {
    final accountId = client.userID;
    if (accountId == null) return Future.value(const []);
    final at = now ?? DateTime.now();
    final computed = _computedAt[accountId];
    if (computed != null && at.difference(computed) < ttl) {
      return Future.value(cached(accountId));
    }
    return _inFlight[accountId] ??= collectDmActivity(client, now: at)
        .then((value) {
          _byAccount[accountId] = value;
          _computedAt[accountId] = at;
          return value;
        })
        // Блочное тело намеренно: `=> _inFlight.remove(...)` вернуло бы этот же
        // future, и whenComplete ждал бы сам себя.
        .whenComplete(() {
          _inFlight.remove(accountId);
        });
  }

  void reset() {
    _byAccount.clear();
    _computedAt.clear();
    _inFlight.clear();
  }
}
