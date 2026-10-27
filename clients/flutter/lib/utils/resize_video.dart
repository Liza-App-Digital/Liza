import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:cross_file/cross_file.dart';
import 'package:matrix/matrix.dart';
import 'package:video_compress/video_compress.dart';

import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/xfile_mime.dart';

/// Таймаут на ЛЮБОЙ нативный вызов извлечения кадра.
///
/// Не «на всякий случай»: iOS-половина плагина структурно способна не ответить
/// вовсе. `SwiftVideoCompressPlugin.getByteThumbnail` — это
/// `if let bitmap = getBitMap(...) { result(bitmap) }` БЕЗ ветки `else`, то есть
/// при неудачном кадре `FlutterResult` не вызывается никогда, и Future
/// метод-канала не завершается ни успехом, ни ошибкой. Без таймаута весь
/// `_send()` вис навсегда: видео не уходило, ошибки не было, экран пустой.
const videoThumbnailTimeout = Duration(seconds: 5);

/// Позиция ПОВТОРНОЙ попытки извлечь кадр — в единицах КОНКРЕТНОЙ платформы.
///
/// Единица аргумента `position` у `VideoCompress.getByteThumbnail` разная на
/// платформах, а dartdoc плагина («position is milliseconds») врёт на обеих:
/// - **Android** — микросекунды: `getFrameAtTime(position, OPTION_CLOSEST_SYNC)`
///   (`android/.../Utility.kt`);
/// - **iOS** — секунды: `CMTimeMakeWithSeconds(Float64(position))`
///   (`ios/Classes/SwiftVideoCompressPlugin.swift`).
///
/// Прежний литерал `1000` с комментарием «повтор на ~1с» не работал НИ НА ОДНОЙ:
/// на Android это 1 мс (`OPTION_CLOSEST_SYNC` снапит на тот же keyframe, что и
/// позиция 0 — повтор впустую), на iOS — 1000 СЕКУНД, то есть за концом почти
/// любого ролика → `copyCGImage` = nil → плагин не отвечает → вечный хэнг.
int videoThumbnailRetryPositionFor(TargetPlatform platform) =>
    platform == TargetPlatform.iOS ? 1 : 1000000;

/// `true`, если тик прогресса компрессии — «стухший» хвост ПРЕДЫДУЩЕГО вызова.
///
/// `VideoCompress.compressProgress$` построен на НЕ-broadcast
/// `StreamController`: события, пришедшие пока подписчика нет, буферизуются и
/// вываливаются первому же `listen` одним залпом. Последнее значение любого
/// завершившегося транскода — ровно `100.00`
/// (`VideoCompressPlugin.onTranscodeCompleted`), а СВОЯ компрессия всегда
/// начинается со значения < 100. Значит 100 ДО первого реального тика — чужое.
///
/// Наблюдаемый эффект без фильтра: снекбар «Сжатие видео… 100%» через 0.2 с
/// после тапа «Прислать», когда не сделано ещё ничего.
bool isStaleCompressTick({
  required bool sawRealTick,
  required double percent,
}) => !sawRealTick && percent >= 100;

/// Оборачивает ОДИН нативный заход за кадром в обязательный таймаут и глушит
/// исключения: провал постера — это деградация (шлём без него), а не отказ
/// отправки.
///
/// Вынесено отдельной функцией намеренно: сам [ResizeVideo.getVideoThumbnail]
/// гейтится `PlatformInfos.isMobile` (через `dart:io`) и на host-тесте не
/// исполняется, а защищать стражем надо именно инвариант «ни один заход за
/// кадром не остаётся без таймаута» — иначе он снова тихо исчезнет.
Future<Uint8List?> videoThumbnailFrameGuarded(
  Future<Uint8List?> Function() fetch, {
  Duration timeout = videoThumbnailTimeout,
}) async {
  try {
    // `.then<Uint8List?>` обязателен ПЕРЕД `.timeout`: `Future.timeout`
    // диспатчится по РАНТАЙМ-типу фьючера, а плагин отдаёт `Future<Uint8List>`
    // — тогда `onTimeout: () => null` падает
    // «() => Null is not a subtype of () => FutureOr<Uint8List>», обёртка
    // уходит в catch и глушит ЛЮБОЙ, даже успешный кадр. Перенаведение типа
    // создаёт настоящий `_Future<Uint8List?>`.
    return await fetch()
        .then<Uint8List?>((bytes) => bytes)
        .timeout(timeout, onTimeout: () => null);
  } catch (e, s) {
    Logs().w('Video thumbnail: заход за кадром не удался', e, s);
    return null;
  }
}

/// true, если байты — валидная, декодируемая нативным кодеком картинка.
/// Битый/усечённый (но непустой) JPEG иначе улетел бы в `info.thumbnail_url`
/// и у получателя/отправителя превратился бы в «битую картинку»
/// (`broken_image`, см. `mxc_image.dart`). Используется как гейт постера
/// видео перед заливкой.
Future<bool> videoThumbnailBytesDecode(Uint8List? bytes) async {
  if (bytes == null || bytes.isEmpty) return false;
  try {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    final ok = frame.image.width > 0 && frame.image.height > 0;
    frame.image.dispose();
    codec.dispose();
    return ok;
  } catch (_) {
    return false;
  }
}

