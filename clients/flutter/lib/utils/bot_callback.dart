import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:collection/collection.dart';
import 'package:matrix/matrix.dart';

/// Нажатие кнопки бота (Liza Bot API → `callback_query`).
///
/// Отдельный ТИП события, а не `m.room.message`: старые сборки скрывают
/// неизвестные типы (а кастомный msgtype нарисовали бы текстом body), push-правила
/// и счётчики непрочитанного его не трогают, в `roomPreviewLastEvents` его нет —
/// превью списка чатов не меняется. Контракт с сервером —
/// `servers/liza-bot-api/matrix/integration.py` (`CALLBACK_EVENT_TYPE`).
const botCallbackEventType = 'com.liza.bot.callback';

/// Ответ бота на нажатие (`answerCallbackQuery`): to-device событие от
/// бот-пользователя только тому, кто нажал, — в ленту чата ничего не попадает.
const botCallbackAnswerEventType = 'com.liza.bot.callback_answer';

/// Содержимое события нажатия: номер кнопки и событие, чью кнопку нажали
/// (для отредактированного сообщения — display-событие правки, сервер это знает).
/// `callback_data` клиент не отправляет — сервер берёт его из своей БД.
/// [tapId] — по нему сервер адресует ответ бота именно этому нажатию.
Map<String, dynamic> botCallbackContent({
  required String index,
  required String eventId,
  String? tapId,
}) => {
  'index': index,
  'm.relates_to': {'rel_type': botCallbackEventType, 'event_id': eventId},
  'tap_id': ?tapId,
};

/// Случайный id нажатия: 16 байт в hex.
String newBotTapId() {
  final rnd = Random.secure();
  return List.generate(
    16,
    (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

/// Отправка нажатия напрямую `PUT /send`, минуя очередь отправки комнаты:
/// `room.sendEvent` ждёт, пока уйдут события, поставленные раньше (заливка
/// видео задержала бы тап на минуты), и в matrix 4.1.0 на ошибке возвращает
/// `null` вместо исключения. Здесь любой сбой — `false`, кнопку не отмечаем.
///
/// Событие уходит открытым и в шифрованной комнате: сервер Bot API E2EE не
/// расшифровывает, а боты живут в нешифрованных DM.
Future<bool> sendBotCallbackTap(
  Room room, {
  required String index,
  required String eventId,
  required String tapId,
  Duration timeout = const Duration(seconds: 10),
}) async {
  try {
    final id = await room.client
        .sendMessage(
          room.id,
          botCallbackEventType,
          room.client.generateUniqueTransactionId(),
          botCallbackContent(index: index, eventId: eventId, tapId: tapId),
        )
        .timeout(timeout);
    return id.isNotEmpty;
  } catch (e) {
    Logs().w('[XlButtons] callback event send failed: $e');
    return false;
  }
}

/// Ответ бота на нажатие (`answerCallbackQuery`).
class BotCallbackAnswer {
  final String? tapId;
  final String roomId;
  final String eventId;
  final String index;
  final String? text;
  final bool showAlert;
  final String? url;

  const BotCallbackAnswer({
    required this.roomId,
    required this.eventId,
    required this.index,
    this.tapId,
    this.text,
    this.showAlert = false,
    this.url,
  });

  static String? _nonEmpty(Object? v) => v is String && v.isNotEmpty ? v : null;

  /// Null для мусора: без комнаты, события или номера ответ не к чему привязать.
  static BotCallbackAnswer? fromContent(Map<String, Object?> content) {
    final roomId = _nonEmpty(content['room_id']);
    final eventId = _nonEmpty(content['event_id']);
    final index = content['index']?.toString();
    if (roomId == null || eventId == null || index == null || index.isEmpty) {
      return null;
    }
    return BotCallbackAnswer(
      tapId: _nonEmpty(content['tap_id']),
      roomId: roomId,
      eventId: eventId,
      index: index,
      text: _nonEmpty(content['text']),
      showAlert: content['show_alert'] == true,
      url: _nonEmpty(content['url']),
    );
  }
}

/// Нажатие, ждущее ответа бота. [botMxid] — отправитель сообщения с кнопками:
/// ответ от кого-то другого не принимаем.
class PendingBotTap {
  final String tapId;
  final String roomId;
  final String eventId;
  final String index;
  final String botMxid;
  final void Function(BotCallbackAnswer answer) onAnswer;

  const PendingBotTap({
    required this.tapId,
    required this.roomId,
    required this.eventId,
    required this.index,
    required this.botMxid,
    required this.onAnswer,
  });
}

/// Приёмник ответов ботов: одна подписка на `onToDeviceEvent` на клиента.
///
/// Нажатие регистрирует виджет кнопок и снимает сам (ответ, 15 с, dispose), так
/// что ответ на нажатие с другого устройства или на неизвестное нажатие здесь
/// ни с чем не сопоставится и будет проигнорирован.
class BotCallbackAnswers {
  // Подписка живёт столько же, сколько клиент: SDK закрывает поток в `dispose`.
  BotCallbackAnswers._(Client client) {
    client.onToDeviceEvent.stream.listen((e) {
      if (e.type == botCallbackAnswerEventType) handle(e);
    });
  }

  static final _byClient = Expando<BotCallbackAnswers>();

  static BotCallbackAnswers of(Client client) =>
      _byClient[client] ??= BotCallbackAnswers._(client);

  final List<PendingBotTap> _pending = [];

  void register(PendingBotTap tap) => _pending.add(tap);

  void unregister(PendingBotTap tap) => _pending.remove(tap);

  @visibleForTesting
  int get pendingCount => _pending.length;

  /// Сопоставление: по `tap_id`; ответ без него (сервер не знал id — нажатие
  /// со сборки без `tap_id`) — по (комната, событие, номер) своего ждущего
  /// нажатия. True — ответ доставлен.
  @visibleForTesting
  bool handle(ToDeviceEvent event) {
    final answer = BotCallbackAnswer.fromContent(event.content);
    if (answer == null) return false;
    final tap = _pending.firstWhereOrNull(
      (t) => answer.tapId != null
          ? t.tapId == answer.tapId
          : t.roomId == answer.roomId &&
                t.eventId == answer.eventId &&
                t.index == answer.index,
    );
    if (tap == null || tap.botMxid != event.senderId) return false;
    _pending.remove(tap);
    tap.onAnswer(answer);
    return true;
  }
}

extension BotCallbackEvent on Event {
  bool get isBotCallbackEvent => type == botCallbackEventType;
}
