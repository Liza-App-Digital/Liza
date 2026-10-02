import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/app_lock.dart';
import 'package:liza/widgets/future_loading_dialog.dart';

// FileType.video на macOS использует UTI public.movie, который не
// включает .mkv/.webm/.avi/.flv (для них нет нативных UTI). На desktop
// диалог NSOpenPanel/GTK либо фильтрует .mkv насовсем, либо игнорирует
// фильтр и показывает всё — поведение неустойчивое. На Web
// FileType.custom + allowedExtensions работает стабильно. Мобильные
// сюда не доходят — у них видео идёт через ImagePicker (см. ниже).
const _videoExtensions = [
  'mp4',
  'm4v',
  'mov',
  'mkv',
  'webm',
  'avi',
  '3gp',
  '3g2',
  'flv',
  'wmv',
  'mpeg',
  'mpg',
  'ts',
];

// file_picker 10.x для FileType.image на macOS прокидывает в NSOpenPanel
// allowedContentTypes только bmp/gif/jpeg/jpg/png/webp (см.
// file_picker_macos.dart). HEIC/HEIF/TIFF в этот whitelist не попадают,
// и iPhone-фото становятся unselectable в Finder. Подмена на FileType.custom
// со своим списком чинит выбор без касания нативного плагина.
const _imageExtensions = [
  'jpg',
  'jpeg',
  'png',
  'gif',
  'webp',
  'bmp',
  'heic',
  'heif',
  'tiff',
  'tif',
  'avif',
];

bool get _isDesktop {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.windows;
}

Future<List<XFile>> selectFiles(
  BuildContext context, {
  String? title,
  FileType type = FileType.any,
  bool allowMultiple = false,
}) async {
  // На Android/iOS видео выбирается из системной медиатеки, а не из
  // файлового менеджера. FilePicker для FileType.custom открывает на
  // обеих платформах документ-пикер (Files / SAF), а FileType.video —
  // галерею только на iOS, на Android всё тот же документ-пикер.
  // ImagePicker даёт единый UX: PHPicker на iOS и системный Photo Picker
  // на Android. Множественный выбор видео image_picker не поддерживает —
  // берётся один ролик (как и при записи с камеры).
  if (type == FileType.video && PlatformInfos.isMobile) {
    final picked = await AppLock.of(context).pauseWhile(
      showFutureLoadingDialog(
        context: context,
        future: () => ImagePicker().pickVideo(source: ImageSource.gallery),
      ),
    );
    final video = picked.result;
    return video == null ? [] : [video];
  }

  final FileType effectiveType;
  final List<String>? allowedExtensions;
  if (type == FileType.video) {
    if (_isDesktop) {
      // На desktop диалог любого фильтра по видео-расширениям не покажет
      // .mkv стабильно — открываем без фильтра, пользователь сам выберет.
      effectiveType = FileType.any;
      allowedExtensions = null;
    } else {
      effectiveType = FileType.custom;
      allowedExtensions = _videoExtensions;
    }
  } else if (type == FileType.image && _isDesktop) {
    effectiveType = FileType.custom;
    allowedExtensions = _imageExtensions;
  } else {
    effectiveType = type;
    allowedExtensions = null;
  }

  final result = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      future: () => FilePicker.platform.pickFiles(
        compressionQuality: 0,
        allowMultiple: allowMultiple,
        type: effectiveType,
        allowedExtensions: allowedExtensions,
      ),
    ),
  );
  return result.result?.xFiles ?? [];
}

/// Выбор фото и видео из системной медиатеки (галереи).
///
/// Mobile: ImagePicker открывает PHPicker на iOS и системный Photo Picker на
/// Android — мультивыбор фото и видео вперемешку, как «Галерея» во вложениях
/// Liza/WhatsApp.
///
/// Desktop (macOS/Win/Linux): системного «медиа-пикера» нет — `image_picker`
/// открывает NSOpenPanel/GTK, отфильтрованный ТОЛЬКО под изображения, и видео
/// в нём неселектируемо (серое). FilePicker с `FileType.custom`+extensions
/// тоже ненадёжен: на macOS 11+ file_picker конвертит каждое расширение через
/// `UTType(filenameExtension:)` в `allowedContentTypes`, и для части видео (в
/// т.ч. `.MP4` от iPhone) файл всё равно остаётся серым. Поэтому на desktop —
/// `FileType.any` БЕЗ фильтра (так же, как `selectFiles` для видео выше):
/// пользователь сам выбирает фото/видео, ничего не гасится. Тип сообщения
/// (m.image/m.video/m.file) всё равно определяется по MIME в SendFileDialog.
Future<List<XFile>> selectGalleryMedia(BuildContext context) async {
  if (_isDesktop) {
    final result = await AppLock.of(context).pauseWhile(
      showFutureLoadingDialog(
        context: context,
        future: () => FilePicker.platform.pickFiles(
          compressionQuality: 0,
          allowMultiple: true,
          type: FileType.any,
        ),
      ),
    );
    return result.result?.xFiles ?? [];
  }
  final picked = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      // Только подсказка системному пикеру (Android без Photo Picker её
      // игнорирует) — гарантию лимита даёт `SendFileDialog`.
      future: () => ImagePicker().pickMultipleMedia(
        limit: AppConfig.maxAttachmentsPerSend,
      ),
    ),
  );
  return picked.result ?? const [];
}

/// Добор изображений к уже собранному набору — плитка «+» в `SendFileDialog`
/// (LABA-2619). Только изображения: лента превью с «+» существует лишь у
/// набора из одних изображений, видео или pdf её бы убрали.
///
/// [limit] — сколько ещё влезает в кап набора. Mobile: `pickMultiImage`
/// бросает `ArgumentError` при `limit < 2`, поэтому на последнее место —
/// одиночный `pickImage`. Desktop/Web: у FilePicker лимита нет, лишнее срежет
/// кап конструктора `SendFileDialog` (со строкой «Лишние N»).
Future<List<XFile>> selectMoreImages(BuildContext context, int limit) async {
  if (!PlatformInfos.isMobile) {
    return selectFiles(context, type: FileType.image, allowMultiple: true);
  }
  final picked = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      future: () async => limit < 2
          ? [?await ImagePicker().pickImage(source: ImageSource.gallery)]
          : await ImagePicker().pickMultiImage(limit: limit),
    ),
  );
  return picked.result ?? const [];
}

/// Выбор ОДНОГО медиа для сториса — фото ИЛИ видео.
///
/// Mobile — `ImagePicker.pickMedia` (системный Photo Picker: предлагает и фото,
/// и видео, один элемент). Desktop/Web — FilePicker с фильтром по image+video
/// расширениям. Тип (изображение/видео) определяет вызывающий по MIME/расширению
/// (`pickStoryMediaComposer`).
///
/// Видео-сторис разблокированы (ранее пикер отдавал только фото — «прототип»;
/// см. retired RL-stories-image-only → RL-stories-video-in-picker).
Future<XFile?> selectSingleMedia(BuildContext context) async {
  if (PlatformInfos.isMobile) {
    final picked = await AppLock.of(context).pauseWhile(
      showFutureLoadingDialog(
        context: context,
        future: () => ImagePicker().pickMedia(),
      ),
    );
    return picked.result;
  }
  final result = await AppLock.of(context).pauseWhile(
    showFutureLoadingDialog(
      context: context,
      future: () => FilePicker.platform.pickFiles(
        compressionQuality: 0,
        allowMultiple: false,
        type: FileType.custom,
        allowedExtensions: [..._imageExtensions, ..._videoExtensions],
      ),
    ),
  );
  return result.result?.xFiles.firstOrNull;
}
