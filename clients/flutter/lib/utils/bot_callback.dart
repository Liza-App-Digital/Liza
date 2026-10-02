import 'package:matrix/matrix.dart';

/// Нажатие кнопки бота (Liza Bot API → `callback_query`).
///
/// Отдельный ТИП события, а не `m.room.message`: старые сборки скрывают
/// неизвестные типы (а кастомный msgtype нарисовали бы текстом body), push-правила
/// и счётчики непрочитанного его не трогают, в `roomPreviewLastEvents` его нет —
/// превью списка чатов не меняется. Контракт с сервером —
/// `servers/liza-bot-api/matrix/integration.py` (`CALLBACK_EVENT_TYPE`).
const botCallbackEventType = 'com.liza.bot.callback';

/// Содержимое события нажатия: номер кнопки и событие, чью кнопку нажали
/// (для отредактированного сообщения — display-событие правки, сервер это знает).
/// `callback_data` клиент не отправляет — сервер берёт его из своей БД.
Map<String, dynamic> botCallbackContent({
  required String index,
  required String eventId,
}) => {
  'index': index,
  'm.relates_to': {'rel_type': botCallbackEventType, 'event_id': eventId},
};

extension BotCallbackEvent on Event {
  bool get isBotCallbackEvent => type == botCallbackEventType;
}
