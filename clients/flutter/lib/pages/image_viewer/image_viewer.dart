import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/pages/chat/events/gallery.dart';
import 'package:liza/pages/image_viewer/image_viewer_view.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/show_scaffold_dialog.dart';
import 'package:liza/widgets/share_scaffold_dialog.dart';
import '../../utils/matrix_sdk_extensions/event_extension.dart';

/// Страницы просмотрщика и стартовая — тапнутое событие.
///
/// Тапнутого нет в отфильтрованной ленте (видео без плеера, событие вне
/// таймлайна) — открываем ТОЛЬКО его. Прежний фолбэк `index = 0` показывал
/// первую попавшуюся картинку чата вместо видео (заявка №57, Windows).
(List<Event>, int) viewerEvents(
  List<Event>? timelineEvents,
  Event tapped, {
  required bool supportsVideo,
}) {
  if (timelineEvents == null) return ([tapped], 0);
  final events = timelineEvents
      .where(
        (event) => {
          MessageTypes.Image,
          MessageTypes.Sticker,
          if (supportsVideo) MessageTypes.Video,
        }.contains(event.messageType),
      )
      .toList()
      .reversed
      .toList();
  final index = events.indexWhere((event) => event.eventId == tapped.eventId);
  if (index < 0) return ([tapped], 0);
  return (events, index);
}

class ImageViewer extends StatefulWidget {
  final Event event;
  final Timeline? timeline;
  final BuildContext outerContext;

  const ImageViewer(
    this.event, {
    required this.outerContext,
    this.timeline,
    super.key,
  });

  @override
  ImageViewerController createState() => ImageViewerController();
}

class ImageViewerController extends State<ImageViewer> {
  final FocusNode focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    final (events, index) = viewerEvents(
      widget.timeline?.events,
      widget.event,
      supportsVideo: PlatformInfos.supportsVideoPlayer,
    );
    allEvents = events;
    _index = index;
    pageController = PageController(initialPage: index);
  }

  late final PageController pageController;

  late final List<Event> allEvents;

  /// `true` — текущее изображение увеличено (scale > 1.0). PageView
  /// блокирует свайп, чтобы InteractiveViewer мог панить внутри.
  final ValueNotifier<bool> isZoomed = ValueNotifier(false);

  /// Текущая страница. Хранится отдельно от [PageController.page], т.к. тот
  /// ассертит `positions.isNotEmpty` и падает, если прочитать его до того,
  /// как PageView смонтирован (а стрелки навигации строятся в том же build).
  late int _index;

  void onPageChanged(int index) {
    if (!mounted) return;
    isZoomed.value = false;
    setState(() => _index = index);
  }

  void onKeyEvent(KeyEvent event) {
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (canGoBack) prevImage();
        break;
      case LogicalKeyboardKey.arrowDown:
        if (canGoNext) nextImage();
        break;
    }
  }

  void prevImage() async {
    await pageController.previousPage(
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
    );
    if (!mounted) return;
    setState(() {});
  }

  void nextImage() async {
    await pageController.nextPage(
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
    );
    if (!mounted) return;
    setState(() {});
  }

  Event get currentEvent => allEvents[_index];

  /// Индекс текущей страницы карусели — для проброса `isActive` в
  /// `EventVideoPlayer` (пауза видео при свайпе на другое медиа).
  int get activeIndex => _index;

  bool get canGoNext => _index < allEvents.length - 1;

  bool get canGoBack => _index > 0;

  /// Запрещён ли вынос контента наружу для ТЕКУЩЕГО медиа.
  ///
  /// Проверяется по комнате конкретного события карусели, а не по одной
  /// комнате на весь просмотрщик: листание идёт по timeline одного чата, но
  /// гейт по событию устойчив к переиспользованию виджета из других мест
  /// (галерея, поиск, сторис).
  ///
  /// Просмотр не ограничиваем — закрыты только сохранение, share и пересылка.
  bool get isContentProtected => currentEvent.room.isContentProtected;

  /// Forward this image to another room.
  void forwardAction() async {
    if (isContentProtected) return;
    // Та же труба пометки «Переслано» (LABA-1991), что и в чате. Просмотрщик
    // фокусирован на ОДНОМ кадре — пересылаем именно его, но через gallery-aware
    // трубу: она СНИМАЕТ поле `com.liza.gallery` (иначе одиночный форвард члена
    // альбома тащил бы старый id/n → у получателя фантом-спиннеры).
    final contents = await buildForwardedGalleryContents(
      currentEvent.room.client,
      [currentEvent],
    );
    if (!mounted) return; // fetchSenderUser — сетевой await, виджет мог уйти
    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: contents.map(ContentShareItem.new).toList(),
      ),
    );
  }

  /// Save this file with a system call.
  void saveFileAction(BuildContext context) {
    if (isContentProtected) return;
    currentEvent.saveFile(context);
  }

  /// Save this file with a system call.
  void shareFileAction(BuildContext context) {
    if (isContentProtected) return;
    currentEvent.shareFile(context);
  }

  static const maxScaleFactor = 1.5;

  /// Go back if user swiped it away
  void onInteractionEnds(ScaleEndDetails endDetails) {
    if (PlatformInfos.usesTouchscreen == false) {
      if (endDetails.velocity.pixelsPerSecond.dy >
          MediaQuery.sizeOf(context).height * maxScaleFactor) {
        Navigator.of(context, rootNavigator: false).pop();
      }
    }
  }

  @override
  void dispose() {
    isZoomed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ImageViewerView(this);
}
