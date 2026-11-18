import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

enum EmojiUsage { text, reaction }

/// Локальная история полного Matrix-аккаунта и назначения эмодзи.
class EmojiHistoryStore {
  EmojiHistoryStore(this.prefs, this.userId, this.usage);

  final SharedPreferences prefs;
  final String userId;
  final EmojiUsage usage;

  // Expando не удерживает закрытые prefs и не смешивает разные хранилища.
  static final _buckets = Expando<Map<String, _HistoryBucket>>();

  static String keyFor(String userId, EmojiUsage usage) =>
      'liza.emoji_history.v1.${usage.name}.${Uri.encodeComponent(userId)}';

  String get storageKey => keyFor(userId, usage);

  _HistoryBucket get _bucket {
    final buckets = _buckets[prefs] ??= {};
    return buckets.putIfAbsent(storageKey, () {
      try {
        return _HistoryBucket.read(prefs.getString(storageKey));
      } catch (_) {
        return _HistoryBucket();
      }
    });
  }

  /// Память обновляется сразу; записи на диск идут в исходном порядке.
  /// Ошибка диска не мешает текущему выбору и следующему сохранению.
  Future<void> record(String emoji) {
    if (emoji.isEmpty || userId.isEmpty) return Future.value();
    final bucket = _bucket;
    final previous = bucket.entries[emoji];
    bucket.entries[emoji] = _HistoryEntry(
      emoji,
      (previous?.count ?? 0) + 1,
      ++bucket.sequence,
    );
    final recent = bucket.entries.values.toList()
      ..sort((a, b) => b.last.compareTo(a.last));
    for (final entry in recent.skip(100)) {
      bucket.entries.remove(entry.emoji);
    }
    final snapshot = jsonEncode({
      'version': 1,
      'sequence': bucket.sequence,
      'entries': bucket.entries.values
          .map((e) => {'emoji': e.emoji, 'count': e.count, 'last': e.last})
          .toList(),
    });
    bucket.pending = bucket.pending.then((_) async {
      try {
        await prefs.setString(storageKey, snapshot);
      } catch (_) {
        // История необязательна для отправки сообщения или реакции.
      }
    });
    return bucket.pending;
  }

  List<String> ranked({int limit = 28}) {
    if (limit <= 0 || userId.isEmpty) return [];
    final entries = _bucket.entries.values.toList()
      ..sort((a, b) {
        final frequency = b.count.compareTo(a.count);
        return frequency != 0 ? frequency : b.last.compareTo(a.last);
      });
    return entries.take(limit).map((e) => e.emoji).toList();
  }

  List<String> quickReactions(List<String> defaults, {int limit = 5}) {
    if (limit <= 0) return [];
    return {
      ...ranked(limit: limit),
      ...defaults.where((e) => e.isNotEmpty),
    }.take(limit).toList();
  }
}

class _HistoryBucket {
  final entries = <String, _HistoryEntry>{};
  var sequence = 0;
  Future<void> pending = Future.value();

  _HistoryBucket();

  factory _HistoryBucket.read(String? encoded) {
    final bucket = _HistoryBucket();
    if (encoded == null) return bucket;
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1 || data['entries'] is! List) {
      return bucket;
    }
    for (final value in data['entries'] as List) {
      if (value is! Map) continue;
      final emoji = value['emoji'];
      final count = value['count'];
      final last = value['last'];
      if (emoji is! String ||
          emoji.isEmpty ||
          count is! int ||
          count <= 0 ||
          last is! int ||
          last <= 0) {
        continue;
      }
      bucket.entries[emoji] = _HistoryEntry(emoji, count, last);
      if (last > bucket.sequence) bucket.sequence = last;
    }
    final recent = bucket.entries.values.toList()
      ..sort((a, b) => b.last.compareTo(a.last));
    for (final entry in recent.skip(100)) {
      bucket.entries.remove(entry.emoji);
    }
    return bucket;
  }
}

class _HistoryEntry {
  const _HistoryEntry(this.emoji, this.count, this.last);
  final String emoji;
  final int count;
  final int last;
}
