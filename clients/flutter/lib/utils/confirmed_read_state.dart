import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Локальное подтверждение относится к снимку комнаты, а не навсегда к preview.
/// SDK Room.setReadMarker не обновляет receipt-state и не сообщает UI об ACK.
class ConfirmedReadState {
  static final _clients = Expando<ConfirmedReadState>();

  /// Для диагностики: не создаёт слушатель и не модифицирует модель комнаты.
  static ConfirmedReadState? existing(Client client) {
    final state = _clients[client];
    return state?._userId == client.userID ? state : null;
  }

  static ConfirmedReadState forClient(Client client) {
    final state = _clients[client] ??= ConfirmedReadState._(client);
    state._checkAccount(client);
    return state;
  }

  final revision = ValueNotifier<int>(0);
  final Map<String, _RoomReadState> _rooms = {};
  String? _userId;

  void _checkAccount(Client client) {
    if (_userId == client.userID) return;
    _userId = client.userID;
    _rooms.clear();
  }

  ConfirmedReadState._(Client client) {
    _userId = client.userID;
    client.onTimelineEvent.stream.listen((event) {
      _checkAccount(client);
      if (!event.status.isSynced) return;
      _rooms.putIfAbsent(event.room.id, _RoomReadState.new).pendingLiveTail =
          event.eventId;
    });
    client.onSync.stream.listen((sync) {
      _checkAccount(client);
      // SDK использует handleSync(nextBatch: '') также для history/context.
      // Последнее событие такой страницы — не живой хвост комнаты.
      if (sync.nextBatch.isEmpty) {
        for (final id in sync.rooms?.join?.keys ?? <String>[]) {
          _rooms[id]?.pendingLiveTail = null;
          _rooms[id]?.anticipatedTail = null;
        }
        return;
      }
      var changed = false;
      for (final entry
          in (sync.rooms?.join ?? <String, JoinedRoomUpdate>{}).entries) {
        final state = _rooms.putIfAbsent(entry.key, _RoomReadState.new);
        final update = entry.value;
        final events = update.timeline?.events;
        final raw = events?.isNotEmpty == true ? events!.last.eventId : null;
        final positive =
            (update.unreadNotifications?.notificationCount ?? 0) > 0 ||
            (update.unreadNotifications?.highlightCount ?? 0) > 0;
        final gap = update.timeline?.limited == true;
        final anticipated =
            raw != null &&
            raw == state.anticipatedTail &&
            raw == state.pendingLiveTail;
        state.anticipatedTail = null;
        state.pendingLiveTail = null;
        if (gap ||
            (raw != null && raw != state.rawTail) ||
            (positive && !anticipated)) {
          state.generation++;
          state.confirmed = null;
          // Счётчик без событий не доказывает, что известный хвост полный.
          // Даже успешная повторная отправка прежнего ID этого не исправит.
          if (gap) state.gap = true;
          if (gap || (positive && (raw == null || raw == state.rawTail))) {
            state.unknown = true;
          }
          if (raw != null &&
              raw != client.getRoomById(entry.key)?.lastEvent?.eventId) {
            state.unknown = true;
          }
          if (raw != null) state.rawTail = raw;
          // HTTP ACK мог успеть обнулить Room, пока SDK ещё писал sync в БД.
          // Если новое поколение не покрыто, возвращаем authoritative counts
          // этого sync; иначе неизвестное unread уже потеряно до onSync.
          if (positive) {
            final room = client.getRoomById(entry.key);
            if (room != null) {
              final counts = update.unreadNotifications!;
              if (counts.notificationCount != null) {
                room.notificationCount = counts.notificationCount!;
              }
              if (counts.highlightCount != null) {
                room.highlightCount = counts.highlightCount!;
              }
            }
          }
          changed = true;
        }
        if (update.unreadNotifications?.notificationCount == 0 &&
            (update.unreadNotifications?.highlightCount ?? 0) == 0) {
          state.unknown = false;
          state.gap = false;
        }
      }
      for (final id in sync.rooms?.leave?.keys ?? <String>[]) {
        changed = _rooms.remove(id) != null || changed;
      }
      if (changed) revision.value++;
    });
  }

