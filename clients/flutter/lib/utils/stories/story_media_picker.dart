import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../compress_image.dart';
import '../file_selector.dart';
import '../heic_converter.dart';
import '../xfile_mime.dart';
import '../../pages/stories/story_composer.dart';
import '../../pages/stories/story_video_scrubber.dart';
import '../../widgets/future_loading_dialog.dart';
import 'story_video_picker.dart';
import 'story_video_trim.dart';

/// Выбрать одно медиа для сториса и вернуть готовый StoryComposer.
/// null — пользователь отменил выбор. Единый путь для ленты ([+]) и для
/// кнопки «Назад» редактора (переоткрыть выбор).
///
/// [channelId] — если задан, публикация из композера идёт от имени канала
/// (см. `StoryComposer.channelId`); прокидывается и через «Назад», чтобы
/// повторный выбор медиа не терял целевой канал.
Future<StoryComposer?> pickStoryMediaComposer(
  BuildContext context, {
  String? channelId,
}) async {
  final xfile = await selectSingleMedia(context);
  if (xfile == null || !context.mounted) return null;

  final mimeType = xfile.mimeType ?? '';
  final name = xfile.name.toLowerCase();
  final isVideo =
      mimeType.startsWith('video') ||
      name.endsWith('.mp4') ||
      name.endsWith('.mov') ||
      name.endsWith('.m4v');

  if (isVideo) {
    // Видео длиннее минуты → дорожка выбора отрезка (Instagram-механика).
    var startMs = 0;
    final durationMs = await probeStoryVideoDurationMs(xfile.path);
    if (!context.mounted) return null;
    if (durationMs > storyMaxVideoMs) {
      final chosen = await Navigator.of(context).push<int>(
        MaterialPageRoute(
          builder: (_) =>
              StoryVideoScrubber(path: xfile.path, durationMs: durationMs),
        ),
      );
      if (chosen == null || !context.mounted) return null; // отмена
      startMs = chosen;
    }
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => prepareStoryVideo(xfile, startMs: startMs),
    );
    final picked = result.result;
    if (picked == null || !context.mounted) return null;
    return StoryComposer(
      file: picked.file,
      thumbnail: picked.thumbnail,
      videoWasTrimmed: picked.wasTrimmed,
      trim: picked.trim,
      channelId: channelId,
    );
  }
  // Фото-сторис: тот же конвейер, что и при отправке фото в чат
  // (send_file_dialog.dart). Сначала HEIC/HEIF → JPEG (iPhone отдаёт HEIC),
  // затем сжатие/перекодировка в JPEG (1280px, q80). Без этого matrix-SDK
  // в sendFileEvent зовёт generateThumbnail → decodeImage (пакет image),
  // который HEIC/AVIF не декодирует, и `image!` валит публикацию на isolate
  // («не удалось опубликовать сторис»). Перекодировка гарантирует
  // декодируемые JPEG-байты до SDK.
  var prepared = (await convertHeicFiles([xfile])).first;
  prepared = await compressImageForSending(prepared);
  final bytes = await prepared.readAsBytes();
  return StoryComposer(
    file: MatrixImageFile(
      bytes: bytes,
      name: prepared.name,
      mimeType: resolveXFileMime(prepared),
    ),
    channelId: channelId,
  );
}
