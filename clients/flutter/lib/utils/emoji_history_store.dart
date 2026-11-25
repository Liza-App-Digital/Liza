import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum EmojiUsage { text, reaction }

/// Account data с историей реакций: одна на аккаунт, общая для всех устройств.
const emojiHistoryAccountDataType = 'ru.liza.emoji_history';

/// История эмодзи полного Matrix-аккаунта и назначения.
///
/// Локальная копия — SharedPreferences. История реакций при переданном
/// [client] дополнительно сливается с account data [emojiHistoryAccountDataType]:
/// так порядок частых реакций одинаков во всех чатах и на всех устройствах
/// аккаунта. Текстовая история остаётся только на устройстве.
class EmojiHistoryStore {
  EmojiHistoryStore(this.prefs, this.userId, this.usage, {this.client});

  final SharedPreferences prefs;
  final String userId;
  final EmojiUsage usage;
  final Client? client;

  /// Пауза перед отправкой на сервер: серия реакций уходит одним PUT.
  static Duration syncDebounce = const Duration(seconds: 3);

  static const _limit = 100;

  // Expando не удерживает закрытые prefs/клиентов и не смешивает хранилища.
  static final _buckets = Expando<Map<String, _HistoryBucket>>();
  static final _syncs = Expando<_PendingSync>();

  static String keyFor(String userId, EmojiUsage usage) =>
      'liza.emoji_history.v1.${usage.name}.${Uri.encodeComponent(userId)}';

  String get storageKey => keyFor(userId, usage);

  Client? get _syncClient {
    final client = this.client;
    if (client == null || usage != EmojiUsage.reaction) return null;
    if (userId.isEmpty || client.userID != userId) return null;
    return client;
  }

  _HistoryBucket get _bucket {
    final buckets = _buckets[prefs] ??= {};
    final bucket = buckets.putIfAbsent(storageKey, () {
      try {
        return _HistoryBucket.read(prefs.getString(storageKey));
      } catch (_) {
        return _HistoryBucket();
      }
    });
    final client = _syncClient;
    if (client != null && bucket.mergeRemote(_remoteOf(client))) {
      _persist(bucket);
    }
    return bucket;
  }

  static Object? _remoteOf(Client client) =>
      client.accountData[emojiHistoryAccountDataType]?.content['reaction'];

  /// Память обновляется сразу; записи на диск идут в исходном порядке.
  /// Ошибка диска или сервера не мешает текущему выбору и следующему сохранению.
  Future<void> record(String emoji) {
    if (emoji.isEmpty || userId.isEmpty) return Future.value();
    final bucket = _bucket;
    final previous = bucket.entries[emoji];
    bucket.entries[emoji] = _HistoryEntry(
      emoji,
      (previous?.count ?? 0) + 1,
      ++bucket.sequence,
    );
    bucket.prune();
    final client = _syncClient;
    if (client != null) _scheduleSync(client);
    return _persist(bucket);
  }

  Future<void> _persist(_HistoryBucket bucket) {
    final snapshot = jsonEncode({'version': 1, ...bucket.toJson()});
    bucket.pending = bucket.pending.then((_) async {
      try {
        await prefs.setString(storageKey, snapshot);
      } catch (_) {
        // История необязательна для отправки сообщения или реакции.
      }
    });
    return bucket.pending;
  }

  void _scheduleSync(Client client) {
    final pending = _syncs[client] ??= _PendingSync();
    pending.timer?.cancel();
    pending.store = this;
    pending.timer = Timer(syncDebounce, () {
      pending.timer = null;
      pending.inFlight = pending.inFlight.then((_) => _upload(client));
    });
  }

  /// Отправляет отложенную запись немедленно (уход приложения в фон, тесты).
  static Future<void> flushSync(Client client) {
    final pending = _syncs[client];
    if (pending == null) return Future.value();
    final timer = pending.timer;
    if (timer != null) {
      timer.cancel();
      pending.timer = null;
      pending.inFlight = pending.inFlight.then(
        (_) => pending.store!._upload(client),
      );
    }
    return pending.inFlight;
  }

