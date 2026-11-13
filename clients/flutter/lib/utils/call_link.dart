import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// «Ссылка на созвон» чата — room state `io.element.call_link` (`{"url": …}`;
/// `{}` — ссылку сняли). Пишет только клиент (`ChatDetailsController`).
///
/// Локальный кеш (`room.getState`) этому state не авторитет: тип не в
/// `importantStateEvents`, поэтому в partial-комнате значение приходит только
/// через `postLoad()` из БД, а потерянная локально запись (откат сервера,
/// `clearCache`, пропущенный sync) не возвращалась НИКОГДА — трубка и секция
/// «Ссылка на созвон» исчезали при живом событии на сервере.
///
/// ⚠️ В `importantStateEvents` тип НЕ вносим: постфактум-промоушен делает уже
/// записанные значения нечитаемыми (`postLoad()` важные типы исключает), то
/// есть ломает то, что работает. Трубка живёт только в открытом чате, где
/// `postLoad()` уже отработал. Тот же класс, что
/// у `McpConnections.fetch`; повторная установка ссылки тут не лечила, потому
/// что Synapse дедуплицирует PUT с тем же содержимым (событие не рождается,
/// sync ничего не присылает).
class CallLink {
  CallLink._();

  static const eventType = 'io.element.call_link';

  /// Не чаще раза в [_ttl] на комнату, если не `force`: один GET на открытие чата.
  static const _ttl = Duration(minutes: 5);
  static final Map<String, DateTime> _checkedAt = {};

  @visibleForTesting
  static void resetChecksForTest() => _checkedAt.clear();

  static String? urlOf(Room room) {
    final url = room.getState(eventType)?.content['url'];
    return url is String && url.isNotEmpty ? url : null;
  }

  /// Сверяет локальное состояние с сервером. `true` — локальное изменилось и
  /// экрану нужна перерисовка. Сбой сети/таймаут — `false`, показанное не
  /// затирается.
  static Future<bool> sync(Room room, {bool force = false}) async {
    final last = _checkedAt[room.id];
    if (!force && last != null && DateTime.now().difference(last) < _ttl) {
      return false;
    }
    final Map<String, Object?> content;
    try {
      content = await room.client
          .getRoomStateWithKey(room.id, eventType, '')
          .timeout(const Duration(seconds: 15));
    } on MatrixException catch (e) {
      // Ответ сервера окончательный (напр. M_FORBIDDEN в превью/инвайте) —
      // до истечения TTL не переспрашиваем; сеть/таймаут ниже — повтор сразу.
      _checkedAt[room.id] = DateTime.now();
      if (e.errcode != 'M_NOT_FOUND') {
        Logs().w('CallLink: не удалось прочитать состояние', e);
        return false;
      }
      return _apply(room, const {});
    } catch (e, s) {
      Logs().w('CallLink: сбой запроса состояния', e, s);
      return false;
    }
    _checkedAt[room.id] = DateTime.now();
    return _apply(room, content);
  }

  static bool _apply(Room room, Map<String, Object?> content) {
    final newUrl = content['url'];
    final next = newUrl is String && newUrl.isNotEmpty ? newUrl : null;
    if (next == urlOf(room)) return false;
    Logs().w(
      'CallLink: локальное состояние расходилось с сервером '
      '(было ${urlOf(room) == null ? "пусто" : "ссылка"}, '
      'на сервере ${next == null ? "пусто" : "ссылка"}) — исправлено',
    );
    room.setState(
      StrippedStateEvent(
        type: eventType,
        content: next == null ? {} : {'url': next},
        stateKey: '',
        senderId: room.client.userID ?? '',
      ),
    );
    return true;
  }
}
