import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image/image.dart' as img;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/compress_image.dart';
import 'package:liza/utils/xfile_mime.dart';

/// GIF в Liza: отправка оригиналом и проигрывание в ленте (заявка №43,
/// спека `docs/superpowers/specs/2026-09-25-gif-animated-send-and-inline-design.md`).
///
/// JPEG-сжатие фото и SDK-shrink убивают анимацию безвозвратно — GIF уходит
/// байт-в-байт. Превью первого кадра строим сами: без него SDK зовёт
/// `generateThumbnail`, а пакет `image` декодирует ВСЕ кадры GIF и кодирует
/// анимированное превью на чистом Dart (на Web — worker с таймаутом 1 мин).

/// Лента грузит оригинал GIF только в этих пределах — дальше превью + бейдж.
const int kInlineGifMaxBytes = 8 * 1024 * 1024;
const int kInlineGifMaxPixels = 4000000;

/// Длинная сторона превью — как у SDK (`Client.defaultThumbnailSize`).
const int kGifThumbnailMaxDimension = 800;

bool isGifMimeOrName(String? mimeType, String? name) =>
    mimeType?.toLowerCase() == 'image/gif' ||
    (name?.toLowerCase().endsWith('.gif') ?? false);

/// У `XFile.fromData` без `path` на io пустое `name` — смотрим и `path`.
bool isGifXFile(XFile file) =>
    isGifMimeOrName(resolveXFileMime(file), file.name) ||
    isGifMimeOrName(null, file.path);

/// SDK-shrink (Win/Linux) перекодировал бы GIF в один кадр.
int? shrinkImageMaxDimensionFor({required bool isGif, required int? batch}) =>
    isGif ? null : batch;

/// Событие-картинка с GIF (стикеры не в счёт — у них своя логика).
bool isGifImageEvent(Event event) {
  if (event.messageType != MessageTypes.Image) return false;
  final name = event.content.tryGet<String>('filename') ?? event.body;
  final mimeType = event.infoMap['mimetype'];
  return isGifMimeOrName(mimeType is String ? mimeType : null, name);
}

/// Играть ли GIF прямо в ленте (грузить оригинал вместо превью).
///
/// Без `info.size` оригинал не грузим: вес неизвестен, а в ленте таких
/// пузырей может быть много.
bool shouldAnimateGifInline(Event event, {required bool autoplay}) {
  if (!autoplay || !isGifImageEvent(event)) return false;
  final info = event.infoMap;
  final size = info['size'];
  if (size is! int || size > kInlineGifMaxBytes) return false;
  final w = info['w'];
  final h = info['h'];
  if (w is int && h is int && w * h > kInlineGifMaxPixels) return false;
  return true;
}

/// Готовит GIF к отправке: оригинал + статичное превью первого кадра.
///
/// Любой сбой декода — отправка оригинала без превью (размеры неизвестны),
/// а не отказ отправки.
Future<({MatrixImageFile file, MatrixImageFile? thumbnail})>
prepareGifForSending(Uint8List bytes, {required String name}) async {
  int? width;
  int? height;
  MatrixImageFile? thumbnail;
  try {
    final size = await _firstFrameSize(bytes);
    width = size.width;
    height = size.height;
    thumbnail = await _firstFrameThumbnail(bytes, name, size);
  } catch (e, s) {
    Logs().w('GIF: не удалось построить превью для "$name"', e, s);
  }
  return (
    file: MatrixImageFile(
      bytes: bytes,
      name: name,
      mimeType: 'image/gif',
      width: width,
      height: height,
      blurhash: thumbnail?.blurhash,
    ),
    thumbnail: thumbnail,
  );
}

Future<({int width, int height})> _firstFrameSize(Uint8List bytes) async {
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

({int width, int height}) _fit(int w, int h, int maxDimension) {
  final longest = w > h ? w : h;
  if (longest <= maxDimension) return (width: w, height: h);
  final scale = maxDimension / longest;
  final tw = (w * scale).round();
  final th = (h * scale).round();
  return (width: tw < 1 ? 1 : tw, height: th < 1 ? 1 : th);
}

Future<ui.Image> _firstFrame(Uint8List bytes, int width, int height) async {
  final codec = await ui.instantiateImageCodec(
    bytes,
    targetWidth: width,
    targetHeight: height,
  );
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}

Future<MatrixImageFile?> _firstFrameThumbnail(
  Uint8List bytes,
  String name,
  ({int width, int height}) src,
) async {
  final target = _fit(src.width, src.height, kGifThumbnailMaxDimension);
  final frame = await _firstFrame(bytes, target.width, target.height);
  final ByteData? png;
  try {
    png = await frame.toByteData(format: ui.ImageByteFormat.png);
  } finally {
    frame.dispose();
  }
  if (png == null) return null;
  var thumbBytes = png.buffer.asUint8List();
  var mimeType = 'image/png';
  if (imageCompressionSupported) {
    try {
      final jpeg = await FlutterImageCompress.compressWithList(
        thumbBytes,
        minWidth: target.width,
        minHeight: target.height,
        quality: kSendImageJpegQuality,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (jpeg.isNotEmpty && jpeg.length < thumbBytes.length) {
        thumbBytes = jpeg;
        mimeType = 'image/jpeg';
      }
    } catch (e) {
      Logs().d('GIF: превью остаётся PNG', e);
    }
  }
  final base = name.toLowerCase().endsWith('.gif')
      ? name.substring(0, name.length - 4)
      : name;
  return MatrixImageFile(
    bytes: thumbBytes,
    name:
        '${base.isEmpty ? 'image' : base}.${mimeType == 'image/jpeg' ? 'jpg' : 'png'}',
    mimeType: mimeType,
    width: target.width,
    height: target.height,
    blurhash: await _blurhash(bytes, src),
  );
}

Future<String?> _blurhash(
  Uint8List bytes,
  ({int width, int height}) src,
) async {
  final tiny = _fit(src.width, src.height, 32);
  final frame = await _firstFrame(bytes, tiny.width, tiny.height);
  try {
    final rgba = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (rgba == null) return null;
    final image = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: rgba.buffer,
      numChannels: 4,
    );
    return BlurHash.encode(image, numCompX: 4, numCompY: 3).hash;
  } finally {
    frame.dispose();
  }
}
