import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:cross_file/cross_file.dart';
import 'package:matrix/matrix.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/album_send_series.dart';
import 'package:liza/utils/animated_gif.dart';
import 'package:liza/utils/clipboard_paste.dart';
import 'package:liza/utils/compress_image.dart';
import 'package:liza/utils/file_selector.dart';
import 'package:liza/utils/heic_converter.dart';
import 'package:liza/utils/mp4_faststart.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/mpv_property.dart';
import 'package:liza/utils/other_party_can_receive.dart';
import 'package:liza/utils/pending_send_echo.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/size_string.dart';
import 'package:liza/utils/upload_error_classifier.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/utils/video_poster_cache.dart';
import 'package:liza/utils/video_thumbnail.dart';
import 'package:liza/utils/xfile_mime.dart';
import 'package:liza/widgets/adaptive_dialogs/adaptive_dialog_action.dart';
import 'package:liza/widgets/adaptive_dialogs/dialog_text_field.dart';
import '../../utils/resize_video.dart';

/// `extraContent` для одного файла альбома. Вынесено из `_send` чистой функцией
/// ради тестируемости целостности `i`/`n`/`caption` (RL-paste-accumulate-album,
/// RL-gallery-count-cap-defensive): альбом (`galleryId != null`) несёт
/// `com.liza.gallery` с индексом `i`, фактической длиной `n`, подписью только на
/// якоре (`i==0`); одиночный файл — подпись в `body`.
///
/// Подпись — ТОЛЬКО на первом событии и без альбома (LABA-2620): набор, не
/// ставший альбомом (pdf с подписью → «Вставить ещё» картинкой), иначе
/// повторял бы её в каждом файле — поле подписи в диалоге уже скрыто, а
/// перенесённый `initialCaption` ушёл бы N раз.
Map<String, dynamic>? buildGalleryExtra({
  required String? galleryId,
  required int index,
  required int total,
  required String caption,
}) {
  final extra = <String, dynamic>{};
  if (galleryId != null) {
    extra['com.liza.gallery'] = {
      'id': galleryId,
      'i': index,
      'n': total,
      if (index == 0 && caption.isNotEmpty) 'caption': caption,
    };
  }
  // Подпись в `body` — только на первом событии: одиночный файл, якорь альбома
  // (лента покажет под сеткой; не-Liza клиенты увидят текст здесь) или первый
  // файл не-альбомного набора.
  if (caption.isNotEmpty && index == 0) {
    extra['body'] = caption;
  }
  return extra.isEmpty ? null : extra;
}

/// Сколько альбомов нужно под медиа-набор из [total] файлов (LABA-2621).
int albumCountFor(int total) =>
    (total + AppConfig.albumChunkSize - 1) ~/ AppConfig.albumChunkSize;

/// `extraContent` файла [index] набора из [total], нарезанного на альбомы по
/// `AppConfig.albumChunkSize` (как в Telegram, LABA-2621). [albumIds] — id
/// альбомов по порядку (`albumCountFor(total)` штук) или `null`, если набор
/// не альбомный. Хвост из одного файла уходит обычным сообщением: альбом
/// `n == 1` рисовался бы сеткой-одиночкой. Подпись — только на первом файле
/// всего набора, иначе она повторилась бы под каждым альбомом.
///
/// Единственный источник `id`/`i`/`n` и для пузыря-пре-эмита, и для финальной
/// отправки: разойдись они — `galleryExpectedCount` держал бы фантом-слоты.
Map<String, dynamic>? buildAlbumExtra({
  required List<String>? albumIds,
  required int index,
  required int total,
  required String caption,
}) {
  final chunk = index ~/ AppConfig.albumChunkSize;
  final start = chunk * AppConfig.albumChunkSize;
  final size = math.min(AppConfig.albumChunkSize, total - start);
  return buildGalleryExtra(
    galleryId: albumIds == null || size < 2 ? null : albumIds[chunk],
    index: index - start,
    total: size,
    caption: index == 0 ? caption : '',
  );
}

class SendFileDialog extends StatefulWidget {
  final Room room;
  final List<XFile> files;
  final BuildContext outerContext;
  final String? threadLastEventId, threadRootEventId;

  /// Перекодировать ли медиа перед отправкой:
  /// `true` — фото → 1280px JPEG q80, видео на mobile → 720p (стандарт
  /// Liza/WhatsApp); `false` — режим «Файл»: оригинал без перекодировки.
  ///
  /// На ТИП сообщения не влияет: изображение всегда уходит как `m.image`,
  /// видео — `m.video` (инлайн-превью), прочие файлы — `m.file`
  /// (документ-карточка). Тип определяется по MIME. См. `chat.dart`.
  final bool compress;

  /// Подпись, перенесённая при накоплении («+» и Cmd/Ctrl+V пересоздают диалог
  /// с уже введённым текстом — см. `_reopen`).
  final String? initialCaption;

  /// Открыть ленту превью у КОНЦА (плитка «+» видна) — ставит только
  /// `_addMore`: пересоздание диалога иначе сбрасывало ленту в начало, и для
  /// следующей вставки её приходилось листать заново (LABA-2631).
  final bool scrollToEndOnOpen;

  /// Источник буфера для Cmd/Ctrl+V внутри диалога; подменяется только в тестах.
  @visibleForTesting
  final PasteboardReader pasteboardReader;

  /// Выбор изображений для плитки «+» (`limit` — сколько ещё влезает в кап);
  /// подменяется только в тестах.
  @visibleForTesting
  final Future<List<XFile>> Function(BuildContext context, int limit)
  moreImagesPicker;

  /// Сколько файлов сверх `AppConfig.maxAttachmentsPerSend` отброшено — диалог
  /// говорит об этом строкой в контенте.
  final int overflowCount;

  /// Кап — здесь, а не в каждой из точек входа (пикеры, вставка, drag&drop,
  /// share) и не state-копией: `files` остаётся единственным списком, по
  /// индексам которого живут превью, постеры и txid. «+» и Cmd/Ctrl+V
  /// пересоздают диалог этим же конструктором — кап действует и на них.
  SendFileDialog({
    required this.room,
    required List<XFile> files,
    required this.outerContext,
    required this.threadLastEventId,
    required this.threadRootEventId,
    this.compress = true,
    this.initialCaption,
    this.scrollToEndOnOpen = false,
    this.pasteboardReader = const SystemPasteboardReader(),
    this.moreImagesPicker = selectMoreImages,
    super.key,
  }) : files = files.length > AppConfig.maxAttachmentsPerSend
           ? files.sublist(0, AppConfig.maxAttachmentsPerSend)
           : files,
       overflowCount = math.max(
         0,
         files.length - AppConfig.maxAttachmentsPerSend,
       );

  @override
  SendFileDialogState createState() => SendFileDialogState();
}

class SendFileDialogState extends State<SendFileDialog> {
  /// Видео мельче этого порога перекодировать смысла нет.
  static const int minSizeToCompress = 20 * 1000;

  final TextEditingController _labelTextController = TextEditingController();

  /// Идёт добор файлов (пикер «+» или чтение буфера по Cmd/Ctrl+V) —
  /// блокируем повторный вызов.
  bool _addingMore = false;

  /// Сколько раз тело `_send` реально стартовало — считает ТОЛЬКО страж
  /// двойного тапа (`AC:RL-media-send-instant-bubble/18`). Наблюдать число
  /// отправок иначе на host нельзя: путь через `sendFileEvent` требует
  /// сетевого стека, а видео-набор — `media_kit`, который на host не
  /// инициализируется вовсе (см. `RL-video-poster-error-retry`).
  ///
  /// Инкремент обёрнут в `assert(...)` — в release-сборке он не исполняется
  /// вовсе (это единственное мутируемое статическое поле-для-теста в `lib/`,
  /// и платить за него у пользователей незачем).
  @visibleForTesting
  static int sendRunsForTest = 0;

  /// Диалог занят длинной операцией — обе его кнопки действия глохнут.
  ///
  /// Гарды `_sending` и `_addingMore` обязаны быть ВЗАИМОисключающими, а не
  /// каждый сам по себе: пока `_send` висит в `_prepareVideoThumbnails()`
  /// (до 40 с на desktop), диалог ещё на экране — и активная «Вставить ещё»
  /// звала бы второй `Navigator.pop()` того же маршрута и открывала новый
  /// диалог поверх идущей отправки. Симметрично, «Отправить» во время
  /// `_addMore` ушла бы со СТАРЫМ списком файлов.
  bool get _busy => _sending || _addingMore;

