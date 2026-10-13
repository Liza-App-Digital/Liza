import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/utils/client_download_content_extension.dart';
import 'package:liza/utils/heic_converter.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:liza/utils/monitoring.dart';
import 'package:liza/widgets/matrix.dart';

class MxcImage extends StatefulWidget {
  final Uri? uri;
  final Event? event;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final bool isThumbnail;
  final bool animated;

  /// Ширина декода в физических пикселях. Для полноразмерного GIF в ленте:
  /// каждый кадр декодируется под пузырь, а не в исходном разрешении.
  final int? cacheWidth;
  final Duration retryDuration;
  final Duration animationDuration;
  final Curve animationCurve;
  final ThumbnailMethod thumbnailMethod;
  final Widget Function(BuildContext context)? placeholder;
  final String? cacheKey;
  final Client? client;
  final BorderRadius borderRadius;

  const MxcImage({
    this.uri,
    this.event,
    this.width,
    this.height,
    this.fit,
    this.placeholder,
    this.isThumbnail = true,
    this.animated = false,
    this.cacheWidth,
    this.animationDuration = LizaThemes.animationDuration,
    this.retryDuration = const Duration(seconds: 2),
    this.animationCurve = LizaThemes.animationCurve,
    this.thumbnailMethod = ThumbnailMethod.scale,
    this.cacheKey,
    this.client,
    this.borderRadius = BorderRadius.zero,
    super.key,
  });

  @override
  State<MxcImage> createState() => _MxcImageState();

  // Sniff по сигнатурам реальных форматов с камер/мессенджеров. Нужен как
  // fallback к MIME-детекту: пакет `mime` по headerBytes знает не все форматы
  // (WebP/HEIC и пр.), а у некоторых отправителей MIME в событии вовсе пуст —
  // тогда detectFileType не распознаёт картинку и полноэкранный просмотр
  // (isThumbnail:false) оставался пустым. Видео сюда не проходит — его magic
  // не матчит, и гард по-прежнему не даёт грузить/рисовать видео как картинку.
  @visibleForTesting
  static bool looksLikeImageMagic(Uint8List d) {
    if (d.length < 12) return false;
    // JPEG: FF D8 FF
    if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) return true;
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (d[0] == 0x89 &&
        d[1] == 0x50 &&
        d[2] == 0x4E &&
        d[3] == 0x47 &&
        d[4] == 0x0D &&
        d[5] == 0x0A &&
        d[6] == 0x1A &&
        d[7] == 0x0A) {
      return true;
    }
    // GIF: "GIF87a" / "GIF89a"
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
    // HEIC/HEIF — общий ISOBMFF ftyp-чек.
    return _MxcImageState._looksLikeHeicMagic(d);
  }

  // Решает, что дисковый файл-кэш SDK для этого вложения отравлен (не-картинка,
  // осевшая с кодом 200 во время переезда медиа) и его нужно сбросить+перекачать.
  // Выделено из `_load` ради юнит-теста (страж RL-mxc-image-cache-selfheal-attachment):
  // testWidgets с живым Matrix Client виснет, а это чистая функция.
  static bool isPoisonedImageCache({
    required bool wasInLocalStore,
    required bool isThumbnail,
    required String msgtype,
    required String mimeType,
    required Uint8List bytes,
  }) {
    // Свежескачанное (не из кэша) не лечим: перекачка не поможет и зациклит.
    if (!wasInLocalStore) return false;
    // Ждём картинку: превью — всегда, полноразмер — если это не видео.
    final expectImage =
        isThumbnail || !(msgtype == 'm.video' || mimeType.startsWith('video/'));
    if (!expectImage) return false;
    // Похоже на картинку по magic-байтам → кэш валиден, не трогаем.
    return !looksLikeImageMagic(bytes);
  }

  // Сменилась ли identity вложения между старым и новым виджетом (пагинация
  // таймлайна / edit сообщения). Выделено чистой функцией (страж
  // RL-media-stuck-load-watchdog AC-7): без перезапуска _load старый спиннер
  // залипает БЕЗ сетевой проблемы (класс γ), и watchdog ложно счёл бы это
  // «media-stuck».
  @visibleForTesting
  /// Превью отправляемого видео. SDK для `status.isSending` отдаёт из
  /// `downloadAndDecryptAttachment` байты `sendingFilePlaceholders`
  /// БЕЗУСЛОВНО, игнорируя `getThumbnail` (matrix-4.1.0 `event.dart:743`), —
  /// для m.video это сырой MP4. Декодер падал «Invalid image data», и плитка
  /// альбома навсегда оставалась BlurHash-ом (лог жалобы 2026-09-25, по
  /// строке на каждый член альбома в момент отправки). Такое превью берём из
  /// `sendingFileThumbnails`, а без него — placeholder, байты видео в декодер
  /// не отдаём. Гард — только на `isSending`: у упавшего (`error`) видео
  /// ветка SDK с плейсхолдером не срабатывает, а оба вызывающих его и так не
  /// монтируют (плитка альбома — `PendingVideoPoster`, пузырь видео — только
  /// при `hasThumbnail`, которого у незалитого нет).
  static bool isSendingVideoThumbnail({
    required bool isSending,
    required bool isThumbnail,
    required String msgtype,
  }) => isSending && isThumbnail && msgtype == MessageTypes.Video;

  static bool attachmentIdentityChanged(MxcImage oldW, MxcImage newW) =>
      oldW.uri != newW.uri ||
      oldW.event?.eventId != newW.event?.eventId ||
      oldW.cacheKey != newW.cacheKey;
}

