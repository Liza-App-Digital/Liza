import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:liza/utils/push_journal.dart';

@immutable
class NotificationHealthSnapshot {
  NotificationHealthSnapshot({
    required Map<String, String> tags,
    this.observedAt,
  }) : tags = Map.unmodifiable(tags);

  final Map<String, String> tags;
  final DateTime? observedAt;
  bool get isDenied => tags['liza.auth'] == 'denied';
  bool get isAllowed => const {
    'authorized',
    'provisional',
    'ephemeral',
  }.contains(tags['liza.auth']);
  bool get isUnknown => !isDenied && !isAllowed;
}

/// Один read-only снимок для UI, auth tracker и отчёта. Запрос разрешения сюда
/// намеренно не входит: открытие диагностики не меняет настройки пользователя.
class NotificationHealth extends ChangeNotifier {
  NotificationHealth({
    Future<Map<Object?, Object?>?> Function()? readSettings,
    Future<bool> Function()? openSettings,
    String? platform,
  }) : _readSettings = readSettings,
       _openSettings = openSettings,
       platform = platform ?? pushReportPlatform();

  static final instance = NotificationHealth();
  static const appleChannel = MethodChannel('com.prodamus.laba.liza/apns');
  static const androidChannel = MethodChannel(
    'com.prodamus.laba.liza/push_health',
  );
  final String platform;
  final Future<Map<Object?, Object?>?> Function()? _readSettings;
  final Future<bool> Function()? _openSettings;
  Future<NotificationHealthSnapshot>? _flight;
  NotificationHealthSnapshot _snapshot = NotificationHealthSnapshot(
    tags: const {'liza.auth': 'unknown'},
  );
  NotificationHealthSnapshot get snapshot => _snapshot;
  MethodChannel get _channel =>
      platform == 'android' ? androidChannel : appleChannel;
  bool get _supported => const {'ios', 'macos', 'android'}.contains(platform);

  Future<NotificationHealthSnapshot> refresh({bool? hasSession}) => _flight ??=
      _refresh(hasSession: hasSession).whenComplete(() => _flight = null);

  Future<NotificationHealthSnapshot> _refresh({bool? hasSession}) async {
    final tags = <String, String>{'liza.auth': 'unknown'};
    DateTime? observedAt;
    if (!_supported) {
      tags['liza.auth'] = 'unsupported';
    } else {
      try {
        final raw =
            await (_readSettings?.call() ??
                    _channel.invokeMapMethod<Object?, Object?>(
                      'getNotificationSettings',
                    ))
                .timeout(const Duration(seconds: 3));
        if (raw != null) {
          tags.addAll(settingsTags(raw));
          observedAt = DateTime.now();
        }
      } catch (_) {
        // Ошибка чтения не превращается в старый успешный снимок.
      }
    }
    if (platform == 'android') {
      // Гибридный FCM может показать уведомление без callback приложения.
      tags['liza.native_auto_display'] = 'unknown';
    }
    _snapshot = NotificationHealthSnapshot(tags: tags, observedAt: observedAt);
    notifyListeners();
    unawaited(
      NotificationAuthTracker.observe(
        authorization(tags),
        hasSession: hasSession,
      ),
    );
    return _snapshot;
  }

  Future<bool> openSettings() async {
    if (!_supported) return false;
    try {
      return await (_openSettings?.call() ??
              _channel
                  .invokeMethod<bool>('openNotificationSettings')
                  .then((v) => v == true))
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return false;
    }
  }

  static int? authorization(Map<String, String> tags) =>
      switch (tags['liza.auth']) {
        'not_determined' => 0,
        'denied' => 1,
        'authorized' => 2,
        'provisional' => 3,
        'ephemeral' => 4,
        _ => null,
      };

  static Map<String, String> settingsTags(Map<Object?, Object?> raw) {
    const auth = {
      0: 'not_determined',
      1: 'denied',
      2: 'authorized',
      3: 'provisional',
      4: 'ephemeral',
    };
    const setting = {
      0: 'not_supported',
      1: 'disabled',
      2: 'enabled',
      -1: 'unsupported',
    };
    const style = {0: 'none', 1: 'banner', 2: 'alert'};
    final out = <String, String>{};
    void put(String tag, String key, Map<int, String> names) {
      if (raw[key] is int) out[tag] = names[raw[key]] ?? 'unknown';
    }

    put('liza.auth', 'authorization', auth);
    put('liza.alert', 'alert', setting);
    put('liza.alert_style', 'alertStyle', style);
    put('liza.badge_setting', 'badge', setting);
    put('liza.sound_setting', 'sound', setting);
    put('liza.nc_setting', 'notificationCenter', setting);
    put('liza.lock_screen', 'lockScreen', setting);
    put('liza.time_sensitive', 'timeSensitive', setting);
    put('liza.scheduled_delivery', 'scheduledDelivery', setting);
    put('liza.channel_importance', 'channelImportance', const {
      -2: 'missing',
      -1: 'unsupported',
      0: 'none',
      1: 'min',
      2: 'low',
      3: 'default',
      4: 'high',
      5: 'max',
    });
    put('liza.battery_optimization', 'batteryOptimization', const {
      -1: 'unsupported',
      0: 'exempt',
      1: 'optimized',
    });
    return out;
  }
}

