import 'package:matrix/matrix.dart';

/// Подтверждённые приватные ответы не появляются в timeline. Храним только IDs
/// использованных клавиатур в личном room account_data, без выбранных данных.
/// При сетевой ошибке cache уже скрывает выполненный запрос; следующий restore
/// или remember повторяет сохранение. Успешный submit не объявляется отменённым.
abstract final class BotInteractiveKeyboardState {
  static const eventType = 'com.liza.bot.keyboard.consumed';
  static const maximumIds = 256;
  static const retryDelay = Duration(seconds: 30);
  static final _scopes = Expando<_KeyboardScope>();

  static _KeyboardScope _scope(Room room) {
    var scope = _scopes[room.client];
    if (scope == null || !scope.current) {
      scope = _KeyboardScope(
        room.client,
        trustCachedAccountData: scope == null,
      );
      _scopes[room.client] = scope;
    }
    return scope;
  }

  static bool isConsumed(Room room, String eventId) {
    final scope = _scope(room);
    final state = scope.room(room.id);
    if (scope.trustCachedAccountData || state.restored) {
      state.merge(room.roomAccountData[eventType]?.content);
    }
    return state.ids.contains(eventId);
  }

  /// Восстановление из Matrix и повтор отложенной записи сериализованы с submit.
  static Future<void> restore(Room room) async {
    final scope = _scope(room);
    final state = scope.room(room.id);
    if (scope.trustCachedAccountData || state.restored) {
      state.merge(room.roomAccountData[eventType]?.content);
    }
    if (state.restored && state.dirty.isEmpty) return;
    // Неудачная попытка не повторяется на каждом refresh чата.
    final last = state.lastAttempt;
    if (last != null && DateTime.now().difference(last) < retryDelay) return;
    state.lastAttempt = DateTime.now();
    await state.serial(() async {
      if (!scope.current) return;
      try {
        final remote = await _read(scope, room);
        if (!scope.current) return;
        state.merge(remote);
        room.roomAccountData[eventType] = BasicEvent(
          type: eventType,
          content: remote,
        );
        state.restored = true;
        if (state.dirty.isNotEmpty) await _write(scope, room, state);
      } catch (_) {
        // Подтверждённое действие остаётся в cache; повтор — на следующем входе.
      }
    });
  }

  /// Вызывать исключительно после успешного server submit. Cache обновляется
  /// синхронно до первого await, поэтому быстрый reentry не оживляет клавиатуру.
  static Future<bool> remember(Room room, String eventId) {
    final scope = _scope(room);
    final state = scope.room(room.id);
    if (!scope.current || eventId.isEmpty || eventId.length > 512) {
      return Future.value(false);
    }
    state.dirty.add(eventId);
    state.merge({
      'event_ids': [eventId],
    });
    return state.serial(() async {
      if (!scope.current) return false;
      try {
        state.merge(await _read(scope, room));
        if (!scope.current) return false;
        await _write(scope, room, state);
        return scope.current;
      } catch (_) {
        return false;
      }
    });
  }

  static Future<Map<String, dynamic>> _read(
    _KeyboardScope scope,
    Room room,
  ) async {
    if (!scope.current) throw StateError('Session changed');
    try {
      return Map<String, dynamic>.from(
        await scope.client
            .getAccountDataPerRoom(scope.user!, room.id, eventType)
            .timeout(const Duration(seconds: 5)),
      );
    } on MatrixException catch (error) {
      if (error.error == MatrixError.M_NOT_FOUND) return {};
      rethrow;
    }
  }

  static Future<void> _write(
    _KeyboardScope scope,
    Room room,
    _KeyboardRoom state,
  ) async {
    if (!scope.current) return;
    final saved = Set<String>.of(state.dirty);
    final content = <String, dynamic>{'event_ids': state.ids.toList()};
    await scope.client
        .setAccountDataPerRoom(scope.user!, room.id, eventType, content)
        .timeout(const Duration(seconds: 5));
    if (!scope.current) return;
    state.dirty.removeAll(saved);
    state.restored = true;
    room.roomAccountData[eventType] = BasicEvent(
      type: eventType,
      content: content,
    );
  }
}

class _KeyboardScope {
  final Client client;
  final String? token;
  final String? user;
  final Uri? homeserver;
  final bool trustCachedAccountData;
  final rooms = <String, _KeyboardRoom>{};
  _KeyboardScope(this.client, {required this.trustCachedAccountData})
    : token = client.accessToken,
      user = client.userID,
      homeserver = client.homeserver;
  bool get current =>
      token != null &&
      client.accessToken == token &&
      client.userID == user &&
      client.homeserver == homeserver;
  _KeyboardRoom room(String id) => rooms.putIfAbsent(id, _KeyboardRoom.new);
}

class _KeyboardRoom {
  final ids = <String>{};
  final dirty = <String>{};
  bool restored = false;
  DateTime? lastAttempt;
  Future<void> _tail = Future.value();
  void merge(Map<String, dynamic>? content) {
    final values = content?['event_ids'];
    if (values is List) {
      for (final id in values.skip(
        values.length > BotInteractiveKeyboardState.maximumIds
            ? values.length - BotInteractiveKeyboardState.maximumIds
            : 0,
      )) {
        if (id is String && id.isNotEmpty && id.length <= 512) {
          ids.remove(id);
          ids.add(id);
        }
      }
    }
    // Незавершённая локальная запись важнее запоздалого account_data из sync.
    for (final id in dirty.toList()) {
      ids.remove(id);
      ids.add(id);
    }
    while (ids.length > BotInteractiveKeyboardState.maximumIds) {
      final removed = ids.first;
      ids.remove(removed);
      dirty.remove(removed);
    }
  }

  Future<T> serial<T>(Future<T> Function() action) {
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }
}