  Future<void> _upload(Client client) async {
    // Аккаунт мог выйти или смениться, пока ждали debounce.
    if (!client.isLogged() || client.userID != userId) return;
    try {
      final bucket = _bucket;
      final reaction = bucket.toJson();
      final current = client.accountData[emojiHistoryAccountDataType]?.content;
      if (const DeepCollectionEquality().equals(
        current?['reaction'],
        reaction,
      )) {
        return;
      }
      final content = <String, Object?>{
        ...?current,
        'version': 1,
        'reaction': reaction,
      };
      await client.setAccountData(userId, emojiHistoryAccountDataType, content);
      // setAccountData в matrix 4.1.0 — голый PUT: без эха следующее открытие
      // меню до прихода /sync слило бы старое значение (см. account_bundles.dart).
      await client.database.storeAccountData(
        emojiHistoryAccountDataType,
        content,
      );
      client.accountData[emojiHistoryAccountDataType] = BasicEvent(
        type: emojiHistoryAccountDataType,
        content: content,
      );
    } catch (e, s) {
      Logs().w('Не удалось синхронизировать историю реакций', e, s);
    }
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

class _PendingSync {
  Timer? timer;
  EmojiHistoryStore? store;
  Future<void> inFlight = Future.value();
}

class _HistoryBucket {
  final entries = <String, _HistoryEntry>{};

  /// Часы Лэмпорта: больше любого известного `last`, локального и удалённого.
  /// Поэтому номера разных устройств сравнимы без опоры на их системное время.
  var sequence = 0;
  Future<void> pending = Future.value();
  Object? _mergedRemote;

  _HistoryBucket();

  factory _HistoryBucket.read(String? encoded) {
    final bucket = _HistoryBucket();
    if (encoded == null) return bucket;
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1) return bucket;
    bucket._mergeEntries(data['entries']);
    bucket.prune();
    return bucket;
  }

  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'entries': entries.values
        .map((e) => {'emoji': e.emoji, 'count': e.count, 'last': e.last})
        .toList(),
  };

  /// Слияние по эмодзи: max(count), max(last). Коммутативно и идемпотентно,
  /// поэтому устройства сходятся к одному порядку в любом порядке обменов.
  /// Возвращает true, если локальная история изменилась.
  bool mergeRemote(Object? remote) {
    if (remote == null || identical(remote, _mergedRemote)) return false;
    _mergedRemote = remote;
    if (remote is! Map) return false;
    final before = toJson();
    _mergeEntries(remote['entries']);
    final remoteSequence = remote['sequence'];
    if (remoteSequence is int && remoteSequence > sequence) {
      sequence = remoteSequence;
    }
    prune();
    return !const DeepCollectionEquality().equals(before, toJson());
  }

  void _mergeEntries(Object? values) {
    if (values is! List) return;
    for (final value in values) {
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
      final known = entries[emoji];
      entries[emoji] = _HistoryEntry(
        emoji,
        known == null || count > known.count ? count : known.count,
        known == null || last > known.last ? last : known.last,
      );
      if (last > sequence) sequence = last;
    }
  }

  /// 100 последних по давности; при равном `last` — по эмодзи, чтобы усечение
  /// давало один результат на всех устройствах.
  void prune() {
    if (entries.length <= EmojiHistoryStore._limit) return;
    final recent = entries.values.toList()
      ..sort((a, b) {
        final byLast = b.last.compareTo(a.last);
        return byLast != 0 ? byLast : a.emoji.compareTo(b.emoji);
      });
    for (final entry in recent.skip(EmojiHistoryStore._limit)) {
      entries.remove(entry.emoji);
    }
  }
}

class _HistoryEntry {
  const _HistoryEntry(this.emoji, this.count, this.last);
  final String emoji;
  final int count;
  final int last;
}
