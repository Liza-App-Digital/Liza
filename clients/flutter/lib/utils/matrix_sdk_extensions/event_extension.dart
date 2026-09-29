import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:async/async.dart' as async;
import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';
import 'package:open_app_file/open_app_file.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:liza/utils/size_string.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'matrix_file_extension.dart';

/// Sanitizes a filename for iOS by replacing non-ASCII characters with a safe
/// ASCII name while preserving the file extension.
///
/// On iOS, [OpenAppFile.open()] cannot handle paths containing non-ASCII
/// characters (Cyrillic, spaces, special chars). This function generates a
/// safe ASCII filename to use when saving to the temp directory.
///
/// Returns the filename unchanged if it contains only ASCII characters.
/// Otherwise, generates a deterministic ASCII base name from the original
/// filename's [hashCode] and preserves the file extension.
String sanitizeFilenameForIOS(String filename) {
  // If every code unit is in the ASCII range (0–127), no sanitization needed.
  if (filename.codeUnits.every((c) => c <= 127)) {
    return filename;
  }

  // Extract extension using lastIndexOf to handle multiple dots correctly.
  final dotIndex = filename.lastIndexOf('.');
  final extension = dotIndex > 0 ? filename.substring(dotIndex) : '';

  // Generate a deterministic ASCII base name from the original filename hash.
  final baseName = 'file_${filename.hashCode.abs()}';

  return extension.isEmpty ? baseName : '$baseName$extension';
}

/// Голый throw строки в matrix-4.1.0 `event.dart:811` при sha256-mismatch
/// расшифровки вложения (`decryptFileImplementation` вернул null). Матчим по
/// точному литералу: рядом SDK бросает другие голые строки (сетевой обрыв,
/// отсутствие ключа) — их перекачкой не чинят.
const kDecryptFailure = 'Unable to decrypt file';

/// Ошибка `error` — это ровно тот decrypt-fail из отравленного файл-кэша, который
/// стоит лечить перекачкой? Вынесено из `downloadAndDecryptAttachmentHealed` в
/// публичную чистую функцию, чтобы страж `ledger:RL-attachment-decrypt-cache-selfheal`
/// проверял РЕАЛЬНЫЙ матчинг, а не реплику: SDK бросает голую `String`, и любая
/// опечатка/локализация/смена версии молча превратила бы self-heal в no-op без
/// единого красного теста. Матчим строго по типу+литералу — соседние голые
/// строки SDK (`'Unable to download file from local store.'`,
/// `"Missing 'decrypt' in 'key_ops'."`, `'Encryption is not enabled…'`) и любые
/// `Exception` перекачкой не чинятся.
bool isHealableDecryptFailure(Object error) =>
    error is String && error == kDecryptFailure;

/// Класс терминального сбоя получения вложения — ЗАКРЫТОЕ перечисление для
/// триажа алёрта и выбора ЧЕСТНОГО сообщения пользователю.
///
/// Зачем: и `[audio-fail] reason=download-fail`, и `TranscriptionErrorKind.decrypt`
/// были catch-all вокруг ОДНОГО шага `downloadAndDecryptAttachmentHealed()` —
/// сетевой обрыв, HTTP-ошибка сервера и настоящий sha256-mismatch приходили под
/// одной меткой. Инцидент 2026-09-09 (issue GlitchTip #111/#112): у пользователя
/// моргнула сеть (прод-MMR за 9 минут вокруг сбоя не получил НИ ОДНОГО запроса,
/// а через 24с та же запись скачалась и транскрибировалась успешно), но алёрт
/// сказал `reason=transcription-decrypt`, а пользователь увидел «Не удалось
/// расшифровать голосовое сообщение» — обоим соврали про причину.
///
/// Значения низкокардинальны и не несут секретов: тип ошибки, не её текст.
String mediaFailureKind(Object error) {
  if (isHealableDecryptFailure(error)) return 'decrypt';
  if (error is MediaDownloadException) return 'http';
  if (error is TimeoutException) return 'timeout';
  // `TlsException` — НАДКЛАСС `HandshakeException`/`CertificateException`: берём
  // его, иначе голый TLS-сбой (captive-portal, смена сети, недоверенный
  // сертификат) провалился бы в `other` → `decrypt`, то есть ровно в ту ложь,
  // которую этот классификатор и заводили лечить. Набор держим синхронным с
  // `classifyMediaDiag` (`networkErrors` ниже) — два разных охвата означали бы
  // два разных диагноза на одну ошибку.
  if (error is SocketException ||
      error is TlsException ||
      error is HttpException ||
      error is http.ClientException) {
    return 'network';
  }
  // Прочие голые строки SDK (`'Unable to download file from local store.'`,
  // `"Missing 'decrypt' in 'key_ops'."`) — не сеть и не наш decrypt-класс.
  if (error is String) return 'sdk';
  return 'other';
}

