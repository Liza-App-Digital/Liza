import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/bot_deep_link.dart';

/// Распознаёт invite-URI и извлекает invite code, иначе null.
///
/// Принимает:
/// - `liza://invite/<code>` (custom scheme deep-link с лендинга)
/// - `https://me.liza.ru/i/<code>` (основная Universal Link / App Link)
/// - `https://liza.laba.pro/i/<code>` (legacy)
/// - `https://liza.laba.pro/<slug>/<code>` (legacy-формат с кастомным
///   слагом приложения)
///
/// Слаг первого сегмента чисто декоративен — auth-proxy резолвит инвайт по коду
/// (второй сегмент). Для legacy-префикса `i` код возвращаем как есть (поведение
/// не меняем). Для произвольного слага требуем, чтобы код был похож на код
/// auth-proxy (`<env_prefix>_<токен>`) — иначе любой двусегментный путь на домене
/// ложно опознавался бы как инвайт. Префиксы `s` (сторисы, см.
/// `parseStoryLinkCode`), `c` (каналы, см. `parseChannelHandle`) и `u`
/// (пользователи, см. `parseUserHandle`) зарезервированы и всегда исключены из
/// слага.
String? parseInviteCode(Uri uri) {
  if (uri.scheme == 'liza' &&
      uri.host == 'invite' &&
      uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.first;
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      _isShortLinkHost(uri.host) &&
      uri.pathSegments.length == 2) {
    final first = uri.pathSegments.first;
    final code = uri.pathSegments[1];
    if (first == 'i') return code;
    if (uri.host == _legacyShortLinkHost &&
        first != '.well-known' &&
        first != 's' &&
        first != 'c' &&
        first != 'u' &&
        first != 'b' &&
        _looksLikeInviteCode(code)) {
      return code;
    }
  }
  return null;
}

/// Формат кода auth-proxy: `<env_prefix>_<slug>`, напр. `p_DKvhaNQUUi`
/// (code_generator.py: префикс среды + slug из безопасного алфавита, ≥8 симв.).
final RegExp _inviteCodeRe = RegExp(r'^[a-z0-9]+_[A-Za-z0-9]{8,}$');

const _shortLinkHost = 'me.liza.ru';
const _legacyShortLinkHost = 'liza.laba.pro';

bool _isShortLinkHost(String host) =>
    host == _shortLinkHost || host == _legacyShortLinkHost;

/// Извлекает invite-код из URL САМОГО веб-клиента (`/i/<code>`), без проверки
/// хоста: веб-клиент живёт на web.liza.ru / dev.web.liza.ru / localhost, а не
/// на домене коротких ссылок, поэтому [parseInviteCode] здесь не подходит.
///
/// Код обязан выглядеть как код auth-proxy (`<env_prefix>_<токен>`) — иначе
/// любой путь `/i/<что-то>` ложно опознавался бы как инвайт.
String? parseWebInviteCode(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'i') return null;
  final code = segments[1];
  return _looksLikeInviteCode(code) ? code : null;
}

bool _looksLikeInviteCode(String value) => _inviteCodeRe.hasMatch(value);

/// Извлекает код сторис из URL САМОГО веб-клиента (`/s/<code>`), без проверки
/// хоста: веб-клиент живёт на web.liza.ru / dev.web.liza.ru / localhost, а не
/// на домене коротких ссылок, поэтому [parseStoryLinkCode] здесь не подходит.
String? parseWebStoryCode(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 's') return null;
  final code = segments[1];
  return code.isEmpty ? null : code;
}

/// Извлекает ник канала из URL веб-клиента (`/c/<ник>`). Ник валидируется тем
/// же `validateChannelHandle`, что и при занятии ника, — иначе `/c/<мусор>`
/// перехватывал бы ссылку у fallback-обработчика.
String? parseWebChannelHandle(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'c') return null;
  final handle = normalizeChannelHandle(segments[1]);
  if (validateChannelHandle(handle) != null) return null;
  return handle;
}

/// Распознаёт короткую ссылку на сторис и извлекает код, иначе null.
///
/// Принимает:
/// - `liza://story/<code>` (custom scheme deep-link)
/// - `https://me.liza.ru/s/<code>` (основная Universal Link / App Link)
/// - `https://liza.laba.pro/s/<code>` (legacy)
///
/// Префикс `s` зарезервирован под сторисы и не попадает под generic-слаг
/// ветку `parseInviteCode` (см. её проверку `first != '.well-known'`).
String? parseStoryLinkCode(Uri uri) {
  if (uri.scheme == 'liza' &&
      uri.host == 'story' &&
      uri.pathSegments.isNotEmpty) {
    return uri.pathSegments.first;
  }
  if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      _isShortLinkHost(uri.host) &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments.first == 's') {
    return uri.pathSegments[1];
  }
  return null;
}

/// Распознаёт ссылку на канал и извлекает ник (handle), иначе null.
///
/// Принимает:
/// - `liza://channel/<ник>` (custom scheme deep-link; на него редиректит
///   лендинг `channel_landing.html`)
/// - `https://me.liza.ru/c/<ник>` (основная Universal Link / App Link —
///   именно эту ссылку генерирует auth-proxy)
/// - `https://liza.laba.pro/c/<ник>` (legacy-домен)
///
/// Ник валидируется тем же `validateChannelHandle`, что и при занятии ника
/// (`channel_handle.dart`): без сигила, `^[a-z][a-z0-9_]{4,31}$`, не служебное
/// слово. Невалидный ник → null, чтобы `/c/<мусор>` не уводил в резолв и не
/// перехватывал ссылку у fallback-обработчика.
String? parseChannelHandle(Uri uri) {
  String? raw;
  if (uri.scheme == 'liza' &&
      uri.host == 'channel' &&
      uri.pathSegments.length == 1) {
    raw = uri.pathSegments.first;
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      _isShortLinkHost(uri.host) &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments.first == 'c') {
    raw = uri.pathSegments[1];
  }
  if (raw == null) return null;
  final handle = normalizeChannelHandle(raw);
  if (validateChannelHandle(handle) != null) return null;
  return handle;
}

