import 'package:matrix/matrix.dart';

import 'package:liza/utils/forced_list_artifact.dart';

extension FileDescriptionExtension on Event {
  static const _mediaTypes = {
    MessageTypes.File,
    MessageTypes.Image,
    MessageTypes.Sticker,
    MessageTypes.Video,
    MessageTypes.Audio,
  };

  /// Whether this event is a media/file type message.
  bool get isMediaEvent => _mediaTypes.contains(messageType);

  // Типы, для которых Event.sendAgain() идёт по file-retry ветке SDK
  // (event.dart: {Image, Video, Audio, File}) — именно она читает
  // sendingFilePlaceholders и зовёт cancelSend при пропаже файла. Sticker в неё
  // НЕ входит (уходит через sendEvent, cancelSend не вызывает), поэтому набор
  // уже, чем isMediaEvent, — иначе стикер блокировался бы напрасно.
  static const _fileRetryTypes = {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.File,
  };

  /// Медиа-событие в статусе ошибки, чьи байты для повторной отправки уже
  /// недоступны: `Event.sendAgain()` берёт их из in-memory
  /// `room.sendingFilePlaceholders[eventId]`, а этот словарь теряется при
  /// перезапуске приложения (и очищается SDK даже после неудачной отправки).
  /// Для такого события `sendAgain()` не отправит повторно, а вызовет
  /// `cancelSend()` и УДАЛИТ сообщение из таймлайна — молчаливая потеря данных
  /// (LABA-2239). Вызвавший ДОЛЖЕН заблокировать «отправить повторно» и
  /// сообщить пользователю вместо вызова `sendAgain()`.
  bool get isUnresendableMissingMedia =>
      status.isError &&
      _fileRetryTypes.contains(messageType) &&
      room.sendingFilePlaceholders[eventId] == null;

  /// Отправляемая копия медиа, у которой ещё НЕТ ничего для воспроизведения:
  /// файл не залит (`url` нет) и байтов у SDK тоже нет. Так живёт пузырь
  /// видео-альбома, который Liza показывает ДО передачи файла в SDK
  /// (`preEmitBubbles` в `send_file_dialog.dart`): члены альбома заливаются по
  /// очереди, и большой хвостовой файл ждёт часами. Открыть его нечем — это не
  /// сбой плеера (GlitchTip #2080: 211-МБ видео ждало очереди с 08:25 до 12:17,
  /// тап в 11:03 давал `swap-failed` и экран ошибки).
  bool get isPendingMediaWithoutBytes =>
      (status.isSending || status.isError) &&
      attachmentMxcUrl == null &&
      room.sendingFilePlaceholders[eventId] == null;

  String? get fileDescription {
    if (!isMediaEvent) return null;
    final filename = content.tryGet<String>('filename');
    // Наличие подписи решаем по ПЛЕЙН-`body` без reply-фолбэка. SDK при
    // `inReplyTo` дописывает цитату в `body` (и `<mx-reply>` в `formatted_body`),
    // а у медиа `body` == имя файла — из-за порчи `body != filename`, и без
    // снятия фолбэка имя файла ложно показывалось подписью под осциллограммой
    // (LABA-2238: reply-голосовое `recording…ogg`).
    final body = stripReplyFallbackBody(content.tryGet<String>('body'));
    if (body == null || body.isEmpty || body == filename) return null;

    // Реальная подпись есть: если у неё разметка (XL <strong>/<em>/…, LABA-2207)
    // — вернуть `formatted_body` (mx-reply снимет HtmlMessage при рендере).
    final formattedBody = content.tryGet<String>('formatted_body');
    if (formattedBody != null && formattedBody.isNotEmpty) return formattedBody;
    return body;
  }

  /// Returns the plain text caption for editing purposes.
  /// Unlike [fileDescription], this never returns formatted_body (HTML).
  String? get fileEditBody {
    if (!isMediaEvent) return null;
    final filename = content.tryGet<String>('filename');
    final body = stripReplyFallbackBody(content.tryGet<String>('body'));
    if (body == null || body.isEmpty || body == filename) return null;
    return body;
  }
}