/// Имя типа ошибки для класса `other` [mediaFailureKind] — ЕДИНСТВЕННЫЙ след
/// причины, доезжающий до дежурного (notifier видит только title алёрта).
///
/// Зачем: issue GlitchTip #2057 (2026-09-23, iPhone15,2, сборка 3764) пришёл как
/// `kind=other` без единой зацепки — `Logs().v` с текстом ошибки остаётся на
/// устройстве, а серверный лог отвечает только за сетевую часть. Конечный набор
/// типов держит кардинальность низкой; текст ошибки НЕ берём (пин
/// `RL-mediadiag-no-secret`: в `FileSystemException` лежит путь с mxc id).
/// Дженерики срезаем (`_Map<String, dynamic>` → `_Map`), длину ограничиваем.
String mediaFailureErrorType(Object error) {
  final name = RegExp(r'^[A-Za-z0-9_$]+')
      .stringMatch(error.runtimeType.toString());
  if (name == null || name.isEmpty) return 'unknown';
  return name.length > 40 ? name.substring(0, 40) : name;
}

/// mxc, для которых в этой сессии уже пытались вылечить отравленный дисковый
/// файл-кэш SDK. Живёт всю сессию: без него упорно-битый на сервере файл
/// зациклил бы перекачку на каждый тап. Ключ — mxc с учётом `getThumbnail`
/// (превью и полноразмер — разные mxc). Аналог `_cachePoisonRetried` в
/// `MxcImage`, но для decrypt-пути аудио/видео/файлов.
final Set<String> _decryptHealRetried = {};

/// mxc, для которых в этой сессии уже лечили ОТРАВЛЕННЫЙ кэш медиа (кэш-хит
/// вернул error-body вместо файла). Отдельно от [_decryptHealRetried]: там
/// decrypt-fail (шифрованное), здесь — нешифрованное медиа, где sha-гейта SDK
/// нет и мусор возвращается БЕЗ исключения. LABA-2361.
final Set<String> _mediaCachePoisonRetried = {};

/// Сервер отдал НЕ медиа, а ошибку (HTTP≥400) или error-page (200 c
/// JSON/HTML-телом) на download воспроизводимого вложения. Бросается ДО того,
/// как SDK запишет тело в файл-кэш, — иначе (для НЕшифрованного медиа, где sha-
/// гейта нет) 173-байтное `{"errcode":…}` осело бы как «аудио» и ушло в плеер
/// немым `(0) Source error` (LABA-2361: осиротевшие после отката MMR-cutover
/// media отдавали 404). НЕ [String] и НЕ decrypt-fail ⇒ [isHealableDecryptFailure]
/// вернёт false ⇒ обёртка залогирует `[MediaDiag]` и пробросит наружу.
class MediaDownloadException implements Exception {
  final int? statusCode;
  final String? contentType;
  const MediaDownloadException({this.statusCode, this.contentType});
  @override
  String toString() =>
      'MediaDownloadException(status=$statusCode, contentType=$contentType)';
}

/// Похожи ли байты на error-body сервера/прокси (Matrix-JSON `{"errcode":…}`
/// или HTML error-page), а НЕ на медиа? Чистая функция — страж
/// `ledger:RL-media-http-error-gate` проверяет РЕАЛЬНОЕ правило, а не реплику.
/// Ноль ложных срабатываний на валидном медиа: ни один контейнер (JPEG `FFD8`,
/// PNG `89 50`, OGG `OggS`, MP4 `…ftyp`, GIF `GIF`) не начинается с `{` или `<`.
/// Используется для само-лечения уже-отравленного кэша старых сборок (кэш-хит
/// возвращает мусор без HTTP-меты). LABA-2361.
bool looksLikeMediaErrorBody(Uint8List bytes) {
  if (bytes.isEmpty) return false;
  final head = bytes.length < 64 ? bytes : bytes.sublist(0, 64);
  final s = String.fromCharCodes(head).trimLeft();
  if (s.startsWith('<')) return true; // HTML error-page
  return s.startsWith('{') && s.contains('errcode'); // Matrix JSON-ошибка
}

