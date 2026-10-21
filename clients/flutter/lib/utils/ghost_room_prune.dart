import 'dart:async';
import 'dart:math';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/ghost_rooms.dart';
import 'package:liza/utils/monitoring.dart';

const _joinedRoomsTimeout = Duration(seconds: 15);
const _probeTimeout = Duration(seconds: 8);

/// Раз за сессию убирает из локального кэша комнаты, которых не знает сервер
/// (логика отбора и лимиты — `ghost_rooms.dart`). [seenInSync] — id комнат,
/// пришедших в sync за эту сессию: их сервер точно знает. [onRemoved] — для
/// ухода с экрана удалённого чата. Сервер не трогаем: ни `/leave`, ни `/forget`.
///
/// Найденный призрак доказывает, что клиент синкался в потерянном окне отката:
/// его since-токен был впереди сервера, и события сразу после восстановления
/// (в т.ч. приглашения) он не получил никогда — Synapse ждёт, пока поток
/// догонит токен, и продолжает С НЕГО. Поэтому вместо точечного удаления —
/// однократный полный ресинк ([Client.clearCache]): призраки уйдут сами, а
/// пропущенное придёт. Ключи E2EE он не трогает, но стирает неотправленные
/// события — при них ресинк откладываем ([hasUnsentEvents]) и удаляем точечно.
/// [onResync] — уйти с экрана чата: его `Room` после сброса недействителен.
Future<void> pruneGhostRooms(
  Client client, {
  required Set<String> seenInSync,
  void Function(String roomId)? onRemoved,
  void Function()? onResync,
  Future<bool> Function(Client client) hasUnsentEvents = clientHasUnsentEvents,
  Duration? jitter,
}) async {
  // Холодный кэш get_rooms_for_user после рестарта Synapse — не бить в него
  // всеми клиентами разом.
  await Future.delayed(jitter ?? Duration(seconds: Random().nextInt(31)));
  if (!client.isLogged() || client.prevBatch == null) return;

  final Set<String> serverJoined;
  try {
    serverJoined = (await client.getJoinedRooms().timeout(
      _joinedRoomsTimeout,
    )).toSet();
  } catch (e) {
    Logs().w('[ghost-room] joined_rooms недоступен, пропуск', e);
    return;
  }

  // Снимок ПОСЛЕ ответа: комната, в которую вступили во время запроса, иначе
  // выглядела бы отсутствующей на сервере.
  final localJoined = [
    for (final room in client.rooms)
      if (room.membership == Membership.join)
        GhostRoomSnapshot(
          id: room.id,
          isSpace: room.isSpace,
          lastEventAt: room.lastEvent?.originServerTs,
        ),
  ];
  final candidates = ghostCandidates(
    localJoined: localJoined,
    serverJoined: serverJoined,
    seenInSync: seenInSync,
    now: DateTime.now(),
  );
  if (candidates.isEmpty) return;
  if (candidates.length > ghostMaxProbes) {
    Monitoring.reportGhostRooms(
      candidates: candidates.length,
      probed: 0,
      removed: 0,
      aborted: true,
    );
    return;
  }

  final probes = <String, GhostProbe>{};
  for (final roomId in candidates) {
    probes[roomId] = await _probe(client, roomId);
  }
  final decision = decideGhostRemoval(
    probes: probes,
    localJoinedCount: localJoined.length,
  );

  final remove = [
    // Комната могла прийти в sync, пока шли пробники.
    for (final roomId in decision.remove)
      if (!seenInSync.contains(roomId)) roomId,
  ];
  if (remove.isNotEmpty && !await hasUnsentEvents(client)) {
    Logs().i('[ghost-room] призраков=${remove.length} → полный ресинк');
    onResync?.call();
    try {
      await client.clearCache();
    } catch (e, s) {
      // clearCache останавливает sync в начале и запускает в конце — при сбое
      // посередине клиент остался бы без синхронизации до перезапуска.
      client.backgroundSync = true;
      Logs().w('[ghost-room] сбой ресинка', e, s);
      return;
    }
    Monitoring.reportGhostRooms(
      candidates: candidates.length,
      probed: probes.length,
      removed: remove.length,
      aborted: false,
      resynced: true,
    );
    return;
  }

  var removed = 0;
  for (final roomId in remove) {
    await client.database.transaction(
      () => client.handleSync(
        SyncUpdate(
          nextBatch: '',
          rooms: RoomsUpdate(leave: {roomId: LeftRoomUpdate()}),
        ),
      ),
    );
    // handleSync кладёт ушедшую комнату в архив в памяти — призраку и там не место.
    client.archivedRooms.removeWhere((a) => a.room.id == roomId);
    removed++;
    onRemoved?.call(roomId);
  }
  Logs().i(
    '[ghost-room] кандидатов=${candidates.length} удалено=$removed '
    'aborted=${decision.aborted}',
  );
  Monitoring.reportGhostRooms(
    candidates: candidates.length,
    probed: probes.length,
    removed: removed,
    aborted: decision.aborted,
  );
}

/// Неотправленное (в полёте или упавшее) [Client.clearCache] стёр бы вместе с
/// кэшем — пользователь потерял бы сообщение, которое ещё может переотправить.
/// SDK держит такие события в отдельном фрагменте SENDING (`onlySending`),
/// поэтому смотрим его, а не `lastEvent`: после упавшего могло прийти чужое.
Future<bool> clientHasUnsentEvents(Client client) async {
  for (final room in client.rooms) {
    if (room.sendingFilePlaceholders.isNotEmpty) return true;
    final pending = await client.database.getEventList(room, onlySending: true);
    if (pending.isNotEmpty) return true;
  }
  return false;
}

Future<GhostProbe> _probe(Client client, String roomId) async {
  try {
    await client
        .getRoomStateWithKey(roomId, EventTypes.RoomCreate, '')
        .timeout(_probeTimeout);
    return classifyGhostProbe(ok: true);
  } on MatrixException catch (e) {
    // Не e.errcode: тот подставляет M_UNKNOWN, когда errcode в теле нет.
    final errcode = e.raw['errcode'];
    return classifyGhostProbe(
      ok: false,
      errcode: errcode is String ? errcode : null,
    );
  } catch (_) {
    return GhostProbe.unknown;
  }
}
