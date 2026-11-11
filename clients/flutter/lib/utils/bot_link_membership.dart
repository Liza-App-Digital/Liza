import 'dart:async';

import 'package:matrix/matrix.dart';

/// Lazy membership в существующем DM может навсегда отсутствовать в room.states.
/// Команду запуска разрешает свежий ответ homeserver, а не локальный кэш.
Future<bool> waitForBotLinkMembership(
  Client client,
  String roomId,
  String botMxid, {
  required bool Function() isCurrent,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final elapsed = Stopwatch()..start();
  while (isCurrent()) {
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) return false;
    final budget = remaining < const Duration(seconds: 4)
        ? remaining
        : const Duration(seconds: 4);
    try {
      final state = await client
          .getRoomStateWithKey(roomId, EventTypes.RoomMember, botMxid)
          .timeout(budget);
      if (!isCurrent()) return false;
      if (state['membership'] == 'join') return true;
      if (state['membership'] != 'invite') return false;
    } on MatrixException catch (error) {
      if (!isCurrent() || error.errcode != 'M_NOT_FOUND') return false;
    } on TimeoutException {
      // Таймер усекает Duration до целых миллисекунд и срабатывает раньше
      // Stopwatch: без этой проверки последний срез бюджета порождал второй
      // GET с остатком <1 мс.
      if (budget == remaining) return false;
      // Медленная сеть: пробуем снова, пока не вышел общий бюджет.
    }
    final pause = timeout - elapsed.elapsed;
    if (pause <= Duration.zero || !isCurrent()) return false;
    await Future<void>.delayed(
      pause < const Duration(milliseconds: 300)
          ? pause
          : const Duration(milliseconds: 300),
    );
  }
  return false;
}
