import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Web Storage виджета (как в Telegram): `localStorage` — своё у сообщения на
/// этом устройстве, переживает пересоздание и перезапуск приложения;
/// `sessionStorage` — до перезапуска. 4 КБ на область (ключи и значения в
/// UTF-8). Квоту проверяет хост: мост недоверенный, шим лишь эмулирует
/// `QuotaExceededError`.
abstract final class TgWidgetStorage {
  static const int quotaBytes = 4096;
  static const String _prefix = 'tgw.ls.';
  static const String _startedKey = 'tgw.started';
  static const int _maxStarted = 500;

  static final Map<String, Map<String, String>> _session = {};
  static final Map<String, Map<String, String>> _localCache = {};

  static String keyFor({
    required String userId,
    required String roomId,
    required String eventId,
  }) => '$userId|$roomId|$eventId';

  static int sizeOf(Map<String, String> data) => data.entries.fold(
    0,
    (n, e) => n + utf8.encode(e.key).length + utf8.encode(e.value).length,
  );

  static Map<String, String> _decode(String? raw) {
    if (raw == null) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final e in json.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<Map<String, String>> loadLocal(String key) async {
    final cached = _localCache[key];
    if (cached != null) return Map.of(cached);
    try {
      final prefs = await SharedPreferences.getInstance();
      final data = _decode(prefs.getString('$_prefix$key'));
      _localCache[key] = data;
      return Map.of(data);
    } catch (e) {
      Logs().v('[TgWidget] storage load: ${e.runtimeType}');
      return {};
    }
  }

  /// `false` — сверх квоты: ничего не сохраняем (как `QuotaExceededError`).
  static Future<bool> saveLocal(String key, Map<String, String> data) async {
    if (sizeOf(data) > quotaBytes) return false;
    _localCache[key] = Map.of(data);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (data.isEmpty) {
        await prefs.remove('$_prefix$key');
      } else {
        await prefs.setString('$_prefix$key', jsonEncode(data));
      }
    } catch (e) {
      Logs().v('[TgWidget] storage save: ${e.runtimeType}');
    }
    return true;
  }

  static Map<String, String> session(String key) => Map.of(_session[key] ?? {});

  static bool saveSession(String key, Map<String, String> data) {
    if (sizeOf(data) > quotaBytes) return false;
    _session[key] = Map.of(data);
    return true;
  }

  /// «Запустить» нажат для сообщения — помним постоянно (последние 500).
  static Future<bool> wasStarted(String eventId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_startedKey)?.contains(eventId) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> markStarted(String eventId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = [
        ...?prefs.getStringList(_startedKey)?.where((e) => e != eventId),
        eventId,
      ];
      await prefs.setStringList(
        _startedKey,
        list.length > _maxStarted
            ? list.sublist(list.length - _maxStarted)
            : list,
      );
    } catch (e) {
      Logs().v('[TgWidget] started: ${e.runtimeType}');
    }
  }

  static void debugClear() {
    _session.clear();
    _localCache.clear();
  }
}
