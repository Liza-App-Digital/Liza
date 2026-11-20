import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/confirmed_read_state.dart';

/// Проекция покрытия preview. UNKNOWN сохраняет прежний SDK fallback, но не
/// становится доказательством прочтения для ACK или мониторинга.
extension UnseenMessages on Room {
  List<String> get _ownReadEventIds {
    final receipts = receiptState.global;
    final ids = <String>{
      if (receipts.ownPrivate != null) receipts.ownPrivate!.eventId,
      if (receipts.ownPublic != null) receipts.ownPublic!.eventId,
    }..remove('');
    // Совместимость с сохранённым старым receipt-state без private/public.
    if (ids.isEmpty) {
      final legacy = receipts.latestOwnReceipt?.eventId;
      if (legacy != null && legacy.isNotEmpty) ids.add(legacy);
    }
    if (ids.isEmpty && fullyRead.isNotEmpty) ids.add(fullyRead);
    return ids.toList();
  }

  bool get hasUnseenMessages =>
      unseenWithOverlay(ConfirmedReadState.forClient(client));

  bool unseenWithOverlay(ConfirmedReadState? localRead) {
    if (localRead?.covers(this) == true) return false;
    final last = lastEvent;
    if (last?.isHiddenByNewsAudience == true) return false;
    if (localRead?.hasUnknownCoverage(this) == true && notificationCount > 0) {
      return true;
    }
    if (last == null || !client.roomPreviewLastEvents.contains(last.type)) {
      return false;
    }
    if (last.senderId == client.userID) return false;
    final own = _ownReadEventIds;
    if (own.isEmpty) return true;
    if (own.contains(last.eventId) || fullyRead == last.eventId) return false;
    return UnseenOrderCache.lookup(this) ?? hasNewMessages;
  }

  _OrderInput? get _orderInput {
    final last = lastEvent;
    if (last == null ||
        !client.roomPreviewLastEvents.contains(last.type) ||
        last.senderId == client.userID ||
        last.isHiddenByNewsAudience) {
      return null;
    }
    final own = _ownReadEventIds;
    if (own.isEmpty ||
        own.contains(last.eventId) ||
        fullyRead == last.eventId) {
      return null;
    }
    final receipts = receiptState.global;
    return (
      private: receipts.ownPrivate?.eventId,
      public: receipts.ownPublic?.eventId,
      privateTs: receipts.ownPrivate?.ts,
      publicTs: receipts.ownPublic?.ts,
      latestTs: receipts.latestOwnReceipt?.ts,
      legacy: receipts.ownPrivate == null && receipts.ownPublic == null
          ? receipts.latestOwnReceipt?.eventId
          : null,
      fully: fullyRead,
      preview: last.eventId,
      sender: last.senderId,
      type: last.type,
      timestamp: last.originServerTs.millisecondsSinceEpoch,
    );
  }
}

typedef _OrderInput = ({
  String? private,
  String? public,
  int? privateTs,
  int? publicTs,
  int? latestTs,
  String? legacy,
  String fully,
  String preview,
  String sender,
  String type,
  int timestamp,
});

/// Кэш не разделяется между Client/user/Room. UNKNOWN тоже кэшируется до
/// изменения tuple или завершённого изменения данных именно этой комнаты.
abstract final class UnseenOrderCache {
  static var _clients = Expando<_ClientOrder>();
  static final _queue = <_OrderRequest>[];
  static final _busyClients = <Client>{};
  static var _physicalReads = 0;
  static var _startsThisTurn = 0;
  static Timer? _nextTurn;
  static Completer<void>? _turnEnded;

  static _ClientOrder _scope(Client client) {
    final existing = _clients[client];
    if (existing != null && existing.user == client.userID && existing.active) {
      return existing;
    }
    if (existing != null) _retire(existing);
    return _clients[client] = _ClientOrder(client);
  }

  static _RoomOrder _room(Room room) {
    final scope = _scope(room.client);
    final existing = scope.rooms[room.id];
    if (existing != null && identical(existing.room, room)) return existing;
    return scope.rooms[room.id] = _RoomOrder(room);
  }

  static bool? lookup(Room room) {
    final scope = _clients[room.client];
    if (scope == null || !scope.active || scope.user != room.client.userID) {
      return null;
    }
    final state = scope.rooms[room.id];
    if (state == null || !identical(state.room, room)) return null;
    final entry = state.request;
    if (entry == null || !entry.current || !entry.settled) return null;
    return entry.unseen;
  }

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

  static bool? _coverage(List<String> ids, _OrderInput input) {
    final receipts = <String>{?input.private, ?input.public, ?input.legacy};
    if (receipts.isEmpty && input.fully.isNotEmpty) receipts.add(input.fully);
    var unknown = false;
    for (final receipt in receipts) {
      final unseen = decide(
        eventIdsNewestFirst: ids,
        receiptEventId: receipt,
        lastEventId: input.preview,
      );
      if (unseen == false) return false;
      if (unseen == null) unknown = true;
    }
    return unknown || receipts.isEmpty ? null : true;
  }

