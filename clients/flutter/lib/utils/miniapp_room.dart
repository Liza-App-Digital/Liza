import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/miniapp_start_path.dart';

/// Параметры запуска подключённого mini App, прочитанные из state-event
/// `com.liza.miniapp.config` комнаты-лаунчера.
class MiniAppLaunch {
  final String appUrl;
  final String appId;
  final String appName;
  final String appType;

  /// Deep-link на конкретную страницу mini App (`#!/tproduct/123`) — приложение
  /// открывается сразу на ней. Пусто у обычных подключений (главная).
  final String appStartPath;

  /// Настройки кнопок быстрого доступа (задаются владельцем через BotFather,
  /// едут из `/liza/mybots`). `*Enabled=false` — кнопка скрыта; непустой `*Label`
  /// подменяет дефолтное «Открыть». У конфигов из state-event комнаты (не из
  /// реестра ботов) — дефолты: кнопки видимы, названия дефолтные.
  final bool composerButtonEnabled;
  final String? composerButtonLabel;
  final bool listButtonEnabled;
  final String? listButtonLabel;

  const MiniAppLaunch({
    required this.appUrl,
    required this.appId,
    required this.appName,
    required this.appType,
    this.appStartPath = '',
    this.composerButtonEnabled = true,
    this.composerButtonLabel,
    this.listButtonEnabled = true,
    this.listButtonLabel,
  });
}

/// Достаёт параметры запуска из content state-event `com.liza.miniapp.config`.
///
/// Возвращает `null`, если комната не является чатом-лаунчером mini App или у
/// конфига нет валидного (непустого) `app_url` — клиент открывает приложение
/// только по https-ссылке. Чистая функция: вся проверка инварианта «кнопка
/// «Открыть» показывается ⇔ есть рабочий app_url» — тут, чтобы её можно было
/// закрепить тестом без поднятия виджета чата.
MiniAppLaunch? miniAppLaunchFromConfig(Map<String, Object?>? content) {
  if (content == null) return null;
  final url = content['app_url'];
  if (url is! String || url.isEmpty) return null;
  // app_start_path — недоверенные данные из state-event: пропускаем через ту же
  // границу безопасности, что и при создании ссылки. Невалидное → главная.
  final rawStartPath = content['app_start_path'];
  final startPath = (rawStartPath is String && isSafeStartPath(rawStartPath))
      ? rawStartPath
      : '';
  return MiniAppLaunch(
    appUrl: url,
    appId: (content['app_id'] as String?) ?? 'unknown',
    appName: (content['app_name'] as String?) ?? 'Mini App',
    appType: (content['app_type'] as String?) ?? 'third_party',
    appStartPath: startPath,
  );
}

/// Конфиг mini App для комнаты (или `null`, если это не чат-лаунчер).
MiniAppLaunch? miniAppLaunchForRoom(Room room) =>
    miniAppLaunchFromConfig(room.getState('com.liza.miniapp.config')?.content);

/// Localparts служебного бота BotFather. Legacy `bot_father` (старый инстанс на
/// prod) + новый `botfather` (на bots.liza.ru). Сверяем по вхождению, домен
/// игнорируем (cross-HS бандл).
const Set<String> botFatherLocalparts = {'bot_father', 'botfather'};

/// Домен хоумсервера всех ботов BotFather (@botfather/@liza/@gpt/@deepseek +
/// пользовательские боты создаются здесь). Домен mxid НЕ меняется при
/// деактивации аккаунта — устойчивый признак «это бот» даже после удаления бота
/// (роль `ai` и реестр `/liza/mybots` после удаления обнуляются, домен — нет).
///
/// ⚠️ ПРОД-домен захардкожен НАМЕРЕННО, НЕ делать flavor-aware (LABA-2242).
/// Дискриминатор `isDeletedBotDm` держится ТОЛЬКО потому, что `bots.liza.ru` —
/// ВЫДЕЛЕННЫЙ хоумсервер ботов (людей на нём нет): «домен бота ∧ membership==leave»
/// однозначно значит «удалённый бот». Локальный стек (`liza.local`) и клиентские
/// инстансы (`nadezhda.liza.ru`, `victoryeng.liza.ru`, …) хостят ЛЮДЕЙ И БОТОВ
/// вместе — подставь их сюда, и любой человек, вышедший из личного DM, ложно
/// станет «Удалённым аккаунтом». Matrix не отдаёт другим пользователям признак
/// «аккаунт деактивирован» по C-S API, поэтому выделенный бот-домен — лучший
/// доступный сигнал, и он корректен для прода. Следствие: удалённый бот на
/// НЕ-`bots.liza.ru` домене (легаси-бот на прод-HS людей
/// `@…:synapse.liza.laba.prodamus.tech`, локальный `@…:liza.local`)
/// «Удалённым аккаунтом» не отрисуется — это ограничение топологии,
/// а не баг. Для эмулятора live-переход показать нельзя (local — общий HS);
/// визуал forward-пути закреплён golden `deleted_bot_avatar` + тестами `deleted_bot_dm`.
const String botsHomeserver = 'bots.liza.ru';

