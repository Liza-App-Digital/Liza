import 'dart:math' show min;
import 'dart:typed_data';
import 'dart:ui';

import 'package:matrix/matrix.dart';

/// Похоже ли тело ответа на настоящую картинку (по magic-байтам).
///
/// Зачем: `downloadMxcCached` может получить `200 OK`, но с телом, которое НЕ
/// является картинкой — например JSON-ошибку матрикса (`{"errcode":...}`),
/// HTML-страницу прокси или обрезанный ответ. Если такое тело закэшировать и
/// потом отдать в `Image.memory`, декодер падает с «Invalid image data», и
/// превью залипает битым НАВСЕГДА (кэш не перепроверяется). Так и случилось у
/// части клиентов во время переезда медиа на MMR (2026-07): в кэш попали
/// не-картинки, и «ранее загруженные» изображения перестали отображаться.
///
/// Проверяем позитивно (это одна из известных картинок), а не «не-ошибка»:
/// ловит и текстовые тела-ошибки, и бинарный мусор/обрезки. Liza отправляет
/// только JPEG/PNG/GIF/WebP/HEIC — все покрыты.
bool looksLikeCacheableImage(Uint8List d) {
  if (d.length < 12) return false;
  // JPEG: FF D8 FF
  if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return true;
  // PNG: 89 50 4E 47
  if (d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) return true;
  // GIF: "GIF"
  if (d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46) return true;
  // BMP: "BM"
  if (d[0] == 0x42 && d[1] == 0x4D) return true;
  // WebP: "RIFF"????"WEBP"
  if (d[0] == 0x52 &&
      d[1] == 0x49 &&
      d[2] == 0x46 &&
      d[3] == 0x46 &&
      d[8] == 0x57 &&
      d[9] == 0x45 &&
      d[10] == 0x42 &&
      d[11] == 0x50) {
    return true;
  }
  // ISOBMFF ftyp (HEIC/HEIF/AVIF): байты 4..7 == "ftyp"
  if (d[4] == 0x66 && d[5] == 0x74 && d[6] == 0x79 && d[7] == 0x70) return true;
  return false;
}

extension ClientDownloadContentExtension on Client {
  Future<Uint8List> downloadMxcCached(
    Uri mxc, {
    num? width,
    num? height,
    bool isThumbnail = false,
    bool? animated,
    ThumbnailMethod? thumbnailMethod,
    bool rounded = false,
  }) async {
    // To stay compatible with previous storeKeys:
    final legacyCacheKey = isThumbnail
        // ignore: deprecated_member_use
        ? mxc.getThumbnail(
            this,
            width: width,
            height: height,
            animated: animated,
            method: thumbnailMethod!,
          )
        : mxc;

    // Старые crop-записи могли содержать уменьшенный круг для уведомления.
    // Новый ЛОКАЛЬНЫЙ ключ хранит только серверные байты. HTTP URI не меняем;
    // fragment здесь не подходит — файловый кэш SDK его игнорирует.
    final cacheKey = isThumbnail && thumbnailMethod == ThumbnailMethod.crop
        ? legacyCacheKey.replace(
            queryParameters: {
              ...legacyCacheKey.queryParameters,
              'liza_raw': '2',
            },
          )
        : legacyCacheKey;

    final cachedData = await database.getFile(cacheKey);
    // Отдаём из кэша ТОЛЬКО если там настоящая картинка. Если в кэше осел
    // не-картинка (тело-ошибка, закэшенное как 200 во время переезда медиа) —
    // игнорируем кэш и перекачиваем свежим запросом (self-heal: битые «ранее
    // загруженные» превью сами чинятся при следующем показе).
    if (cachedData != null && looksLikeCacheableImage(cachedData)) {
      return rounded
          ? _convertToCircularImage(
              cachedData,
              min(width ?? 64, height ?? 64).round(),
            )
          : cachedData;
    }

    final httpUri = isThumbnail
        ? await mxc.getThumbnailUri(
            this,
            width: width,
            height: height,
            animated: animated,
            method: thumbnailMethod,
          )
        : await mxc.getDownloadUri(this);

    final headers = accessToken == null
        ? null
        : {'authorization': 'Bearer $accessToken'};
    var requestUri = httpUri;
    var response = await httpClient.get(requestUri, headers: headers);
    // 400 на /thumbnail — сервер не может отдать превью, хотя оригинал цел:
    // Synapse без dynamic_thumbnails генерирует превью один раз при загрузке, и
    // если процесс упал в этот момент, превью нет навсегда (GlitchTip #2111,
    // сегфолт d3n8it 14.10). Ретраи бьют в тот же 400 → вечный спиннер и
    // give-up, поэтому сразу берём оригинал.
    if (isThumbnail && response.statusCode == 400) {
      requestUri = await mxc.getDownloadUri(this);
      response = await httpClient.get(requestUri, headers: headers);
    }
    if (response.statusCode != 200) {
      throw Exception('Failed to download $requestUri: ${response.statusCode}');
    }
    final imageData = response.bodyBytes;

    // 200, но тело — не картинка (ошибка/HTML/обрезок). НЕ кэшируем мусор
    // (иначе «Invalid image data» залипнет в кэше), отдаём как есть — виджет
    // покажет placeholder через errorBuilder, а следующий показ повторит запрос.
    final isImage = looksLikeCacheableImage(imageData);
    if (!isImage) {
      return imageData;
    }

    // Декодирование для уведомления может отклонить усечённую картинку с
    // валидным magic. Сначала убеждаемся, что результат получен, иначе такой
    // ответ закрепился бы на диске и все следующие попытки обходили бы сеть.
    final result = rounded
        ? await _convertToCircularImage(
            imageData,
            min(width ?? 64, height ?? 64).round(),
          )
        : imageData;
    await database.storeFile(cacheKey, imageData, 0);
    return result;
  }
}

Future<Uint8List> _convertToCircularImage(
  Uint8List imageBytes,
  int size,
) async {
  final codec = await instantiateImageCodec(imageBytes);
  try {
    final frame = await codec.getNextFrame();
    final originalImage = frame.image;
    try {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);

      final paint = Paint();
      final rect = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());

      final clipPath = Path()
        ..addOval(
          Rect.fromCircle(center: Offset(size / 2, size / 2), radius: size / 2),
        );

      canvas.clipPath(clipPath);

      canvas.drawImageRect(
        originalImage,
        Rect.fromLTWH(
          0,
          0,
          originalImage.width.toDouble(),
          originalImage.height.toDouble(),
        ),
        rect,
        paint,
      );

      final picture = recorder.endRecording();
      try {
        final circularImage = await picture.toImage(size, size);
        try {
          final byteData = await circularImage.toByteData(
            format: ImageByteFormat.png,
          );
          return byteData!.buffer.asUint8List();
        } finally {
          circularImage.dispose();
        }
      } finally {
        picture.dispose();
      }
    } finally {
      originalImage.dispose();
    }
  } finally {
    codec.dispose();
  }
}