/// Классификатор причины сдачи загрузки для сигнала `[media-stuck]` (ЗАКРЫТЫЙ
/// перечень): `stuck-timeout` — сетевой await завис и был прерван таймаутом
/// (тихий вечный спиннер); `give-up` — исчерпаны ретраи по иным исключениям.
@visibleForTesting
String mediaStuckReasonFor(Object error) =>
    error is TimeoutException ? 'stuck-timeout' : 'give-up';

/// Оконный агрегатор сигнала «застрявшего» медиа (leading-edge + дедуп).
///
/// Leading-edge: ПЕРВАЯ сдача в окне эмитит сигнал сразу — единичный застрявший
/// спиннер обязан быть виден (жалоба владельца именно про «одно пересланное
/// медиа висит вечно»); остальные сдачи в окне дедуплицируются (обрыв сети =
/// N плиток галереи разом → всё равно ≤1 сигнал за окно, без лавины).
///
/// Часы инъектируемы ([now]) — детерминированный страж без реального времени.
/// Маркер-семейство `[media-…]` в TITLE обязателен: notifier роутит по подстроке
/// (`MEDIA_TITLE_MARKERS`), тег до него не доезжает — без префикса сигнал падал
/// бы в общий ALERT_ROOM, а не в «Liza · Медиа».
@visibleForTesting
class MediaStuckAggregator {
  MediaStuckAggregator({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  static const Duration window = Duration(minutes: 5);
  static const String prefix = '[media-stuck]';

  int _count = 0;
  DateTime? _windowStart;

  /// Возвращает сообщение для эмита (leading-edge) либо `null` (дедуп в окне).
  /// [error] — последнее исключение ретраев: для `give-up` из него берётся класс
  /// (`kind=`) и, при `other`, имя типа (`err=`), при `http` — статус (`st=`) —
  /// без текста ошибки.
  String? onGiveUp(String reason, String? host, {Object? error}) {
    final now = _now();
    final start = _windowStart;
    if (start == null || now.difference(start) > window) {
      _windowStart = now;
      _count = 0;
    }
    _count++;
    if (_count != 1) return null;
    // Хост — короткой формой, а пояснение коротким: GlitchTip режет title на 100
    // символов, и прежняя длинная форма («host=synapse.liza.laba.prodamus.tech
    // (медиа не загрузилось: вечный спиннер без ошибки)») доезжала до чата
    // обрубком «…вечный спи…» (проверено на прод-БД 2026-09-10).
    final hostPart = (host != null && host.isNotEmpty)
        ? ' host=${Monitoring.shortHost(host)}'
        : '';
    final head = '$prefix reason=$reason$hostPart';
    // «Без ошибки» правда только для stuck-timeout. give-up — это ретраи,
    // исчерпанные на НАСТОЯЩИХ исключениях, и пользователь видит tap-to-retry,
    // а не спиннер. Issue GlitchTip #2059 (2026-09-23, macOS 3766) пришёл с этой
    // ложной припиской и без типа ошибки: сервер медиа-запроса не получил, и
    // зацепки не осталось ни у кого.
    if (reason != 'give-up' || error == null) {
      return '$head (вечный спиннер без ошибки)';
    }
    final kind = mediaFailureKind(error);
    if (kind == 'http') {
      return '$head kind=http st=${mediaFailureHttpStatus(error)}';
    }
    if (kind != 'other') return '$head kind=$kind';
    final withKind = '$head kind=other err=';
    // host приходит из mxc:// — его задаёт чужой сервер федерации: два его
    // DNS-лейбла могут съесть весь бюджет, тогда тип не влезает вовсе.
    final room = (Monitoring.maxAlertTitleLength - withKind.length).clamp(0, 99);
    final type = mediaFailureErrorType(error);
    return '$withKind${type.length > room ? type.substring(0, room) : type}';
  }
}

class _MxcImageState extends State<MxcImage> {
  static const int _imageDataCacheMaxEntries = 50;
  static const int _maxRetries = 5;
  static const Duration _maxBackoff = Duration(seconds: 30);

  // Агрегатор сигнала «застрявшего» медиа — общий на все MxcImage сессии.
  static final MediaStuckAggregator _stuckAggregator = MediaStuckAggregator();

  // [reason] — из ЗАКРЫТОГО перечня (см. [mediaStuckReasonFor]); [host] — только
  // server_name из mxc/uri, БЕЗ media_id (PII, пин RL-mediadiag-no-secret).
  static void _recordGiveUp(String reason, String? host, Object error) {
    final message = _stuckAggregator.onGiveUp(reason, host, error: error);
    if (message != null) Monitoring.captureMessage(message);
  }

  // LRU через Map: Dart гарантирует insertion-order. При промахе/попадании
  // переcтавляем ключ в хвост; при превышении лимита удаляем head.
  static final Map<String, Uint8List> _imageDataCache = {};

  // mxc, для которых уже делали одноразовую перекачку при подозрении на битый
  // дисковый файл-кэш SDK (см. self-heal в _load). Set живёт всю сессию: без
  // него экзотический-но-валидный формат (не в списке magic) зациклил бы
  // бесконечную перекачку на каждый рендер.
  static final Set<String> _cachePoisonRetried = {};

  Uint8List? _imageDataNoCache;

  // true после исчерпания ретраев: рендерим tap-to-retry вместо вечного
  // спиннера/блюра. Сбрасывается при ручном повторе.
  bool _failed = false;

  Uint8List? get _imageData {
    final cacheKey = widget.cacheKey;
    if (cacheKey == null) return _imageDataNoCache;
    final data = _imageDataCache[cacheKey];
    if (data != null) {
      // Promote to MRU: remove + re-insert keeps key at tail.
      _imageDataCache.remove(cacheKey);
      _imageDataCache[cacheKey] = data;
    }
    return data;
  }

  set _imageData(Uint8List? data) {
    if (data == null) return;
    final cacheKey = widget.cacheKey;
    if (cacheKey == null) {
      _imageDataNoCache = data;
      return;
    }
    _imageDataCache.remove(cacheKey);
    _imageDataCache[cacheKey] = data;
    while (_imageDataCache.length > _imageDataCacheMaxEntries) {
      _imageDataCache.remove(_imageDataCache.keys.first);
    }
  }

  // Щедрый таймаут ТОЛЬКО на сетевую фазу загрузки (download/decrypt), чтобы
  // зависший await (сервер не отдаёт байты, исключения нет) не давал вечный
  // спиннер. Превью маленькое → 20с; полноразмер (E2EE-видео/большое фото,
  // декрипт vodozemac на слабом устройстве) → 60с. `_maybeTranscodeHeic` НЕ
  // оборачиваем — HEIC→JPEG на CPU честно может быть долгим.
  Duration get _networkTimeout =>
      widget.isThumbnail ? const Duration(seconds: 20) : const Duration(seconds: 60);

  // server_name из mxc/uri для PII-safe сигнала (без media_id).
  String? _attachmentHost() {
    final uri = widget.uri;
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return widget.event
        ?.attachmentOrThumbnailMxcUrl(getThumbnail: widget.isThumbnail)
        ?.host;
  }

  Future<void> _load() async {
    if (!mounted) return;
    final client =
        widget.client ?? widget.event?.room.client ?? Matrix.of(context).client;
    final uri = widget.uri;
    final event = widget.event;

    if (uri != null && uri.host.isNotEmpty) {
      final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
      final width = widget.width;
      final realWidth = width == null ? null : width * devicePixelRatio;
      final height = widget.height;
      final realHeight = height == null ? null : height * devicePixelRatio;

      final remoteData = await client
          .downloadMxcCached(
            uri,
            width: realWidth,
            height: realHeight,
            thumbnailMethod: widget.thumbnailMethod,
            isThumbnail: widget.isThumbnail,
            animated: widget.animated,
          )
          .timeout(_networkTimeout);
      if (!mounted) return;
      // Без event MIME неизвестен — детектим по magic bytes (federation
      // через прокси, серверный raw thumbnailer, и т.п.).
      final transcoded = await _maybeTranscodeHeic(remoteData);
      if (!mounted) return;
      setState(() {
        _imageData = transcoded;
      });
    }

    if (event != null &&
        MxcImage.isSendingVideoThumbnail(
          isSending: event.status.isSending,
          isThumbnail: widget.isThumbnail,
          msgtype: event.messageType,
        )) {
      final thumbnail = event.room.sendingFileThumbnails[event.eventId];
      if (thumbnail == null || !mounted) return;
      setState(() {
        _imageData = thumbnail.bytes;
      });
      return;
    }

    if (event != null) {
      final wasInLocalStore = await event.isAttachmentInLocalStore(
        getThumbnail: widget.isThumbnail,
      );
      var data = await event
          .downloadAndDecryptAttachment(
            getThumbnail: widget.isThumbnail,
          )
          .timeout(_networkTimeout);
      // Self-heal отравленного файл-кэша. Во время переезда медиа (переключение
      // на MMR, 2026-07-26) сервер мог кратко отдать не-картинку с кодом 200, и
      // SDK записал её в дисковый файл-кэш БЕЗ валидации. storeFile НЕ
      // перезаписывает существующий файл (io: `if (file.exists) return`), а
      // clearCache файл-стор не трогает — поэтому битый кэш «залипает» навсегда
      // и Image.memory каждый раз падает с «Invalid image data». Путь
      // downloadMxcCached уже самолечится; здесь чиним второй путь (превью/файлы
      // из события). Если из кэша пришли байты, которые мы ЖДЁМ картинкой, но
      // они ей не являются (и это не видео) — сбрасываем запись и качаем свежее
      // (аутентиф. v1) ОДИН раз за сессию на этот mxc.
      if (MxcImage.isPoisonedImageCache(
        wasInLocalStore: wasInLocalStore,
        isThumbnail: widget.isThumbnail,
        msgtype: widget.event?.content['msgtype']?.toString() ?? '',
        mimeType: data.mimeType,
        bytes: data.bytes,
      )) {
        final mxc =
            event.attachmentOrThumbnailMxcUrl(getThumbnail: widget.isThumbnail);
        final key = mxc?.toString();
        if (mxc != null && key != null && _cachePoisonRetried.add(key)) {
          if (await client.database.deleteFile(mxc)) {
            data = await event
                .downloadAndDecryptAttachment(
                  getThumbnail: widget.isThumbnail,
                )
                .timeout(_networkTimeout);
          }
        }
      }
      // detectFileType определяет тип ТОЛЬКО по MIME. У части отправителей
      // (напр. Android/Windows-клиент в E2EE-комнате) `info.mimetype` пуст, а
      // имя файла без расширения — тогда detectFileType не распознаёт картинку
      // и полноэкранный просмотр (isThumbnail:false) оставался пустым, хотя
      // инлайн-превью рендерилось (его спасал `|| isThumbnail`). Поэтому
      // дополнительно нюхаем магические байты. Видео сюда не попадает — его
      // magic не матчит image, и гард по-прежнему не даёт грузить видео целиком.
      if (data.detectFileType is MatrixImageFile ||
          widget.isThumbnail ||
          MxcImage.looksLikeImageMagic(data.bytes)) {
        if (!mounted) return;
        // HEIC/HEIF от federation (Element/iMessage без серверного
        // transcode) — Skia на Android/Web/Linux/Windows не отрисует;
        // на iOS/macOS отрисует, но единый путь проще.
        final transcoded = await _maybeTranscodeHeic(
          data.bytes,
          mimeType: data.mimeType,
        );
        if (!mounted) return;
        setState(() {
          _imageData = transcoded;
        });
        return;
      }
      // Гард не распознал картинку по MIME/magic, но это и НЕ видео (msgtype
      // m.video сюда не должен грузиться целиком — см. выше). Раньше метод
      // молча возвращался: _imageData оставался null, исключения не было,
      // ретраи не запускались → вечный placeholder на чёрном фоне (баг
      // «чёрные сторисы иногда»: WebP/битый первый чанк/экзотика вне списка
      // magic). Отдаём байты в Image.memory: валидная-но-нераспознанная
      // картинка отрисуется, реально битая уйдёт в errorBuilder (broken_image),
      // а не в бесконечный спиннер.
      final isVideo =
          widget.event?.content['msgtype'] == 'm.video' ||
          (data.mimeType.startsWith('video/'));
      if (!isVideo) {
        if (!mounted) return;
        final transcoded = await _maybeTranscodeHeic(
          data.bytes,
          mimeType: data.mimeType,
        );
        if (!mounted) return;
        setState(() {
          _imageData = transcoded;
        });
      }
    }
  }

  static bool get _heicTranscodeSupported {
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

  // ISOBMFF: первые 4 байта — размер box-а, следующие 4 — "ftyp",
  // далее 4-байтовый major brand. Для HEIC/HEIF список brand-ов фиксирован.
  static const _heicBrands = {
    'heic',
    'heix',
    'heim',
    'heis',
    'hevc',
    'hevx',
    'hevm',
    'hevs',
    'mif1',
    'msf1',
  };

  static bool _looksLikeHeicMagic(Uint8List data) {
    if (data.length < 12) return false;
    if (data[4] != 0x66 ||
        data[5] != 0x74 ||
        data[6] != 0x79 ||
        data[7] != 0x70) {
      return false;
    }
    final brand = String.fromCharCodes(data.sublist(8, 12));
    return _heicBrands.contains(brand);
  }

  Future<Uint8List> _maybeTranscodeHeic(
    Uint8List data, {
    String? mimeType,
  }) async {
    if (!_heicTranscodeSupported) return data;
    final isHeic = isHeicMimeType(mimeType) || _looksLikeHeicMagic(data);
    if (!isHeic) return data;
    try {
      final jpeg = await FlutterImageCompress.compressWithList(
        data,
        quality: 90,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (jpeg.isEmpty) return data;
      return Uint8List.fromList(jpeg);
    } catch (e, s) {
      Logs().w('MxcImage: HEIC transcode for render failed', e, s);
      return data;
    }
  }

  void _tryLoad([int attempt = 0]) async {
    if (_imageData != null) {
      return;
    }
    try {
      await _load();
    } catch (e, s) {
      if (!mounted) return;
      if (attempt >= _maxRetries) {
        Logs().w(
          'MxcImage: giving up after ${attempt + 1} attempts for '
          '${widget.uri ?? widget.cacheKey ?? widget.event?.eventId}',
          e,
          s,
        );
        // Авто-ретраи (5×/~60с) укладываются внутрь короткого обрыва сети;
        // если обрыв длиннее — после возврата связи виджет уже не перезагрузит
        // медиа сам, пока смонтирован. Показываем tap-to-retry вместо
        // неотличимого от «грузится» спиннера/блюра.
        setState(() => _failed = true);
        _recordGiveUp(mediaStuckReasonFor(e), _attachmentHost(), e);
        return;
      }
      // Exp backoff: 2s, 4s, 8s, 16s, 30s (capped)
      final delayMs = widget.retryDuration.inMilliseconds * (1 << attempt);
      final delay = Duration(
        milliseconds: delayMs.clamp(0, _maxBackoff.inMilliseconds),
      );
      await Future.delayed(delay);
      if (!mounted) return;
      _tryLoad(attempt + 1);
    }
  }

  void _retry() {
    if (_imageData != null) return;
    setState(() => _failed = false);
    _tryLoad();
  }

  // Провал декода в Image.memory (errorBuilder) для байт, осевших в локальном
  // файл-кэше SDK: битый/усечённый blob с валидной сигнатурой проскакивает
  // `isPoisonedImageCache` (тот сверяет только magic). Один раз за сессию на
  // mxc сбрасываем файл и перекачиваем свежее. Бюджет общий с self-heal в
  // `_load` (`_cachePoisonRetried`) — если сервер отдаёт те же битые байты,
  // второго круга нет и виджет остаётся на placeholder/broken_image.
  void _maybeHealOnDecodeFailure() {
    final event = widget.event;
    if (event == null) return;
    final mxc =
        event.attachmentOrThumbnailMxcUrl(getThumbnail: widget.isThumbnail);
    final key = mxc?.toString();
    if (mxc == null || key == null) return;
    if (!_cachePoisonRetried.add(key)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final client = widget.client ?? event.room.client;
      try {
        if (!await client.database.deleteFile(mxc)) return;
        if (!mounted) return;
        _imageDataNoCache = null;
        final cacheKey = widget.cacheKey;
        if (cacheKey != null) _imageDataCache.remove(cacheKey);
        setState(() {});
        _tryLoad();
      } catch (e, s) {
        Logs().w('MxcImage: heal-on-decode-failure failed', e, s);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _tryLoad());
  }

  @override
  void didUpdateWidget(MxcImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Identity вложения сменилась (пагинация таймлайна / edit сообщения): без
    // перезапуска _load старая картинка/спиннер залипают БЕЗ сетевой проблемы
    // (класс γ), а watchdog ложно счёл бы это «media-stuck». Сбрасываем
    // состояние и перезагружаем. Общий по cacheKey кэш НЕ трогаем — им владеют
    // и другие виджеты; при смене cacheKey геттер _imageData сам вернёт запись
    // нового ключа (или null → загрузка).
    if (MxcImage.attachmentIdentityChanged(oldWidget, widget)) {
      setState(() {
        _imageDataNoCache = null;
        _failed = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _tryLoad();
      });
    }
  }

  Widget placeholder(BuildContext context) =>
      widget.placeholder?.call(context) ??
      Container(
        width: widget.width,
        height: widget.height,
        alignment: Alignment.center,
        child: const CircularProgressIndicator.adaptive(strokeWidth: 2),
      );

  /// Placeholder + полупрозрачная кнопка «повторить» поверх. Для видео
  /// под ней остаётся BlurHash, для картинки — обычный placeholder.
  Widget _retryOverlay(BuildContext context) => GestureDetector(
        onTap: _retry,
        child: Stack(
          alignment: Alignment.center,
          fit: StackFit.passthrough,
          children: [
            placeholder(context),
            Container(
              width: widget.width,
              height: widget.height,
              alignment: Alignment.center,
              color: Colors.black.withValues(alpha: 0.25),
              child: Icon(
                Icons.refresh,
                size: min(widget.height ?? 48, 48),
                color: Colors.white,
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final data = _imageData;
    final hasData = data != null && data.isNotEmpty;

    return AnimatedSwitcher(
      duration: LizaThemes.animationDuration,
      child: hasData
          ? ClipRRect(
              borderRadius: widget.borderRadius,
              child: Image.memory(
                data,
                width: widget.width,
                height: widget.height,
                cacheWidth: widget.cacheWidth,
                fit: widget.fit,
                filterQuality: widget.isThumbnail
                    ? FilterQuality.low
                    : FilterQuality.medium,
                errorBuilder: (context, e, s) {
                  Logs().d('Unable to render mxc image', e, s);
                  // Байты непустые, но не декодируются (усечённый/битый JPEG:
                  // напр. постер видео из батч-отправки или частичная заливка).
                  // Если они из локального файл-кэша — ОДИН раз за сессию
                  // сбрасываем кэш и перекачиваем свежие (расширение self-heal
                  // с «не тот magic» на «не декодируется»).
                  _maybeHealOnDecodeFailure();
                  // Превью (лента/галерея) не должно показывать мёртвую «битую
                  // картинку»: откатываемся на placeholder (BlurHash постера).
                  // Терминальную иконку оставляем только для полноэкранного.
                  if (widget.isThumbnail && widget.placeholder != null) {
                    return widget.placeholder!.call(context);
                  }
                  return SizedBox(
                    width: widget.width,
                    height: widget.height,
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainer,
                      child: Icon(
                        Icons.broken_image_outlined,
                        size: min(widget.height ?? 64, 64),
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  );
                },
              ),
            )
          : _failed
              ? _retryOverlay(context)
              : placeholder(context),
    );
  }
}
