import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/news_audience.dart';

/// Порядковое решение «есть ли в комнате чужие сообщения НОВЕЕ моей квитанции».
///
/// SDK-геттер `Room.hasNewMessages` сравнивает `latestOwnReceipt.ts` — а это
/// ВРЕМЯ ОТПРАВКИ КВИТАНЦИИ (`models/receipts.dart`, `receipt.originServerTs`),
/// не ts события — с `lastEvent.originServerTs`. Пока клиент читал только
/// «до последнего», это совпадало с правдой. С моделью популярных мессенджеров «прочитано =
/// увидено» квитанция уходит на событие в середине ленты, её ts новее всех
/// событий, и `hasNewMessages` даёт `false` при 7 реально непрочитанных:
/// сепаратор «Непрочитанное» пропадает, комната выпадает из бейджа иконки
/// (`countsTowardAppBadge`), а у низа глушится сетевая квитанция. Здесь —
/// порядок событий вместо времени.
///
/// Три яруса (спека 2026-09-17-read-receipts-viewport…):
/// - Tier0 — без порядка: нет preview-события / последнее моё / квитанция
///   стоит ровно на последнем → решение синхронно;
/// - Tier1 — кэш порядкового сравнения по `database.getEventIdList` (тот же
///   примитив, которым SDK ранжирует ownPrivate/ownPublic), ключ
///   `(квитанция, lastEvent)` — пересчёт только при смене пары;
/// - Tier2 — `hasNewMessages` SDK как fail-safe, когда порядок неизвестен
///   (событие квитанции вне локальной БД): сохраняет прежнюю защиту от
///   фантомного бейджа по застрявшему серверному счётчику
///   (`howItWoks/pushes.md` §9).
extension UnseenMessages on Room {
  /// Событие моей квитанции: приоритет — receipt-state SDK, затем `m.fully_read`
  /// (клиент шлёт их одним запросом, но чужой клиент мог прислать только одно).
  String? get _ownReadEventId {
    final own = receiptState.global.latestOwnReceipt?.eventId;
    if (own != null && own.isNotEmpty) return own;
    final fully = fullyRead;
    return fully.isEmpty ? null : fully;
  }

  bool get hasUnseenMessages {
    final last = lastEvent;
    if (last == null || !client.roomPreviewLastEvents.contains(last.type)) {
      return false;
    }
    if (last.senderId == client.userID) return false;
    if (last.isHiddenByNewsAudience) return false;
    final own = _ownReadEventId;
    // Никогда ничего не читал — всё новое (как readAt=0 в SDK).
    if (own == null) return true;
    if (own == last.eventId || fullyRead == last.eventId) return false;
    final cached = UnseenOrderCache.lookup(
      roomId: id,
      receiptEventId: own,
      lastEventId: last.eventId,
    );
    if (cached != null) return cached;
    return hasNewMessages;
  }

  /// Пара (квитанция, lastEvent), по которой кэш решает порядок; `null`, если
  /// ярус Tier0 уже дал ответ и порядок не нужен.
  ({String receiptEventId, String lastEventId})? get _orderKey {
    final last = lastEvent;
    if (last == null || !client.roomPreviewLastEvents.contains(last.type)) {
      return null;
    }
    if (last.senderId == client.userID) return null;
    final own = _ownReadEventId;
    if (own == null || own == last.eventId || fullyRead == last.eventId) {
      return null;
    }
    return (receiptEventId: own, lastEventId: last.eventId);
  }
}

/// Кэш порядкового сравнения квитанции и последнего события. Статический, на
/// процесс; ключ включает roomId, поэтому смена аккаунта в том же процессе
/// не подсовывает чужое решение (другой roomId/eventId — другая запись).
abstract final class UnseenOrderCache {
  static final Map<String, _UnseenEntry> _entries = {};

  /// Синхронный lookup для `hasUnseenMessages`; `null` — пары нет в кэше.
  static bool? lookup({
    required String roomId,
    required String receiptEventId,
    required String lastEventId,
  }) {
    final entry = _entries[roomId];
    if (entry == null ||
        entry.receiptEventId != receiptEventId ||
        entry.lastEventId != lastEventId) {
      return null;
    }
    return entry.unseen;
  }

  /// Чистое решение по списку id (новейшие первыми, как отдаёт
  /// `getEventIdList`): квитанция СТАРШЕ последнего события ⟺ есть невидённое.
  /// `null` — хотя бы одного id в списке нет, порядок неизвестен.
  @visibleForTesting
  static bool? decide({
    required List<String> eventIdsNewestFirst,
    required String receiptEventId,
    required String lastEventId,
  }) {
    final receiptIdx = eventIdsNewestFirst.indexOf(receiptEventId);
    final lastIdx = eventIdsNewestFirst.indexOf(lastEventId);
    if (receiptIdx < 0 || lastIdx < 0) return null;
    return receiptIdx > lastIdx;
  }

  /// Досчитать порядок для одной комнаты (например, перед открытием чата).
  static Future<void> reconcileRoom(Room room) async {
    final key = room._orderKey;
    if (key == null) return;
    if (lookup(
          roomId: room.id,
          receiptEventId: key.receiptEventId,
          lastEventId: key.lastEventId,
        ) !=
        null) {
      return;
    }
    List<String> ids;
    try {
      ids = await room.client.database.getEventIdList(room);
    } catch (e) {
      Logs().w('UnseenOrderCache: getEventIdList failed for ${room.id}', e);
      return;
    }
    final unseen = decide(
      eventIdsNewestFirst: ids,
      receiptEventId: key.receiptEventId,
      lastEventId: key.lastEventId,
    );
    // Неизвестный порядок не кэшируем: следующий sync может добрать событие.
    if (unseen == null) return;
    _entries[room.id] = _UnseenEntry(
      receiptEventId: key.receiptEventId,
      lastEventId: key.lastEventId,
      unseen: unseen,
    );
  }

  /// Досчитать порядок для всех комнат, где он может понадобиться бейджу:
  /// только `notificationCount > 0` (иначе `_isUnreadForBadge` до
  /// `hasUnseenMessages` не доходит). Зовётся перед подсчётом бейджа после
  /// sync — одна выборка из локальной БД на комнату при смене пары.
  static Future<void> reconcile(Client client) async {
    for (final room in client.rooms) {
      if (room.notificationCount == 0) continue;
      await reconcileRoom(room);
    }
  }

  @visibleForTesting
  static void reset() => _entries.clear();
}

class _UnseenEntry {
  final String receiptEventId;
  final String lastEventId;
  final bool unseen;

  const _UnseenEntry({
    required this.receiptEventId,
    required this.lastEventId,
    required this.unseen,
  });
}