/// Воспроизводимое медиа (audio/video/image), где error-body в файле = битый
/// плеер/картинка. `m.file` СОЗНАТЕЛЬНО исключён: легитимное вложение может быть
/// маленьким JSON/HTML — его гейтить нельзя.
bool _isPlayableMediaMsgtype(String? msgtype) =>
    msgtype == 'm.audio' || msgtype == 'm.video' || msgtype == 'm.image';

/// Решение гейта доставки медиа (LABA-2361): непусто ⇒ надо бросить —
/// сервер отдал не медиа. Чистая функция: страж `ledger:RL-media-http-error-gate`
/// проверяет РЕАЛЬНОЕ правило, а не реплику. Порог `>= 400` (НЕ `!= 200`: 206/
/// Range и 3xx-после-follow НЕ гейтим); error-page — только точные `text/html`/
/// `application/json` при 200; ТОЛЬКО воспроизводимое медиа (`m.file` исключён).
MediaDownloadException? mediaDownloadGate({
  required String? msgtype,
  required int? statusCode,
  required String? contentType,
}) {
  if (!_isPlayableMediaMsgtype(msgtype)) return null;
  if (statusCode != null && statusCode >= 400) {
    return MediaDownloadException(statusCode: statusCode);
  }
  if (statusCode == 200 &&
      contentType != null &&
      (contentType.startsWith('text/html') ||
          contentType.startsWith('application/json'))) {
    return MediaDownloadException(
      statusCode: statusCode,
      contentType: contentType,
    );
  }
  return null;
}

/// Класс сбоя медиа-загрузки — вычисляется из полей [classifyMediaDiag] и пишется
/// в диагностическую строку `[MediaDiag]`, чтобы по логу Максима однозначно
/// назвать причину (см. `docs/superpowers/specs/2026-08-04-media-download-diagnostics-design.md`).
enum MediaDiagClass {
  poisonedCache,
  networkError,
  httpError,
  errorPage200,
  truncated,
  corrupted,
  unknown,
}

/// Чистая классификация сбоя медиа-загрузки по СОБРАННЫМ примитивам. Вынесена
/// отдельно, чтобы страж `ledger:RL-mediadiag-no-secret` проверял РЕАЛЬНОЕ
/// решающее правило (в т.ч. gzip-исключение усечения), а не реплику. Секретов на
/// входе нет by design — только размеры/статус/публичные хэши.
MediaDiagClass classifyMediaDiag({
  required bool wasFromCache,
  int? statusCode,
  String? contentType,
  String? msgtype,
  int? contentLength,
  int? receivedBytes,
  String? contentEncoding,
  String? expectedCiphertextSha,
  String? actualCiphertextSha,
  String? errorType,
}) {
  // 1. Кэш-хит: SDK не звал callback (нет HTTP-меты) → отравленный локальный кэш.
  if (wasFromCache) return MediaDiagClass.poisonedCache;
  // 2. Сетевой обрыв/таймаут: HTTP-ответа нет вовсе, исключение из транспорта.
  const networkErrors = {
    'SocketException',
    'ClientException',
    'HandshakeException',
    'TlsException',
    'HttpException',
    'TimeoutException',
  };
  if (statusCode == null && errorType != null && networkErrors.contains(errorType)) {
    return MediaDiagClass.networkError;
  }
  // 3. HTTP не-200.
  if (statusCode != null && statusCode != 200) return MediaDiagClass.httpError;
  // 4. error-page-200: сервер/прокси отдал HTML/JSON с кодом 200 вместо медиа.
  final looksLikeMedia =
      msgtype == 'm.audio' ||
      msgtype == 'm.video' ||
      msgtype == 'm.image' ||
      msgtype == 'm.file';
  if (looksLikeMedia &&
      contentType != null &&
      (contentType.startsWith('text/html') ||
          contentType.startsWith('application/json'))) {
    return MediaDiagClass.errorPage200;
  }
  // 5. Усечение — ТОЛЬКО при отсутствии content-encoding: при gzip/br
  // `contentLength`=сжатый, а `receivedBytes`=расжатый → сравнение невалидно.
  final gzipped = contentEncoding != null &&
      contentEncoding.isNotEmpty &&
      contentEncoding != 'identity';
  if (!gzipped &&
      contentLength != null &&
      receivedBytes != null &&
      receivedBytes < contentLength) {
    return MediaDiagClass.truncated;
  }
  // 6. Порча: полный размер, но sha шифртекста не сошёлся.
  if (expectedCiphertextSha != null &&
      actualCiphertextSha != null &&
      expectedCiphertextSha != actualCiphertextSha) {
    return MediaDiagClass.corrupted;
  }
  return MediaDiagClass.unknown;
}

