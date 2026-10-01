import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:matrix/matrix.dart';
import 'package:liza/utils/animated_gif.dart';
import 'package:liza/utils/xfile_mime.dart';

/// Сжатие изображений перед отправкой — уровень по стандартам Liza/WhatsApp.
///
/// Liza/WhatsApp при отправке фото «как изображение» ужимают самую
/// длинную сторону до ~1280 px и перекодируют в JPEG q≈80. Это даёт
/// многократную экономию трафика при визуально неотличимом качестве
/// в ленте чата. Если нужен оригинал — пользователь шлёт через «Файл».
///
/// `flutter_image_compress` (нативные ImageIO/MediaCodec/Canvas, MIT, уже
/// в pubspec — задействован в HEIC-конвертере) покрывает iOS/Android/macOS/Web.
/// На Windows/Linux нативного декодера нет — там сжатие пропускается,
/// а уменьшение размера делает matrix-SDK через `shrinkImageMaxDimension`.
///
/// **Важно про `flutter_image_compress`.** Его `minWidth`/`minHeight` — это
/// *нижняя* граница: плагин масштабирует так, что результат не меньше этих
/// значений по обеим сторонам (`scale = max(minW/w, minH/h)`, не больше 1).
/// При равных `minWidth == minHeight` это клампит **короткую** сторону —
/// длинная остаётся больше, и фото выходит примерно вдвое тяжелее
/// задуманного. Поэтому целевой прямоугольник считаем сами
/// ([sendImageTargetSize]) и передаём плагину уже готовые размеры.
const int kSendImageMaxDimension = 1280;
const int kSendImageJpegQuality = 80;

/// Картинки мельче этого порога перекодировать смысла нет.
const int _minSizeToCompress = 20 * 1000;

/// Поддерживает ли текущая платформа сжатие изображений через
/// `flutter_image_compress`. На Windows/Linux — нет (нет нативных API).
bool get imageCompressionSupported {
  if (kIsWeb) return true;
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.android:
    case TargetPlatform.macOS:
      return true;
    case TargetPlatform.windows:
    case TargetPlatform.linux:
    case TargetPlatform.fuchsia:
      return false;
  }
}

bool _isImage(XFile file) {
  final mime = resolveXFileMime(file);
  return mime != null && mime.startsWith('image/');
}

/// Целевые размеры кадра так, чтобы **длинная** сторона стала ровно
/// [kSendImageMaxDimension], а короткая — пропорционально. Если по длинной
/// стороне изображение уже не больше порога — возвращает исходные размеры
/// (апскейл не делаем).
({int width, int height}) sendImageTargetSize(int srcWidth, int srcHeight) {
  final longest = srcWidth > srcHeight ? srcWidth : srcHeight;
  if (longest <= kSendImageMaxDimension) {
    return (width: srcWidth, height: srcHeight);
  }
  final scale = kSendImageMaxDimension / longest;
  final w = (srcWidth * scale).round();
  final h = (srcHeight * scale).round();
  return (width: w < 1 ? 1 : w, height: h < 1 ? 1 : h);
}

/// Размеры изображения с учётом EXIF-ориентации — как его увидит
/// пользователь. Нативное декодирование `dart:ui` само применяет
/// EXIF-поворот, поэтому ширина/высота — в «экранной» ориентации, той же,
/// в которой `flutter_image_compress` отдаёт результат.
Future<({int width, int height})> _displayImageSize(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    final size = (width: frame.image.width, height: frame.image.height);
    frame.image.dispose();
    return size;
  } finally {
    codec.dispose();
  }
}

/// Сжимает одно изображение: длинная сторона → [kSendImageMaxDimension],
/// перекодировка в JPEG [kSendImageJpegQuality]. Возвращает исходный файл
/// без изменений, если платформа без поддержки, файл уже мелкий, это не
/// изображение, либо перекодировка упала / раздула файл.
Future<XFile> compressImageForSending(XFile file) async {
  if (!imageCompressionSupported || !_isImage(file)) return file;
  try {
    final bytes = await file.readAsBytes();
    if (bytes.length < _minSizeToCompress) return file;

    // Целевой прямоугольник считаем сами (см. doc-комментарий к
    // kSendImageMaxDimension): minWidth/minHeight у flutter_image_compress —
    // нижняя граница, равные значения клампят короткую сторону. Берём
    // EXIF-исправленные размеры и приводим длинную сторону к порогу.
    // autoCorrectionAngle (по умолчанию) запекает EXIF-поворот в пиксели,
    // поэтому keepExif: false здесь безопасен.
    final src = await _displayImageSize(bytes);
    final target = sendImageTargetSize(src.width, src.height);

    final compressed = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: target.width,
      minHeight: target.height,
      quality: kSendImageJpegQuality,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    // Перекодировка в JPEG иногда раздувает уже-оптимальный файл —
    // в этом случае отправляем оригинал.
    if (compressed.isEmpty || compressed.length >= bytes.length) return file;
    final newName = _toJpegName(file.name);
    Logs().i(
      'Compressed image "${file.name}" → "$newName" '
      '(${bytes.length}B ${src.width}×${src.height} → '
      '${compressed.length}B ${target.width}×${target.height}, '
      'q=$kSendImageJpegQuality)',
    );
    // На dart:io реализации cross_file именованный `name` игнорируется —
    // basename берётся из `path`. Дублируем имя в оба параметра (как в
    // heic_converter.dart), иначе MatrixImageFile получит пустое имя.
    return XFile.fromData(
      Uint8List.fromList(compressed),
      name: newName,
      path: newName,
      mimeType: 'image/jpeg',
    );
  } catch (e, s) {
    Logs().w('Image compression failed for "${file.name}"', e, s);
    return file;
  }
}

/// Сжимает изображения из списка, остальные файлы пропускает без изменений.
/// GIF не трогаем: JPEG-перекодировка убивает анимацию безвозвратно
/// (заявка №43). Обход — здесь, а не в [compressImageForSending]: её же
/// зовут сторис, где GIF публикуется статичным кадром.
Future<List<XFile>> compressImagesForSending(
  List<XFile> files, {
  @visibleForTesting
  Future<XFile> Function(XFile) compress = compressImageForSending,
}) => Future.wait(
  files.map(
    (f) => isGifXFile(f)
        ? Future.value(f)
        : compress(f),
  ),
);

String _toJpegName(String name) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : (dot == 0 ? '' : name);
  // Пустой base (имя было пустым или вида «.png») иначе дал бы «.jpg» —
  // это dotfile без base, у получателя пустое поле «Сохранить как».
  return base.isEmpty ? 'image.jpg' : '$base.jpg';
}