  static Future<void> reconcileRoom(Room room) {
    final scope = _scope(room.client);
    final state = _room(room);
    final input = room._orderInput;
    if (input == null) {
      _publish(state);
      return Future.value();
    }
    final previous = state.request;
    if (previous != null && previous.current) {
      if (room.notificationCount > 0 &&
          previous.countZero &&
          !previous.settled) {
        _pump();
        return Future.value();
      }
      return previous.waiting;
    }
    // Замена queued tuple не накапливает старые задания.
    _queue.removeWhere((r) {
      if (!identical(r.state, state)) return false;
      r.finish();
      return true;
    });
    final request = _OrderRequest(scope, state, input);
    state.request = request;
    if (room.notificationCount > 0 && state.physical == null) {
      // Критический badge path не ждёт дополнительной count0 очереди.
      unawaited(_read(request));
    } else {
      _queue.add(request);
      if (room.notificationCount > 0) request.finish();
      _pump();
    }
    return request.waiting;
  }

  /// Числовой badge ожидает только свои положительные комнаты. Нулевые
  /// гидратируются независимо и после результата обновляют смонтированные UI.
  static Future<void> reconcile(Client client) async {
    final positive = <Future<void>>[];
    for (final room in client.rooms.toList()) {
      final future = reconcileRoom(room);
      if (room.notificationCount > 0) positive.add(future);
    }
    await Future.wait(positive);
  }

  static void _pump() {
    // Новое поколение положительной комнаты не ждёт старый count0 read в
    // badge await, но физически повторяется только после завершения старого.
    for (final request in _queue.toList()) {
      if (request.countZero ||
          request.state.room.notificationCount <= 0 ||
          request.state.physical != null) {
        continue;
      }
      _queue.remove(request);
      if (request.current) {
        unawaited(_read(request));
      } else {
        request.finish();
      }
    }
    while (_physicalReads < 2 && _startsThisTurn < 8) {
      final index = _queue.indexWhere(
        (r) =>
            !_busyClients.contains(r.scope.client) && r.state.physical == null,
      );
      if (index < 0) return;
      final request = _queue.removeAt(index);
      if (!request.current) {
        request.finish();
        continue;
      }
      // Round-robin: оставшиеся комнаты этого клиента уступают другим.
      final sameClient = _queue
          .where((r) => identical(r.scope.client, request.scope.client))
          .toList();
      _queue.removeWhere(
        (r) => identical(r.scope.client, request.scope.client),
      );
      _queue.addAll(sameClient);
      // Режим можно только ужесточить до запуска: queued positive к этому
      // моменту могла стать count0. Её снимок тоже требует transaction/budget.
      request.countZero = true;
      _physicalReads++;
      _busyClients.add(request.scope.client);
      unawaited(
        _read(request).whenComplete(() {
          _physicalReads--;
          _busyClients.remove(request.scope.client);
          _pump();
        }),
      );
    }
  }

  static Future<void> _reserveReadStart() async {
    while (_startsThisTurn >= 8) {
      await _turnEnded!.future;
    }
    _startsThisTurn++;
    if (_nextTurn != null) return;
    _turnEnded = Completer<void>();
    // Квант считается у фактического DB read, после ожидания transaction.
    _nextTurn = Timer(Duration.zero, () {
      _nextTurn = null;
      _startsThisTurn = 0;
      final turn = _turnEnded;
      _turnEnded = null;
      turn?.complete();
      _pump();
    });
  }

  static Future<void> _read(_OrderRequest request) async {
    request.state.physical = request;
    // timeout завершает ожидание вызывающего, но НЕ этот physical Future.
    final timer = Timer(const Duration(seconds: 2), () {
      request.expired = true;
      request.settled = true;
      if (request.current) _publish(request.state);
      request.finish();
    });
    try {
      final database = request.scope.client.database;
      List<String>? ids;
      if (request.countZero) {
        // Внешние callers (AppBadge/onSync/openChat) тоже могут оказаться до
        // commit. Сам снимок читается под внешним SDK transaction lock, чтобы
        // следующая history transaction не успела подменить quick cache.
        await database.transaction(() async {
          if (!request.current || request.expired) return;
          await _reserveReadStart();
          if (!request.current || request.expired) return;
          ids = await database.getEventIdList(request.state.room);
        });
      } else {
        ids = await database.getEventIdList(request.state.room);
      }
      if (ids == null) return;
      if (request.current && !request.expired) {
        request.unseen = _coverage(ids!, request.input);
        request.settled = true;
        _publish(request.state);
      }
    } catch (error) {
      // Ошибка — negative cache, без самоповторения и без доказательства read.
      if (request.current) {
        request.settled = true;
        _publish(request.state);
      }
      Logs().w('UnseenOrderCache: ошибка чтения порядка', error);
    } finally {
      timer.cancel();
      request.state.physical = null;
      request.finish();
      scheduleMicrotask(_pump);
    }
  }