/// Отдельный installation journal: чтение никогда не подтверждает доставку
/// отчёта и не удаляет записи. Stable id позволяет дедуп при повторных отчётах.
abstract final class NativePushDiagnostics {
  /// Успешное чтение пустого spool всё равно не доказывает получение пуша.
  static String lastReadStatus = 'unknown';
  static Future<List<Map<String, Object>>> readJournal() async {
    final platform = pushReportPlatform();
    if (!const {'ios', 'macos', 'android'}.contains(platform)) {
      lastReadStatus = 'unsupported';
      return const [];
    }
    try {
      final channel = platform == 'android'
          ? NotificationHealth.androidChannel
          : NotificationHealth.appleChannel;
      final raw = await channel
          .invokeMethod<Object?>('readDiagnosticJournal')
          .timeout(const Duration(seconds: 3));
      final entries = sanitize(raw);
      if (raw is! List) {
        lastReadStatus = 'unknown';
      } else {
        final filtered =
            raw.length != entries.length ||
            raw.indexed.any(
              (item) =>
                  item.$2 is! Map ||
                  !mapEquals(item.$2 as Map, entries[item.$1]),
            );
        final hasLoss = entries.any(
          (entry) =>
              entry['s'] == 'diagnosticLoss' &&
              (entry['value'] as int? ?? 0) > 0,
        );
        lastReadStatus = filtered || hasLoss ? 'partial' : 'available';
      }
      return entries;
    } catch (_) {
      lastReadStatus = 'unknown';
      return const [];
    }
  }

  @visibleForTesting
  static List<Map<String, Object>> sanitize(Object? raw, {DateTime? now}) {
    if (raw is! List) return const [];
    final out = <Map<String, Object>>[];
    final ids = <String>{};
    var bytes = 0;
    final nowMs = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final minMs = nowMs - const Duration(days: 7).inMilliseconds;
    for (final item in raw.take(257)) {
      if (item is! Map) continue;
      final id = item['id'];
      final t = item['t'];
      final s = item['s'];
      if (id is! String ||
          (id != 'native-diagnostic-loss' &&
              !RegExp(
                r'^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$',
              ).hasMatch(id)) ||
          ids.contains(id) ||
          t is! int ||
          t < minMs ||
          t > nowMs + 60000 ||
          !const {
            'nseReceived',
            'nseCompleted',
            'nseExpired',
            'nseError',
            'nseSwept',
            'fcmReceived',
            'fcmDuplicate',
            'nseSuppressed',
            'token',
            'diagnosticLoss',
          }.contains(s)) {
        continue;
      }
      final entry = <String, Object>{'id': id, 't': t, 's': s as String};
      final reason = item['reason'];
      if (const {
        'first',
        'unchanged',
        'rotated',
        'registration_failed',
        'storage',
        'dropped',
      }.contains(reason)) {
        entry['reason'] = reason as String;
      }
      final hash = item['event_hash'];
      if (hash is String && RegExp(r'^[a-f0-9]{32}$').hasMatch(hash)) {
        entry['event_hash'] = hash;
        entry['hash_version'] = 'sha256-128';
      }
      final value = item['value'];
      if (value is int && value >= 0 && value <= 2147483647) {
        entry['value'] = value;
      }
      // M6: момент отправки Sygnal'ом (`liza_sent_ms`), мс эпохи.
      final sent = item['sent'];
      if (sent is int && sent > 0 && sent <= nowMs + 86400000) {
        entry['sent'] = sent;
      }
      final size = utf8.encode(jsonEncode(entry)).length;
      if (bytes + size > 128 * 1024) break;
      bytes += size;
      ids.add(id);
      out.add(Map.unmodifiable(entry));
    }
    return List.unmodifiable(out);
  }
}
