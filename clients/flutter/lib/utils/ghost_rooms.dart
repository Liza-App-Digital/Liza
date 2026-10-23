/// Комнаты-«призраки»: локальный кэш SDK считает нас участником, а сервер
/// комнату не знает. Так бывает после отката сервера к снимку (пожар в ДЦ
/// 05–08.10.2026: комнаты, созданные в потерянном окне, остались у клиентов) —
/// sync такую комнату больше никогда не пришлёт, и её метка непрочитанного
/// висит вечно (заявка №55). Спека —
/// `docs/superpowers/specs/2026-10-20-ghost-room-local-prune-design.md`.
///
/// Здесь только решение, без SDK: удаление ЖИВОЙ комнаты хуже призрака (sync
/// вернёт её лишь дельтой, без истории), поэтому каждое условие отбора
/// покрыто host-тестом `test/ghost_rooms_test.dart`.
library;

/// Локальная join-комната глазами отбора.
class GhostRoomSnapshot {
  final String id;
  final bool isSpace;
  final DateTime? lastEventAt;

  const GhostRoomSnapshot({
    required this.id,
    required this.isSpace,
    required this.lastEventAt,
  });
}

/// Ответ пробника `GET /rooms/{id}/state/m.room.member/{me}`.
///
/// Спрашиваем своё членство, а не `m.room.create`: бывшему участнику сервер
/// отдаёт state комнаты на момент ухода с 200. Так у Надежды (21.10) остался
/// чат, из которого она вышла 10.10 в окне, пропущенном клиентом после отката.
enum GhostProbe {
  /// Наше членство на сервере — `join` (лаг кэша `/joined_rooms`).
  alive,

  /// Членство не `join` либо Matrix-ошибка из [ghostProbeGoneErrcodes] —
  /// сервер не считает нас участником, sync эту комнату не пришлёт.
  gone,

  /// Сеть, таймаут, 429, 5xx, ответ без `errcode` — судить нельзя.
  unknown,
}

/// Призрак на проде отвечает `403 M_FORBIDDEN … not in room`. `M_UNKNOWN` сюда
/// не входит: это errcode общих сбоев Synapse, по нему живую комнату не судим.
const ghostProbeGoneErrcodes = {'M_FORBIDDEN', 'M_NOT_FOUND'};

/// Свежая активность может не успеть попасть в кэш `get_rooms_for_user`.
const ghostMinAge = Duration(minutes: 10);

/// Больше кандидатов — это уже не остатки отката, а сбой ответа сервера.
const ghostMaxProbes = 20;
const ghostMaxRemovals = 5;

GhostProbe classifyGhostProbe({
  required bool ok,
  String? membership,
  String? errcode,
}) {
  if (ok) {
    if (membership == null) return GhostProbe.unknown;
    return membership == 'join' ? GhostProbe.alive : GhostProbe.gone;
  }
  if (errcode != null && ghostProbeGoneErrcodes.contains(errcode)) {
    return GhostProbe.gone;
  }
  return GhostProbe.unknown;
}

/// Кандидаты на пробник. Пусто, если [serverJoined] неизвестен (запрос упал).
List<String> ghostCandidates({
  required List<GhostRoomSnapshot> localJoined,
  required Set<String>? serverJoined,
  required Set<String> seenInSync,
  required DateTime now,
}) {
  if (serverJoined == null) return const [];
  return [
    for (final room in localJoined)
      if (!room.isSpace &&
          !serverJoined.contains(room.id) &&
          !seenInSync.contains(room.id) &&
          room.lastEventAt != null &&
          now.difference(room.lastEventAt!) >= ghostMinAge)
        room.id,
  ];
}

class GhostRemovalDecision {
  final List<String> remove;
  final bool aborted;

  const GhostRemovalDecision({required this.remove, required this.aborted});
}

/// Итог по ответам пробника. Предохранитель срабатывает целиком: при
/// превышении лимита не удаляем ничего.
GhostRemovalDecision decideGhostRemoval({
  required Map<String, GhostProbe> probes,
  required int localJoinedCount,
}) {
  final gone = [
    for (final entry in probes.entries)
      if (entry.value == GhostProbe.gone) entry.key,
  ];
  final shareCap = (localJoinedCount * 0.2).floor();
  final cap = shareCap < 1 ? 1 : shareCap;
  if (gone.length > ghostMaxRemovals || gone.length > cap) {
    return const GhostRemovalDecision(remove: [], aborted: true);
  }
  return GhostRemovalDecision(remove: gone, aborted: false);
}