/// Собирает строку `[MediaDiag]` из ALLOWLIST-полей. Секрет попасть не может
/// СТРУКТУРНО: сигнатура не принимает ни ключ расшифровки (`content.file.key.k`),
/// ни `iv`, ни токен — только размеры, статус, заголовки-allowlist и ПУБЛИЧНЫЕ
/// хэши шифртекста. Единственная точка формирования строки (никаких дампов
/// объектов). Классификацию вычисляет [classifyMediaDiag].
String buildMediaDiagLine({
  required String phase,
  required bool wasFromCache,
  required bool initialWasCache,
  String? mxc,
  String? msgtype,
  int? declaredSize,
  int? receivedBytes,
  int? contentLength,
  String? contentEncoding,
  int? statusCode,
  String? contentType,
  String? expectedCiphertextSha,
  String? actualCiphertextSha,
  String? first16,
  String? errorType,
}) {
  final cls = classifyMediaDiag(
    wasFromCache: wasFromCache,
    statusCode: statusCode,
    contentType: contentType,
    msgtype: msgtype,
    contentLength: contentLength,
    receivedBytes: receivedBytes,
    contentEncoding: contentEncoding,
    expectedCiphertextSha: expectedCiphertextSha,
    actualCiphertextSha: actualCiphertextSha,
    errorType: errorType,
  );
  final parts = <String>[
    'class=${cls.name}',
    'phase=$phase',
    'wasFromCache=$wasFromCache',
    'initialWasCache=$initialWasCache',
    if (mxc != null) 'mxc=$mxc',
    if (msgtype != null) 'msgtype=$msgtype',
    if (declaredSize != null) 'declaredSize=$declaredSize',
    if (receivedBytes != null) 'received=$receivedBytes',
    if (contentLength != null) 'contentLength=$contentLength',
    if (contentEncoding != null) 'contentEncoding=$contentEncoding',
    if (statusCode != null) 'status=$statusCode',
    if (contentType != null) 'contentType=$contentType',
    if (expectedCiphertextSha != null) 'expectedSha=$expectedCiphertextSha',
    if (actualCiphertextSha != null) 'actualSha=$actualCiphertextSha',
    if (first16 != null) 'first16=$first16',
    if (errorType != null) 'error=$errorType',
  ];
  return '[MediaDiag] ${parts.join(' ')}';
}

/// sha256 шифртекста в том же формате, что SDK кладёт в событие
/// (`content.file.hashes.sha256` = base64 без паддинга, см.
/// `encrypted_file.dart`) — чтобы `actualSha` был прямо сравним с `expectedSha`.
/// Top-level (не замыкание) — годится для `compute()` на крупных видео.
String sha256B64Unpadded(Uint8List bytes) =>
    base64.encode(crypto.sha256.convert(bytes).bytes).replaceAll('=', '');

