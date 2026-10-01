import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/image_viewer/image_viewer.dart';
import 'package:liza/pages/chat/events/upload_overlays.dart';
import 'package:liza/utils/animated_gif.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/widgets/mxc_image.dart';
import '../../../widgets/blur_hash.dart';

class ImageBubble extends StatelessWidget {
  final Event event;
  final bool tapToView;
  final BoxFit fit;
  final Color? backgroundColor;
  final Color? textColor;
  final Color? linkColor;
  final bool thumbnailOnly;
  final bool animated;
  final double width;
  final double height;
  final void Function()? onTap;
  final BorderRadius? borderRadius;
  final Timeline? timeline;

  /// Плашка времени (Liza-стиль) — в правом нижнем углу поверх картинки.
  final Widget? timeOverlay;

  /// Чат в режиме выделения: тап по пузырю выделяет, крестик отмены
  /// отправки не должен его перехватывать.
  final bool longPressSelect;

  const ImageBubble(
    this.event, {
    this.tapToView = true,
    this.backgroundColor,
    this.fit = BoxFit.contain,
    this.thumbnailOnly = true,
    this.width = 400,
    this.height = 300,
    this.animated = false,
    this.onTap,
    this.borderRadius,
    this.timeline,
    this.textColor,
    this.linkColor,
    this.timeOverlay,
    this.longPressSelect = false,
    super.key,
  });

  /// Отмена отправки своего фото (LABA-2622): кольцо прогресса с крестиком,
  /// пока идёт отправка. ↻ упавшего фото сюда НЕ выносим — он остаётся в
  /// футере и меню. [UploadProgressTracker.seriesChanges] будит оверлей, когда
  /// серия отпускает txid.
  Widget? _uploadOverlay() {
    if (event.status.isSent ||
        event.messageType == MessageTypes.Sticker ||
        event.senderId != event.room.client.userID) {
      return null;
    }
    final tracker = UploadProgressTracker.instance;
    return ValueListenableBuilder<int>(
      valueListenable: tracker.seriesChanges,
      builder: (context, _, _) {
        final notifier = tracker.byId(event.eventId);
        // Упавший член идущей серии (обрыв сети) — это «в очереди», серия
        // дошлёт его сама: крестик нужен и ему. Серия кончилась — notifier
        // снят, оверлея нет.
        if (notifier == null) {
          return const SizedBox.shrink();
        }
        return IgnorePointer(
          ignoring: longPressSelect,
          child: UploadProgressOverlay(
            notifier: notifier,
            event: event,
            compact:
                width < _fullOverlayMinSide || height < _fullOverlayMinSide,
            buttonOnly: height < _ringOverlayMinHeight,
          ),
        );
      },
    );
  }

  static const _fullOverlayMinSide = 140.0;
  static const _ringOverlayMinHeight = 64.0;

  Widget _buildPlaceholder(BuildContext context) {
    final String blurHashString =
        event.infoMap['xyz.amorgan.blurhash'] is String
        ? event.infoMap['xyz.amorgan.blurhash']
        : 'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
    return SizedBox(
      width: width,
      height: height,
      child: BlurHash(
        blurhash: blurHashString,
        width: width,
        height: height,
        fit: fit,
      ),
    );
  }

  void _onTap(BuildContext context) {
    if (onTap != null) {
      onTap!();
      return;
    }
    if (!tapToView) return;
    showDialog(
      context: context,
      builder: (_) =>
          ImageViewer(event, timeline: timeline, outerContext: context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final borderRadius =
        this.borderRadius ?? BorderRadius.circular(AppConfig.borderRadius);

    // GIF играет в ленте сам (заявка №43): грузим оригинал, а превью первого
    // кадра держим в placeholder, пока оригинал качается. Вне лимитов или при
    // выключенном автоплее — статичное превью с бейджем, тап → вьювер.
    final isGif = isGifImageEvent(event);
    final animateGif =
        thumbnailOnly &&
        shouldAnimateGifInline(
          event,
          autoplay: AppSettings.autoplayImages.value,
        );
    final placeholder = animateGif
        ? (BuildContext context) => MxcImage(
            event: event,
            width: width,
            height: height,
            fit: fit,
            isThumbnail: true,
            placeholder: _buildPlaceholder,
          )
        : event.messageType == MessageTypes.Sticker
        ? null
        : _buildPlaceholder;

    final uploadOverlay = _uploadOverlay();

    return Material(
      color: Colors.transparent,
      clipBehavior: Clip.hardEdge,
      shape: RoundedRectangleBorder(
        borderRadius: borderRadius,
        side: BorderSide(
          color: event.messageType == MessageTypes.Sticker
              ? Colors.transparent
              : theme.dividerColor,
        ),
      ),
      child: InkWell(
        onTap: () => _onTap(context),
        borderRadius: borderRadius,
        child: Stack(
          children: [
            Hero(
              tag: event.eventId,
              child: MxcImage(
                event: event,
                width: width,
                height: height,
                fit: fit,
                animated: animated,
                // Анимацию GIF даёт оригинал: `animated` в event-пути MxcImage
                // не участвует, превью статично.
                isThumbnail: thumbnailOnly && !animateGif,
                cacheWidth: animateGif
                    ? (width * MediaQuery.devicePixelRatioOf(context)).round()
                    : null,
                placeholder: placeholder,
              ),
            ),
            if (uploadOverlay != null) Positioned.fill(child: uploadOverlay),
            if (isGif && !animateGif)
              const Positioned(top: 6, left: 6, child: GifBadge()),
            if (timeOverlay != null)
              Positioned(bottom: 6, right: 6, child: timeOverlay!),
          ],
        ),
      ),
    );
  }
}

/// Бейдж «GIF» на статичном превью GIF (лента вне лимитов / автоплей
/// выключен, плитка альбома).
class GifBadge extends StatelessWidget {
  const GifBadge({super.key});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      L10n.of(context).gifBadge,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}
