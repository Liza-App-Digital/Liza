import 'package:cross_file/cross_file.dart';
import 'package:mime/mime.dart';

/// MIME файла, выбранного для отправки, — ЕДИНЫЙ резолвер для диалога
/// отправки, сжатия, HEIC и GIF (LABA-2620).
///
/// Порядок: непустой `mimeType` → расширение `name` → расширение `path`.
/// `name` раньше `path` из-за Web: `file_picker` отдаёт
/// `XFile.fromData(bytes, name:)` без `mimeType`, а `path` у такого файла —
/// `blob:`-URL без расширения. Смотрели на `path` — получали `null`, набор
/// «не медиа» и подпись в каждом файле, хотя UI (он смотрел на `name`)
/// рисовал альбом. На io `name` — basename `path`, так что там результат
/// прежний. Пустая строка = нет MIME: иначе `''` проходит `??` и глушит
/// фолбэки.
String? resolveXFileMime(XFile file) {
  final declared = file.mimeType;
  if (declared != null && declared.isNotEmpty) return declared;
  return lookupMimeType(file.name) ?? lookupMimeType(file.path);
}

bool isMediaMime(String? mime) =>
    mime != null && (mime.startsWith('image/') || mime.startsWith('video/'));

/// Набор уходит альбомом (`com.liza.gallery`, одна подпись): ≥2 файла, и все
/// — изображения/видео. Одна функция и для UI диалога, и для отправки —
/// расхождение этих двух решений и дало LABA-2620.
bool isMediaAlbum(List<XFile> files) =>
    files.length >= 2 && files.every((f) => isMediaMime(resolveXFileMime(f)));

/// MIME ВИДЕО для `MatrixVideoFile` при отправке (заявка №52).
///
/// Без явного типа SDK сниффит заголовок: в `package:mime` сигнатура EBML
/// (`1A 45 DF A3`, общая у WebM и MKV) записана как `audio/weba` и бьёт
/// расширение. Так любой WebM с Android, где у `XFile` нет `mimeType`, уходил
/// в событие как аудио. Звать ТОЛЬКО для видео: `audio/*` здесь переписывается.
///
/// [transcoded] — байты от `video_compress` (всегда mp4), а имя и заявленный
/// тип остались от исходника: верить можно только содержимому.
String resolveVideoSendMime({
  required String? declared,
  required String name,
  required List<int> bytes,
  required bool transcoded,
}) {
  final String? found;
  if (transcoded) {
    found = lookupMimeType('', headerBytes: bytes) ?? 'video/mp4';
  } else if (declared != null && declared.isNotEmpty) {
    found = declared;
  } else {
    found = lookupMimeType(name) ?? lookupMimeType('', headerBytes: bytes);
  }
  if (found == 'audio/weba' || found == 'audio/webm') return 'video/webm';
  return found ?? 'video/mp4';
}