/// Первые ≤16 байт в hex (пробел-разделённый). НЕ ASCII-дамп: текст error-page
/// детектим полем `contentType`, а не сырьём тела — чтобы не утащить токен из
/// возможного redirect-URL в теле ошибки.
String mediaDiagFirst16Hex(Uint8List bytes) {
  final n = bytes.length < 16 ? bytes.length : 16;
  return [
    for (var i = 0; i < n; i++) bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join(' ');
}

/// Захваченная HTTP-мета одной попытки загрузки (per-вызов, НЕ static). `bytes`
/// держим ссылкой ТОЛЬКО чтобы посчитать sha/first16 на СБОЕ (на успехе GC
/// освобождает) — sha на happy-path не считаем.
class _MediaDiagMeta {
  bool callbackInvoked = false;
  int? statusCode;
  int? contentLength;
  String? contentType;
  String? contentEncoding;
  int? receivedBytes;
  Uint8List? bytes;
}

extension LocalizedBody on Event {
  /// Скачивает и расшифровывает вложение под прогресс-диалогом. Публичная точка
  /// для всех, кому нужны байты вложения (save/share/copy) — единый прогресс и
  /// одно место правки логики размера.
  Future<async.Result<MatrixFile?>> downloadWithProgress(BuildContext context) =>
      _getFile(context);

  /// Как [downloadAndDecryptAttachment], но с self-heal отравленного дискового
  /// файл-кэша SDK. Во время переезда медиа (2026-07-26) сервер мог кратко
  /// отдать не-тот-контент с кодом 200, и SDK записал его в файл-кэш БЕЗ
  /// валидации; `storeFile` существующий файл не перезаписывает, `clearCache`
  /// файл-стор не трогает → на кэш-хите расшифровка падает навсегда
  /// (sha256-mismatch → голый `throw 'Unable to decrypt file'`), и голосовые/
  /// видео/файлы перестают открываться. Здесь ловим РОВНО эту ошибку и ОДИН раз
  /// за сессию на mxc сбрасываем дисковый файл + перекачиваем свежее (кэш пуст →
  /// download v1 → перезапись → валидный шифртекст → decrypt проходит).
  ///
  /// Аналог self-heal картинок в [MxcImage], но там триггер — magic-байты уже
  /// РАСшифрованного вывода, а тут расшифровка падает раньше байтов, поэтому
  /// сигнал — сам факт decrypt-fail. Все параметры проксируются в ОБА внутренних
  /// вызова (в т.ч. кастомный [downloadCallback] видео-плеера — иначе перекачка
  /// потеряла бы его отдельный http.Client и вернула баг обрыва фоновой загрузки).
  Future<MatrixFile> downloadAndDecryptAttachmentHealed({
    bool getThumbnail = false,
    Future<Uint8List> Function(Uri)? downloadCallback,
    bool fromLocalStoreOnly = false,
    void Function(int)? onDownloadProgress,
  }) async {
    // Заливка упала (`error`), а байты SDK оставил в `sendingFilePlaceholders`
    // (`sendFileEvent` снимает их только на успехе). Сам SDK отдаёт их лишь при
    // `isSending`, на `error` бросает «hasn't any attachment» — хотя файл вот он
    // (#2080, найдено adversarial-verifier). Отдаём байты сами.
    if (!getThumbnail && attachmentMxcUrl == null) {
      final pending = room.sendingFilePlaceholders[eventId];
      if (pending != null) return pending;
    }
    // Инструментовка диагностики (`[MediaDiag]`): оборачиваем эффективный
    // download-callback, чтобы на СБОЕ собрать поля для классификации причины.
    // Для дефолт-пути (аудио/файлы — главный кейс Максима) снимаем полную
    // HTTP-мету сами (SDK наружу response не отдаёт). Для кастомного callback
    // (видео) снимаем принятые байты/длину (без HTTP-заголовков — их видит только
    // сам video-callback). callbackInvoked=false ⇒ кэш-хит (SDK не звал GET).
    final meta = _MediaDiagMeta();
    Future<Uint8List> effective(Uri url) async {
      if (downloadCallback != null) {
        // `callbackInvoked` ДО await: обрыв в потоке кастомного (видео) callback
        // — это сетевой сбой, НЕ кэш-хит. Иначе исключение из downloadCallback
        // оставило бы флаг false → ложная классификация `poisonedCache`.
        meta.callbackInvoked = true;
        final b = await downloadCallback(url);
        meta
          ..receivedBytes = b.length
          ..bytes = b;
        return b;
      }
      return _instrumentedDefaultDownload(url, onDownloadProgress, meta);
    }

    try {
      final result = await downloadAndDecryptAttachment(
        getThumbnail: getThumbnail,
        downloadCallback: effective,
        fromLocalStoreOnly: fromLocalStoreOnly,
        onDownloadProgress: onDownloadProgress,
      );
      // Само-лечение ОТРАВЛЕННОГО кэша (LABA-2361): старые сборки без гейта выше
      // записали error-body сервера как «медиа» (нешифр. → без sha-гейта SDK), и
      // кэш-хит теперь возвращает мусор БЕЗ исключения → немой плеер. Детект по
      // сигнатуре error-body + one-shot перекачка (аналог MxcImage.isPoisoned-
      // ImageCache). На перекачке `effective` пройдёт через гейт: сервер починен
      // → валидное медиа; всё ещё ошибка → MediaDownloadException наружу.
      final mxc = attachmentOrThumbnailMxcUrl(getThumbnail: getThumbnail);
      if (!meta.callbackInvoked && // кэш-хит: SDK не звал сеть
          mxc != null &&
          _isPlayableMediaMsgtype(content.tryGet<String>('msgtype')) &&
          looksLikeMediaErrorBody(result.bytes) &&
          _mediaCachePoisonRetried.add(mxc.toString()) &&
          await room.client.database.deleteFile(mxc)) {
        Logs().i('[Heal] media-cache: перекачал отравленный $mxc');
        return await downloadAndDecryptAttachment(
          getThumbnail: getThumbnail,
          downloadCallback: effective,
          fromLocalStoreOnly: fromLocalStoreOnly,
          onDownloadProgress: onDownloadProgress,
        );
      }
      return result;
    } catch (e) {
      final initialWasCache = !meta.callbackInvoked;
      if (!isHealableDecryptFailure(e)) {
        // Сетевой/иной сбой (не decrypt-fail) — диагностика и проброс.
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'initial',
          initialWasCache: initialWasCache,
          error: e,
        );
        rethrow;
      }
      final mxc = attachmentOrThumbnailMxcUrl(getThumbnail: getThumbnail);
      final key = mxc?.toString();
      if (mxc == null || key == null) {
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'initial',
          initialWasCache: initialWasCache,
          error: e,
        );
        rethrow;
      }
      // One-shot на сессию: упорно-битый на сервере файл не зацикливаем.
      if (!_decryptHealRetried.add(key)) {
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'initial',
          initialWasCache: initialWasCache,
          error: e,
        );
        rethrow;
      }
      // `bool` от deleteFile — и детекция «был отравленный кэш», и гейт ретрая:
      // false → чистить нечего (байты пришли прямо с сервера) → отдаём ошибку
      // как есть, повторная закачка тех же байт не поможет. Так же гейтит ретрай
      // self-heal картинок (mxc_image.dart:249). `isAttachmentInLocalStore` не
      // зовём: её тело перечитывает весь файл с диска (видео = десятки МБ).
      final bool deleted;
      try {
        deleted = await room.client.database.deleteFile(mxc);
      } catch (delErr, s) {
        // Ошибка самого удаления (напр. FS-гонка `file.delete()`) транзиентна:
        // снимаем бюджет, чтобы следующий тап мог полечить, и НЕ маскируем
        // исходную ошибку расшифровки системным исключением — пробрасываем `e`.
        _decryptHealRetried.remove(key);
        Logs().w('[Heal] decrypt-cache: deleteFile($mxc) сорвался', delErr, s);
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'initial',
          initialWasCache: initialWasCache,
          error: e,
        );
        throw e;
      }
      if (!deleted) {
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'initial',
          initialWasCache: initialWasCache,
          error: e,
        );
        rethrow;
      }
      // Кэш пуст → download v1 → перезапись → валидный шифртекст → decrypt. Если
      // сервер и правда отдаёт битое, повторный decrypt-fail улетит наружу, а
      // one-shot (ключ в Set) не даст качать в цикле. `effective` переиспользуем —
      // meta перезаполнится значениями свежей закачки (phase=heal-retry).
      try {
        final healed = await downloadAndDecryptAttachment(
          getThumbnail: getThumbnail,
          downloadCallback: effective,
          fromLocalStoreOnly: fromLocalStoreOnly,
          onDownloadProgress: onDownloadProgress,
        );
        Logs().i('[Heal] decrypt-cache: перекачал отравленный $mxc');
        return healed; // успех self-heal → НИ ОДНОЙ строки [MediaDiag]
      } catch (e2) {
        await _logMediaDiag(
          meta,
          getThumbnail: getThumbnail,
          phase: 'heal-retry',
          initialWasCache: initialWasCache,
          error: e2,
        );
        rethrow;
      }
    }
  }

  /// Дефолт-загрузка вложения с захватом HTTP-меты для диагностики. Копия
  /// SDK-дефолта (`event.dart`: Bearer-GET + стрим), но statusCode/заголовки/
  /// принятые байты сохраняем в [meta] (SDK их наружу не отдаёт). Прогресс ведём
  /// сами, т.к. при переданном downloadCallback SDK свой onDownloadProgress не
  /// применяет. Токен и заголовок Authorization в [meta] НЕ кладём.
  Future<Uint8List> _instrumentedDefaultDownload(
    Uri url,
    void Function(int)? onDownloadProgress,
    _MediaDiagMeta meta,
  ) async {
    meta.callbackInvoked = true;
    final request = http.Request('GET', url);
    final token = room.client.accessToken;
    if (token != null) request.headers['authorization'] = 'Bearer $token';
    final response = await room.client.httpClient.send(request);
    meta
      ..statusCode = response.statusCode
      ..contentLength = response.contentLength
      ..contentType = response.headers['content-type']
      ..contentEncoding = response.headers['content-encoding'];
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      builder.add(chunk);
      onDownloadProgress?.call(builder.length);
    }
    final bytes = builder.toBytes();
    meta
      ..receivedBytes = bytes.length
      ..bytes = bytes;
    // Гейт доставки медиа (LABA-2361): сервер отдал ошибку (HTTP≥400) или
    // error-page (200 c JSON/HTML). Бросаем ЗДЕСЬ, ДО возврата в SDK, поэтому
    // `storeFile` не вызовется — кэш не отравится телом ошибки, а обёртка
    // залогирует `[MediaDiag]`.
    final gate = mediaDownloadGate(
      msgtype: content.tryGet<String>('msgtype'),
      statusCode: meta.statusCode,
      contentType: meta.contentType,
    );
    if (gate != null) throw gate;
    return bytes;
  }

  /// Пишет ОДНУ строку `[MediaDiag]` в лог (файл, который присылает пользователь).
  /// Только на терминальном сбое. sha/first16 считаем ЗДЕСЬ (не на happy-path);
  /// для крупного видео sha — через `compute()`. Читаем из события ТОЛЬКО
  /// публичные поля (`hashes.sha256`, `info.size`, mxc, msgtype) — ключ/iv/токен
  /// не трогаем. Собственные ошибки глотаем: диагностика ничего не ломает.
  Future<void> _logMediaDiag(
    _MediaDiagMeta meta, {
    required bool getThumbnail,
    required String phase,
    required bool initialWasCache,
    required Object error,
  }) async {
    try {
      final mxc = attachmentOrThumbnailMxcUrl(getThumbnail: getThumbnail);
      final info = getThumbnail ? thumbnailInfoMap : infoMap;
      final declaredSize = info['size'] is int ? info['size'] as int : null;
      final expectedSha = content
          .tryGetMap<String, dynamic>('file')
          ?.tryGetMap<String, dynamic>('hashes')
          ?.tryGet<String>('sha256');
      final bytes = meta.bytes;
      String? actualSha;
      String? first16;
      if (bytes != null) {
        actualSha = bytes.length > 2 * 1024 * 1024
            ? await compute(sha256B64Unpadded, bytes)
            : sha256B64Unpadded(bytes);
        first16 = mediaDiagFirst16Hex(bytes);
      }
      final line = buildMediaDiagLine(
        phase: phase,
        wasFromCache: !meta.callbackInvoked,
        initialWasCache: initialWasCache,
        mxc: mxc?.toString(),
        msgtype: content.tryGet<String>('msgtype'),
        declaredSize: declaredSize,
        receivedBytes: meta.receivedBytes,
        contentLength: meta.contentLength,
        contentEncoding: meta.contentEncoding,
        statusCode: meta.statusCode,
        contentType: meta.contentType,
        expectedCiphertextSha: expectedSha,
        actualCiphertextSha: actualSha,
        first16: first16,
        errorType: error is String ? error : error.runtimeType.toString(),
      );
      Logs().w(line);
    } catch (_) {
      // Диагностика не должна ломать воспроизведение/проброс исходной ошибки.
    }
  }

  Future<async.Result<MatrixFile?>> _getFile(BuildContext context) =>
      showFutureLoadingDialog(
        context: context,
        futureWithProgress: (onProgress) {
          final fileSize = infoMap['size'] is int
              ? infoMap['size'] as int
              : null;
          // `size <= 0` (некоторые клиенты шлют 0/некорректный размер) дал бы
          // `bytes / 0` = Infinity/NaN в индикаторе прогресса — тогда прогресс
          // не считаем (индетерминантный диалог).
          return downloadAndDecryptAttachmentHealed(
            onDownloadProgress: fileSize == null || fileSize <= 0
                ? null
                : (bytes) => onProgress(bytes / fileSize),
          );
        },
      );

  void saveFile(BuildContext context) async {
    final matrixFile = await _getFile(context);

    matrixFile.result?.save(context);
  }

  void shareFile(BuildContext context) async {
    final matrixFile = await _getFile(context);
    inspect(matrixFile);

    matrixFile.result?.share(context);
  }

  /// Стабильный уникальный сегмент пути под вложение в temp-каталоге.
  ///
  /// Берётся из mxc-идентификатора вложения (содержимое по mxc неизменяемо,
  /// форварды одного файла делят один mxc — переиспользуют тот же temp-файл),
  /// с откатом на [eventId]. Небезопасные для ФС символы заменяем. Без этого
  /// разные файлы с одинаковым [MatrixFile.name] писались бы по одному пути
  /// `<tmp>/<имя>` и затирали друг друга.
  String get _attachmentTmpKey {
    final url = content['url'] is String
        ? content['url'] as String
        : content.tryGetMap<String, dynamic>('file')?.tryGet<String>('url');
    return (url ?? eventId).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  /// Downloads the file to a temp directory and opens it with the native app.
  /// Falls back to saveFile on web (no temp filesystem).
  void openFile(BuildContext context) async {
    if (kIsWeb) {
      saveFile(context);
      return;
    }
    final matrixFile = await _getFile(context);
    final file = matrixFile.result;
    if (file == null) return;
    final tmpDir = await getTemporaryDirectory();
    final fileName =
        Platform.isIOS ? sanitizeFilenameForIOS(file.name) : file.name;
    // basename отрезает любой path-traversal из имени, пришедшего от отправителя
    // (`../../foo` или абсолютный путь иначе вывели бы запись за пределы temp).
    final safeName = p.basename(fileName);
    final dir = Directory(p.join(tmpDir.path, 'attachments', _attachmentTmpKey));
    await dir.create(recursive: true);
    final tmpFile = File(p.join(dir.path, safeName));
    await tmpFile.writeAsBytes(file.bytes);
    if (Platform.isMacOS) {
      // open_app_file uses `sh -c 'open <path>'` which breaks on special chars.
      // Process.run passes the path as a direct argument — no shell involved.
      await Process.run('open', [tmpFile.path]);
    } else {
      await OpenAppFile.open(tmpFile.path);
    }
  }

  bool get isAttachmentSmallEnough =>
      infoMap['size'] is int &&
      infoMap['size'] < room.client.database.maxFileSize;

  bool get isThumbnailSmallEnough =>
      thumbnailInfoMap['size'] is int &&
      thumbnailInfoMap['size'] < room.client.database.maxFileSize;

  bool get showThumbnail =>
      [
        MessageTypes.Image,
        MessageTypes.Sticker,
        MessageTypes.Video,
      ].contains(messageType) &&
      (kIsWeb ||
          isAttachmentSmallEnough ||
          isThumbnailSmallEnough ||
          (content['url'] is String));

  String? get sizeString => content
      .tryGetMap<String, dynamic>('info')
      ?.tryGet<int>('size')
      ?.sizeString;
}
