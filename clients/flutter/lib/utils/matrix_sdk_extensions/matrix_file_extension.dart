import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:file_picker/file_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/file_download_helper.dart';
import 'package:liza/utils/object_url.dart';
import 'package:liza/utils/size_string.dart';

/// Достоверный mime-тип скачанного вложения.
///
/// SDK определяет mime по magic-байтам только когда в событии `info.mimetype`
/// ОТСУТСТВУЕТ (см. `MatrixFile`-конструктор: снифф идёт лишь для пустого mime).
/// Если отправитель — мост/бот — явно проставил `application/octet-stream`,
/// конструктор сохраняет эту заглушку и байты НЕ смотрит, поэтому настоящий
/// PNG/JPEG доезжает как octet-stream. Здесь пересниффиваем содержимое, но
/// только когда явного типа нет: валидный mime из события не перетираем.
/// package:mime сначала матчит magic-числа, потом расширение имени.
String _resolveMimeType(MatrixFile file) {
  final declared = file.mimeType;
  if (declared.isNotEmpty && declared != 'application/octet-stream') {
    return declared;
  }
  // headerBytes: package:mime читает лишь первые ~16 байт (длина самой длинной
  // сигнатуры), полный буфер не сканируется. Пустые/короткие bytes → null.
  return lookupMimeType('', headerBytes: file.bytes) ??
      _sniffMissingMagic(file.bytes) ??
      declared;
}

/// Форматы, которых НЕТ в magic-таблице package:mime, но которые реально
/// прилетают в чат. Реальный кейс (2026-07-17): картинка из буфера Windows
/// приходит как BMP без имени и без `info.mimetype`; package:mime знает `bmp`
/// только по расширению, поэтому снифф по содержимому его не ловит.
String? _sniffMissingMagic(List<int> bytes) {
  // BMP: сигнатура «BM» (0x42 0x4D) в первых двух байтах.
  if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
    return 'image/bmp';
  }
  return null;
}

/// Имя для диалога «Сохранить как», гарантированно непустое и с расширением.
///
/// Полученные изображения часто приходят без имени: у отправителя вставка из
/// буфера обмена / скриншот даёт пустой `filename` в Matrix-событии, а имя вида
/// `.jpg` — это пустой base с одним расширением. В обоих случаях macOS
/// NSSavePanel показывает пустое поле имени (file_picker кладёт `fileName`
/// в `nameFieldStringValue` как есть). Здесь достраиваем осмысленное имя:
/// корректное оставляем как есть, при пустом base генерируем
/// `<тип>_<timestamp>.<ext>`. Тип и расширение берём из [_resolveMimeType]
/// (mime события, а при заглушке octet-stream — снифф по байтам).
/// Символы, недопустимые в имени файла хотя бы на одной платформе, заменяем на
/// `_` — так же поступает Chrome при скачивании. Главный из них «:» (заявка
/// №51): на Web `package:path` работает в url-контексте и читает его как схему
/// URL, `extension('… 09:33 … .txt')` там пустой, и file_picker отказывался
/// сохранять; на Windows «:» в имени не допускается вовсе. Чистим ПОСЛЕ
/// basename, иначе `../../secret` превратился бы в `.._.._secret`.
/// [now] инъектируется в тестах ради детерминизма.
String safeSaveFileName(MatrixFile file, {DateTime? now}) {
  final raw = p
      .basename(file.name)
      .trim()
      .replaceAll(RegExp(r'[:/\\*?"<>|\x00-\x1f]'), '_');
  final lastDot = raw.lastIndexOf('.');
  final base = lastDot > 0
      ? raw.substring(0, lastDot)
      : (lastDot == 0 ? '' : raw);
  final currentExt = lastDot >= 0 ? raw.substring(lastDot + 1) : '';
  // `application/octet-stream` — заглушка для неизвестного типа; для неё
  // extensionFromMime вернул бы бессмысленное «.so», поэтому считаем расширение
  // неизвестным. Тип для скачанного вложения определяем по mime, а не по
  // Dart-классу: downloadAndDecryptAttachment всегда отдаёт базовый MatrixFile.
  final mime = _resolveMimeType(file);
  final mimeExt =
      mime == 'application/octet-stream' ? null : extensionFromMime(mime);

  if (base.isEmpty) {
    final prefix = mime.startsWith('image/')
        ? 'image'
        : mime.startsWith('video/')
            ? 'video'
            : mime.startsWith('audio/')
                ? 'audio'
                : 'file';
    final ext = mimeExt ?? (currentExt.isNotEmpty ? currentExt : null);
    final ts = _saveFileTimestamp(now ?? DateTime.now());
    return ext == null ? '${prefix}_$ts' : '${prefix}_$ts.$ext';
  }
  if (currentExt.isEmpty && mimeExt != null) {
    // Имя с хвостовой точкой (`report.`) уже несёт разделитель — иначе вышло бы
    // `report..png`.
    final sep = raw.endsWith('.') ? '' : '.';
    return '$raw$sep$mimeExt';
  }
  return raw;
}