  /// Только после реального изменения/commit данных, не из build/таймера.
  static void committedRooms(Client client, Iterable<String> roomIds) {
    final scope = _scope(client);
    for (final id in roomIds.toSet()) {
      final room = client.getRoomById(id);
      if (room == null) {
        scope.rooms.remove(id);
        continue;
      }
      final state = _room(room);
      state.generation++;
      state.notifications = room.notificationCount;
      state.highlights = room.highlightCount;
      unawaited(reconcileRoom(room));
    }
    _queue.removeWhere((r) {
      if (r.current) return false;
      r.finish();
      return true;
    });
  }

  static void _publish(_RoomOrder state) {
    final unseen = state.room.hasUnseenMessages;
    if (state.published != unseen) {
      state.published = unseen;
      ConfirmedReadState.forClient(state.room.client).invalidateProjection();
    }
  }

  static void _retire(_ClientOrder scope) {
    scope.active = false;
    _queue.removeWhere((r) {
      if (!identical(r.scope, scope)) return false;
      r.finish();
      return true;
    });
    for (final state in scope.rooms.values) {
      state.request?.finish();
    }
    scope.rooms.clear();
  }

  static void detach(Client client) {
    final scope = _clients[client];
    if (scope != null) _retire(scope);
  }

  @visibleForTesting
  static void reset() {
    _nextTurn?.cancel();
    _nextTurn = null;
    _startsThisTurn = 0;
    _turnEnded?.complete();
    _turnEnded = null;
    for (final request in _queue) {
      request.scope.active = false;
      request.finish();
    }
    _queue.clear();
    _clients = Expando<_ClientOrder>();
    // Физические reads не отменяем и не освобождаем их слоты даже в reset.
  }
}

class _ClientOrder {
  final Client client;
  final String? user;
  final rooms = <String, _RoomOrder>{};
  bool active = true;
  _ClientOrder(this.client) : user = client.userID;
}

class _RoomOrder {
  final Room room;
  int generation = 0;
  _OrderRequest? request;
  _OrderRequest? physical;
  bool published;
  int notifications;
  int highlights;
  _RoomOrder(this.room)
    : published = room.hasUnseenMessages,
      notifications = room.notificationCount,
      highlights = room.highlightCount;
}

class _OrderRequest {
  final _ClientOrder scope;
  final _RoomOrder state;
  final _OrderInput input;
  final int generation;
  final bool registered;
  bool countZero;
  final done = Completer<void>();
  late final Future<void> waiting;
  bool settled = false;
  bool expired = false;
  bool? unseen;
  _OrderRequest(this.scope, this.state, this.input)
    : generation = state.generation,
      countZero = state.room.notificationCount <= 0,
      registered = identical(
        scope.client.getRoomById(state.room.id),
        state.room,
      ) {
    // Ожидание очереди тоже ограничено; физические слоты не освобождаются.
    waiting = done.future.timeout(const Duration(seconds: 2), onTimeout: () {});
  }

  bool get current =>
      scope.active &&
      scope.user == scope.client.userID &&
      (!registered ||
          identical(scope.client.getRoomById(state.room.id), state.room)) &&
      identical(UnseenOrderCache._clients[scope.client], scope) &&
      identical(scope.rooms[state.room.id], state) &&
      identical(state.request, this) &&
      state.generation == generation &&
      state.room._orderInput == input;

  void finish() {
    if (!done.isCompleted) done.complete();
  }
}

/// Владелец — Matrix per-client lifecycle, независимо от платформы/мониторинга.
/// Live refresh требует реального finished; history/decryption ждут DB barrier.
class UnseenProjectionSubscription {
  static final _bound = Expando<UnseenProjectionSubscription>();

  /// Timeline.onUpdate также сигнализирует расшифровку по session key, которую
  /// SDK сохраняет напрямую, без onSync/onEvent. Callback не является commit.
  static void timelineUpdated(Room room) {
    final owner = _bound[room.client];
    if (owner == null || owner._disposed) return;
    unawaited(owner._afterLocalUpdate([room.id]));
  }

  final Client client;
  final _subscriptions = <StreamSubscription>[];
  final _dirty = <String>{};
  final _localDirty = <String>{};
  bool _disposed = false;
  bool _waiting = false;
  bool _processing = false;
  bool _clean = false;
  bool _localBarrier = false;
  String? _token;

