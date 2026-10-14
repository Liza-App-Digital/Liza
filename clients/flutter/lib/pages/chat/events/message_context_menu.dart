import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/utils/news_poll.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/events/message_content.dart';
import 'package:liza/pages/chat/events/reply_content.dart';
import 'package:liza/pages/chat/events/xl_buttons_content.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/copy_media_eligibility.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/message_link.dart';
import 'package:liza/utils/stories/story_model.dart';
import 'package:liza/widgets/matrix.dart';

/// Контекстное меню сообщения в стиле Liza: единый заякоренный поповер —
/// затемнённый фон, «вылетающий» снимок пузыря, ряд быстрых реакций сверху и
/// вертикальный список действий под/над пузырём.
///
/// Открывается из [ChatController.onMessageContextMenu] по long-press (mobile)
/// / правому клику (desktop) на ОДНОМ сообщении. Снимок пузыря снимается
/// синхронно через `RenderRepaintBoundary.toImageSync` (см. [bubbleRect]) —
/// без асинхронного мигания. Поповер НЕ трогает `selectedEvents`: мультивыбор
/// остаётся отдельным режимом, входимым пунктом «Выбрать».
///
/// Возвращает маршрут поповера: он висит на корневом навигаторе и переживает
/// закрытие чата, поэтому [ChatController] снимает его в `dispose`.
Route<void> showMessageContextMenu({
  required ChatController controller,
  required Event event,
  required Timeline timeline,
  required ui.Image snapshot,
  required Rect bubbleRect,
  required bool ownMessage,
}) {
  HapticFeedback.mediumImpact();
  // Держатель выделения живёт ровно столько, сколько этот поповер: новое
  // открытие — новый держатель, иначе фрагмент прошлого сообщения утёк бы в
  // копию следующего.
  final selection = ValueNotifier<String?>(null);
  final route = PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    fullscreenDialog: true,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (context, animation, secondaryAnimation) =>
        _MessageContextMenu(
          controller: controller,
          event: event,
          timeline: timeline,
          snapshot: snapshot,
          bubbleRect: bubbleRect,
          ownMessage: ownMessage,
          animation: animation,
          selection: selection,
        ),
  );
  Navigator.of(
    controller.context,
    rootNavigator: true,
  ).push(route).whenComplete(selection.dispose);
  return route;
}

/// Можно ли в поповере включить живой selectable-слой текста поверх снимка
/// (выделение части сообщения → копировать, Liza 1:1). Условия:
/// снимок в натуральном размере (`bubbleFullSize`, иначе масштабированный
/// `BoxFit.fill` разошёлся бы с живым текстом), канал НЕ защищён
/// (`!contentProtected` — не открываем третий путь выноса контента в обход
/// запрета, класс бага 1a76d221) и сообщение рендерится как обычный текст.
@visibleForTesting
bool canSelectTextInPopover({
  required Event event,
  required bool contentProtected,
  required bool bubbleFullSize,
}) => !contentProtected && bubbleFullSize && rendersAsPlainText(event);