  bool get _atLimit => widget.files.length >= AppConfig.maxAttachmentsPerSend;

  /// Отправка уже запущена — «Отправить» больше не принимает тапов.
  ///
  /// Между тапом и `Navigator.pop()` стоит `_prepareVideoThumbnails()`: на
  /// desktop это ожидание постера media_kit до 40 с на файл, на Web —
  /// `generateWebVideoThumbnail` до 30 с. Всё это время диалог открыт, а
  /// пользователю (ровно по жалобе LABA-2559) кажется, что ничего не
  /// происходит, и он жмёт ещё раз. Без гарда второй тап запускает второй
  /// проход `_send` со своим набором `txid` — 2N пузырей и дублирующая
  /// отправка тех же файлов.
  bool _sending = false;

  /// Байты превью по индексу файла — читаются ОДИН раз на файл.
  ///
  /// Раньше `FutureBuilder` получал `widget.files[i].readAsBytes()` прямо в
  /// `itemBuilder`: новый `Future` на каждый rebuild родителя, а значит сброс в
  /// `ConnectionState.waiting` и мигание спиннера по всей ленте на любом
  /// `setState` (приход видео-постера, смена `_busy`, тик расчёта размера).
  /// Плитка «+» добавила ещё один источник `setState`, поэтому кэш обязателен.
  /// Ленивый (а не заполняемый в `initState`): для видео-набора байты не нужны
  /// вовсе, читать их наперёд — лишние сотни мегабайт в RAM.
  final Map<int, Future<Uint8List>> _previewBytes = {};

  Future<Uint8List> _previewBytesOf(int i) =>
      _previewBytes.putIfAbsent(i, () => widget.files[i].readAsBytes());

  /// Постеры видео для desktop-платформ — извлекаются `_VideoThumbnailView`
  /// (media_kit, первый кадр локального файла) пока диалог открыт.
  /// Ключ — индекс в `widget.files`. См. `plans/media-v-format.md` §8.8.
  final Map<int, MatrixImageFile?> _videoThumbnails = {};
  final Map<int, Completer<MatrixImageFile?>> _videoThumbnailCompleters = {};

  /// desktop = не Web и не mobile. На desktop постер видео генерит media_kit;
  /// на mobile — `video_compress`, на Web — `generateWebVideoThumbnail`.
  bool get _isDesktop => !kIsWeb && !PlatformInfos.isMobile;

  @override
  void initState() {
    super.initState();
    // Перенос подписи при накоплении: диалог пересоздаётся с новым списком,
    // текст берётся из предыдущего экземпляра (см. `_addMore`).
    if (widget.initialCaption != null) {
      _labelTextController.text = widget.initialCaption!;
    }
    // Постер на desktop генерит `_VideoThumbnailView`, который рисуется
    // только когда ВСЕ файлы — видео (см. build). Completer заводим под ту
    // же ситуацию, иначе `_prepareVideoThumbnails` ждал бы несуществующий
    // виджет 40 c. Постер нужен и в режиме «Файл»: видео и оттуда уходит
    // инлайн (m.video), без постера получатель увидит пустой бабл.
    if (_isDesktop) {
      final allVideo =
          widget.files.isNotEmpty &&
          widget.files.every((f) => isVideoMime(resolveXFileMime(f)));
      if (allVideo) {
        for (var i = 0; i < widget.files.length; i++) {
          _videoThumbnailCompleters[i] = Completer<MatrixImageFile?>();
        }
      }
    }
  }

  @override
  void dispose() {
    _labelTextController.dispose();
    super.dispose();
  }

  /// Плитка «+»: системный выбор ИЗОБРАЖЕНИЙ (проводник/Finder, на mobile —
  /// галерея) и добор выбранного к набору (LABA-2619; до того «+» читала буфер).
  /// Не-изображения отсеиваются: лента с «+» живёт только у набора из одних
  /// изображений, и видео/pdf в наборе убрали бы саму плитку.
  Future<void> _addMore() async {
    // Тот же общий гард, что и у `_send`: две кнопки диалога взаимоисключающи
    // (см. `_busy`), иначе «+» во время идущей отправки открывает второй
    // диалог поверх неё.
    if (_busy || _atLimit) return;
    setState(() => _addingMore = true);
    try {
      // До вызова пикера — ни одного `await`: на Web file_picker открывается
      // только в пределах пользовательского жеста.
      final picked = await widget.moreImagesPicker(
        widget.outerContext,
        AppConfig.maxAttachmentsPerSend - widget.files.length,
      );
      if (!mounted) return;
      await _appendImagesOrReset(picked);
    } catch (e, s) {
      Logs().w('Failed to pick more images', e, s);
      if (mounted) setState(() => _addingMore = false);
    }
  }

  /// Cmd/Ctrl+V в открытом диалоге: изображения из буфера добираются в набор
  /// (накопление скриншотов — RL-paste-accumulate-album; буфер Windows/Android
  /// держит один растр за раз). Иначе — обычная вставка текста в подпись через
  /// [textPaste] (родное действие поля; `null`, если поле не в фокусе).
  Future<void> _pasteFromClipboard(VoidCallback? textPaste) async {
    if (_busy || _atLimit) {
      textPaste?.call();
      return;
    }
    setState(() => _addingMore = true);
    try {
      final result = await collectPasteXFiles(widget.pasteboardReader);
      if (!mounted) return;
      final images = result.handledAsMedia
          ? _onlyImages(result.files)
          : const <XFile>[];
      if (images.isEmpty) {
        setState(() => _addingMore = false);
        textPaste?.call();
        return;
      }
      await _appendImagesOrReset(images);
    } catch (e, s) {
      Logs().w('Failed to add more from clipboard', e, s);
      if (mounted) setState(() => _addingMore = false);
    }
  }

  static List<XFile> _onlyImages(List<XFile> files) => files
      .where((f) => resolveXFileMime(f)?.startsWith('image/') ?? false)
      .toList();

  /// Добирает изображения из [incoming] в набор и пересоздаёт диалог; если
  /// изображений нет (отмена пикера, пустой ответ) — диалог остаётся как был.
  Future<void> _appendImagesOrReset(List<XFile> incoming) async {
    final images = _onlyImages(incoming);
    if (images.isEmpty) {
      setState(() => _addingMore = false);
      return;
    }
    final merged = await accumulate(widget.files, images);
    if (!mounted) return;
    await _reopen(merged);
  }

  /// Пересоздаёт диалог с набором [files] (не мутирует `widget.files` — иначе
  /// рушится индексная схема видео-постеров). Все параметры диалога переносятся
  /// здесь, в одном месте, — иначе пересозданный диалог молча терял бы поле.
  Future<void> _reopen(List<XFile> files) async {
    final caption = _labelTextController.text;
    Navigator.of(context, rootNavigator: false).pop();
    await showAdaptiveDialog(
      context: widget.outerContext,
      builder: (c) => SendFileDialog(
        files: files,
        room: widget.room,
        outerContext: widget.outerContext,
        threadRootEventId: widget.threadRootEventId,
        threadLastEventId: widget.threadLastEventId,
        compress: widget.compress,
        initialCaption: caption,
        scrollToEndOnOpen: true,
        pasteboardReader: widget.pasteboardReader,
        moreImagesPicker: widget.moreImagesPicker,
      ),
    );
  }