  UnseenProjectionSubscription(this.client) {
    _bound[client]?.dispose();
    _bound[client] = this;
    _subscriptions.add(client.onSync.stream.listen(_wire));
    _subscriptions.add(client.onSyncStatus.stream.listen(_status));
    // SDK не имеет отдельного публичного after-decryption stream.
    _subscriptions.add(
      // ignore: deprecated_member_use
      client.onEvent.stream.listen((event) {
        if (event.type == EventUpdateType.decryptedTimelineQueue) {
          _afterLocalUpdate([event.roomID]);
        }
      }),
    );
    _subscriptions.add(
      client.onLoginStateChanged.stream.listen((_) {
        UnseenOrderCache.detach(client);
        if (client.isLogged()) _initial();
      }),
    );
    _initial();
  }

  /// Начальная гидратация стартует DB-транзакции сразу после login. В
  /// виджет-тестах они идут в FakeAsync-зоне и не завершаются к моменту
  /// `client.dispose(closeDatabase: true)`, закрытие БД ждёт их вечно.
  /// `test/flutter_test_config.dart` выключает её; тесты самой проекции
  /// включают обратно.
  @visibleForTesting
  static bool initialHydration = true;

  Future<void> _initial() async {
    if (!initialHydration) return;
    await client.roomsLoading;
    if (_disposed) return;
    // Подписка может подключиться посреди начального sync.
    await _afterLocalUpdate(client.rooms.map((r) => r.id));
  }

  void _wire(SyncUpdate update) {
    final ids = <String>{
      ...?update.rooms?.join?.keys,
      ...?update.rooms?.leave?.keys,
    };
    if (update.nextBatch.isEmpty) {
      unawaited(_afterLocalUpdate(ids));
      return;
    }
    if (!_processing) return;
    if (_token != null) {
      _processing = false;
      _dirty.clear();
      return;
    }
    _token = update.nextBatch;
    _dirty.addAll(update.rooms?.leave?.keys ?? const <String>[]);
    for (final entry
        in (update.rooms?.join ?? <String, JoinedRoomUpdate>{}).entries) {
      final room = client.getRoomById(entry.key);
      if (room == null) continue;
      final state = UnseenOrderCache._scope(client).rooms[room.id];
      final update = entry.value;
      if (state == null ||
          !identical(state.room, room) ||
          state.request?.input != room._orderInput ||
          state.notifications != room.notificationCount ||
          state.highlights != room.highlightCount ||
          update.timeline?.limited == true ||
          update.timeline?.events?.isNotEmpty == true ||
          update.state?.isNotEmpty == true) {
        _dirty.add(room.id);
      }
    }
  }

  void _status(SyncStatusUpdate update) {
    switch (update.status) {
      case SyncStatus.waitingForResponse:
        _waiting = true;
        _processing = _clean = false;
        _token = null;
        _dirty.clear();
      case SyncStatus.processing:
        if (_waiting && update.progress == null) _processing = true;
      case SyncStatus.cleaningUp:
        _clean = _processing && _token != null && _token == client.prevBatch;
        _processing = false;
      case SyncStatus.finished:
        final committed = _clean && _token == client.prevBatch
            ? _dirty.toSet()
            : <String>{};
        _waiting = _processing = _clean = false;
        _token = null;
        _dirty.clear();
        // Между live commit и finished могла начаться отдельная transaction
        // истории той же комнаты. Её quick cache ещё не является commit.
        if (committed.isNotEmpty || _localDirty.isNotEmpty) {
          unawaited(_afterLocalUpdate(committed));
        }
      case SyncStatus.error:
        _waiting = _processing = _clean = false;
        _token = null;
        _dirty.clear();
        if (_localDirty.isNotEmpty) unawaited(_afterLocalUpdate(const []));
    }
  }

  Future<void> _afterLocalUpdate(Iterable<String> ids) async {
    _localDirty.addAll(ids);
    if (_localBarrier || _disposed || _processing || _clean) return;
    _localBarrier = true;
    try {
      // Listener исполняется в зоне регистрации Matrix, вне SDK transaction.
      // ZoneTransactionMixin сериализует её ПОСЛЕ текущего physical commit
      // как для SQLite, так и IndexedDB. Microtask/yield такого не гарантирует.
      await client.database.transaction(() async {});
      if (!_disposed && !_processing && !_clean) {
        final rooms = _localDirty.toList();
        _localDirty.clear();
        UnseenOrderCache.committedRooms(client, rooms);
      }
    } catch (error) {
      Logs().w('UnseenOrderCache: ошибка барьера БД', error);
    } finally {
      _localBarrier = false;
    }
  }

  void dispose() {
    if (identical(_bound[client], this)) _bound[client] = null;
    _disposed = true;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _localDirty.clear();
    _dirty.clear();
    UnseenOrderCache.detach(client);
  }
}