/// Рендерится ли событие как ОБЫЧНЫЙ HTML-текст (default-ветка [MessageContent]
/// → [HtmlMessage]). Только для таких сообщений в поповере включаем живой
/// selectable-слой поверх снимка (Liza: выделить часть текста → копировать).
/// Медиа/аудио/файл/карточки/поллы имеют другую вёрстку — прозрачный текст-оверлей
/// лёг бы мимо глифов снимка, поэтому их исключаем (остаётся снимок как сейчас).
@visibleForTesting
bool rendersAsPlainText(Event event) {
  if (event.type != EventTypes.Message || event.redacted) return false;
  const nonText = {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Sticker,
    MessageTypes.Audio,
    MessageTypes.File,
    MessageTypes.Location,
    MessageTypes.BadEncrypted,
    CuteEventContent.eventType,
    'com.liza.miniapp.launch',
    'com.liza.miniapp.choice',
    'com.liza.miniapp.list',
    'com.liza.miniapp.data',
    newsPollMsgType,
  };
  if (nonText.contains(event.messageType)) return false;
  // Медиа с подписью — тоже не «обычный текст» (свой caption-путь).
  if (event.isMediaEvent || event.fileDescription != null) return false;
  // Карточки, подменяющие текст на нестандартную вёрстку.
  if (event.content.containsKey(storyRefKey)) return false;
  if (event.content.containsKey(XlButtonsContent.contentKey)) return false;
  // Голая ссылка-на-сообщение → карточка-превью вместо текста (тот же гейт, что
  // в MessageContent).
  if (event.messageType == MessageTypes.Text) {
    final bareLink = MessageLink.bareLinkFrom(event.body);
    if (bareLink != null &&
        event.room.client.getRoomById(bareLink.roomId) != null) {
      return false;
    }
  }
  return true;
}

class _MenuAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool destructive;

  const _MenuAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.destructive = false,
  });
}

class _MessageContextMenu extends StatelessWidget {
  final ChatController controller;
  final Event event;
  final Timeline timeline;
  final ui.Image snapshot;
  final Rect bubbleRect;
  final bool ownMessage;
  final Animation<double> animation;

  /// Последнее НЕПУСТОЕ выделение в живом слое текста (см. [SelectableTextOverlay]).
  final ValueNotifier<String?> selection;

  const _MessageContextMenu({
    required this.controller,
    required this.event,
    required this.timeline,
    required this.snapshot,
    required this.bubbleRect,
    required this.ownMessage,
    required this.animation,
    required this.selection,
  });

  static const double _reactionRowHeight = 56;
  static const double _menuItemHeight = 48;
  static const double _gap = 8;
  static const double _sidePadding = 8;

  // Право на РЕАКЦИЮ, а не на сообщение: в канале events_default:100, и гейт
  // на canSendDefaultMessages прятал реакции у всех подписчиков.
  bool get _canReact =>
      event.status.isSent &&
      event.messageType != MessageTypes.BadEncrypted &&
      controller.room.canSendReaction;

