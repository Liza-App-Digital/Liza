import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:matrix/matrix.dart';

/// To-device событие с ходом сборки виджета (Liza Bot API
/// `sendWidgetProgress`). В комнату не пишется — только тому, кто спросил.
const String widgetProgressEventType = 'com.liza.bot.widget_progress';

/// Этапы, на которых виджет ещё собирается (карточка-загрузка видна).
const Set<String> widgetProgressActiveStages = {'writing', 'sending'};

const Set<String> _widgetProgressStages = {
  'writing',
  'sending',
  'done',
  'failed',
};

/// Сколько ход сборки считается живым без обновлений. Бот шлёт прогресс
/// примерно раз в секунду; 15 с — заведомо больше паузы между шагами.
const Duration widgetProgressTtl = Duration(seconds: 15);

/// Последний прогресс сборки виджета в комнате.
@immutable
class WidgetGenerationProgress {
  final String roomId;
  final String senderId;
  final String stage;

  /// Оценка, не измерение: растёт монотонно, 100 — только когда виджет ушёл.
  final int percent;
  final String? hint;
  final DateTime updatedAt;

  const WidgetGenerationProgress({
    required this.roomId,
    required this.senderId,
    required this.stage,
    required this.percent,
    required this.updatedAt,
    this.hint,
  });

  bool get active => widgetProgressActiveStages.contains(stage);

  WidgetGenerationProgress copyWith({int? percent, DateTime? updatedAt}) =>
      WidgetGenerationProgress(
        roomId: roomId,
        senderId: senderId,
        stage: stage,
        percent: percent ?? this.percent,
        hint: hint,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Прогресс сборки виджетов: одна подписка на to-device события клиента,
/// последнее состояние на комнату, TTL и монотонный процент.
///
/// Источник — только собеседник личного чата: чужой бот и группа прогресс не
/// двигают. В историю, превью и пуши ничего не попадает.
class WidgetProgressStore extends ChangeNotifier {
  static final Expando<WidgetProgressStore> _byClient =
      Expando<WidgetProgressStore>();

  static WidgetProgressStore of(Client client) =>
      _byClient[client] ??= WidgetProgressStore._(client);

  WidgetProgressStore._(this._client) {
    _subscription = _client.onToDeviceEvent.stream.listen(handle);
  }

  final Client _client;
  final Map<String, WidgetGenerationProgress> _byRoom = {};
  final Map<String, Timer> _ttl = {};
  StreamSubscription<ToDeviceEvent>? _subscription;

  @visibleForTesting
  WidgetProgressStore.debug(Client client, {bool subscribe = false})
    : _client = client {
    if (subscribe) {
      _subscription = _client.onToDeviceEvent.stream.listen(handle);
    }
  }

  @visibleForTesting
  void debugPut(WidgetGenerationProgress progress) {
    _byRoom[progress.roomId] = progress;
    _restartTtl(progress.roomId);
    notifyListeners();
  }

  /// Свежий прогресс комнаты или `null`. Протухший снимается на чтении.
  WidgetGenerationProgress? forRoom(String roomId) {
    final progress = _byRoom[roomId];
    if (progress == null) return null;
    if (_isStale(progress)) {
      _byRoom.remove(roomId);
      _ttl.remove(roomId)?.cancel();
      return null;
    }
    return progress;
  }

  static bool _isStale(WidgetGenerationProgress p) =>
      DateTime.now().difference(p.updatedAt) > widgetProgressTtl;

  void _restartTtl(String roomId) {
    _ttl.remove(roomId)?.cancel();
    _ttl[roomId] = Timer(widgetProgressTtl, () {
      _ttl.remove(roomId);
      if (_byRoom.remove(roomId) != null) notifyListeners();
    });
  }

  void _cancelTtl(String roomId) => _ttl.remove(roomId)?.cancel();

  @visibleForTesting
  bool handle(ToDeviceEvent event) {
    if (event.type != widgetProgressEventType) return false;
    final content = event.content;
    final roomId = content['room_id'];
    final stage = content['stage'];
    if (roomId is! String || roomId.isEmpty) return false;
    if (stage is! String || !_widgetProgressStages.contains(stage)) {
      return false;
    }
    final room = _client.getRoomById(roomId);
    if (room == null) return false;
    // Прогресс двигает только собеседник лички (виджет — личка с ботом).
    if (room.directChatMatrixID != event.senderId) return false;

    if (stage == 'done' || stage == 'failed') {
      _cancelTtl(roomId);
      final removed = _byRoom.remove(roomId);
      if (removed != null) notifyListeners();
      return true;
    }

    final rawPercent = content['percent'];
    final parsed = rawPercent is int ? rawPercent.clamp(0, 100).toInt() : null;
    final previous = _byRoom[roomId];
    final percent = parsed == null
        ? (previous?.percent ?? 0)
        : previous == null
        ? parsed
        : math.max(previous.percent, parsed);
    final hint = content['hint'];
    _byRoom[roomId] = WidgetGenerationProgress(
      roomId: roomId,
      senderId: event.senderId,
      stage: stage,
      percent: percent,
      hint: hint is String && hint.isNotEmpty ? hint : null,
      updatedAt: DateTime.now(),
    );
    _restartTtl(roomId);
    notifyListeners();
    return true;
  }

  @override
  void dispose() {
    for (final timer in _ttl.values) {
      timer.cancel();
    }
    _ttl.clear();
    unawaited(_subscription?.cancel());
    _subscription = null;
    super.dispose();
  }
}
