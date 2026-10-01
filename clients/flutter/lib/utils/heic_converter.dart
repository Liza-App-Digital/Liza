import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/xfile_mime.dart';

/// Совпадает ли MIME с одним из вариантов HEIC/HEIF (включая sequence).
bool isHeicMimeType(String? mimeType) {
  if (mimeType == null) return false;
  final lower = mimeType.toLowerCase();
  return lower == 'image/heic' ||
      lower == 'image/heif' ||
      lower == 'image/heic-sequence' ||
      lower == 'image/heif-sequence';
}

/// Расширение файла указывает на HEIC/HEIF.
bool isHeicFile(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.heic') || lower.endsWith('.heif');
}

/// HEIC-декодеры есть только в iOS/Android/macOS системных API
/// (ImageIO/MediaCodec, через flutter_image_compress). На Linux/Windows/Web
/// Skia HEIC не понимает — там конверсия пропускается.
bool get _heicConversionSupported {
  if (kIsWeb) return false;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return false;
  }
}

const _jpegQuality = 85;

/// Конвертирует HEIC/HEIF в JPEG quality 85 через системные API.
/// Возвращает `null`, если платформа не поддерживает HEIC или конверсия
/// упала — caller должен отправить оригинал.
Future<XFile?> convertHeicToJpeg(XFile xfile) async {
  if (!_heicConversionSupported) {
    Logs().w(
      'HEIC conversion is not supported on $defaultTargetPlatform — '
      'sending "${xfile.name}" as-is',
    );
    return null;
  }
  try {
    final bytes = await xfile.readAsBytes();
    final jpeg = await FlutterImageCompress.compressWithList(
      bytes,
      quality: _jpegQuality,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (jpeg.isEmpty) {
      Logs().w(
        'flutter_image_compress returned empty bytes for "${xfile.name}"',
      );
      return null;
    }
    final newName = xfile.name.replaceAll(
      RegExp(r'\.(heic|heif)$', caseSensitive: false),
      '.jpg',
    );
    Logs().i(
      'Converted HEIC "${xfile.name}" → "$newName" '
      '(${bytes.length} → ${jpeg.length} bytes, q=$_jpegQuality)',
    );
    // На dart:io реализации cross_file именованный параметр `name`
    // игнорируется (баг/дизайн пакета) — basename берётся из `path`.
    // Поэтому имя пробрасываем через path, иначе MatrixImageFile получит
    // пустое name и matrix-dart-sdk упадёт в санитизации.
    return XFile.fromData(
      Uint8List.fromList(jpeg),
      name: newName,
      path: newName,
      mimeType: 'image/jpeg',
    );
  } catch (e, s) {
    Logs().w('Failed to convert HEIC "${xfile.name}" to JPEG', e, s);
    return null;
  }
}

/// Конвертирует HEIC/HEIF файлы в JPEG, остальные пропускает.
/// Если конверсия не удалась — оставляет файл как есть; сервер должен
/// разрешить `image/heic` в `allowed_media_types`, иначе будет 403.
Future<List<XFile>> convertHeicFiles(List<XFile> files) async {
  final result = <XFile>[];
  for (final file in files) {
    final mimeType = resolveXFileMime(file);
    if (isHeicMimeType(mimeType) || isHeicFile(file.name)) {
      final converted = await convertHeicToJpeg(file);
      result.add(converted ?? file);
    } else {
      result.add(file);
    }
  }
  return result;
}