/// Единый резолвер «внутренняя ли это ссылка Liza» → путь роутера.
///
/// Возвращает `/s/<code>`, `/i/<code>`, `/c/<handle>` или `/u/<handle>` для
/// сторис/инвайт/канал/пользователь-ссылок (короткий хост `me.liza.ru`/
/// `liza.laba.pro` либо custom-scheme `liza://…`), иначе `null` — вызывающий
/// тогда открывает ссылку по-прежнему.
///
/// Нужен ДВУМ точкам входа: deep-link из `AppLinks` (`chat_list._processIncomingUris`)
/// и ТАП по ссылке в сообщении (`UrlLauncher.launchUrl`). До этого хелпера
/// `UrlLauncher` не знал про парсеры → `https://me.liza.ru/c/<ник>` уходил во
/// внешний браузер, откуда ОС показывала «Поделиться» вместо открытия канала
/// ([[RL-channel-link-open-internal]]). Порядок проверок — как в `_processIncomingUris`
/// (сторис → инвайт → канал → пользователь), чтобы обе точки резолвили одинаково.
String? resolveInternalRoute(Uri uri) {
  final botLink = parseBotLink(uri);
  if (botLink != null) return botLink.route;
  final storyCode = parseStoryLinkCode(uri);
  if (storyCode != null) return '/s/$storyCode';
  final inviteCode = parseInviteCode(uri);
  if (inviteCode != null) return '/i/$inviteCode';
  final channelHandle = parseChannelHandle(uri);
  if (channelHandle != null) return '/c/$channelHandle';
  final userHandle = parseUserHandle(uri);
  if (userHandle != null) return '/u/$userHandle';
  return null;
}

/// Распознаёт ссылку на публичный @-ник пользователя и извлекает его, иначе
/// null.
///
/// Принимает:
/// - `liza://user/<ник>` (custom scheme deep-link)
/// - `https://me.liza.ru/u/<ник>` (основная Universal Link / App Link)
/// - `https://liza.laba.pro/u/<ник>` (legacy-домен)
///
/// Формат ника у людей и каналов совпадает (`channel_handle.dart`), поэтому
/// валидируется тем же `validateChannelHandle`. Невалидный ник → null, чтобы
/// `/u/<мусор>` не перехватывал ссылку у fallback-обработчика.
String? parseUserHandle(Uri uri) {
  String? raw;
  if (uri.scheme == 'liza' &&
      uri.host == 'user' &&
      uri.pathSegments.length == 1) {
    raw = uri.pathSegments.first;
  } else if ((uri.scheme == 'https' || uri.scheme == 'http') &&
      _isShortLinkHost(uri.host) &&
      uri.pathSegments.length == 2 &&
      uri.pathSegments.first == 'u') {
    raw = uri.pathSegments[1];
  }
  if (raw == null) return null;
  final handle = normalizeChannelHandle(raw);
  if (validateChannelHandle(handle) != null) return null;
  return handle;
}

/// Извлекает ник пользователя из URL веб-клиента (`/u/<ник>`), без проверки
/// хоста — та же причина, что у [parseWebChannelHandle].
String? parseWebUserHandle(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.length < 2 || segments.first != 'u') return null;
  final handle = normalizeChannelHandle(segments[1]);
  if (validateChannelHandle(handle) != null) return null;
  return handle;
}

/// Стартовый маршрут роутера для URL САМОГО веб-клиента (`Uri.base`), либо
/// `null` — обычный старт с `/`.
///
/// Веб живёт на hash-стратегии: go_router читает маршрут из `#…`, а лендинг
/// auth-proxy («Открыть в браузере») и пользователи вставляют ссылку
/// path-формы `web.liza.ru/i/<code>` — hash пуст, роутер стартовал с `/` и
/// залогиненный пользователь оказывался в списке чатов вместо цели
/// (LABA-2551). Незалогиненный путь читал `Uri.base` на экране входа
/// (`_restoreInviteCodeForWeb`) — этот хелпер закрывает залогиненный, теми же
/// `parseWeb*`, чтобы разбор web-URL не разошёлся на две копии.
///
/// Порядок — как в [resolveInternalRoute] (сторис → инвайт → канал →
/// пользователь). Query/fragment не учитываются: маршрут — только path.
String? webInitialLocation(Uri base) {
  final botLink = parseWebBotLink(base);
  if (botLink != null) return botLink.route;
  final storyCode = parseWebStoryCode(base);
  if (storyCode != null) return '/s/$storyCode';
  final inviteCode = parseWebInviteCode(base);
  if (inviteCode != null) return '/i/$inviteCode';
  final channelHandle = parseWebChannelHandle(base);
  if (channelHandle != null) return '/c/$channelHandle';
  final userHandle = parseWebUserHandle(base);
  if (userHandle != null) return '/u/$userHandle';
  return null;
}
