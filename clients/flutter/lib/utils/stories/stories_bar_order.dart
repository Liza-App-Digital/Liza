import 'package:matrix/matrix.dart';

import 'frequent_contacts.dart';

/// Время самой свежей активной сторис, мс от эпохи (0, если событий нет).
int latestStoryTs(Iterable<Event> events) {
  var latest = 0;
  for (final e in events) {
    final ts = e.originServerTs.millisecondsSinceEpoch;
    if (ts > latest) latest = ts;
  }
  return latest;
}

/// Сортировка авторов сторис: свежая публикация — левее; при равенстве — по id
/// комнаты (детерминированно). Боты и агенты считаются наравне с людьми.
List<T> sortByLatestStory<T>(
  Iterable<T> items, {
  required int Function(T item) latestTs,
  required String Function(T item) tiebreak,
}) {
  final list = items.toList();
  list.sort((a, b) {
    final byTs = latestTs(b).compareTo(latestTs(a));
    return byTs != 0 ? byTs : tiebreak(a).compareTo(tiebreak(b));
  });
  return list;
}

/// Категория 2 ленты: собеседники из личных чатов, которые сейчас онлайн.
/// Вышедший в онлайн встаёт левее всех ([onlineSince] — когда стал онлайн).
/// Боты и агенты не показываются; [excludedUserIds] — я и авторы сторис.
List<DmActivity> rankOnlineContacts(
  Iterable<DmActivity> dms, {
  required Map<String, DateTime> onlineSince,
  required Set<String> excludedUserIds,
  required bool Function(String userId) isBot,
}) {
  final seen = <String>{};
  final online = <DmActivity>[];
  for (final d in dms) {
    if (!onlineSince.containsKey(d.userId)) continue;
    if (excludedUserIds.contains(d.userId) || isBot(d.userId)) continue;
    if (seen.add(d.userId)) online.add(d);
  }
  online.sort((a, b) {
    final byTs = onlineSince[b.userId]!.compareTo(onlineSince[a.userId]!);
    return byTs != 0 ? byTs : a.userId.compareTo(b.userId);
  });
  return online;
}

/// Категория 3: остальные собеседники по времени последнего сообщения
/// (отправленного или полученного) — свежий диалог левее. Боты и агенты
/// считаются; те, кто уже показан выше, исключаются ([excludedUserIds]).
List<DmActivity> rankRecentDialogs(
  Iterable<DmActivity> dms, {
  required Set<String> excludedUserIds,
  int limit = recentDialogsLimit,
}) {
  final byUser = <String, DmActivity>{};
  for (final d in dms) {
    if (excludedUserIds.contains(d.userId)) continue;
    final prev = byUser[d.userId];
    if (prev == null || d.lastMessageTs > prev.lastMessageTs) {
      byUser[d.userId] = d;
    }
  }
  final list = byUser.values.toList()
    ..sort((a, b) {
      final byTs = b.lastMessageTs.compareTo(a.lastMessageTs);
      return byTs != 0 ? byTs : a.userId.compareTo(b.userId);
    });
  return list.take(limit).toList();
}

const int recentDialogsLimit = 30;
