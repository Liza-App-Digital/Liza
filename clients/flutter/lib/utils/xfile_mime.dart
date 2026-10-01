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