/// DM с УДАЛЁННЫМ ботом (LABA-2242): при удалении бота через BotFather его
/// Matrix-аккаунт деактивируется на сервере → бот выходит из комнаты
/// (`membership == leave`). По этому сигналу клиент рисует «Удалённый аккаунт» +
/// серый аватар-призрак + блок ввода (паритет с Liza «Deleted Account»).
///
/// Сужено доменом ботов намеренно: обычный человек, вышедший из личного чата,
/// должен остаться штатным «Пустой чат (был …)» (SDK `isAbandonedDMRoom`), а не
/// «Удалённым аккаунтом». Зеркалит SDK-условие leave-собеседника в DM.
bool isDeletedBotDm(Room room) {
  final peer = room.directChatMatrixID;
  if (peer == null) return false;
  final domain = peer.contains(':') ? peer.split(':').last : '';
  if (domain != botsHomeserver) return false;
  return room.unsafeGetUserFromMemoryOrFallback(peer).membership ==
      Membership.leave;
}

/// Диалог с BotFather. Пункт «Создать mini App» в «+»-меню показываем только
/// здесь: команда `/createMiniApp` осмысленна лишь в чате с этим ботом (он
/// отвечает карточкой подключения). В обычном чате/группе пункта нет.
bool isBotFatherRoom(Room room) {
  final partner = room.directChatMatrixID;
  if (partner != null) {
    final localpart = partner.split(':').first.replaceFirst('@', '');
    return botFatherLocalparts.contains(localpart);
  }
  // Групповой чат с BotFather (directChatMatrixID == null, напр. «Группа с
  // BotFather»): ищем участника-бота по локалпарту среди членов, кроме себя.
  // Нужно и для «+»-меню, и для меню-кнопки композера (chat_input_row).
  final myId = room.client.userID;
  for (final member in room.getParticipants()) {
    if (member.id == myId) continue;
    final lp = member.id.split(':').first.replaceFirst('@', '');
    if (botFatherLocalparts.contains(lp)) return true;
  }
  return false;
}

/// Общий чат службы поддержки «Liza support hub». Кнопку-меню композера
/// (Необработанные заявки / Мои задачи / Обработанные) показываем ТОЛЬКО здесь:
/// в per-ticket чатах текст уходит мостом заявителю, а не в меню. Детекция —
/// групповой чат (не DM) с участником `@support` и именем «Liza support hub».
bool isSupportHubRoom(Room room) {
  if (room.directChatMatrixID != null) return false;
  if (room.name != 'Liza support hub') return false;
  final myId = room.client.userID;
  for (final member in room.getParticipants()) {
    if (member.id == myId) continue;
    // Сверяем ПОЛНЫЙ mxid бота поддержки (flavor-aware), а не только localpart:
    // чужой `@support:<клиентский-сервер>` в одноимённом чате не должен включать
    // меню службы. Наш бот всегда `@support:bots.liza.ru` (в local — liza.local).
    if (member.id ==
        AppConfig.supportBotMxidForHomeserver(room.client.homeserver?.host)) {
      return true;
    }
  }
  return false;
}

/// Чат с ассистентом Лизой, который закрепляем первым в списке.
///
/// Сверяем ПОЛНЫЙ mxid, а не localpart: у пользователей остались мёртвые DM со
/// старой `@liza:synapse.liza.laba.prodamus.tech` (аккаунт деактивирован при
/// выводе prod-ботов 2026-07-14, бот выброшен из комнаты). По localpart они
/// неотличимы от живого DM на bots.liza.ru и перехватывали закрепление.
///
/// mini App-чаты — тоже DM с `@liza`, но у них есть кастомное имя комнаты
/// (название приложения). Ассистент — единственный @liza-DM БЕЗ `m.room.name`,
/// иначе свежесозданный mini App-чат отодвигал бы ассистента вниз. Запрос к
/// Лизе («Новый запрос») исключаем по маркеру — его имя человек может стереть.
bool isLizaAssistantRoom(Room room, String lizaMxid) =>
    room.directChatMatrixID == lizaMxid &&
    !isLizaRequestRoom(room) &&
    (room.getState(EventTypes.RoomName)?.content.tryGet<String>('name') ?? '')
        .isEmpty;
