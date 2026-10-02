import 'package:matrix/matrix.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/utils/bot_callback.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/support_intent.dart';
import 'package:liza/utils/xl_credentials.dart';

extension VisibleInGuiExtension on List<Event> {
  List<Event> filterByVisibleInGui({
    String? exceptionEventId,
    String? threadId,
  }) => where((event) {
    if (threadId != null &&
        event.relationshipType != RelationshipTypes.reaction) {
      if ((event.relationshipType != RelationshipTypes.thread ||
              event.relationshipEventId != threadId) &&
          event.eventId != threadId) {
        return false;
      }
    } else if (event.relationshipType == RelationshipTypes.thread) {
      return false;
    }
    // Удалённый пост канала не оставляет следа (как в Liza): ни надгробия,
    // ни реакций, ни кнопки комментариев. Гейт стоит ВНЕ `||
    // exceptionEventId`, иначе подсвечиваемое по ссылке событие воскресило бы
    // надгробие.
    if (event.isRedactedChannelPost) return false;
    // Пост Liza News для других платформ — тоже вне `|| exceptionEventId`:
    // переход по ссылке не должен показывать адресованное не этому устройству.
    if (event.isHiddenByNewsAudience) return false;
    return event.isVisibleInGui || event.eventId == exceptionEventId;
  }).toList();
}

/// Системные state-события, которые лента канала не показывает.
///
/// Liza в канале не показывает служебный шум: вступления, смену имени,
/// аватара, описания и ссылки-приглашения. `m.room.create` остаётся —
/// «канал создан» показывают обе системы.
///
/// Скоуп намеренно ограничен каналом: в группах и ЛС эти события несут
/// смысл (кто кого добавил, кто вышел).
const _hiddenChannelStateTypes = {
  EventTypes.RoomMember,
  EventTypes.RoomName,
  EventTypes.RoomAvatar,
  EventTypes.RoomTopic,
  EventTypes.RoomCanonicalAlias,
};

extension IsStateExtension on Event {
  /// Удалённый (redacted) пост в комнате-канале. В ленте канала такой пост
  /// обязан исчезать ЦЕЛИКОМ, независимо от настройки `hideRedactedEvents`:
  /// она — личный выбор пользователя для обычных чатов (дефолт FluffyChat —
  /// показывать надгробие), а для канала «удалено = нет поста» это
  /// продуктовое правило, а не предпочтение.
  ///
  /// `redacted` проверяется ПЕРВЫМ: он читается из `unsigned`, а `isChannel`
  /// лезет в room-state (`m.room.create`) — при обычной ленте без удалений
  /// state не трогаем вовсе.
  bool get isRedactedChannelPost => redacted && room.isChannel;

  bool get isHiddenChannelStateEvent =>
      _hiddenChannelStateTypes.contains(type) && room.isChannel;

  /// Служебное событие с API-ключом XL: техника обмена с ботом, не реплика
  /// пользователя. В ленте выглядело как отправленное мерчантом «Подключение
  /// интеграции XL» и засоряло диалог при каждом открытии чата.
  bool get isXlCredentialsEvent =>
      type == EventTypes.Message &&
      content.tryGet<String>('msgtype') == xlCredentialsMsgtype;

  bool get isVisibleInGui =>
      // служебная передача ключа XL боту — не пользовательское сообщение
      !isXlCredentialsEvent &&
      // нажатие кнопки бота — сигнал боту, не реплика (скрыто и при выключенном
      // «скрывать неизвестные события»)
      !isBotCallbackEvent &&
      // удалённый пост канала не показываем никогда (см. isRedactedChannelPost)
      !isRedactedChannelPost &&
      // служебный шум канала (вступления, смена аватара/имени) — не показываем
      !isHiddenChannelStateEvent &&
      // пост Liza News для других платформ (read_marker_logic ставит квитанцию
      // только на видимое — значит, и на скрытый пост её не поставит)
      !isHiddenByNewsAudience &&
      // always filter out edit and reaction relationships
      !{
        RelationshipTypes.edit,
        RelationshipTypes.reaction,
      }.contains(relationshipType) &&
      // always filter out m.key.* and other known but unimportant events
      !isKnownHiddenStates &&
      // event types to hide: redaction and reaction events
      // if a reaction has been redacted we also want it to be hidden in the timeline
      !{EventTypes.Reaction, EventTypes.Redaction}.contains(type) &&
      // if we enabled to hide all redacted events, don't show those
      (!AppSettings.hideRedactedEvents.value || !redacted) &&
      // if we enabled to hide all unknown events, don't show those
      (!AppSettings.hideUnknownEvents.value || isEventTypeKnown);

  bool get isState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
  }.contains(type);

  bool get isCollapsedState => !{
    EventTypes.Message,
    EventTypes.Sticker,
    EventTypes.Encrypted,
    EventTypes.RoomCreate,
    EventTypes.RoomTombstone,
  }.contains(type);

  bool get isKnownHiddenStates =>
      {PollEventContent.responseType}.contains(type) ||
      type.startsWith('m.key.verification.') ||
      // Интент клиента боту поддержки — служебное состояние комнаты, не сообщение.
      type == supportIntentStateType;
}