String _saveFileTimestamp(DateTime dt) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${dt.year}${two(dt.month)}${two(dt.day)}_'
      '${two(dt.hour)}${two(dt.minute)}${two(dt.second)}';
}

extension MatrixFileExtension on MatrixFile {
  /// Сохраняет файл на диск, возвращает итоговый путь (`null` — пользователь
  /// отменил диалог). Если [directory] задан — пишет туда без диалога
  /// (авто-сохранение в «Загрузки»/настроенную папку на desktop); иначе
  /// открывает системный диалог «Сохранить как» (web — прямая загрузка
  /// браузером). Снэкбар не показывает — это забота вызывающего (чтобы при
  /// пакетном скачивании не сыпать по уведомлению на файл).
  Future<String?> saveToDisk(BuildContext context, {Directory? directory}) async {
    final fileName = safeSaveFileName(this);
    if (directory != null) {
      try {
        return await writeToDownloadDirectory(directory, fileName, bytes);
      } on FileSystemException catch (e) {
        // Песочница macOS: без entitlement на каталог прямая запись запрещена
        // (FileSystemException). Не роняем скачивание — откатываемся на
        // системный диалог «Сохранить как», где доступ выдаёт сам пользователь.
        Logs().w('Direct save to ${directory.path} failed, using dialog', e);
      }
    }
    // Web скачиваем сами: file_picker на Web отказывается сохранять файл без
    // расширения и пустой файл, а диалога «Сохранить как» в браузере всё равно
    // нет. Путь браузер не сообщает — возвращаем null, как и file_picker.
    if (kIsWeb) {
      downloadBytes(fileName, bytes, _resolveMimeType(this));
      return null;
    }
    // Одного `fileName` мало: с FileType.any NSSavePanel только подставляет имя
    // по умолчанию, но не удерживает расширение (сотрёшь — сохранит без него).
    // FileType.custom + allowedExtensions заставляет панель закрепить расширение.
    // allowedExtensions валиден только с FileType.custom и обязан быть непустым.
    final ext = p.posix.extension(fileName).replaceFirst('.', '');
    return FilePicker.platform.saveFile(
      dialogTitle: L10n.of(context).saveFile,
      fileName: fileName,
      type: ext.isEmpty ? filePickerFileType : FileType.custom,
      allowedExtensions: ext.isEmpty ? null : [ext],
      bytes: bytes,
    );
  }

  void save(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    // Одиночное скачивание — всегда системный диалог «Сохранить как»
    // (directory: null). Пакетное скачивание (LABA-2202) отдельно вызывает
    // saveToDisk с директорией для тихого сохранения в «Загрузки».
    final String? downloadPath;
    try {
      downloadPath = await saveToDisk(context);
    } catch (e, s) {
      // `save` никто не ждёт (`void async`): без catch исключение ушло бы в
      // zone, и пользователь не увидел бы ничего (заявка №51).
      Logs().e('Failed to save file', e, s);
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.fileSaveFailed)),
      );
      return;
    }
    if (downloadPath == null) return;

    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.fileHasBeenSavedAt(downloadPath))),
    );
  }

  FileType get filePickerFileType {
    if (this is MatrixImageFile) return FileType.image;
    if (this is MatrixAudioFile) return FileType.audio;
    if (this is MatrixVideoFile) return FileType.video;
    return FileType.any;
  }

  void share(BuildContext context) async {
    // Workaround for iPad from
    // https://github.com/fluttercommunity/plus_plugins/tree/main/packages/share_plus/share_plus#ipad
    final box = context.findRenderObject() as RenderBox?;

    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(bytes, name: name, mimeType: mimeType)],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
    return;
  }

  MatrixFile get detectFileType {
    if (msgType == MessageTypes.Image) {
      return MatrixImageFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Video) {
      return MatrixVideoFile(bytes: bytes, name: name);
    }
    if (msgType == MessageTypes.Audio) {
      return MatrixAudioFile(bytes: bytes, name: name);
    }
    return this;
  }

  String get sizeString => size.sizeString;
}
