import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:matrix/matrix.dart';

import '../../config/app_config.dart';
import '../../config/themes.dart';
import '../../l10n/l10n.dart';
import '../../utils/stories/stories_extension.dart';
import '../../utils/stories/story_model.dart';
import '../../utils/stories/story_overlay_geometry.dart';
import '../../widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import '../../widgets/avatar.dart';
import '../../widgets/matrix.dart';
import '../../widgets/mxc_image.dart';
import '../image_viewer/video_player.dart';
import 'story_media_canvas.dart';
import 'story_mute_button.dart';
import 'story_viewer.dart';

// Высота чёрной зоны под медиа для нижней панели (инпут ответа у чужих сторис,
// статистика у своих). Медиа заканчивается выше на эту величину, панель лежит
// в зоне под медиа, а не поверх неё. ~ высота компактного инпута (40) + отступы.
const double _bottomPanelHeight = 64;

class StoryViewerView extends StatelessWidget {
  const StoryViewerView(this.controller, {super.key});

  final StoryViewerController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: PageView.builder(
        controller: controller.pageController,
        onPageChanged: controller.onAuthorPageChanged,
        itemCount: controller.roomIdsCount,
        itemBuilder: (context, page) {
          if (page != controller.authorIndex) {
            // Соседняя страница при свайпе: чёрный фон (контент грузится
            // только для активного автора).
            return const ColoredBox(color: Colors.black);
          }
          return _buildActiveAuthor(context);
        },
      ),
    );
  }

  void _handleTap(BuildContext context, TapUpDetails details) {
    // Если активен ввод ответа (клавиатура открыта) - тап по сторис снимает
    // фокус (закрывает клавиатуру), а НЕ переключает сегмент. Иначе выйти из
    // поля тапом по медиа было бы невозможно (тап пролистывал бы историю).
    if (controller.replyFocus.hasFocus) {
      controller.replyFocus.unfocus();
      return;
    }
    // Зоны навигации по горизонтали: тап левее левой трети экрана - назад,
    // иначе вперёд. Медиа во всю ширину экрана, деление идёт по ширине области.
    final width = MediaQuery.of(context).size.width;
    final localX = details.localPosition.dx;
    if (localX < width / 3) {
      controller.prev();
    } else {
      controller.next();
    }
  }

  Widget _buildActiveAuthor(BuildContext context) {
    final segments = controller.segments;
    if (segments.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final event = segments[controller.index];
    final story = StoryContent.fromContent(event.content);
    final isVideo = event.content['msgtype'] == 'm.video';
    final client = Matrix.of(context).client;
    final r = controller.room!;
    final owner = client.storyOwnerOf(r);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): controller.close,
        const SingleActivator(LogicalKeyboardKey.arrowRight): controller.next,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): controller.prev,
      },
      child: Focus(
        autofocus: true,
        // RawGestureDetector вместо GestureDetector: нужен кастомный порог
        // удержания. Дефолтный long-press (kLongPressTimeout = 500 мс)
        // ощущается медленным - ставим 200 мс, чтобы "заморозка" срабатывала
        // почти сразу. Удержание только паузит (onHoldStart), UI не скрывает.
        child: RawGestureDetector(
          gestures: {
            TapGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                  () => TapGestureRecognizer(),
                  (r) => r.onTapUp = (details) => _handleTap(context, details),
                ),
            VerticalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  VerticalDragGestureRecognizer
                >(() => VerticalDragGestureRecognizer(), (r) {
                  r.onEnd = (d) {
                    if ((d.primaryVelocity ?? 0) > 200) controller.close();
                  };
                }),
            LongPressGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<
                  LongPressGestureRecognizer
                >(
                  () => LongPressGestureRecognizer(
                    duration: const Duration(milliseconds: 200),
                  ),
                  (r) {
                    r.onLongPressStart = (_) => controller.onHoldStart();
                    r.onLongPressEnd = (_) => controller.onHoldEnd();
                    r.onLongPressCancel = controller.onHoldEnd;
                  },
                ),
          },
          child: LayoutBuilder(
            builder: (context, c) {
              final area = Size(c.maxWidth, c.maxHeight);
              final topInset = MediaQuery.of(context).padding.top;
              final bottomInset = MediaQuery.of(context).padding.bottom;
              // Раскладка как в Liza/IG: медиа сверху под статус-баром, таймлайн
              // и автор - оверлеи ПОВЕРХ верха медиа. Нижняя панель (инпут
              // ответа у чужих сторис, статистика у своих) - НЕ поверх медиа:
              // под неё резервируется чёрная зона ПОД медиа (медиа заканчивается
              // выше на _bottomPanelHeight). Панель видна всегда (удержание
              // пальца её не скрывает, только паузит сторис).
              final media = storyViewerMediaRect(
                area,
                topInset: topInset,
                bottomInset: bottomInset,
                bottomPanelHeight: _bottomPanelHeight,
                // На широком desktop/web-окне режем ширину под 9:16 (letterbox
                // по бокам), высота остаётся на весь экран. На мобильном
                // (область уже 9:16) ограничение не срабатывает.
                maxAspect: storyFrameAspect,
              );

              return Stack(
                fit: StackFit.expand,
                children: [
                  // Медиа заполняет почти весь экран (cover, как в Liza/IG),
                  // углы скруглены (ClipRRect). ValueKey по eventId пересоздаёт
                  // виджет при смене сегмента (баг №5: без key Flutter
                  // переиспользовал State и показывал картинку первого сториса
                  // для всех последующих).
                  Positioned.fromRect(
                    rect: media,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        storyFrameCornerRadius,
                      ),
                      child: _buildStoryMedia(
                        event: event,
                        story: story,
                        isVideo: isVideo,
                        controller: controller,
                        media: media,
                      ),
                    ),
                  ),
                  // Лёгкий верхний градиент - чтобы таймлайн/крестик не
                  // сливались со светлым фото (референс Liza).
                  // IgnorePointer: чисто визуальный слой, не должен
                  // перехватывать тапы навигации по кадру (onTapUp выше).
                  Positioned(
                    left: media.left,
                    top: media.top,
                    width: media.width,
                    height: media.height * 0.15,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.black45, Colors.transparent],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Текст-оверлеи: позиционируем от прямоугольника медиа
                  // (mediaContainRect), а не от всей области Stack.
                  // Так x/y-доли редактора и просмотрщика совпадают при
                  // любом соотношении сторон экрана.
                  if (story != null)
                    for (final o in story.overlays)
                      Builder(
                        builder: (_) {
                          final center = fractionToLocal(o.x, o.y, media);
                          return Positioned(
                            left: center.dx,
                            top: center.dy,
                            child: FractionalTranslation(
                              translation: const Offset(-0.5, -0.5),
                              child: _OverlayLabel(
                                overlay: o,
                                areaWidth: media.width,
                                onTapLink: controller.openLink,
                              ),
                            ),
                          );
                        },
                      ),
                  // Подпись сториса (caption): full-width градиентная
                  // подложка снизу кадра (не плашка с обводкой), как в
                  // Liza. maxLines ограничивает рост вверх — при
                  // длинном тексте кнопка "ещё" разворачивает полный текст
                  // поверх затемнения (см. слой ниже в Stack).
                  // Скрываем короткий текст при развёрнутой подписи: оверлей
                  // полного текста заливает полупрозрачный black54, сквозь
                  // который collapsed-текст в той же нижней зоне просвечивал.
                  if (story?.caption != null &&
                      story!.caption!.isNotEmpty &&
                      !controller.captionExpanded)
                    Positioned(
                      left: media.left,
                      top: media.top,
                      width: media.width,
                      height: media.height,
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: _StoryCaption(
                          caption: story.caption!,
                          controller: controller,
                        ),
                      ),
                    ),
                  // Панель зрителя (чужая сторис): поле ответа автору +
                  // кнопка реакций + опциональный ряд быстрых реакций.
                  // Отступы как в обычном инпуте чата; поднимается над
                  // клавиатурой (viewInsets.bottom). Удержание пальца НЕ
                  // скрывает панель (только паузит сторис).
                  if (!controller.isOwnStory)
                    Positioned(
                      // По ширине медиа (медиа во всю ширину экрана): панель не
                      // должна выглядеть уже сториса. Небольшой внутренний зазор
                      // 8, чтобы капсула инпута не прилипала к самому краю.
                      left: media.left + 8,
                      right: (c.maxWidth - media.right) + 8,
                      // Инпут лежит в ЧЁРНОЙ ЗОНЕ ПОД медиа (media.bottom выше
                      // на _bottomPanelHeight), не налезает на медиа. Без
                      // клавиатуры - у низа зоны, отступ от safe-area. При
                      // клавиатуре поднимается над ней (viewInsets); медиа не
                      // двигается (resizeToAvoidBottomInset:false).
                      bottom:
                          (MediaQuery.of(context).viewInsets.bottom > 0
                              ? MediaQuery.of(context).viewInsets.bottom
                              : bottomInset) +
                          12,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (controller.reactionRowOpen)
                            _StoryReactionRow(controller: controller),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: controller.replyController,
                                  focusNode: controller.replyFocus,
                                  style: const TextStyle(color: Colors.white),
                                  textCapitalization:
                                      TextCapitalization.sentences,
                                  minLines: 1,
                                  maxLines: 5,
                                  decoration: InputDecoration(
                                    hintText: L10n.of(context).storyReplyHint,
                                    hintStyle: const TextStyle(
                                      color: Colors.white70,
                                    ),
                                    filled: true,
                                    // Цвет подложки зависит от фокуса: без
                                    // фокуса инпут лежит в ЧЁРНОЙ зоне под медиа
                                    // - светлый, чтобы не сливаться. При вводе
                                    // (фокус) он поднят над клавиатурой ПОВЕРХ
                                    // обычно светлой сторис - тёмный, чтобы
                                    // читаться и контрастировать.
                                    fillColor: controller.replyFocus.hasFocus
                                        ? Colors.black54
                                        : Colors.white24,
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(24),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                  textInputAction: TextInputAction.send,
                                  onSubmitted: (_) =>
                                      controller.sendReplyToAuthor(),
                                ),
                              ),
                              const SizedBox(width: 8),
                              _ReplyTrailingButton(controller: controller),
                            ],
                          ),
                        ],
                      ),
                    ),
                  // Статистика автора (свои сторис): счётчик просмотров +
                  // агрегат реакций по emoji. Оверлей у низа медиа с зазором
                  // (симметрично инпуту ответа у чужих сторис), не полоса под
                  // медиа. Горизонтальный скролл: много реакций не должно
                  // переполнять ширину и рвать Row.
                  if (controller.isOwnStory)
                    Positioned(
                      // По ширине медиа (симметрично инпуту у чужих).
                      left: media.left + 8,
                      right: (c.maxWidth - media.right) + 8,
                      // В чёрной зоне под медиа (симметрично инпуту у чужих).
                      bottom: bottomInset + 12,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.remove_red_eye_outlined,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${controller.currentViewsCount}',
                                  style: const TextStyle(color: Colors.white),
                                ),
                                for (final entry
                                    in controller
                                        .reactionsAggregateOnCurrent
                                        .entries) ...[
                                  const SizedBox(width: 10),
                                  Text(
                                    '${entry.key} ${entry.value}',
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // Верх: прогресс-полоса + ряд с кнопками под ней.
                  // Оверлей ПОВЕРХ верха медиа (не отдельная полоса): медиа уже
                  // начинается под статус-баром (media.top == topInset), поэтому
                  // таймлайн не залезает под чёлку/камеру. Небольшой внутренний
                  // отступ от верха медиа. Структурная Column гарантирует, что
                  // крестик стоит НИЖЕ полосы, а не поверх неё.
                  if (!controller.chromeHidden)
                    Positioned(
                      left: media.left,
                      top: media.top + 8,
                      width: media.width,
                      child: Padding(
                        padding: EdgeInsets.zero,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Первая строка: сегменты прогресс-полосы.
                            Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                              child: Row(
                                children: [
                                  for (var i = 0; i < segments.length; i++)
                                    Expanded(
                                      child: Container(
                                        height: 3,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                          child: Stack(
                                            children: [
                                              // Фон: будущие сегменты и трек текущего.
                                              Container(color: Colors.white38),
                                              if (i < controller.index)
                                                // Пройденный сегмент: полностью белый.
                                                Container(color: Colors.white)
                                              else if (i == controller.index)
                                                // Текущий: заполняется по анимации прогресса.
                                                AnimatedBuilder(
                                                  animation:
                                                      controller.progress,
                                                  builder: (_, child) =>
                                                      FractionallySizedBox(
                                                        widthFactor: controller
                                                            .progress
                                                            .value,
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Container(
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            // Вторая строка: слева аватар/имя/время автора
                            // (кликабельно - открывает ЛС для чужих сторис),
                            // справа меню и крестик - в одном Row, чтобы блок
                            // не рос по вертикали.
                            Row(
                              children: [
                                Expanded(
                                  child: InkWell(
                                    onTap: controller.isOwnStory
                                        ? null
                                        : controller.openAuthorDm,
                                    child: Row(
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 8,
                                          ),
                                          child: Avatar(
                                            mxContent: client.storyOwnerAvatar(
                                              r,
                                              owner,
                                            ),
                                            name: client.storyOwnerName(
                                              r,
                                              owner,
                                            ),
                                            size: 32,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                client.storyOwnerName(
                                                      r,
                                                      owner,
                                                    ) ??
                                                    '',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 14,
                                                ),
                                              ),
                                              Text(
                                                _ageLabel(context, event),
                                                style: const TextStyle(
                                                  color: Colors.white70,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                // Кнопка-грамофон mute — только у видео-сторисов
                                // и только при неразвёрнутой подписи (гейт —
                                // shouldShowStoryMuteButton). Стоит в ТОЙ ЖЕ
                                // строке, что «⋮» и ✕ → выравнивается layout-
                                // движком, без magic-offset (баг ①). Читает/
                                // пишет общий controller.storyMuted → состояние
                                // держится на всех историях сессии (②③).
                                if (shouldShowStoryMuteButton(
                                  isVideo: isVideo,
                                  captionExpanded: controller.captionExpanded,
                                )) ...[
                                  StoryMuteButton(muted: controller.storyMuted),
                                  const SizedBox(width: 8),
                                ],
                                PopupMenuButton<String>(
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.more_horiz,
                                    color: Colors.white,
                                  ),
                                  onOpened: controller.pause,
                                  onCanceled: controller.resumeIfIdle,
                                  onSelected: (value) async {
                                    switch (value) {
                                      case 'share':
                                        controller.shareStory();
                                      case 'copy_link':
                                        controller.copyStoryLink();
                                      case 'toggle_notify':
                                        await controller.toggleStoryNotify();
                                        // Меню паузит таймлайн (onOpened); при
                                        // ВЫБОРЕ пункта onCanceled не вызывается
                                        // — возобновляем сами (как ветка delete),
                                        // иначе кадр зависает на паузе.
                                        controller.resumeIfIdle();
                                      case 'delete':
                                        // Паузим таймлайн на время диалога:
                                        // иначе таймер сегмента может истечь
                                        // под диалогом (next()/close() без
                                        // ведома пользователя) или index
                                        // сдвинется, и deleteCurrent() удалит
                                        // не тот сегмент.
                                        controller.pause();
                                        final consent =
                                            await showOkCancelAlertDialog(
                                              context: context,
                                              title: L10n.of(
                                                context,
                                              ).storyDeleteConfirmTitle,
                                              message: L10n.of(
                                                context,
                                              ).areYouSure,
                                              okLabel: L10n.of(context).yes,
                                              isDestructive: true,
                                            );
                                        if (consent != OkCancelResult.ok) {
                                          controller.resume();
                                          return;
                                        }
                                        await controller.deleteCurrent();
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    PopupMenuItem(
                                      value: 'share',
                                      child: Text(L10n.of(context).storyShare),
                                    ),
                                    PopupMenuItem(
                                      value: 'copy_link',
                                      child: Text(
                                        L10n.of(context).storyCopyLink,
                                      ),
                                    ),
                                    // LABA-1970: тумблер уведомлений о сторис —
                                    // только на ЧУЖИХ сторис (уведомлять о самом
                                    // себе бессмысленно).
                                    if (!controller.isOwnStory)
                                      PopupMenuItem(
                                        value: 'toggle_notify',
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              controller.isStoryNotifyEnabled
                                                  ? Icons
                                                        .notifications_off_outlined
                                                  : Icons
                                                        .notifications_active_outlined,
                                              size: 20,
                                            ),
                                            const SizedBox(width: 12),
                                            Text(
                                              L10n.of(
                                                context,
                                              ).storyNotifyMenuLabel,
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (controller.canDeleteCurrent)
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text(
                                          L10n.of(context).delete,
                                          style: TextStyle(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white,
                                  ),
                                  onPressed: controller.close,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  // Развёрнутая подпись: полный текст поверх затемнения,
                  // последний ребёнок Stack — перекрывает даже верхний
                  // блок (прогресс/аватар/крестик), пока подпись открыта.
                  if (controller.captionExpanded && story?.caption != null)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: controller.collapseCaption,
                        child: Container(
                          color: Colors.black54,
                          alignment: Alignment.bottomCenter,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: media.height * 0.6,
                            ),
                            child: SingleChildScrollView(
                              padding: EdgeInsets.fromLTRB(
                                16,
                                16,
                                16,
                                MediaQuery.of(context).padding.bottom + 16,
                              ),
                              child: Linkify(
                                text: story!.caption!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                ),
                                linkStyle: const TextStyle(
                                  color: Colors.lightBlueAccent,
                                  decoration: TextDecoration.underline,
                                ),
                                options: const LinkifyOptions(humanize: false),
                                onOpen: (link) => controller.openLink(link.url),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Текст возраста сториса для оверлея автора ("3 ч" / "5 мин").
String _ageLabel(BuildContext context, Event event) {
  final age = storyAge(DateTime.now().difference(event.originServerTs));
  return age.hours
      ? L10n.of(context).storyPostedHoursAgo(age.value)
      : L10n.of(context).storyPostedMinutesAgo(age.value);
}

/// Подпись: максимум 2 строки; при переполнении справа-снизу кнопка "ещё"
/// (жирный текст). Тап - разворачивание с затемнением (см. Stack родителя).
class _StoryCaption extends StatelessWidget {
  const _StoryCaption({required this.caption, required this.controller});

  final String caption;
  final StoryViewerController controller;

  static const _style = TextStyle(color: Colors.white, fontSize: 16);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final painter = TextPainter(
          text: TextSpan(text: caption, style: _style),
          maxLines: 3,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: c.maxWidth - 32); // горизонтальные паддинги
        final overflows = painter.didExceedMaxLines;
        return Container(
          width: double.infinity,
          // Небольшой фиксированный отступ снизу (8px, без safe-area): последняя
          // строка подписи у самого низа кадра, как просили. На iPhone с полоской
          // жестов текст окажется ближе к краю - осознанный выбор.
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 8),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Colors.black87],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Linkify(
                text: caption,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: _style,
                linkStyle: const TextStyle(
                  color: Colors.lightBlueAccent,
                  decoration: TextDecoration.underline,
                ),
                options: const LinkifyOptions(humanize: false),
                onOpen: (link) => controller.openLink(link.url),
              ),
              if (overflows)
                GestureDetector(
                  onTap: controller.expandCaption,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      L10n.of(context).storyCaptionMore,
                      style: _style.copyWith(fontWeight: FontWeight.w400),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Текст-оверлей, спозиционированный по доле x/y с якорем по центру блока.
/// Имеет полупрозрачную чёрную подложку для читаемости (баг №6).
/// https:// ссылки в тексте кликабельны через Linkify.
class _OverlayLabel extends StatelessWidget {
  const _OverlayLabel({
    required this.overlay,
    required this.areaWidth,
    this.onTapLink,
  });

  final StoryOverlay overlay;
  final double areaWidth;
  final void Function(String url)? onTapLink;

  @override
  Widget build(BuildContext context) {
    // Позиционирование (Positioned + FractionalTranslation) выполняет родитель.
    // Здесь только Container + Linkify. Ссылки авто-распознаются и кликабельны.
    return Container(
      constraints: BoxConstraints(maxWidth: areaWidth * 0.9),
      decoration: BoxDecoration(
        color: Colors.black45,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Linkify(
        text: overlay.text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 24,
          fontWeight: FontWeight.w600,
          // Двойная защита читаемости: тень + подложка.
          shadows: [Shadow(blurRadius: 6, color: Colors.black)],
        ),
        linkStyle: const TextStyle(
          color: Colors.lightBlueAccent,
          decoration: TextDecoration.underline,
        ),
        options: const LinkifyOptions(humanize: false),
        onOpen: (link) => onTapLink?.call(link.url),
      ),
    );
  }
}

/// Ряд быстрых реакций (пилюля) над панелью зрителя: набор emoji из
/// AppConfig.defaultReactions + кнопка выбора произвольного emoji.
class _StoryReactionRow extends StatelessWidget {
  const _StoryReactionRow({required this.controller});

  final StoryViewerController controller;

  @override
  Widget build(BuildContext context) {
    final mine = controller.myReactionOnCurrent;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final emoji in AppConfig.defaultReactions)
            IconButton(
              onPressed: () {
                controller.toggleStoryReaction(emoji);
                controller.toggleReactionRow();
              },
              icon: Text(
                emoji,
                style: TextStyle(
                  fontSize: 22,
                  backgroundColor: mine == emoji
                      ? Colors.white24
                      : Colors.transparent,
                ),
              ),
            ),
          IconButton(
            onPressed: controller.pickCustomStoryReaction,
            icon: const Icon(Icons.add, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// Хвостовая кнопка панели ответа: поле пустое -> реакции, есть текст ->
/// отправка (стиль как обычный инпут чата: bubbleColor + Icons.send_outlined).
class _ReplyTrailingButton extends StatelessWidget {
  const _ReplyTrailingButton({required this.controller});

  final StoryViewerController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasText = controller.replyController.text.trim().isNotEmpty;
    // Размер согласован с высотой компактного inline-поля ответа (isDense +
    // vertical:10 ~ 40px): кнопка 48 была заметно крупнее инпута.
    const size = 40.0;
    if (hasText) {
      return SizedBox(
        width: size,
        height: size,
        child: IconButton(
          tooltip: L10n.of(context).send,
          padding: EdgeInsets.zero,
          iconSize: 20,
          onPressed: controller.sendReplyToAuthor,
          style: IconButton.styleFrom(
            backgroundColor: theme.bubbleColor,
            foregroundColor: theme.onBubbleColor,
          ),
          icon: const Icon(Icons.send_outlined),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 22,
        icon: Icon(
          controller.myReactionOnCurrent == null
              ? Icons.add_reaction_outlined
              : Icons.add_reaction,
          color: Colors.white,
        ),
        onPressed: controller.toggleReactionRow,
      ),
    );
  }
}

/// Рендер медиа сториса во вьюере. Новые сторис (`story.media` с bg=blur)
/// рисуются через общий [StoryMediaCanvas] (блюр-фон + вписанный передний план с
/// трансформом автора — идентично редактору). Легаси-сторис без `media` → прежний
/// BoxFit.cover (нулевой регресс). Оверлеи/подпись рисуются ВЫШЕ этого виджета и
/// зумом не смещаются.
Widget _buildStoryMedia({
  required Event event,
  required StoryContent? story,
  required bool isVideo,
  required StoryViewerController controller,
  required Rect media,
}) {
  final Widget foreground = isVideo
      ? EventVideoPlayer(
          event,
          key: ValueKey(event.eventId),
          storyMode: true,
          fit: BoxFit.cover,
          isActive: !controller.isPaused,
          mutedNotifier: controller.storyMuted,
          onDurationKnown: controller.onVideoDuration,
          onStoryEnded: controller.next,
          // desktop-trim: окно отрезка приехало метаданными — играем срез.
          startPositionMs: story?.media?.trim?.startMs,
          endPositionMs: story?.media?.trim?.endMs,
        )
      : MxcImage(
          key: ValueKey(event.eventId),
          event: event,
          isThumbnail: false,
          fit: BoxFit.cover,
          width: media.width,
          height: media.height,
        );

  final storyMedia = story?.media;
  if (storyMedia == null ||
      storyMedia.background != StoryMediaBackground.blur) {
    return foreground; // легаси cover
  }
  return StoryMediaCanvas(
    key: ValueKey('canvas-${event.eventId}'),
    foreground: foreground,
    background: StoryMediaBackground.blur,
    scale: storyMedia.scale,
    translation: Offset(storyMedia.dx, storyMedia.dy),
    mediaAspect: _storyEventAspect(event),
    blurBackground: MxcImage(
      event: event,
      isThumbnail: true,
      fit: BoxFit.cover,
    ),
  );
}

/// Аспект (ширина/высота) медиа события из info.w/h. null — данных нет (канвас
/// деградирует к cover).
double? _storyEventAspect(Event event) {
  final info = event.content.tryGetMap<String, Object?>('info');
  final w = info?.tryGet<int>('w');
  final h = info?.tryGet<int>('h');
  if (w != null && h != null && w > 0 && h > 0) return w / h;
  return null;
}