extension ResizeVideo on XFile {
  /// Считывает метаданные (и при необходимости перекодирует) видео-файл
  /// в формат, пригодный для отправки в Matrix.
  ///
  /// При `compress = true` на mobile запускается нативная перекодировка
  /// через `video_compress` (AVAssetExportSession на iOS, MediaCodec на
  /// Android) до 720p — уровень, сопоставимый со сжатием видео при отправке
  /// в Liza/WhatsApp. На desktop/Web `video_compress` нет: видео уходит
  /// оригиналом (см. `send_file_dialog.dart`).
  /// `onProgress` подписывается на `VideoCompress.compressProgress$`
  /// и вызывается значениями 0..100.
  Future<MatrixVideoFile> getVideoInfo({
    bool compress = true,
    void Function(double progressPercent)? onProgress,

    /// Путь файла-РЕЗУЛЬТАТА транскода (только mobile + `compress == true`).
    /// Отдаётся колбэком, а не в возвращаемом значении, чтобы не менять тип
    /// `MatrixVideoFile`, который ждут оба вызывающих. Нужен для постера: кадр
    /// надёжнее брать из 720p H.264, а не из исходника — см.
    /// [ResizeVideo.getVideoThumbnail].
    void Function(String outputPath)? onOutputPath,
  }) async {
    MediaInfo? mediaInfo;
    Subscription? sub;
    try {
      if (PlatformInfos.isMobile) {
        // Подписываемся ВСЕГДА, даже когда onProgress не нужен. Иначе вызов без
        // подписчика (публикация сториса — `story_video_picker.dart`) копит в
        // не-broadcast StreamController'е весь ряд 0…100, и СЛЕДУЮЩАЯ отправка
        // видео в чат получает этот хвост первым залпом. Пустая подписка
        // осушает буфер, не показывая чужой прогресс.
        var sawRealTick = false;
        sub = VideoCompress.compressProgress$.subscribe((percent) {
          if (isStaleCompressTick(sawRealTick: sawRealTick, percent: percent)) {
            return;
          }
          sawRealTick = true;
          onProgress?.call(percent);
        });
        // Даём буферу вылиться ДО старта своей компрессии: события стрима
        // доставляются микротасками, а `Duration.zero` — таймер, он сработает
        // после того как микротаск-очередь опустеет.
        await Future.delayed(Duration.zero);
        // will throw an error e.g. on Android SDK < 18
        mediaInfo = compress
            ? await VideoCompress.compressVideo(
                path,
                deleteOrigin: true,
                quality: VideoQuality.Res1280x720Quality,
              )
            : await VideoCompress.getMediaInfo(path);
      }
    } catch (e, s) {
      Logs().w('Error while fetching video media info', e, s);
    } finally {
      sub?.unsubscribe();
    }

    final outputPath = mediaInfo?.file?.path;
    if (outputPath != null) onOutputPath?.call(outputPath);

    // На Android width и height возвращаются перевёрнутыми для portrait-видео:
    // https://github.com/jonataslaw/VideoCompress/issues/172
    // Workaround применяем для обоих веток (с компрессией и без), потому что
    // источник перепутывания — нативный API, а не сама компрессия.
    final swap = PlatformInfos.isAndroid;
    final transcoded = compress && mediaInfo?.file != null;
    final bytes = (await mediaInfo?.file?.readAsBytes()) ?? await readAsBytes();
    return MatrixVideoFile(
      bytes: bytes,
      name: name,
      mimeType: resolveVideoSendMime(
        declared: mimeType,
        name: name,
        bytes: bytes,
        transcoded: transcoded,
      ),
      width: swap ? mediaInfo?.height : mediaInfo?.width,
      height: swap ? mediaInfo?.width : mediaInfo?.height,
      duration: mediaInfo?.duration?.round(),
    );
  }

  /// Один нативный заход за кадром — ОБЯЗАТЕЛЬНО под таймаутом.
  /// Причина таймаута — не перестраховка, см. [videoThumbnailTimeout].
  Future<Uint8List?> _frameAt(String sourcePath, int position) =>
      videoThumbnailFrameGuarded(
        () => VideoCompress.getByteThumbnail(sourcePath, position: position),
      );

  /// Постер видео для `info.thumbnail_url`.
  ///
  /// [sourcePath] — откуда брать кадр; по умолчанию сам файл. При отправке с
  /// mobile-сжатием сюда передаётся **путь сжатого выхода**: 720p H.264 из
  /// MediaCodec декодируется `MediaMetadataRetriever` всегда, тогда как
  /// исходник с камеры (HEVC/HDR10+, Samsung S24) — нет: `getFrameAtTime`
  /// отдаёт null, плагин отвечает пустым массивом, и в логе появляется `len=0`
  /// (наблюдалось 3 раза из 3).
  Future<MatrixImageFile?> getVideoThumbnail({String? sourcePath}) async {
    if (!PlatformInfos.isMobile) return null;
    final src = sourcePath ?? path;

    // position: -1 (дефолт плагина) → отрицательный CMTime; на части кодеков и
    // особенно при активном соседнем compressVideo (батч-отправка нескольких
    // видео) кадр 2-го/3-го видео извлекается битым. Просим валидный первый
    // кадр (t=0) и ВАЛИДИРУЕМ его декодом — без проверки непустой-но-битый JPEG
    // уходил в info.thumbnail_url и рисовался «битой картинкой» у получателя.
    var bytes = await _frameAt(src, 0);
    if (!await videoThumbnailBytesDecode(bytes)) {
      // Повтор ~на 1 секунде обходит чёрный/битый keyframe в начале ролика.
      // Позиция — платформенная: единица аргумента у плагина разная.
      bytes = await _frameAt(
        src,
        videoThumbnailRetryPositionFor(defaultTargetPlatform),
      );
    }
    if (!await videoThumbnailBytesDecode(bytes)) {
      // Лучше без постера (получатель увидит BlurHash), чем битый постер.
      Logs().w(
        'Video thumbnail не декодируется — отправляем без постера '
        '(len=${bytes?.length ?? 0}, path=$src)',
      );
      return null;
    }
    return MatrixImageFile(bytes: bytes!, name: name);
  }
}