  ReadCoverageSnapshot capture(
    Room room, {
    required String targetEventId,
    required String? rawTailEventId,
    required String? scope,
    required bool hasGap,
  }) {
    final state = _rooms.putIfAbsent(room.id, _RoomReadState.new);
    if (state.rawTail != rawTailEventId) {
      // SDK сначала сообщает Timeline.onUpdate и лишь после записи БД шлёт
      // onSync. Уже наблюдаемый новый хвост начинает то же поколение здесь;
      // onSync с этим exact raw завершит его. Count-only/limited всё равно
      // создают новое поколение и не могут воспользоваться этим совпадением.
      state.generation++;
      state.confirmed = null;
      state.anticipatedTail = state.pendingLiveTail == rawTailEventId
          ? rawTailEventId
          : null;
      state.rawTail = rawTailEventId;
      if (rawTailEventId != room.lastEvent?.eventId) state.unknown = true;
    }
    return ReadCoverageSnapshot._(
      room: room,
      userId: room.client.userID,
      generation: state.generation,
      targetEventId: targetEventId,
      rawTailEventId: rawTailEventId,
      previewEventId: room.lastEvent?.eventId,
      scope: scope,
      notificationCount: room.notificationCount,
      highlightCount: room.highlightCount,
      known:
          !hasGap &&
          (!state.unknown || state.provenGeneration == state.generation) &&
          state.rawTail == rawTailEventId &&
          rawTailEventId == room.lastEvent?.eventId,
    );
  }

  int? generationOf(Room room) => _rooms[room.id]?.generation;

  bool hasUnknownCoverage(Room room) => _rooms[room.id]?.unknown ?? false;

  /// Один read-only запрос даёт доказательство хвоста для count-only sync.
  /// Результат не обновляет SDK timeline и не является synthetic sync.
  Future<bool> reconcile(Room room, ReadCoverageSnapshot snapshot) async {
    if (_rooms[room.id]?.gap == true ||
        snapshot.scope != null ||
        snapshot.targetEventId != snapshot.rawTailEventId ||
        snapshot.rawTailEventId != snapshot.previewEventId) {
      return false;
    }
    final response = await room.client
        .getRoomEvents(room.id, Direction.b, limit: 1)
        .timeout(const Duration(seconds: 10));
    final state = _rooms[room.id];
    if (state == null ||
        room.client.userID != snapshot.userId ||
        state.generation != snapshot.generation ||
        state.rawTail != snapshot.rawTailEventId ||
        room.lastEvent?.eventId != snapshot.previewEventId ||
        response.chunk.firstOrNull?.eventId != snapshot.targetEventId) {
      return false;
    }
    // Доказательство ещё не ACK: UI сохраняет unknown до confirm.
    state.provenGeneration = state.generation;
    return true;
  }

  bool covers(Room room) {
    final state = _rooms[room.id];
    final confirmed = state?.confirmed;
    return confirmed != null &&
        identical(confirmed.room, room) &&
        confirmed.userId == room.client.userID &&
        state!.generation == confirmed.generation &&
        state.rawTail == confirmed.rawTailEventId &&
        room.lastEvent?.eventId == confirmed.previewEventId &&
        room.notificationCount == 0 &&
        room.highlightCount == 0 &&
        room.membership == Membership.join;
  }

  /// true только если ACK покрыл всё актуальное состояние основной ленты.
  bool confirm(Room room, ReadCoverageSnapshot snapshot) {
    final state = _rooms[room.id];
    if (!snapshot.known ||
        snapshot.scope != null ||
        !identical(snapshot.room, room) ||
        snapshot.userId != room.client.userID ||
        room.membership != Membership.join ||
        state == null ||
        (state.unknown && state.provenGeneration != state.generation) ||
        state.generation != snapshot.generation ||
        state.rawTail != snapshot.rawTailEventId ||
        snapshot.targetEventId != snapshot.rawTailEventId ||
        room.lastEvent?.eventId != snapshot.previewEventId ||
        room.notificationCount != snapshot.notificationCount ||
        room.highlightCount != snapshot.highlightCount) {
      return false;
    }
    room.notificationCount = 0;
    room.highlightCount = 0;
    state.unknown = false;
    state.confirmed = snapshot;
    revision.value++;
    return true;
  }
}

class ReadCoverageSnapshot {
  final Room room;
  final String? userId;
  final int generation;
  final String targetEventId;
  final String? rawTailEventId;
  final String? previewEventId;
  final String? scope;
  final int notificationCount;
  final int highlightCount;
  final bool known;

  ReadCoverageSnapshot._({
    required this.room,
    required this.userId,
    required this.generation,
    required this.targetEventId,
    required this.rawTailEventId,
    required this.previewEventId,
    required this.scope,
    required this.notificationCount,
    required this.highlightCount,
    required this.known,
  });
}

class _RoomReadState {
  int generation = 0;
  String? rawTail;
  String? anticipatedTail;
  String? pendingLiveTail;
  bool unknown = false;
  bool gap = false;
  int? provenGeneration;
  ReadCoverageSnapshot? confirmed;
}