  /// Плитка «+» — аффорданс накопления, ПОСЛЕДНИЙ элемент ленты превью.
  ///
  /// Живёт в контенте, а не в `actions`: действие редактирует НАБОР, а ряд
  /// действий диалога несёт только терминальные решения (отменить/отправить).
  /// Тот же приём у апстрима FluffyChat (иконка-карандаш поверх превью-тайла) и
  /// у Liza (добавление — по сетке медиа, не третьей кнопкой).
  /// Гейт `_busy` — общий с «Прислать» (см. `_busy`): пока идёт отправка или
  /// предыдущее накопление, тап не принимается. На лимите набора плитка гаснет,
  /// а не исчезает: её индекс в reverse-ленте держит LABA-2631.
  Widget _addMoreTile(ThemeData theme, double height) {
    final enabled = !_busy && !_atLimit;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: SizedBox(
        key: const Key('add-more-tile'),
        width: 96,
        height: height,
        child: Material(
          borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
          color: theme.colorScheme.surfaceContainerHighest,
          clipBehavior: Clip.hardEdge,
          child: InkWell(
            onTap: enabled ? _addMore : null,
            child: Tooltip(
              message: L10n.of(context).addMoreImages,
              child: Center(
                child: Icon(
                  Icons.add_photo_alternate_outlined,
                  size: 32,
                  color: enabled
                      ? theme.colorScheme.primary
                      : theme.disabledColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Превью файла `index` в ленте (одинаково в прямом и обратном порядке ленты).
  Widget _previewTile(ThemeData theme, int index, double height) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: Material(
        borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
        color: Colors.black,
        clipBehavior: Clip.hardEdge,
        child: FutureBuilder(
          future: _previewBytesOf(index),
          builder: (context, snapshot) {
            final bytes = snapshot.data;
            if (bytes == null) {
              return const Center(child: CircularProgressIndicator.adaptive());
            }
            if (snapshot.error != null) {
              Logs().w(
                'Unable to preview image',
                snapshot.error,
                snapshot.stackTrace,
              );
              return Center(
                child: SizedBox(
                  width: height,
                  height: height,
                  child: const Icon(Icons.broken_image_outlined, size: 64),
                ),
              );
            }
            return Image.memory(
              bytes,
              height: height,
              width: widget.files.length == 1 ? height - 36 : null,
              fit: BoxFit.contain,
              errorBuilder: (context, e, s) {
                Logs().w('Unable to preview image', e, s);
                return Center(
                  child: SizedBox(
                    width: height,
                    height: height,
                    child: const Icon(Icons.broken_image_outlined, size: 64),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  void _onVideoThumbnail(int index, MatrixImageFile? result) {
    _videoThumbnails[index] = result;
    final completer = _videoThumbnailCompleters[index];
    if (completer != null && !completer.isCompleted) {
      completer.complete(result);
    }
    if (mounted) setState(() {});
  }

  /// Дожидается готовности видео-постеров, пока диалог ещё открыт
  /// (на macOS media_kit `screenshot` требует смонтированный `Video`).
  /// На Web — генерит постер здесь же. Mobile-постер делает `video_compress`
  /// в цикле `_send`.
  Future<void> _prepareVideoThumbnails() async {
    for (var i = 0; i < widget.files.length; i++) {
      final file = widget.files[i];
      if (!isVideoMime(resolveXFileMime(file))) continue;
      if (kIsWeb) {
        _videoThumbnails[i] = await generateWebVideoThumbnail(file);
      } else if (_isDesktop) {
        final completer = _videoThumbnailCompleters[i];
        if (completer != null && !completer.isCompleted) {
          try {
            await completer.future.timeout(const Duration(seconds: 40));
          } catch (_) {
            // Не успели/не смогли — отправим без постера, у получателя
            // есть fallback (VideoPosterCache / BlurHash).
          }
        }
      }
    }
  }

  Future<void> _send() async {
    // Синхронно, до первого `await`: иначе второй тап в том же кадре успеет
    // проскочить между проверкой и установкой флага.
    if (_busy) return;
    setState(() => _sending = true);
    assert(() {
      sendRunsForTest++;
      return true;
    }());
    final scaffoldMessenger = ScaffoldMessenger.of(widget.outerContext);
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final room = widget.room;
    final client = room.client;

    // txid'ы всех файлов, сгенерированные ДО подготовки: по ним пре-эмитятся
    // пузыри и по ним же потом идёт sendFileEvent. `notHandedToSdk` — те, чьи
    // пузыри ещё НАШИ: если подготовка не дойдёт до sendFileEvent, их надо
    // снять (см. withdrawPendingAttachment). Живут вне try — читает уборка.
    final txids = <String>[];
    final notHandedToSdk = <String>{};
    // Плашка подготовки для вложений без пузыря-пре-эмита (фото/документы/
    // смешанные альбомы). Для видео её роль забрал пузырь.
    _PreparationBanner? banner;
    // Провалы серии — для итогового сообщения.
    final prepareFailures = <Object>[];
    final uploadFailures = <Object>[];

    try {
      // LABA-2242: удалённому боту (аккаунт деактивирован) файлы тоже не шлём —
      // drag-drop/вставка идут сюда в обход скрытого композера.
      if (isDeletedBotDm(room) || !room.otherPartyCanReceiveMessages) {
        throw OtherPartyCanNotReceiveMessages();
      }
      // Видео-постеры (desktop/Web) дожидаемся ДО закрытия диалога: на
      // macOS media_kit `screenshot` требует смонтированный `Video`-виджет
      // (media-v-format.md §8.8).
      await _prepareVideoThumbnails();
      Navigator.of(context, rootNavigator: false).pop();

      final caption = _labelTextController.text.trim();
      // Альбом: ≥2 медиа (изображения и/или видео) уходят с общим
      // `com.liza.gallery.id` — лента рисует их единой сеткой
      // (media-v-format.md §8.5); набор длиннее `albumChunkSize` режется на
      // несколько альбомов (`buildAlbumExtra`). От сжатия не зависит.
      // Считаем по ИСХОДНОМУ списку: ни `convertHeicFiles`, ни
      // `compressImagesForSending` не меняют
      // ни длину, ни порядок, ни image/video-природу MIME (HEIC→JPEG остаётся
      // image), поэтому предикат тот же, что и на сжатом списке. Тот же
      // `isMediaAlbum`, что решает в build() показ поля подписи: два разных
      // предиката дали LABA-2620 (UI — альбом, отправка — россыпь).
      final sources = widget.files;
      final albumIds = isMediaAlbum(sources)
          ? [
              for (var k = 0; k < albumCountFor(sources.length); k++)
                client.generateUniqueTransactionId(),
            ]
          : null;
      // Фото при compress == true уже ужато compressImagesForSending.
      // Исключение — Windows/Linux (нет flutter_image_compress): там ресайз
      // делает SDK. В режиме «Файл» сжатия нет вовсе.
      final shrinkImageMaxDimension =
          widget.compress && !imageCompressionSupported ? 1600 : null;

      // ── Пузыри ПЕРВЫМ делом ────────────────────────────────────────────
      // До getConfig (первый вызов за час — сетевой round-trip), до HEIC, до
      // постера и до транскода. Раньше всё это шло ПЕРЕД sendFileEvent, а
      // пузырь рождается только внутри него — отсюда 6.3 с пустого экрана.
      // Здесь ни одного тяжёлого await: `length()` — это stat().
      //
      // ТОЛЬКО когда ВЕСЬ набор — видео. Два независимых ограничения:
      // 1. У SDK-шного placeholder-а байты лежат в `sendingFilePlaceholders`,
      //    и бабл КАРТИНКИ рисует их локально. У пре-эмита байтов ещё нет
      //    (в этом и смысл), поэтому `MxcImage` для m.image в окне подготовки
      //    показал бы ошибку загрузки вместо превью. Видео этим не страдает:
      //    его бабл идёт через `_VideoPosterImage`, который для sending-события
      //    молча ждёт (`VideoPosterCache.isSupported`), а кадр берёт из кэша.
      // 2. Альбом обязан быть всё-или-ничего: пре-эмит части членов при
      //    `com.liza.gallery.n == N` даёт ровно те фантом-слоты, от которых
      //    защищает RL-gallery-count-cap-defensive.
      // Длинная фаза (транскод 720p) и жалоба — именно про видео, так что
      // сужение ничего из предмета задачи не теряет.
      final preEmitBubbles =
          sources.isNotEmpty &&
          sources.every((f) => isVideoMime(resolveXFileMime(f)));

      // Не-видео (и смешанные наборы) пузыря-пре-эмита не получают — им
      // обратную связь по-прежнему даёт плашка, иначе окно getConfig + HEIC +
      // сжатия фото осталось бы таким же немым, как было у видео.
      if (!preEmitBubbles) {
        banner = _PreparationBanner(
          scaffoldMessenger,
          l10n.prepareSendingAttachment,
        );
      }

      for (var i = 0; i < sources.length; i++) {
        final xfile = sources[i];
        final txid = client.generateUniqueTransactionId();
        txids.add(txid);
        UploadProgressTracker.instance.register(txid);
        if (!preEmitBubbles) continue;
        notHandedToSdk.add(txid);
        final mime = resolveXFileMime(xfile);
        await emitPendingAttachment(
          room,
          buildPendingAttachmentSync(
            roomId: room.id,
            senderId: client.userID!,
            txid: txid,
            msgtype: MatrixFile.msgTypeFromMime(
              mime ?? 'application/octet-stream',
            ),
            name: xfile.name,
            // w/h/duration ещё неизвестны — их даст getVideoInfo уже после
            // транскода. Бабл до замены рисуется по фолбэку 300×300
            // (`video_player.dart`), после — по фактическим пропорциям.
            info: {'mimetype': mime, 'size': await xfile.length()},
            extraContent: buildAlbumExtra(
              albumIds: albumIds,
              index: i,
              total: sources.length,
              caption: caption,
            ),
            shrinkImageMaxDimension: shrinkImageMaxDimension,
            // Симметрично финальному `room.sendFileEvent` ниже: без этого
            // пузырь всё окно подготовки висит в основной ленте вместо треда.
            threadRootEventId: widget.threadRootEventId,
            threadLastEventId: widget.threadLastEventId,
          ),
        );
      }

      // Серия владеет своими txid до конца: повторять их вправе только она
      // (иначе авто-досыл и ↻ шли параллельно её собственным повторам).
      UploadProgressTracker.instance.claimForSeries(txids);

      final clientConfig = await client.getConfig();
      final maxUploadSize = clientConfig.mUploadSize ?? 100 * 1000 * 1000;

      // Convert HEIC/HEIF images to JPEG for broad compatibility
      var files = await convertHeicFiles(widget.files);
      // Сжатие фото по стандартам Liza/WhatsApp (1280px, JPEG q80).
      // В режиме «Файл» (compress == false) — оригинал без перекодировки.
      if (widget.compress) {
        files = await compressImagesForSending(files);
      }
      // Не `assert`: в сторовой сборке он вырезан, а последствие расхождения
      // видно только там — байты файла B ушли бы под пузырём и именем файла A,
      // молча. Дешевле упасть с честной причиной (внешний catch покажет
      // снекбар, внешний finally снимет все пузыри), чем отправить не то.
      if (files.length != txids.length) {
        throw StateError(
          'Подготовка изменила длину списка вложений: '
          '${files.length} файлов против ${txids.length} txid — '
          'txid и файл разъедутся',
        );
      }

      // Отправка — через `AlbumSendSeries`: провал одного файла больше НЕ
      // рвёт весь набор (инцидент 2026-09-25: `rethrow` на 6-м из 23 видео
      // снял пузыри 17 остальных молча), обрыв сети ставит серию на паузу, а
      // transient-провал заливки повторяется. Индекс — счётчик серии, а не
      // `files.indexOf(xfile)`: последний хрупок при одинаковых
      // XFile.fromData и O(N²). Индекс несёт порядок альбома.
      Future<_PreparedAttachment> prepare(int index) async {
        final xfile = files[index];
        final txid = txids[index];
        MatrixFile file;
        MatrixImageFile? thumbnail;
        final length = await xfile.length();
        final mimeType = resolveXFileMime(xfile);
        final isVideo = mimeType != null && mimeType.startsWith('video');
        final isGif = !isVideo && isGifXFile(xfile);
        if (files.length > 1) {
          banner?.update(
            l10n.sendingAttachmentCountOfCount(index + 1, files.length),
          );
        }

        // Постер видео нужен всегда — и для сжатого, и для оригинала из
        // «Файла»: видео в обоих режимах уходит инлайн (m.video), без
        // постера получатель увидит пустой бабл. Постер кладётся в
        // info.thumbnail_url → виден всем (media-v-format.md §8.8).
        // На desktop/Web он уже добыт `_prepareVideoThumbnails` (media_kit),
        // на mobile добывается ниже — ПОСЛЕ транскода, см. там же почему.
        if (isVideo && !PlatformInfos.isMobile) {
          thumbnail = _videoThumbnails[index];
        }

        if (PlatformInfos.isMobile && isVideo) {
          // Видео на mobile: перекодируем в 720p только в режиме сжатия.
          // В режиме «Файл» — оригинал, но метаданные (w/h/duration) всё
          // равно извлекаем через getVideoInfo(compress: false), чтобы
          // видео ушло как m.video с корректным info.
          if (!widget.compress && length > maxUploadSize) {
            throw FileTooBigMatrixException(length, maxUploadSize);
          }
          final willCompress = widget.compress && length > minSizeToCompress;
          String? compressedPath;
          if (willCompress) {
            UploadProgressTracker.instance.reportPhase(
              txid,
              UploadPhase.compressing,
            );
          }
          file = await xfile.getVideoInfo(
            compress: willCompress,
            // percent — 0..100 от video_compress. Пишем в тот же notifier,
            // который читает оверлей бабла: снекбар как транспорт прогресса
            // непригоден (пересоздаётся на каждый тик и не успевает
            // отрисоваться — 250 мс входной анимации).
            onProgress: willCompress
                ? (double percent) {
                    UploadProgressTracker.instance.reportCompressProgress(
                      txid,
                      percent,
                    );
                    // Плашка живёт только у наборов без пузыря (смешанный
                    // альбом с видео) — там прогресс сжатия больше негде
                    // показать. Обновление НЕ пересоздаёт SnackBar.
                    banner?.update(
                      '${l10n.compressVideo} '
                      '${percent.clamp(0, 100).round()}%',
                    );
                  }
                : null,
            onOutputPath: (path) => compressedPath = path,
          );
          UploadProgressTracker.instance.reportPhase(
            txid,
            UploadPhase.preparing,
          );
          // Кадр берём из СЖАТОГО выхода, если он есть: 720p H.264 из
          // MediaCodec декодируется `MediaMetadataRetriever` всегда, а
          // исходник с камеры (HEVC/HDR10+, Samsung S24) — нет: в логе
          // `len=0` три раза из трёх, и видео уходили без постера вовсе.
          // Когда сжатия не было (режим «Файл» или файл мельче порога) —
          // берём из исходника, как раньше. Провал в любой ветке = отправка
          // без постера (получатель увидит BlurHash), а не отказ отправки.
          banner?.update(l10n.generatingVideoThumbnail);
          thumbnail = await xfile.getVideoThumbnail(sourcePath: compressedPath);
        } else {
          // Фото (сжатое в режиме compress или оригинал из «Файла»), видео
          // desktop/Web и прочие файлы. detectFileType выбирает тип по MIME:
          // m.image / m.video / m.audio уходят инлайн-сообщением, остальное —
          // m.file документ-карточкой. Сжатие на тип сообщения не влияет.
          if (length > maxUploadSize) {
            throw FileTooBigMatrixException(length, maxUploadSize);
          }
          final bytes = await xfile.readAsBytes();
          if (isGif) {
            // Оригинал байт-в-байт + своё превью первого кадра (см.
            // animated_gif.dart, заявка №43).
            final gif = await prepareGifForSending(bytes, name: xfile.name);
            file = gif.file;
            thumbnail = gif.thumbnail;
          } else {
            file = MatrixFile(
              bytes: bytes,
              name: xfile.name,
              mimeType: mimeType,
            ).detectFileType;
          }
        }

        if (file.bytes.length > maxUploadSize) {
          throw FileTooBigMatrixException(length, maxUploadSize);
        }

        // Гейт против фантомного 0-байтного медиа: если файл заявлен непустым
        // (`length>0`), но прочитанных байт нет — это молчаливый провал чтения
        // (на Web `readAsBytes()` при OOM вкладки возвращает пустой буфер без
        // исключения). Без гейта ушло бы `0` байт → сервер `media_length=0` →
        // событие с реальным размером → видео не грузится НИ У КОГО (инцидент
        // 2026-09-01). Fail-loud вместо тихого фантома.
        if (file.bytes.isEmpty && length > 0) {
          throw EmptyMediaBytesException(length);
        }

        // Desktop-видео мы не перекодируем (в отличие от mobile-compress, где
        // транскод уже отдаёт faststart-MP4). iPhone/камеры пишут moov в
        // хвост → получатель не может стримить (Synapse без Range качает весь
        // файл до индекса в конце = чёрный экран на минуты). Перекладываем
        // moov в начало без перекодирования. При любой нестандартности
        // Mp4Faststart вернёт null → шлём оригинал (деградация, не порча).
        if (_isDesktop && file is MatrixVideoFile) {
          final fast = Mp4Faststart.process(file.bytes);
          if (fast != null) {
            Logs().i(
              'Faststart: moov перенесён в начало для ${file.name} '
              '(${file.bytes.length} байт)',
            );
            file = MatrixFile(
              bytes: fast,
              name: file.name,
              mimeType: file.mimeType,
            ).detectFileType;
          }
        }

        // Постер — на диск под ключом txid. `_VideoPosterImage._bootstrap`
        // спрашивает `VideoPosterCache.getCached` ПЕРВЫМ шагом, ДО гейта
        // `isSupported` (который отсекает sending-события), поэтому наш
        // пре-эмитнутый пузырь покажет настоящий кадр без сети и без правки
        // гейтов — как в Liza. Best-effort: не сохранили (Web, диск) —
        // пузырь покажет BlurHash, а постер всё равно уйдёт в thumbnail_url.
        if (isVideo && thumbnail != null) {
          await VideoPosterCache.instance.storeBytesForIdBestEffort(
            txid,
            thumbnail.bytes,
          );
        }

        return _PreparedAttachment(
          file: file,
          thumbnail: thumbnail,
          isGif: isGif,
          extraContent: buildAlbumExtra(
            albumIds: albumIds,
            index: index,
            total: files.length,
            caption: caption,
          ),
        );
      }

      Future<void> upload(int index, _PreparedAttachment p, int attempt) async {
        final txid = txids[index];
        UploadProgressTracker.instance.reportPhase(txid, UploadPhase.uploading);
        final uploadProgress = _UploadProgressReporter.start(
          txid: txid,
          totalBytes: p.file.bytes.length,
        );
        // Привязываем реальный прогресс (UploadProgressHttpClient) к этому
        // txid: отдача идёт последовательно по файлам, активный — один.
        UploadProgressTracker.instance.markActive(txid);

        // Передача владения ВПЛОТНУЮ к вызову: `sendFileEvent` первой же
        // строкой делает `sendingFilePlaceholders[txid] = file` и эмитит ТОТ
        // ЖЕ placeholder (Timeline заменит наш на месте), дальше сам выставит
        // EventStatus.error при сбое — байты у него есть, повтор законен.
        // Снимать txid из `notHandedToSdk` РАНЬШЕ нельзя: брось что-нибудь
        // между снятием и вызовом — и пузырь остался бы ничьим.
        Future<String?> sendOnce() {
          notHandedToSdk.remove(txid);
          return room.sendFileEvent(
            p.file,
            txid: txid,
            thumbnail: p.thumbnail,
            shrinkImageMaxDimension: shrinkImageMaxDimensionFor(
              isGif: p.isGif,
              batch: shrinkImageMaxDimension,
            ),
            extraContent: p.extraContent,
            threadRootEventId: widget.threadRootEventId,
            threadLastEventId: widget.threadLastEventId,
          );
        }

        try {
          // Одна попытка = один `sendFileEvent` = свежее 30-секундное окно
          // повторов SDK. Повторы поверх (обрыв на мобильной сети посреди
          // долгой заливки) делает `AlbumSendSeries`. Отдельная ветка —
          // rate-limit сервера: ждём серверный retryAfterMs и пробуем ещё раз.
          String? eventId;
          try {
            eventId = await sendOnce();
          } on MatrixException catch (e) {
            final retryAfterMs = e.retryAfterMs;
            if (e.error != MatrixError.M_LIMIT_EXCEEDED ||
                retryAfterMs == null) {
              rethrow;
            }
            uploadProgress.pause();
            final retryAfter = Duration(milliseconds: retryAfterMs + 1000);
            scaffoldMessenger.showSnackBar(
              SnackBar(
                content: Text(l10n.serverLimitReached(retryAfter.inSeconds)),
              ),
            );
            await Future.delayed(retryAfter);
            uploadProgress.reset();
            eventId = await sendOnce();
          }
          if (eventId == null) {
            // Отменённому возвращать байты некуда: пузыря уже нет, ↻ не будет,
            // а `cancelPendingSend` их уже снял — вернуть = держать файл в
            // памяти `Room` до перезапуска (LABA-2622).
            if (UploadProgressTracker.instance.isCancelled(txid)) {
              throw const SendCancelledAfterUploadException();
            }
            // Файл залит, событие не ушло, а SDK уже выбросил байты — вернём
            // их, иначе ↻ этого сообщения удалил бы его (LABA-2239).
            room.sendingFilePlaceholders[txid] = p.file;
            final thumbnail = p.thumbnail;
            if (thumbnail != null) {
              room.sendingFileThumbnails[txid] = thumbnail;
            }
            throw const SendEventDroppedException();
          }
          // Опоздавшая отмена (LABA-2622): флаг здесь ещё жив — `unregister`
          // идёт позже, в onSent/finally.
          if (revokeIfCancelledAfterSend(room, txid, eventId)) {
            throw const SendCancelledAfterUploadException();
          }
        } finally {
          uploadProgress.complete();
        }
      }

      final result = await AlbumSendSeries<_PreparedAttachment>(
        count: files.length,
        prepare: prepare,
        upload: upload,
        sizeOf: (p) => p.file.bytes.length,
        isCancelled: (i) =>
            UploadProgressTracker.instance.isCancelled(txids[i]),
        waitForReconnect: () => _waitForReconnect(client),
        onSent: (i) => UploadProgressTracker.instance.unregister(txids[i]),
        onPrepareFailed: (i, e) {
          prepareFailures.add(e);
          UploadProgressTracker.instance.unregister(txids[i]);
          // Пузырь снимает внешний finally (txid остался в notHandedToSdk):
          // `cancelSend`, НЕ error — у события нет байтов (LABA-2239).
        },
        onUploadFailed: (i, e, kind) {
          // Причина и класс — для тултипа и ↻ на пузыре/плитке и для
          // авто-досыла при возврате связи (transient досылается, terminal —
          // нет). Событие уже в EventStatus.error, байты у SDK.
          UploadProgressTracker.instance
            ..reportError(txids[i], _uploadErrorReason(e, l10n))
            ..reportErrorKind(txids[i], kind);
          uploadFailures.add(e);
        },
        onWaiting: (indices) {
          for (final i in indices) {
            UploadProgressTracker.instance.reportPhase(
              txids[i],
              UploadPhase.waitingNetwork,
            );
          }
          banner?.update(l10n.uploadWaitingForNetwork);
        },
        onCancelled: (i) async {
          // Пользователь отменил загрузку крестиком — гасим тихо: ни ошибки,
          // ни ретрая. Отдачу уже оборвал UploadProgressHttpClient, событие из
          // ленты убрал `cancelSend`; если retry-цикл SDK успел
          // переотрисовать его error-статусом — снимаем повторно.
          final txid = txids[i];
          if (!notHandedToSdk.contains(txid)) {
            final pending = await widget.room.getEventById(txid);
            try {
              await pending?.cancelSend();
            } catch (_) {}
          }
        },
      ).run();
      scaffoldMessenger.clearSnackBars();
      if (result.notSent > 0) {
        final firstError = uploadFailures.isNotEmpty
            ? uploadFailures.first
            : prepareFailures.isNotEmpty
            ? prepareFailures.first
            : null;
        final String message;
        if (result.total == 1 && firstError != null) {
          // Одиночный файл — как раньше: ↻ есть на самом пузыре.
          message = _isTransientUploadError(firstError)
              ? l10n.uploadFailedTryFromMessage
              : firstError.toLocalizedString(widget.outerContext);
        } else {
          // Набор: одно итоговое сообщение с числом, а не отсылка к
          // «значку повтора на сообщении», которого у плитки альбома не было.
          final reason =
              firstError != null && !_isTransientUploadError(firstError)
              ? '\n${_uploadErrorReason(firstError, l10n)}'
              : '';
          message =
              '${l10n.albumNotSentCount(result.notSent, result.total)}'
              '${result.retryable > 0 ? ' ${l10n.albumNotSentRetryHint}' : ''}'
              '$reason';
        }
        scaffoldMessenger.showSnackBar(
          SnackBar(
            backgroundColor: theme.colorScheme.errorContainer,
            closeIconColor: theme.colorScheme.onErrorContainer,
            content: Text(
              message,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
            duration: const Duration(seconds: 10),
            showCloseIcon: true,
          ),
        );
      }
    } catch (e) {
      scaffoldMessenger.clearSnackBars();
      scaffoldMessenger.showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            _isTransientUploadError(e)
                ? l10n.uploadFailedTryFromMessage
                : e.toLocalizedString(widget.outerContext),
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          duration: const Duration(seconds: 30),
          showCloseIcon: true,
        ),
      );
      // `rethrow` намеренно убран: `_send` зовётся fire-and-forget из
      // `onPressed`, и проброс уходил в unhandled async error — причём
      // ДО уборки ниже, оставляя пузыри-призраки навсегда.
    } finally {
      // Диалог ещё на экране = отправка сорвалась ДО `pop()` (исключение в
      // `_prepareVideoThumbnails` или в гейте получателя). Возвращаем кнопку,
      // иначе повторить отправку стало бы нечем. После `pop()` состояние
      // размонтировано — трогать его нельзя, да и незачем.
      if (mounted) setState(() => _sending = false);
      // Плашка подготовки (если была) снимается в любом исходе. В ветке
      // ошибки её уже убрал clearSnackBars — dismiss идемпотентен.
      banner?.dismiss();
      // Пузыри файлов, до которых подготовка не дошла (исключение до
      // серии, провал подготовки файла, серия сдалась до начала файла), —
      // наши, снимаем. Отправленные и упавшие на заливке — у SDK.
      for (final txid in notHandedToSdk) {
        UploadProgressTracker.instance.unregister(txid);
        await withdrawPendingAttachment(room, txid);
      }
      // Серия кончилась: прогресс упавших снимаем, и только ПОСЛЕ этого
      // отдаём их txid остальным механизмам повтора (↻, авто-досыл) — релиз
      // будит пузыри, и они рисуют ↻ вместо «Ожидание сети».
      for (final txid in txids) {
        UploadProgressTracker.instance.unregister(txid);
      }
      UploadProgressTracker.instance.releaseFromSeries(txids);
    }
  }

  Future<String> _calcCombinedFileSize() async {
    final lengths = await Future.wait(
      widget.files.map((file) => file.length()),
    );
    return lengths.fold<double>(0, (p, length) => p + length).sizeString;
  }

  @override
  Widget build(BuildContext context) {
    // Cmd/Ctrl+V перехватывается как `PasteTextIntent`, а не `onKeyEvent`:
    // EditableText объявляет это действие переопределяемым, и родная вставка
    // текста остаётся доступна как `callingAction` (selection/undo не
    // переписываем руками). `Focus(autofocus)` нужен, чтобы шорткат нашёл
    // действие, пока поле подписи не в фокусе.
    return Actions(
      actions: {PasteTextIntent: _DialogPasteAction(this)},
      child: Focus(autofocus: true, child: _buildDialog(context)),
    );
  }

  Widget _buildDialog(BuildContext context) {
    final theme = Theme.of(context);

    var sendStr = L10n.of(context).sendFile;
    final uniqueFileType = widget.files
        .map(resolveXFileMime)
        .map((mimeType) => mimeType?.split('/').first)
        .toSet()
        .singleOrNull;

    final fileName = widget.files.length == 1
        ? widget.files.single.name
        : L10n.of(context).countFiles(widget.files.length);
    final fileTypes = widget.files
        .map((file) => file.name.split('.').last)
        .toSet()
        .join(', ')
        .toUpperCase();

    if (uniqueFileType == 'image') {
      if (widget.files.length == 1) {
        sendStr = L10n.of(context).sendImage;
      } else {
        sendStr = L10n.of(context).sendImages(widget.files.length);
      }
    } else if (uniqueFileType == 'audio') {
      sendStr = L10n.of(context).sendAudio;
    } else if (uniqueFileType == 'video') {
      sendStr = L10n.of(context).sendVideo;
    }

    // Высота превью адаптивна, а не литерал 256: `actions` диалога НЕ гибкие
    // (сжимается только контент), поэтому фиксированный блок ~348 dp вместе с
    // подписью выдавливал кнопку отправки и само поле подписи за вьюпорт на
    // 360×640 и на любом экране с открытой клавиатурой — жалоба «не вмещается
    // в экран, ловил прокрутку внутри». Считаем от реально доступной высоты.
    //
    // Считаем «доступная высота минус бюджет остальных блоков» (заголовок,
    // поле подписи, ряд действий, отступы диалога), а не долю экрана: доля
    // не знает, что несжимаемая часть — константа, и на 375×667 с клавиатурой
    // оставляла подпись на 9 px ниже вьюпорта. 240 — замеренный бюджет с
    // запасом (host-шрифт Ahem шире системного, на устройстве останется люфт).
    final mediaQuery = MediaQuery.of(context);
    final availableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.bottom;
    const nonPreviewBudget = 240.0;
    final previewHeight = math.max(
      88.0,
      math.min(256.0, availableHeight - nonPreviewBudget),
    );

    return FutureBuilder<String>(
      future: _calcCombinedFileSize(),
      builder: (context, snapshot) {
        final sizeString =
            snapshot.data ?? L10n.of(context).calculatingFileSize;

        return AlertDialog.adaptive(
          title: Text(sendStr),
          content: SizedBox(
            width: 256,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: .min,
                children: [
                  const SizedBox(height: 12),
                  if (uniqueFileType == 'image')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: SizedBox(
                        height: previewHeight,
                        child: Center(
                          child: ListView.builder(
                            shrinkWrap: true,
                            // +1 — плитка «добавить ещё» ПОСЛЕДНИМ элементом
                            // (порядок ленты = порядок отправки альбома,
                            // плитка впереди сбивала бы чтение набора).
                            itemCount: widget.files.length + 1,
                            scrollDirection: Axis.horizontal,
                            // После «+» лента строится от правого края: offset 0
                            // = плитка, а догрузка ширин превью слева растит
                            // только maxScrollExtent и вид не сдвигает. Прыжок
                            // `jumpTo(maxScrollExtent)` промахивался бы — ширины
                            // известны лишь после чтения байтов. Визуальный
                            // порядок тот же за счёт `j` ниже.
                            reverse: widget.scrollToEndOnOpen,
                            // Индексы builder'а при reverse идут справа налево —
                            // screen reader считал бы набор задом наперёд.
                            addSemanticIndexes: false,
                            itemBuilder: (context, i) {
                              final j = widget.scrollToEndOnOpen
                                  ? widget.files.length - i
                                  : i;
                              return IndexedSemantics(
                                index: j,
                                child: j == widget.files.length
                                    ? _addMoreTile(theme, previewHeight)
                                    : _previewTile(theme, j, previewHeight),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  // Desktop-видео: показываем реальный первый кадр как
                  // превью. Тот же media_kit-Player отдаёт постер для
                  // заливки (media-v-format.md §8.8) — нужен и в режиме
                  // «Файл»: видео уходит инлайн (m.video).
                  if (uniqueFileType == 'video' && _isDesktop)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: SizedBox(
                        height: 180,
                        child: Center(
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: widget.files.length,
                            scrollDirection: Axis.horizontal,
                            itemBuilder: (context, i) => Padding(
                              padding: const EdgeInsets.only(right: 8.0),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(
                                  AppConfig.borderRadius / 2,
                                ),
                                child: _VideoThumbnailView(
                                  key: ValueKey(widget.files[i].path),
                                  file: widget.files[i],
                                  width: widget.files.length == 1 ? 240 : 200,
                                  height: 180,
                                  onResult: (img) => _onVideoThumbnail(i, img),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    )
                  else if (uniqueFileType != 'image')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: Row(
                        children: [
                          Icon(
                            uniqueFileType == null
                                ? Icons.description_outlined
                                : uniqueFileType == 'video'
                                ? Icons.video_file_outlined
                                : uniqueFileType == 'audio'
                                ? Icons.audio_file_outlined
                                : Icons.description_outlined,
                            size: 32,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              mainAxisSize: .min,
                              crossAxisAlignment: .start,
                              children: [
                                Text(
                                  fileName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  '$sizeString - $fileTypes',
                                  style: theme.textTheme.labelSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Строкой в контенте: снекбар на `outerContext` лёг бы под
                  // барьер диалога, а третья кнопка ломает ряд действий
                  // (RL-send-dialog-two-actions).
                  if (_atLimit)
                    Padding(
                      key: const Key('attach-limit-note'),
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: Text(
                        [
                          L10n.of(
                            context,
                          ).attachLimitReached(AppConfig.maxAttachmentsPerSend),
                          if (widget.overflowCount > 0)
                            L10n.of(
                              context,
                            ).attachLimitDropped(widget.overflowCount),
                        ].join(' '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  // Подпись: для одиночного файла — как раньше; для
                  // альбома медиа (изображения и/или видео) — одна общая
                  // подпись на весь альбом (media-v-format.md §8.6).
                  if (widget.files.length == 1 ||
                      uniqueFileType == 'image' ||
                      uniqueFileType == 'video' ||
                      isMediaAlbum(widget.files))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8.0),
                      child: DialogTextField(
                        controller: _labelTextController,
                        labelText: L10n.of(context).optionalMessage,
                        minLines: 1,
                        maxLines: 3,
                        maxLength: 255,
                        counterText: '',
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ),
                ],
              ),
            ),
          ),
          // РОВНО два действия — инвариант (RL-send-dialog-two-actions), тот же,
          // что в апстриме FluffyChat. Третье действие («Вставить ещё») ломало
          // раскладку: `CupertinoAlertDialog` ставит кнопки в ряд ТОЛЬКО при
          // ровно двух (`childCount != 3` → столбец) и даёт секции действий
          // собственный скролл, а Material-`OverflowBar` сваливался в столбец по
          // ширине. Накопление живёт плиткой «+» в ленте превью — как в
          // Liza, где «добавить» никогда не стоит в ряду Отмена/Отправить.
          actions: <Widget>[
            AdaptiveDialogAction(
              onPressed: () =>
                  Navigator.of(context, rootNavigator: false).pop(),
              child: Text(L10n.of(context).cancel),
            ),
            AdaptiveDialogAction(
              onPressed: _busy ? null : _send,
              child: Text(L10n.of(context).send),
            ),
          ],
        );
      },
    );
  }
}

/// Cmd/Ctrl+V внутри `SendFileDialog` — см. `_pasteFromClipboard`.
/// Пункт «Вставить» контекстного меню поля сюда НЕ приходит: тулбар зовёт
/// `pasteText` напрямую, мимо интента, — он вставляет только текст.
class _DialogPasteAction extends ContextAction<PasteTextIntent> {
  _DialogPasteAction(this.state);

  final SendFileDialogState state;

  @override
  void invoke(PasteTextIntent intent, [BuildContext? context]) {
    // `callingAction` валиден только во время `invoke` — захватываем сейчас,
    // зовём после асинхронного чтения буфера.
    final textPaste = callingAction;
    state._pasteFromClipboard(
      textPaste == null ? null : () => textPaste.invoke(intent),
    );
  }
}

/// media_kit/libmpv на macOS/Windows нестабильно открывают пути с
/// кириллицей, пробелами и спецсимволами (FFI-передача строки). Если путь
/// небезопасный — кладём symlink с ASCII-именем во временную папку и
/// отдаём его. Данные НЕ копируются (важно для тяжёлых видео), media_kit
/// `normalizeURI` symlink не разворачивает — libmpv откроет ссылку,
/// а ОС сама дойдёт до файла с кириллицей в пути.
Future<String> _mediaKitSafePath(String original) async {
  final isSafe = RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(original);
  if (isSafe) return original;
  try {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/liza_mediakit_links');
    if (!await dir.exists()) await dir.create(recursive: true);
    final dot = original.lastIndexOf('.');
    final rawExt = (dot >= 0 && original.length - dot <= 6)
        ? original.substring(dot).toLowerCase()
        : '';
    final ext = RegExp(r'^\.[a-z0-9]+$').hasMatch(rawExt) ? rawExt : '';
    final linkPath =
        '${dir.path}/${original.hashCode.toUnsigned(32).toRadixString(16)}$ext';
    final link = Link(linkPath);
    if (await link.exists()) await link.delete();
    if (await File(linkPath).exists()) await File(linkPath).delete();
    await link.create(File(original).absolute.path);
    return linkPath;
  } catch (e) {
    Logs().w('_mediaKitSafePath: symlink failed, using original path: $e');
    return original;
  }
}

/// Превью видео в диалоге отправки на desktop + извлечение постера.
///
/// Открывает **локальный файл** через media_kit (libmpv): локальный файл
/// доступен целиком, поэтому проблем Range/faststart (как у получателя при
/// извлечении из удалённого видео) здесь нет — экстракция детерминирована.
///
/// `Video`-виджет смонтирован в дереве (виден как превью) — это
/// обязательно: на macOS headless `Player.screenshot()` отдаёт пустой
/// буфер, VO mpv заполняется только когда Flutter compositor тикает
/// render-callback (урок коммита `a97c460`). См. media-v-format.md §8.8.
class _VideoThumbnailView extends StatefulWidget {
  final XFile file;
  final double width;
  final double height;
  final void Function(MatrixImageFile?) onResult;

  const _VideoThumbnailView({
    required this.file,
    required this.width,
    required this.height,
    required this.onResult,
    super.key,
  });

  @override
  State<_VideoThumbnailView> createState() => _VideoThumbnailViewState();
}

class _VideoThumbnailViewState extends State<_VideoThumbnailView> {
  Player? _player;
  VideoController? _controller;
  Uint8List? _captured;
  bool _failed = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _extract();
  }

  /// Ждёт, пока seek и декод keyframe реально завершатся: `buffering`
  /// должен опуститься, плюс финальный settle — чтобы VO успел показать
  /// устоявшийся кадр до `screenshot()` (media-v-format.md §8.11).
  Future<void> _waitDecodeSettled(Player player) async {
    // Даём seek/буферизации начаться.
    await Future.delayed(const Duration(milliseconds: 200));
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (!_disposed && DateTime.now().isBefore(deadline)) {
      if (!player.state.buffering) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }
    await Future.delayed(const Duration(milliseconds: 600));
  }

  Future<void> _extract() async {
    final player = Player(
      configuration: const PlayerConfiguration(
        logLevel: MPVLogLevel.error,
        muted: true,
      ),
    );
    // Извлечение кадра — строго SW-декод. По умолчанию media_kit ставит
    // `hwdec: auto` (native_video_controller); тяжёлое видео (HEVC/4K/10-bit)
    // декодируется аппаратно, кадр лежит в GPU-surface, и `screenshot-raw`
    // при readback выдаёт битый/«кривой» кадр. SW-декод одного кадра
    // детерминирован — постер чёткий (media-v-format.md §8.10).
    final controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        hwdec: 'no',
        enableHardwareAcceleration: false,
      ),
    );
    if (mounted) {
      setState(() {
        _player = player;
        _controller = controller;
      });
    }
    Uint8List? captured;
    try {
      await controller.platform.future.timeout(const Duration(seconds: 8));
      // Путь с кириллицей/пробелами media_kit FFI открывает нестабильно —
      // подменяем на ASCII-symlink (media-v-format.md §8.8).
      final safePath = await _mediaKitSafePath(widget.file.path);
      if (_disposed) return;
      // Локальный файл — открываем напрямую, play=true чтобы VO mpv
      // гарантированно заполнилась реальным кадром (урок §8.8).
      await player.open(Media(safePath), play: true);
      await controller.waitUntilFirstFrameRendered.timeout(
        const Duration(seconds: 25),
      );
      if (_disposed) return;
      // Пауза ДО seek. На играющем плеере VO обновляется непрерывно, и
      // `screenshot-raw` ловит полу-собранный кадр → разбросанные
      // макроблоки. На паузе в VO один стабильный кадр (media-v-format.md
      // §8.11).
      await player.pause();
      // Keyframe-only seek: `hr-seek=no` снапит seek на ближайший keyframe.
      // Keyframe (IDR) — самодостаточный I-frame, декодируется без ссылок
      // на соседние кадры → inter-frame артефактов в принципе нет. Точная
      // позиция постеру не важна (media-v-format.md §8.11).
      await setMpvProperty(player, 'hr-seek', 'no');
      // Кадр t≈0 у многих видео чёрный (fade-in, тёмная заставка). Просим
      // keyframe около ~10% длительности, зажато в [3с, 10с]
      // (media-v-format.md §8.8). С hr-seek=no позиция снапнется на
      // ближайший keyframe.
      final duration = player.state.duration;
      if (duration > const Duration(seconds: 3)) {
        var target = duration * 0.1;
        if (target < const Duration(seconds: 3)) {
          target = const Duration(seconds: 3);
        } else if (target > const Duration(seconds: 10)) {
          target = const Duration(seconds: 10);
        }
        await player.seek(target);
      }
      // Ждём реального завершения seek+декода keyframe, затем скриншот.
      await _waitDecodeSettled(player);
      if (_disposed) return;
      var bytes = await player.screenshot(format: 'image/jpeg');
      // <8 KB — подозрительно (чёрный кадр / пустой буфер): одна повторная
      // попытка после доп. задержки, затем не отдаём.
      if (bytes == null || bytes.length < 8192) {
        await Future.delayed(const Duration(milliseconds: 700));
        if (_disposed) return;
        bytes = await player.screenshot(format: 'image/jpeg');
      }
      if (bytes != null && bytes.length >= 8192) {
        captured = bytes;
        widget.onResult(MatrixImageFile(bytes: bytes, name: 'thumbnail.jpg'));
      } else {
        Logs().w(
          'Send video thumbnail: suspicious screenshot '
          '(${bytes?.length} bytes) for ${widget.file.name}',
        );
        widget.onResult(null);
      }
    } catch (e, s) {
      Logs().w('Send video thumbnail extraction failed', e, s);
      if (!_disposed) widget.onResult(null);
    } finally {
      if (!_disposed) {
        _player = null;
        _controller = null;
        if (mounted) {
          setState(() {
            _captured = captured;
            _failed = captured == null;
          });
        }
        await player.dispose();
      }
      // Если _disposed — Player уже dispose-нут в [dispose].
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final player = _player;
    _player = null;
    _controller = null;
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final captured = _captured;
    if (captured != null) {
      return Image.memory(
        captured,
        width: widget.width,
        height: widget.height,
        fit: BoxFit.cover,
      );
    }
    final controller = _controller;
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (controller != null)
              Video(
                controller: controller,
                controls: NoVideoControls,
                fit: BoxFit.cover,
              ),
            Center(
              child: _failed
                  ? const Icon(
                      Icons.videocam_outlined,
                      size: 48,
                      color: Colors.white54,
                    )
                  : const CircularProgressIndicator.adaptive(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Одна долгоживущая плашка подготовки — для вложений БЕЗ пузыря-пре-эмита
/// (фото, документы, смешанные альбомы; см. `preEmitBubbles` в `_send`).
///
/// Текст меняется через `ValueNotifier`, сам `SnackBar` **не пересоздаётся**.
/// Прежний `showLoadingSnackBar` делал `clearSnackBars()` + `showSnackBar()` на
/// КАЖДОЕ обновление — бар каждый раз начинал входную анимацию (~250 мс)
/// заново и на записи экрана не появлялся вовсе. Это и был корень «ничего не
/// происходит»; повторять его для не-видео нельзя.
class _PreparationBanner {
  final ScaffoldMessengerState _messenger;
  final ValueNotifier<String> _label;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _controller;

  _PreparationBanner(this._messenger, String initial)
    : _label = ValueNotifier<String>(initial) {
    _controller = _messenger.showSnackBar(
      SnackBar(
        duration: const Duration(minutes: 5),
        dismissDirection: DismissDirection.none,
        content: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator.adaptive(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _label,
                builder: (context, value, _) => Text(value),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void update(String label) {
    if (_controller != null) _label.value = label;
  }

  /// Идемпотентно. Notifier диспоузим только после того, как плашка доиграла
  /// выход — иначе `ValueListenableBuilder` в уходящем дереве читал бы
  /// disposed-notifier.
  void dismiss() {
    final controller = _controller;
    if (controller == null) return;
    _controller = null;
    try {
      controller.close();
    } catch (_) {
      // Плашку уже сняли (clearSnackBars в ветке ошибки) — это нормально.
    }
    controller.closed
        .then<void>((_) {})
        .catchError((_) {})
        .whenComplete(_label.dispose);
  }
}

/// Обрыв соединения при заливке (`ClientException` оборачивает
/// `SocketException` / `Connection reset by peer`) или таймаут — такие
/// ошибки имеет смысл повторить. `dart:io` (`SocketException`) намеренно
/// не импортируем — ради совместимости с Web-сборкой.
bool _isTransientUploadError(Object e) =>
    classifyUploadError(e) == UploadErrorKind.transient;

/// Подготовленный к заливке файл серии: байты, постер и `content`-добавки.
class _PreparedAttachment {
  final MatrixFile file;
  final MatrixImageFile? thumbnail;
  final bool isGif;
  final Map<String, dynamic>? extraContent;

  const _PreparedAttachment({
    required this.file,
    required this.thumbnail,
    required this.isGif,
    required this.extraContent,
  });
}

/// Дождаться, когда связь с сервером снова есть: ближайший успешный цикл
/// sync. `false` — ждать нечего (вышли из аккаунта). Таймаута нет намеренно:
/// серия на паузе держит только пузыри «Ожидание сети» (их можно отменить
/// крестиком), а на свёрнутом iOS время всё равно стоит.
Future<bool> _waitForReconnect(Client client) async {
  if (!client.isLogged()) return false;
  final result = Completer<bool>();
  final syncSub = client.onSyncStatus.stream.listen((update) {
    if (update.status == SyncStatus.finished && !result.isCompleted) {
      result.complete(true);
    }
  });
  final loginSub = client.onLoginStateChanged.stream.listen((state) {
    if (state != LoginState.loggedIn && !result.isCompleted) {
      result.complete(false);
    }
  });
  try {
    return await result.future;
  } finally {
    await syncSub.cancel();
    await loginSub.cancel();
  }
}

/// Человекочитаемая причина терминальной ошибки отправки для тултипа на бабле.
/// Использует сохранённый [l10n] (не BuildContext после await — тот мог
/// размонтироваться к моменту catch).
String _uploadErrorReason(Object e, L10n l10n) {
  if (e is EmptyMediaBytesException) {
    return l10n.couldNotReadFileTooLargeForBrowser;
  }
  if (e is FileTooBigMatrixException) return l10n.uploadFileTooLargeForServer;
  if (e is MatrixException) {
    if (e.error == MatrixError.M_TOO_LARGE) {
      return l10n.uploadFileTooLargeForServer;
    }
    final message = e.errorMessage;
    return message.isNotEmpty ? message : l10n.couldNotSendMessage;
  }
  return l10n.couldNotSendMessage;
}

/// Псевдо-прогресс upload вложения — оценка по времени.
///
/// Основной источник прогресса — реальный счётчик байт в
/// `UploadProgressHttpClient`. Этот репортёр запасной: покрывает фазу до
/// начала отдачи (шифрование E2EE, мелкие файлы) и Web, где перехват на
/// HTTP-уровне невозможен (`BrowserClient` буферизует тело перед XHR).
///
/// Оценка: процент по времени и фиксированной скорости (4 МБ/с —
/// консервативно для домашних/мобильных каналов), notifier растёт 0..0.95.
/// Как только по `txid` приходит реальный прогресс
/// ([UploadProgressTracker.hasRealProgress]) — репортёр умолкает.
///
/// Прогресс публикуется через [UploadProgressTracker] по `txid`. Bubble
/// видео-сообщения слушает этот notifier и рисует overlay поверх превью.
/// SnackBar намеренно НЕ используется — он перекрывает поле ввода и не
/// даёт user-у писать в чат во время длинной загрузки.
class _UploadProgressReporter {
  final String _txid;
  final int _totalBytes;
  final Stopwatch _elapsed = Stopwatch();
  Timer? _timer;
  bool _completed = false;

  static const double _assumedMbPerSec = 4.0;
  static const double _maxRatio = 0.95;
  static const Duration _tickPeriod = Duration(milliseconds: 500);

  _UploadProgressReporter._(this._txid, this._totalBytes);

  factory _UploadProgressReporter.start({
    required String txid,
    required int totalBytes,
  }) {
    final reporter = _UploadProgressReporter._(txid, totalBytes);
    reporter._tick();
    reporter._startTimer();
    return reporter;
  }

  void _startTimer() {
    if (_completed || _timer != null) return;
    _elapsed.start();
    _timer = Timer.periodic(_tickPeriod, (_) => _tick());
  }

  /// Сбросить прогресс в 0 и продолжить тикать. Используется при повторной
  /// попытке заливки после обрыва: upload в Matrix не докачивается — файл
  /// уходит на сервер заново, значит и псевдо-прогресс считаем с нуля.
  void reset() {
    if (_completed) return;
    _timer?.cancel();
    _timer = null;
    _elapsed
      ..stop()
      ..reset();
    _startTimer();
    _tick();
  }

  void pause() {
    _elapsed.stop();
    _timer?.cancel();
    _timer = null;
  }

  void complete() {
    if (_completed) return;
    _completed = true;
    _elapsed.stop();
    _timer?.cancel();
    _timer = null;
    // notifier тут не диспозим — за это отвечает UploadProgressTracker
    // через unregister() в вызывающем коде.
  }

  void _tick() {
    if (_completed) return;
    // Как только UploadProgressHttpClient прислал реальный прогресс по
    // этому txid — псевдо-оценка умолкает, чтобы не перебивать факт.
    if (UploadProgressTracker.instance.hasRealProgress(_txid)) return;
    final mb = _totalBytes / (1024 * 1024);
    final assumedTotalSec = mb / _assumedMbPerSec;
    final elapsedSec = _elapsed.elapsedMilliseconds / 1000;
    final rawRatio = assumedTotalSec > 0 ? elapsedSec / assumedTotalSec : 0;
    final ratio = rawRatio.clamp(0.0, _maxRatio);
    final notifier = UploadProgressTracker.instance.byId(_txid);
    notifier?.value = ratio.toDouble();
  }
}