  /// [selectedText] — фрагмент, выделенный в живом слое поповера (null/пусто =
  /// пользователь ничего не выделял). От него зависит ТОЛЬКО пункт копирования
  /// текста: набор и порядок пунктов не меняются, поэтому геометрию меню можно
  /// считать по вызову с `selectedText: null`.
  List<_MenuAction> _buildActions(BuildContext context, String? selectedText) {
    final l10n = L10n.of(context);
    final actions = <_MenuAction>[];
    // Владелец канала запретил вынос контента подписчикам (com.liza.channel
    // .no_forwards) — прячем пункты, которые копируют/пересылают/сохраняют
    // содержимое наружу. Админов канала (PL >= 100) не ограничиваем.
    final contentProtected = controller.room.isContentProtected;

    void close() => Navigator.of(context).pop();

    final isSent = event.status.isSent;
    final isError = event.status.isError;
    final isBadEncrypted = event.messageType == MessageTypes.BadEncrypted;

    // Не отправленное (sending) / ошибка отправки — кардинально другой набор.
    if (!isSent) {
      if (isError) {
        actions.add(
          _MenuAction(
            icon: Icons.refresh_outlined,
            label: l10n.tryToSendAgain,
            onTap: () {
              close();
              controller.resendEvent(event);
            },
          ),
        );
      }
      actions.add(
        _MenuAction(
          icon: Icons.delete_outlined,
          label: l10n.remove,
          destructive: true,
          onTap: () {
            close();
            controller.deleteLocalEvent(event);
          },
        ),
      );
      return actions;
    }

    if (controller.room.canSendDefaultMessages && !isBadEncrypted) {
      actions.add(
        _MenuAction(
          icon: Icons.reply_outlined,
          label: l10n.reply,
          onTap: () {
            close();
            controller.replyToEvent(event);
          },
        ),
      );
    }

    // На медиа без подписи «Скопировать текст» скопировал бы generic-заглушку
    // («Отправил картинку»), а не осмысленный текст — прячем его. Само
    // изображение копируется отдельным пунктом «Скопировать изображение» ниже.
    // Гейт считаем на DISPLAY-событии — как и `copyEvent`, иначе у
    // отредактированной подписи показ пункта и копия разъехались бы по версиям.
    final displayEventForCopy = event.getDisplayEvent(timeline);
    final hasCopyableText = shouldOfferCopyText(
      isMedia: displayEventForCopy.isMediaEvent,
      hasCaption: displayEventForCopy.fileDescription != null,
    );
    if (!contentProtected &&
        !isBadEncrypted &&
        !event.redacted &&
        hasCopyableText) {
      // Если пользователь выделил кусок в живом слое — копируем ИМЕННО его, а не
      // всё событие (жалоба 2026-09-08: «копирую фразу — копируется всё
      // сообщение целиком»). Раньше этот пункт безусловно звал `copyEvent`, и
      // выделение молча игнорировалось; на web-desktop он вообще единственный
      // путь копирования — там всплывающий тулбар выделения подавлен браузером
      // (`_webContextMenuEnabled`).
      final fragment = selectedText?.trim();
      final hasSelection = fragment != null && fragment.isNotEmpty;
      actions.add(
        _MenuAction(
          icon: Icons.copy_outlined,
          label: hasSelection ? l10n.copySelection : l10n.copyToClipboard,
          onTap: () {
            close();
            if (hasSelection) {
              controller.copySelectedText(fragment);
            } else {
              controller.copyEvent(event);
            }
          },
        ),
      );
    }

    if (!contentProtected && controller.canCopyMedia(event)) {
      actions.add(
        _MenuAction(
          icon: Icons.photo_library_outlined,
          label: l10n.copyImage,
          onTap: () {
            close();
            controller.copyMediaEvent(event);
          },
        ),
      );
    }

    if (controller.canCopyMessageLink(event)) {
      actions.add(
        _MenuAction(
          icon: Icons.link_outlined,
          label: l10n.copyMessageLink,
          onTap: () {
            close();
            controller.copyMessageLink(event);
          },
        ),
      );
    }

    if (!contentProtected && controller.canSaveEvent(event)) {
      actions.add(
        _MenuAction(
          icon: Icons.download_outlined,
          label: l10n.saveFile,
          onTap: () {
            close();
            controller.saveEvent(event);
          },
        ),
      );
    }

    if (controller.canEditEvent(event)) {
      actions.add(
        _MenuAction(
          icon: Icons.edit_outlined,
          label: l10n.edit,
          onTap: () {
            close();
            controller.editEventAction(event);
          },
        ),
      );
    }

    if (controller.canPinEvent(event)) {
      final pinned = controller.room.pinnedEventIds.contains(event.eventId);
      actions.add(
        _MenuAction(
          icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
          label: pinned ? l10n.unpin : l10n.pinMessage,
          onTap: () {
            close();
            controller.togglePinEvent(event);
          },
        ),
      );
    }

    if (!contentProtected && !isBadEncrypted) {
      actions.add(
        _MenuAction(
          icon: Icons.forward_outlined,
          label: l10n.forward,
          onTap: () {
            close();
            controller.forwardEvent(event);
          },
        ),
      );
    }

    actions.add(
      _MenuAction(
        icon: Icons.check_circle_outline,
        label: l10n.select,
        onTap: () {
          close();
          controller.onSelectMessage(event);
        },
      ),
    );

    if (Matrix.of(context).isCurrentUserDeveloper) {
      actions.add(
        _MenuAction(
          icon: Icons.info_outline,
          label: l10n.messageInfo,
          onTap: () {
            close();
            controller.showEventInfo(event);
          },
        ),
      );
    }

    if (!ownMessage) {
      actions.add(
        _MenuAction(
          icon: Icons.flag_outlined,
          label: l10n.reportMessage,
          destructive: true,
          onTap: () {
            close();
            controller.reportEvent(event);
          },
        ),
      );
    }

    if (controller.canRedactEvent(event)) {
      // Удаление текста и медиа называем по-разному: «Удалить сообщение» vs
      // «Удалить контент» — иначе единая подпись на медиа вводит в заблуждение.
      actions.add(
        _MenuAction(
          icon: Icons.delete_outlined,
          label: event.isMediaEvent ? l10n.redactContent : l10n.redactMessage,
          destructive: true,
          onTap: () {
            close();
            controller.redactEvent(event);
          },
        ),
      );
    }

    return actions;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final screen = media.size;

    final actions = _buildActions(context, null);
    final menuWidth = (screen.width - _sidePadding * 2).clamp(0.0, 280.0);
    final reactionRowHeight = _canReact ? _reactionRowHeight + _gap : 0.0;

    final topSafe = media.padding.top + _sidePadding;
    final bottomSafe =
        screen.height -
        media.padding.bottom -
        media.viewInsets.bottom -
        _sidePadding;
    final available = (bottomSafe - topSafe).clamp(0.0, double.infinity);

    // Меню не выше доступного места (минус реакции) — иначе скроллится внутри
    // (клавиатура / низкий экран / много пунктов).
    final maxMenuHeight = (available - reactionRowHeight - _gap).clamp(
      0.0,
      double.infinity,
    );
    final menuHeight = (actions.length * _menuItemHeight + 12).clamp(
      0.0,
      maxMenuHeight,
    );

    // Снимок пузыря масштабируем вниз под остаток места; если места нет совсем —
    // прячем снимок (size 0), оставляя реакции и меню.
    var bubbleWidth = bubbleRect.width;
    var bubbleHeight = bubbleRect.height;
    final maxBubbleHeight = available - reactionRowHeight - menuHeight - _gap;
    if (maxBubbleHeight <= 0) {
      bubbleWidth = 0;
      bubbleHeight = 0;
    } else if (bubbleHeight > maxBubbleHeight) {
      final scale = maxBubbleHeight / bubbleHeight;
      bubbleWidth *= scale;
      bubbleHeight *= scale;
    }

    var bubbleLeft = bubbleRect.left;
    bubbleLeft = bubbleLeft.clamp(
      _sidePadding,
      (screen.width - _sidePadding - bubbleWidth).clamp(
        _sidePadding,
        double.infinity,
      ),
    );

    // Держим пузырь рядом с исходным местом, затем зажимаем группу в экран.
    var bubbleTop = bubbleRect.top;
    final groupTop = bubbleTop - reactionRowHeight;
    if (groupTop < topSafe) bubbleTop += topSafe - groupTop;
    final groupBottom = bubbleTop + bubbleHeight + _gap + menuHeight;
    if (groupBottom > bottomSafe) bubbleTop -= groupBottom - bottomSafe;
    if (bubbleTop - reactionRowHeight < topSafe) {
      bubbleTop = topSafe + reactionRowHeight;
    }

    final targetRect = Rect.fromLTWH(
      bubbleLeft,
      bubbleTop,
      bubbleWidth,
      bubbleHeight,
    );
    // Живой selectable-слой (выделение части текста, Liza 1:1) вешаем ТОЛЬКО
    // когда снимок показан в натуральном размере (`scale == 1`): иначе
    // отмасштабированный `BoxFit.fill` снимок разошёлся бы с не-масштабируемым
    // живым текстом и выделение легло бы мимо глифов. Защищённые каналы
    // (`isContentProtected`) — без выделения, чтобы не открыть третий путь выноса
    // контента в обход запрета (класс бага, закрытого 1a76d221).
    final bubbleScaled = bubbleWidth < bubbleRect.width - 0.5;
    final canSelectText = canSelectTextInPopover(
      event: event,
      contentProtected: controller.room.isContentProtected,
      bubbleFullSize: !bubbleScaled && maxBubbleHeight > 0,
    );
    final bubbleRight = bubbleLeft + bubbleWidth;
    final menuTop = bubbleTop + bubbleHeight + _gap;
    final reactionTop = bubbleTop - _reactionRowHeight - _gap;

    // Меню и реакции якорим к ГОРИЗОНТАЛИ пузыря (как в Liza — у того же
    // сообщения, рядом с курсором), а не к краю экрана. Для своих сообщений
    // прижимаем к правому краю пузыря, для чужих — к левому.
    final maxMenuLeft = (screen.width - _sidePadding - menuWidth).clamp(
      _sidePadding,
      double.infinity,
    );
    final menuLeft = (ownMessage ? bubbleRight - menuWidth : bubbleLeft).clamp(
      _sidePadding,
      maxMenuLeft,
    );

    // Дедуп уже поставленных реакций считаем один раз (скан таймлайна), а не на
    // каждом кадре анимации внутри _ReactionRow.
    final sentReactions = _canReact
        ? controller.sentReactionsOf(event)
        : const <String>{};

    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = animation.value;
        final lift = Curves.easeOutCubic.transform(t);
        final fade = Curves.easeOut.transform(t);
        final currentRect = Rect.lerp(bubbleRect, targetRect, lift)!;

        return Stack(
          children: [
            // Затемнение фона + закрытие по тапу-вне.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55 * fade),
                ),
              ),
            ),
            // «Вылетающий» снимок пузыря. По завершении анимации (посадка) поверх
            // снимка монтируем прозрачный selectable-слой живого текста: снимок
            // даёт весь chrome (фон/градиент/цитата/время) пиксель-точно, а
            // невидимый живой текст сверху ложится на глифы снимка и даёт
            // выделение части сообщения с копированием (Liza 1:1).
            Positioned.fromRect(
              rect: currentRect,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppConfig.borderRadius),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.28 * fade),
                      blurRadius: 24 * fade,
                      offset: Offset(0, 6 * fade),
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    IgnorePointer(
                      child: RawImage(image: snapshot, fit: BoxFit.fill),
                    ),
                    if (canSelectText &&
                        animation.status == AnimationStatus.completed)
                      SelectableTextOverlay(
                        event: event,
                        timeline: timeline,
                        ownMessage: ownMessage,
                        selection: selection,
                      ),
                  ],
                ),
              ),
            ),
            // Ряд быстрых реакций над пузырём, прижатый к его стороне.
            if (_canReact)
              Positioned(
                top: reactionTop,
                left: ownMessage
                    ? null
                    : bubbleLeft.clamp(_sidePadding, maxMenuLeft),
                right: ownMessage
                    ? (screen.width - bubbleRight).clamp(
                        _sidePadding,
                        double.infinity,
                      )
                    : null,
                child: Opacity(
                  opacity: fade,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: screen.width - _sidePadding * 2,
                    ),
                    child: _ReactionRow(
                      controller: controller,
                      event: event,
                      sentReactions: sentReactions,
                      scale: 0.9 + 0.1 * fade,
                    ),
                  ),
                ),
              ),
            // Вертикальный список действий под пузырём, у его стороны.
            Positioned(
              top: menuTop,
              left: menuLeft,
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: 0.92 + 0.08 * fade,
                  alignment: ownMessage
                      ? Alignment.topRight
                      : Alignment.topLeft,
                  child: SizedBox(
                    width: menuWidth,
                    height: menuHeight,
                    // Пункт копирования зависит от текущего выделения (подпись и
                    // действие), поэтому меню перестраивается на его изменение.
                    // Геометрия выше от выделения не зависит — набор пунктов
                    // тот же.
                    child: ValueListenableBuilder<String?>(
                      valueListenable: selection,
                      builder: (context, selectedText, _) => _ActionMenu(
                        actions: _buildActions(context, selectedText),
                        theme: theme,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Прозрачный живой слой текста поверх снимка пузыря — даёт выделение части
/// сообщения и копирование фрагмента (Liza 1:1). Рендерит ТОТ ЖЕ
/// [MessageContent] с прозрачным цветом текста: глифы невидимы (их рисует
/// снимок под слоем), но вёрстка идентична — значит подсветка выделения ложится
/// ровно на текст снимка, а встроенная кнопка «Копировать» кладёт в буфер
/// реальный текст. Reply-цитата резервируется невидимым стабом той же высоты,
/// чтобы текст встал под ней как на снимке; сама цитата в выделение не входит
/// ([SelectionContainer.disabled]). Своя панель «Копировать» вместо системного
/// ОС-тулбара — чтобы он не всплывал поверх вертикального меню поповера.
class SelectableTextOverlay extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final bool ownMessage;

  /// Куда публиковать выделенный фрагмент, чтобы пункт меню «Скопировать»
  /// положил в буфер именно его. `null` — слой используется без меню (тесты).
  final ValueNotifier<String?>? selection;

  const SelectableTextOverlay({
    super.key,
    required this.event,
    required this.timeline,
    required this.ownMessage,
    this.selection,
  });

  @override
  Widget build(BuildContext context) {
    final displayEvent = event.getDisplayEvent(timeline);
    final hasReply = event.inReplyToEventId(includingFallback: false) != null;

    return SelectionArea(
      // Основной канал выделения — пункт «Скопировать выделенное» поповера.
      // Запоминаем только НЕПУСТОЕ значение и никогда не затираем его на null:
      // нажатие пункта меню уводит фокус из SelectableRegion, тот чистит
      // выделение — и обнулённый держатель отдал бы в буфер всё сообщение.
      onSelectionChanged: (content) {
        final holder = selection;
        if (holder == null) return;
        final text = content?.plainText.trim();
        if (text != null && text.isNotEmpty) holder.value = text;
      },
      // Своя панель с ЕДИНСТВЕННОЙ кнопкой «Копировать» вместо полного системного
      // ОС-тулбара (иначе «Выделить всё/Поделиться» всплыли бы поверх нашего
      // вертикального меню). Берём встроенный copy-item (его onPressed не
      // deprecated), меняем подпись на нашу и по нажатию закрываем поповер.
      contextMenuBuilder: (menuContext, selectableRegionState) {
        final copyItems = selectableRegionState.contextMenuButtonItems
            .where((item) => item.type == ContextMenuButtonType.copy)
            .toList();
        if (copyItems.isEmpty) return const SizedBox.shrink();
        return AdaptiveTextSelectionToolbar.buttonItems(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: [
            for (final item in copyItems)
              ContextMenuButtonItem(
                type: item.type,
                label: L10n.of(menuContext).copyToClipboard,
                onPressed: () {
                  item.onPressed?.call();
                  Navigator.of(menuContext, rootNavigator: true).pop();
                },
              ),
          ],
        );
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Reply-цитата: резервируем её ТОЧНУЮ высоту невидимым стабом (тот же
          // виджет/паддинги, что в пузыре), чтобы текст-слой лёг под цитатой
          // ровно как на снимке. Из выделения исключена.
          if (hasReply)
            SelectionContainer.disabled(
              // Opacity(0) сохраняет РАЗМЕР в лэйауте (резервирует высоту цитаты),
              // но не рисует — цитату показывает снимок под слоем.
              child: Opacity(opacity: 0.0, child: _replyOffsetStub()),
            ),
          MessageContent(
            displayEvent,
            textColor: Colors.transparent,
            linkColor: Colors.transparent,
            borderRadius: BorderRadius.circular(AppConfig.borderRadius),
            timeline: timeline,
            selected: false,
          ),
        ],
      ),
    );
  }

  /// Копия reply-цитаты из `message.dart` (те же паддинги/виджет), нужна ТОЛЬКО
  /// ради высоты — рисуется невидимо. Fallback-событие «...» повторяет пузырь,
  /// чтобы высота совпала и до подгрузки настоящего reply-события.
  Widget _replyOffsetStub() {
    return FutureBuilder<Event?>(
      future: event.getReplyEvent(timeline),
      builder: (context, snapshot) {
        final replyEvent = snapshot.hasData
            ? snapshot.data!
            : Event(
                eventId: event.inReplyToEventId() ?? '\$fake_event_id',
                content: {'msgtype': 'm.text', 'body': '...'},
                senderId: event.senderId,
                type: 'm.room.message',
                room: event.room,
                status: EventStatus.sent,
                originServerTs: DateTime.now(),
              );
        return Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 8),
          child: ReplyContent(
            replyEvent,
            ownMessage: ownMessage,
            timeline: timeline,
          ),
        );
      },
    );
  }
}

class _ActionMenu extends StatelessWidget {
  final List<_MenuAction> actions;
  final ThemeData theme;

  const _ActionMenu({required this.actions, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      // Скроллится, если в редком случае меню выше отведённой высоты.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final action in actions)
              InkWell(
                // Не забираем фокус: иначе живой слой выделения теряет его при
                // нажатии и чистит выделение ДО того, как отработает onTap.
                canRequestFocus: false,
                onTap: action.onTap,
                child: SizedBox(
                  height: _MessageContextMenu._menuItemHeight,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            action.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              color: action.destructive
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                        ),
                        Icon(
                          action.icon,
                          size: 22,
                          color: action.destructive
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurface,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ReactionRow extends StatelessWidget {
  final ChatController controller;
  final Event event;
  final Set<String> sentReactions;
  final double scale;

  const _ReactionRow({
    required this.controller,
    required this.event,
    required this.sentReactions,
    required this.scale,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Transform.scale(
      scale: scale,
      alignment: Alignment.bottomCenter,
      child: Material(
        elevation: 8,
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final emoji in AppConfig.defaultReactions)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Opacity(
                    opacity: sentReactions.contains(emoji) ? 0.4 : 1,
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    controller.toggleReaction(event, emoji);
                  },
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.add_reaction_outlined),
                tooltip: L10n.of(context).customReaction,
                onPressed: () => _pickCustomReaction(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickCustomReaction(BuildContext context) async {
    final theme = Theme.of(context);
    Navigator.of(context).pop();
    final emoji = await showAdaptiveBottomSheet<String>(
      context: controller.context,
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).customReaction),
          leading: CloseButton(
            onPressed: () => Navigator.of(context).pop(null),
          ),
        ),
        body: SizedBox(
          height: double.infinity,
          child: EmojiPicker(
            onEmojiSelected: (_, emoji) =>
                Navigator.of(context).pop(emoji.emoji),
            config: Config(
              locale: Localizations.localeOf(context),
              emojiViewConfig: const EmojiViewConfig(
                backgroundColor: Colors.transparent,
              ),
              bottomActionBarConfig: const BottomActionBarConfig(
                enabled: false,
              ),
              categoryViewConfig: CategoryViewConfig(
                initCategory: Category.SMILEYS,
                backspaceColor: theme.colorScheme.primary,
                iconColor: theme.colorScheme.primary.withAlpha(128),
                iconColorSelected: theme.colorScheme.primary,
                indicatorColor: theme.colorScheme.primary,
                backgroundColor: theme.colorScheme.surface,
              ),
              skinToneConfig: SkinToneConfig(
                dialogBackgroundColor: Color.lerp(
                  theme.colorScheme.surface,
                  theme.colorScheme.primaryContainer,
                  0.75,
                )!,
                indicatorColor: theme.colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
    if (emoji == null) return;
    controller.toggleReaction(event, emoji);
  }
}
