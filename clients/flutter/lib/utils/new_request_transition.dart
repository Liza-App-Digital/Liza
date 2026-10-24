import 'package:flutter/foundation.dart';

/// Разовый кроссфейд «пустая панель → чат-запрос» (видео Надежды 23.10:
/// «резкий переход… главное, чтобы оно мягко переходило»).
///
/// Не `state.extra`: `ChatPageWithRoom` пере-применяет его при пересоздании
/// (ресайз окна, бегунок mini App). Токен читается без удаления — go_router
/// зовёт pageBuilder повторно, и ответ обязан совпасть, — и протухает сам,
/// чтобы fade не повторился при следующем открытии того же чата.
abstract final class NewRequestTransition {
  static const Duration fade = Duration(milliseconds: 280);
  static const Duration _ttl = Duration(milliseconds: 1500);

  static String? _roomId;
  static DateTime? _armedAt;

  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static void arm(String roomId) {
    _roomId = roomId;
    _armedAt = now();
  }

  /// Длительность перехода на страницу чата `roomId` в column-mode.
  static Duration durationFor(String roomId) {
    final armedAt = _armedAt;
    if (_roomId != roomId || armedAt == null) return Duration.zero;
    return now().difference(armedAt) < _ttl ? fade : Duration.zero;
  }

  @visibleForTesting
  static void reset() {
    _roomId = null;
    _armedAt = null;
    now = DateTime.now;
  }
}
