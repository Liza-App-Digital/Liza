import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:liza/utils/news_poll.dart';
import 'package:liza/pages/chat/events/media_caption.dart';
import 'package:matrix/matrix.dart';
import 'package:swipe_to_action/swipe_to_action.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/channel_discussion.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/date_time_extension.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/utils/string_color.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/member_actions_popup_menu_button.dart';
import 'package:liza/widgets/user_role_badge.dart';
import '../../../config/app_config.dart';
import 'channel_post_comments.dart';
import 'gallery.dart';
import 'message_bubble_row.dart';
import 'message_content.dart';
import 'message_reactions.dart';
import 'message_time.dart';
import 'forwarded_content.dart';
import 'reply_content.dart';
import 'bubble_receipts_side.dart';
import 'seen_by_receipts_sheet.dart';
import 'state_message.dart';

/// Атрибуция релея «Входящие»: сообщение клиента бот постит в единую комнату
/// владельца от своего имени, но с полем `com.liza.relay` (кто клиент). Владелец
/// видит имя/аватар/цвет клиента, а не бота, — чтобы не путаться, от кого сообщение.
String? _relayName(Event event) {
  final relay = event.content.tryGetMap<String, Object?>('com.liza.relay');
  final name = relay?['name'];
  return (name is String && name.isNotEmpty) ? name : null;
}

String? _relayCustomer(Event event) {
  final relay = event.content.tryGetMap<String, Object?>('com.liza.relay');
  final customer = relay?['customer'];
  return (customer is String && customer.isNotEmpty) ? customer : null;
}

/// Пересылка (LABA-1991): forward кладёт в `content` маркер `com.liza.forwarded`
/// (см. `ChatController.forwardEvent`). Читаем из `event.content`, а НЕ из
/// `getDisplayEvent().content` — иначе edit пересланного (SDK подменяет content на
/// `m.new_content`) стёр бы плашку. Маркер присутствует ВСЕГДА при пересылке (даже
/// пустым), поэтому пометка «Переслано» видна и когда имени нет.
bool _isForwarded(Event event) =>
    event.content.containsKey('com.liza.forwarded');

String? _forwardedName(Event event) {
  final forwarded = event.content.tryGetMap<String, Object?>(
    'com.liza.forwarded',
  );
  final name = forwarded?['from_name'];
  return (name is String && name.isNotEmpty) ? name : null;
}

/// Пост в канале: атрибутируется каналу (аватар/имя комнаты), а не автору.
/// `sender` технически конкретный админ — скрываем только при отрисовке.
bool isChannelPost(Event event) => event.room.isChannel;

class Message extends StatelessWidget {
  final Event event;
  final Event? nextEvent;
  final Event? previousEvent;
  final bool displayReadMarker;
  final void Function(Event) onSelect;
  final void Function(Event) onInfoTab;
  final void Function(String) scrollToEventId;
  final void Function() onSwipe;
  final void Function() onMention;
  final void Function() onEdit;
  final void Function(String eventId)? enterThread;
  final bool longPressSelect;
  final bool selected;
  final Set<String> selectedEventIds;
  final Timeline timeline;
  final bool highlightMarker;
  final bool animateIn;
  final void Function()? resetAnimateIn;
  final bool wallpaperMode;
  final ScrollController scrollController;
  final List<Color> colors;
  final void Function()? onExpand;
  final bool isCollapsed;

  /// originServerTs, до которого дочитал хотя бы один другой участник
  /// (Room.readUpToTs). Управляет галочками done/done_all своих сообщений.
  final int readUpToTs;

  /// Участники, чья граница прочтения стоит ровно на этом сообщении («прочитал
  /// до сюда»), с временем прочтения. Может быть непусто и для своих, и для
  /// чужих сообщений; под собственным сообщением участника аватарка не
  /// показывается. Рисуем кластер аватарок у нижнего края пузыря.
  final List<MessageReadReceipt> seenByUsers;

  /// Загруженный таймлайн обсуждения — для счётчика комментариев под постом.
  /// Пустой список в обычных чатах: плашка там всё равно не рисуется.
  final List<Map<String, dynamic>> discussionEvents;

  /// Перечитать комментарии после тихого join в чат обсуждения.
  final VoidCallback? onMembershipGained;

  /// Ключ RepaintBoundary вокруг пузыря — для синхронного снимка пузыря в
  /// «вылетающей» анимации контекстного меню (Liza-стиль).
  final GlobalKey? bubbleKey;

  /// Открыть контекстное меню сообщения (long-press / правый клик по пузырю).
  final void Function(Event)? onContextMenu;

  const Message(
    this.event, {
    this.nextEvent,
    this.previousEvent,
    this.displayReadMarker = false,
    this.longPressSelect = false,
    this.bubbleKey,
    this.onContextMenu,
    required this.onSelect,
    required this.onInfoTab,
    required this.scrollToEventId,
    required this.onSwipe,
    this.selected = false,
    this.selectedEventIds = const {},
    required this.onEdit,
    required this.timeline,
    this.highlightMarker = false,
    this.animateIn = false,
    this.resetAnimateIn,
    this.wallpaperMode = false,
    required this.onMention,
    required this.scrollController,
    required this.colors,
    this.onExpand,
    required this.enterThread,
    this.isCollapsed = false,
    this.readUpToTs = 0,
    this.seenByUsers = const [],
    this.discussionEvents = const [],
    this.onMembershipGained,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!{
      EventTypes.Message,
      EventTypes.Sticker,
      EventTypes.Encrypted,
      EventTypes.CallInvite,
      PollEventContent.startType,
    }.contains(event.type)) {
      if (event.type.startsWith('m.call.')) {
        return const SizedBox.shrink();
      }
      return StateMessage(event, onExpand: onExpand, isCollapsed: isCollapsed);
    }

    if (event.type == EventTypes.Message &&
        event.messageType == EventTypes.KeyVerificationRequest) {
      return StateMessage(event);
    }

    final client = Matrix.of(context).client;
    // Флаг ТОЛЬКО для отрисовки: выравнивание, цвет пузыря, углы, галочки.
    // Лента канала выглядит одинаково для всех, как в Liza: пост админа
    // рисуется как чужой — слева, единым цветом, без индикаторов доставки,
    // иначе автор видит свою же ленту зеркальной относительно подписчиков.
    // Права (правка/удаление/жалоба) считаются отдельно в chat.dart прямо от
    // event.senderId — эта подмена их не затрагивает.
    final ownMessage = event.senderId == client.userID && !isChannelPost(event);
    final alignment = ownMessage ? Alignment.topRight : Alignment.topLeft;

    var color = theme.colorScheme.surfaceContainerHigh;
    final displayTime =
        event.type == EventTypes.RoomCreate ||
        nextEvent == null ||
        !event.originServerTs.sameEnvironment(nextEvent!.originServerTs);
    final nextEventSameSender =
        nextEvent != null &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
        }.contains(nextEvent!.type) &&
        nextEvent!.senderId == event.senderId &&
        !displayTime;

    final previousEventSameSender =
        previousEvent != null &&
        {
          EventTypes.Message,
          EventTypes.Sticker,
          EventTypes.Encrypted,
        }.contains(previousEvent!.type) &&
        previousEvent!.senderId == event.senderId &&
        previousEvent!.originServerTs.sameEnvironment(event.originServerTs);

    final textColor = ownMessage
        ? theme.onBubbleColor
        : theme.colorScheme.onSurface;

    final linkColor = ownMessage
        ? theme.brightness == Brightness.light
              ? theme.colorScheme.primaryFixed
              : theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.primary;

    final rowMainAxisAlignment = ownMessage
        ? MainAxisAlignment.end
        : MainAxisAlignment.start;

    final displayEvent = event.getDisplayEvent(timeline);
    const hardCorner = Radius.circular(4);
    const roundedCorner = Radius.circular(AppConfig.borderRadius);
    final borderRadius = BorderRadius.only(
      topLeft: !ownMessage && nextEventSameSender ? hardCorner : roundedCorner,
      topRight: ownMessage && nextEventSameSender ? hardCorner : roundedCorner,
      bottomLeft: !ownMessage && previousEventSameSender
          ? hardCorner
          : roundedCorner,
      bottomRight: ownMessage && previousEventSameSender
          ? hardCorner
          : roundedCorner,
    );
    final isMediaMessage =
        {
          MessageTypes.Video,
          MessageTypes.Image,
          MessageTypes.Sticker,
        }.contains(displayEvent.messageType) &&
        !displayEvent.redacted;
    // У альбома подпись рисует сам `GalleryBubble` — прямо под сеткой,
    // как в Liza. Отдельный caption-bubble Message-виджета для
    // anchor-события альбома подавляем, иначе подпись задваивается
    // (media-v-format.md §8.6).
    final mediaCaption = isMediaMessage && displayEvent.galleryId == null
        ? displayEvent.fileDescription
        : null;
    final noBubble =
        isMediaMessage ||
        // Карточка-выбор и список mini App рисуют свой плоский Liza-стиль
        // (полупрозрачный пузырь/панель) — сплошной пузырь чата им не нужен,
        // иначе получается двойной непрозрачный блок.
        displayEvent.messageType == 'com.liza.miniapp.choice' ||
        displayEvent.messageType == 'com.liza.miniapp.list' ||
        (displayEvent.messageType == MessageTypes.Text &&
            displayEvent.relationshipType == null &&
            displayEvent.onlyEmotes &&
            displayEvent.numberEmotes > 0 &&
            displayEvent.numberEmotes <= 3);

    if (ownMessage) {
      color = displayEvent.status.isError
          ? Colors.redAccent
          : theme.bubbleColor;
    } else if (displayEvent.status.isError) {
      // Пост канала рисуется в «чужом» стиле ради единообразия ленты, из-за
      // чего терялась подсветка неотправленного: галочек статуса у постов
      // канала нет, и ошибку автору было видно только из контекстного меню.
      color = Colors.redAccent;
    }

    // Liza-стиль: время HH:MM у КАЖДОГО сообщения. Размещение зависит от
    // типа контента, чтобы НЕ добавлять лишнюю строку (высоту пузыря):
    //  • текст          → хвостовым inline-span в конце последней строки текста
    //                     (float; переносится только если не влезло);
    //  • голос/файл     → в конце ряда контролов (справа от mic/Тт | кнопки
    //                     скачивания, по центру по вертикали);
    //  • фото/видео/альбом → оверлеем в правом НИЖНЕМ углу поверх медиа;
    //  • подпись медиа  → строкой под подписью (caption-бабл ниже);
    //  • опрос/гео/miniapp → строкой под контентом (редкие, высокие).
    // Текст/голос/файл кладут время внутрь себя (`trailingTime`), чтобы не
    // росла высота пузыря. У своих рядом со временем — индикатор доставки/
    // прочтения (галочку убрали из левого жёлоба сюда).
    final messageTime = event.originServerTs.localizedTimeOfDay(context);
    final isRead = event.originServerTs.millisecondsSinceEpoch <= readUpToTs;
    final mt = displayEvent.messageType;
    // Медиа без подписи (фото/видео/стикер/альбом) → плашка-оверлей ВНУТРИ
    // самого медиа-виджета (рядом с бейджем длительности), гарантированно
    // поверх картинки/видео. Внешний sibling-Stack поверх медиа не рисовался.
    final mediaOverlayTime = isMediaMessage && mediaCaption == null;
    // Рендерится ли контент как ТЕКСТ (default-ветка message_content →
    // HtmlMessage). КЛЮЧЕВОЙ инвариант: message_content ловит НЕизвестный/
    // отсутствующий/кастомный msgtype в `default:` и всё равно рисует текст.
    // Раньше тут был ВАЙТЛИСТ {Text,Notice,Emote,None} — сообщения с иным
    // msgtype (но текстовые по факту, напр. из мостов/клиентов без явного
    // msgtype) уходили в belowFooter: время отдельной строкой справа + пузырь
    // раздувался Align'ом (баг «Перемудрили. Плохо это»). Теперь — КОМПЛЕМЕНТ
    // явных НЕ-текстовых типов, ровно как ветвится message_content.
    final rendersAsText =
        event.type == EventTypes.Message &&
        !isMediaMessage &&
        mediaCaption == null &&
        mt != MessageTypes.Audio &&
        mt != MessageTypes.File &&
        mt != MessageTypes.Location &&
        mt != MessageTypes.BadEncrypted &&
        mt != CuteEventContent.eventType &&
        mt != 'com.liza.miniapp.launch' &&
        mt != 'com.liza.miniapp.choice' &&
        mt != 'com.liza.miniapp.list' &&
        mt != 'com.liza.miniapp.data' &&
        mt != newsPollMsgType;
    // В посте канала время рисует ТОЛЬКО строка статистики (ChannelPostStatsRow,
    // Liza-стиль). Гасим его во ВСЕХ путях размещения сразу — иначе оно
    // задваивается. После выноса времени текста в правый нижний угол
    // (RL-message-time-corner) текст идёт тем же путём `trailingTime`, что и
    // голос/файл, — отдельного `trailingTextTimeSpan` больше нет. Осталось три
    // точки подавления: `contentPlacesTime` (текст + голос/файл + оверлей на
    // медиа → всё через `trailingTime`), `belowFooter` (строка справа под
    // контентом) и `trailingSpan` подписи медиа.
    final timeInChannelStatsRow = isChannelPost(event);
    final contentPlacesTime =
        !timeInChannelStatsRow &&
        (mediaOverlayTime ||
            rendersAsText ||
            (mediaCaption == null &&
                (mt == MessageTypes.Audio || mt == MessageTypes.File)));
    // Гейт канала здесь ОБЯЗАТЕЛЕН и не следует из contentPlacesTime: тот для
    // канала уже false, поэтому без явного !timeInChannelStatsRow погашенное
    // время вернулось бы отдельной строкой справа — то самое задвоение «одна
    // метка под другой», только теперь под строкой статистики.
    final belowFooter =
        !timeInChannelStatsRow && !contentPlacesTime && mediaCaption == null;
    // Время и статус — chrome пузыря, а не текст сообщения: из выделения мышью
    // (desktop/web, `SelectionArea` в `chat_event_list.dart`) они исключены,
    // иначе Ctrl+C по выделенному сообщению кладёт в буфер «Привет14:32». Тот же
    // инвариант уже держит живой слой поповера (`SelectableTextOverlay`).
    // `SelectionContainer.disabled` layout-прозрачен — вёрстка не меняется.
    //
    // Свой АЛЬБОМ: статус — сводный по всем членам, а не по якорю i=0
    // (`GallerySendSummary`), иначе «✓✓» при идущей/упавшей отправке
    // остальных. Пересчёт и на конец серии отправки (`seriesChanges`): статус
    // событий в этот момент не меняется, лента сама не перерисуется.
    final albumId = ownMessage ? event.galleryId : null;
    Widget footerTime({required bool overlay, GallerySendSummary? album}) =>
        MessageTime(
          time: messageTime,
          color: textColor.withAlpha(160),
          overlay: overlay,
          showStatus: ownMessage,
          isError: album != null
              ? album.state == GallerySendState.error
              : event.status == EventStatus.error,
          isSendingFile: album == null && event.fileSendingStatus != null,
          isSending: album != null
              ? album.state == GallerySendState.sending
              : event.status.isSending,
          isRead: isRead,
        );
    Widget messageFooter({required bool overlay}) => SelectionContainer.disabled(
      child: albumId == null
          ? footerTime(overlay: overlay)
          : ValueListenableBuilder<int>(
              valueListenable: UploadProgressTracker.instance.seriesChanges,
              builder: (context, _, _) {
                final album = GallerySendSummary.of(timeline, albumId);
                final time = footerTime(overlay: overlay, album: album);
                if (album.state != GallerySendState.error) return time;
                final label = L10n.of(
                  context,
                ).albumNotSentCount(album.failed.length, album.total);
                return Semantics(
                  button: true,
                  label: label,
                  child: Tooltip(
                    message: label,
                    child: GestureDetector(
                      key: const ValueKey('album-unsent-status'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => showAlbumUnsentMenu(context, album),
                      child: time,
                    ),
                  ),
                );
              },
            ),
    );

    // ТЕКСТ размещает время+статус (и метку «изменено») ЕДИНЫМ футером на уровне
    // пузыря (`textCornerFooterWidget`, блок рендера ниже), а НЕ внутри
    // `CornerTimeLayout`. Причина: `CornerTimeLayout.IntrinsicWidth` обнимает
    // только текст, а reply-цитата и строка «изменено» — сиблинги вне него.
    // Когда сиблинг шире короткого текста (ответ на длинное сообщение),
    // время липло к правому краю УЗКОГО текста → визуально «в середину» пузыря;
    // «изменено» же было отдельным `Row` без `Align` → отдельной строкой слева.
    // Единый футер под общим `IntrinsicWidth` (reply+текст+футер) выравнивается
    // по правому краю ВСЕГО пузыря, а «изменено» встаёт в ту же строку.
    final textCornerFooter = contentPlacesTime && rendersAsText;
    final isEdited = event.hasAggregatedEvents(
      timeline,
      RelationshipTypes.edit,
    );
    // Футер текста — Row во всю ширину пузыря: «изменено» (карандаш + время
    // правки) в ЛЕВОМ нижнем углу, время отправки + статус — в ПРАВОМ, оба на
    // ОДНОЙ строке (по просьбе пользователя, 2026-07-29). `spaceBetween`
    // разводит их по краям; без правки слева — `SizedBox.shrink`, тогда время
    // отправки прижато вправо. `mainAxisSize.max` заставляет Row занять ширину
    // пузыря (её держит общий `IntrinsicWidth`: intrinsic Row = сумма детей,
    // короткое сообщение не раздувается). Вертикальное выравнивание по центру —
    // время правки и время отправки на одном уровне.
    // `spacing` — минимальный зазор: у короткого текста ширину пузыря задаёт сам
    // футер (сумма меток), и spaceBetween делит 0 px → «✎ 10:3410:34» (баг
    // 2026-09-24). Только при правке: без неё слева `SizedBox.shrink`, и зазор
    // лишь раздул бы короткое «ок».
    Widget textCornerFooterWidget() => Padding(
      padding: const EdgeInsets.only(left: 16, right: 12, top: 2, bottom: 6),
      child: Row(
        spacing: isEdited ? 8 : 0,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isEdited)
            // Метка правки — тот же chrome, что и время: вне выделения.
            SelectionContainer.disabled(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.edit_outlined,
                    color: textColor.withAlpha(164),
                    size: 14,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    displayEvent.originServerTs.localizedTimeShort(context),
                    style: TextStyle(
                      color: textColor.withAlpha(164),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            )
          else
            const SizedBox.shrink(),
          messageFooter(overlay: false),
        ],
      ),
    );
    // Reply-цитата (общая для текста и не-текста). Для ТЕКСТА едет ВНУТРЬ общего
    // `IntrinsicWidth` вместе с контентом и футером (чтобы футер прижимался к
    // правому краю ПУЗЫРЯ, а не узкого текста); для остального контента — обычным
    // сиблингом Column пузыря.
    final Widget? replyWidget =
        event.inReplyToEventId(includingFallback: false) != null
        ? FutureBuilder<Event?>(
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
                // Цитата — контекст чужого сообщения, а не текст этого: из
                // выделения исключена (тот же инвариант, что в поповере), иначе
                // копия куска тянет за собой ещё и цитируемое сообщение.
                child: SelectionContainer.disabled(
                  child: Material(
                    color: Colors.transparent,
                    borderRadius: ReplyContent.borderRadius,
                    child: InkWell(
                      borderRadius: ReplyContent.borderRadius,
                      onTap: () => scrollToEventId(replyEvent.eventId),
                      child: AbsorbPointer(
                        child: ReplyContent(
                          replyEvent,
                          ownMessage: ownMessage,
                          timeline: timeline,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          )
        : null;

    // Хвостовой inline-span времени для ПОДПИСИ медиа (captioned image/video):
    // TextSpan времени + WidgetSpan-галочка своих течёт в конце подписи. Для
    // ОБЫЧНОГО текста время больше НЕ inline — оно в правом нижнем углу пузыря
    // (см. `MessageContent._withCornerTime`), единообразно с голосом/файлом.
    Widget? ownStatusIcon;
    if (ownMessage) {
      if (event.status == EventStatus.error) {
        // Причина терминальной ошибки отправки (квота/слишком большой файл/…)
        // вместо голого значка ⚠️ без пояснения. Для медиа её кладёт
        // send_file_dialog по txid; для прочего — общий текст.
        final reason =
            UploadProgressTracker.instance.errorFor(event.eventId) ??
            L10n.of(context).couldNotSendMessage;
        ownStatusIcon = Tooltip(
          message: reason,
          child: Semantics(
            label: reason,
            child: Icon(Icons.error, size: 13, color: textColor.withAlpha(160)),
          ),
        );
      } else if (event.fileSendingStatus != null) {
        ownStatusIcon = SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: textColor.withAlpha(160),
          ),
        );
      } else {
        ownStatusIcon = MessageReadIndicator(
          isSending: event.status.isSending,
          isRead: isRead,
          color: textColor.withAlpha(160),
        );
      }
    }
    final inlineTimeSpan = TextSpan(
      children: [
        TextSpan(
          text: '  $messageTime',
          style: TextStyle(
            fontSize: 12,
            color: textColor.withAlpha(150),
            fontWeight: FontWeight.w500,
          ),
        ),
        if (ownStatusIcon != null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Padding(
              padding: const EdgeInsets.only(left: 3),
              child: ownStatusIcon,
            ),
          ),
      ],
    );

    final content = MessageContent(
      displayEvent,
      textColor: textColor,
      linkColor: linkColor,
      onInfoTab: onInfoTab,
      borderRadius: borderRadius,
      timeline: timeline,
      selected: selected,
      longPressSelect: longPressSelect,
      selectedEventIds: selectedEventIds,
      onSelect: onSelect,
      // Голос/файл/текст-карточки → время строкой в правом нижнем углу
      // (MessageContent сам размещает); медиа без подписи → плашка-оверлей.
      // ТЕКСТ (textCornerFooter) время НЕ размещает внутри контента — его кладёт
      // единый футер пузыря (textCornerFooterWidget), поэтому здесь null.
      trailingTime: !contentPlacesTime || textCornerFooter
          ? null
          : mediaOverlayTime
          ? messageFooter(overlay: true)
          : messageFooter(overlay: false),
    );

    final resetAnimateIn = this.resetAnimateIn;
    var animateIn = this.animateIn;

    // Каналы (счётчик просмотров внутри пузыря) и Liza News
    // (hide_read_receipts) — без аватарок прочтения и без бокового слота.
    final showSeenSlot = !isChannelPost(event) && !event.room.hideReadReceipts;

    final showReceiptsRow = event.hasAggregatedEvents(
      timeline,
      RelationshipTypes.reaction,
    );

    final threadChildren = event.aggregatedEvents(
      timeline,
      RelationshipTypes.thread,
    );

    final enterThread = this.enterThread;

    return Center(
      child: Swipeable(
        key: ValueKey(event.eventId),
        background: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12.0),
          child: Center(child: Icon(Icons.check_outlined)),
        ),
        direction: AppSettings.swipeRightToLeftToReply.value
            ? SwipeDirection.endToStart
            : SwipeDirection.startToEnd,
        onSwipe: (_) => onSwipe(),
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: LizaThemes.maxTimelineWidth,
          ),
          padding: EdgeInsets.only(
            left: 8.0,
            right: 8.0,
            top: nextEventSameSender ? 1.0 : 4.0,
            bottom: previousEventSameSender ? 1.0 : 4.0,
          ),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: ownMessage ? .end : .start,
            children: <Widget>[
              if (displayTime || selected)
                Padding(
                  padding: displayTime
                      ? const EdgeInsets.symmetric(vertical: 8.0)
                      : EdgeInsets.zero,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Material(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius * 2,
                        ),
                        color: theme.colorScheme.surface.withAlpha(128),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 2.0,
                          ),
                          child: Text(
                            event.originServerTs.localizedTime(context),
                            style: TextStyle(
                              fontSize: 12 * AppSettings.fontSizeFactor.value,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.secondary,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              StatefulBuilder(
                builder: (context, setState) {
                  if (animateIn && resetAnimateIn != null) {
                    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
                      animateIn = false;
                      if (context.mounted) setState(resetAnimateIn);
                    });
                  }
                  return AnimatedSize(
                    duration: LizaThemes.animationDuration,
                    curve: LizaThemes.animationCurve,
                    clipBehavior: Clip.none,
                    alignment: ownMessage
                        ? Alignment.bottomRight
                        : Alignment.bottomLeft,
                    child: animateIn
                        ? const SizedBox(height: 0, width: double.infinity)
                        : Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Positioned(
                                top: 0,
                                bottom: 0,
                                left: 0,
                                right: 0,
                                child: IgnorePointer(
                                  child: Material(
                                    borderRadius: BorderRadius.circular(
                                      AppConfig.borderRadius / 2,
                                    ),
                                    color: selected || highlightMarker
                                        ? theme.colorScheme.secondaryContainer
                                              .withAlpha(128)
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                              MessageBubbleRow(
                                alignGutterToBubble: ownMessage,
                                mainAxisAlignment: rowMainAxisAlignment,
                                gutter: longPressSelect && !event.redacted
                                    ? SizedBox(
                                        height: 32,
                                        width: Avatar.defaultSize,
                                        child: IconButton(
                                          padding: EdgeInsets.zero,
                                          tooltip: L10n.of(context).select,
                                          icon: Icon(
                                            selected
                                                ? Icons.check_circle
                                                : Icons.circle_outlined,
                                          ),
                                          onPressed: () => onSelect(event),
                                        ),
                                      )
                                    : (!isChannelPost(event) &&
                                          (nextEventSameSender || ownMessage))
                                    ? const SizedBox(
                                        width: Avatar.defaultSize,
                                        // Индикатор доставки/прочтения своих
                                        // сообщений переехал в футер пузыря
                                        // (рядом со временем, Liza-стиль).
                                        // Жёлоб оставляем распоркой под
                                        // выравнивание аватар-колонки.
                                        child: Center(
                                          child: SizedBox(
                                            width: 16,
                                            height: 16,
                                          ),
                                        ),
                                      )
                                    : isChannelPost(event)
                                    ? Avatar(
                                        mxContent: event.room.avatar,
                                        name: event.room
                                            .getLocalizedDisplayname(
                                              MatrixLocals(L10n.of(context)),
                                            ),
                                      )
                                    : FutureBuilder<User?>(
                                        future: event.fetchSenderUser(),
                                        builder: (context, snapshot) {
                                          // Релей «Входящие»: сообщение клиента бот
                                          // постит от своего имени, но с атрибуцией в
                                          // поле com.liza.relay. Показываем аватар
                                          // КЛИЕНТА (инициал+цвет), а не бота, чтобы
                                          // владелец видел, от кого сообщение.
                                          final relayName = _relayName(event);
                                          if (relayName != null) {
                                            return Avatar(
                                              mxContent: null,
                                              name: relayName,
                                            );
                                          }
                                          final user =
                                              snapshot.data ??
                                              event.senderFromMemoryOrFallback;
                                          return Avatar(
                                            mxContent: user.avatarUrl,
                                            name: user.calcDisplayname(),
                                            onTap: () =>
                                                showMemberActionsPopupMenu(
                                                  context: context,
                                                  user: user,
                                                  onMention: onMention,
                                                ),
                                            presenceUserId: user.stateKey,
                                            presenceBackgroundColor:
                                                wallpaperMode
                                                ? Colors.transparent
                                                : null,
                                            isHexagonal: Matrix.of(
                                              context,
                                            ).isAiUser(event.senderId),
                                          );
                                        },
                                      ),
                                header:
                                    (nextEventSameSender &&
                                        !isChannelPost(event))
                                    ? null
                                    : Padding(
                                        padding: const EdgeInsets.only(
                                          left: 8.0,
                                          bottom: 4,
                                        ),
                                        child: isChannelPost(event)
                                            ? Text(
                                                event.room
                                                    .getLocalizedDisplayname(
                                                      MatrixLocals(
                                                        L10n.of(context),
                                                      ),
                                                    ),
                                                style: const TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              )
                                            : ownMessage ||
                                                  event.room.isDirectChat
                                            ? const SizedBox(height: 12)
                                            : FutureBuilder<User?>(
                                                future: event.fetchSenderUser(),
                                                builder: (context, snapshot) {
                                                  // Релей «Входящие»: заголовок —
                                                  // имя КЛИЕНТА (из com.liza.relay), а
                                                  // цвет стабилен по его MXID (две
                                                  // «Марии» → разные цвета). Бот-бейдж
                                                  // роли для релеенных не показываем.
                                                  final relayName = _relayName(
                                                    event,
                                                  );
                                                  final displayname =
                                                      relayName ??
                                                      snapshot.data
                                                          ?.calcDisplayname() ??
                                                      event
                                                          .senderFromMemoryOrFallback
                                                          .calcDisplayname();
                                                  final colorKey =
                                                      _relayCustomer(event) ??
                                                      displayname;
                                                  // Имя отправителя — chrome
                                                  // пузыря, вне выделения (см.
                                                  // messageFooter).
                                                  return SelectionContainer.disabled(
                                                    child: Wrap(
                                                      crossAxisAlignment:
                                                          WrapCrossAlignment
                                                              .center,
                                                      spacing: 4,
                                                      runSpacing: 2,
                                                      children: [
                                                        Text(
                                                          displayname,
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            color:
                                                                (theme.brightness ==
                                                                    Brightness
                                                                        .light
                                                                ? colorKey.color
                                                                : colorKey
                                                                      .lightColorText),
                                                            shadows:
                                                                !wallpaperMode
                                                                ? null
                                                                : [
                                                                    const Shadow(
                                                                      offset:
                                                                          Offset(
                                                                            0.0,
                                                                            0.0,
                                                                          ),
                                                                      blurRadius:
                                                                          3,
                                                                      color: Colors
                                                                          .black,
                                                                    ),
                                                                  ],
                                                          ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                        ),
                                                        if (relayName == null)
                                                          UserRoleBadge(
                                                            userId:
                                                                event.senderId,
                                                            fontSize: 9,
                                                            padding:
                                                                const EdgeInsets.symmetric(
                                                                  horizontal: 4,
                                                                  vertical: 1,
                                                                ),
                                                          ),
                                                      ],
                                                    ),
                                                  );
                                                },
                                              ),
                                      ),
                                bubble: [
                                  GestureDetector(
                                    onTap: longPressSelect
                                        ? () => onSelect(event)
                                        : null,
                                    onLongPressStart: longPressSelect
                                        ? null
                                        : (_) => onContextMenu?.call(event),
                                    onSecondaryTapDown: longPressSelect
                                        ? null
                                        : (_) => onContextMenu?.call(event),
                                    behavior: HitTestBehavior.opaque,
                                    child: Container(
                                      alignment: alignment,
                                      padding: const EdgeInsets.only(left: 8),
                                      // RepaintBoundary вокруг ВИДИМОГО пузыря
                                      // (за паддингом) — снимок и якорь меню
                                      // совпадают с левой границей сообщения.
                                      // Аватарки прочтения — сбоку от пузыря,
                                      // вне bubbleKey (снимок/якорь меню —
                                      // только сам пузырь), см.
                                      // BubbleReceiptsSide.
                                      child: BubbleReceiptsSide(
                                        ownMessage: ownMessage,
                                        reserve: showSeenSlot,
                                        cluster:
                                            seenByUsers.isNotEmpty &&
                                                mediaCaption == null
                                            ? (maxWidth) => SeenByAvatars(
                                                receipts: seenByUsers,
                                                maxWidth: maxWidth,
                                              )
                                            : null,
                                        child: RepaintBoundary(
                                          key: bubbleKey,
                                          child: AnimatedOpacity(
                                            opacity: animateIn
                                                ? 0
                                                : event.messageType ==
                                                          MessageTypes
                                                              .BadEncrypted ||
                                                      event.status.isSending
                                                ? 0.5
                                                : 1,
                                            duration:
                                                LizaThemes.animationDuration,
                                            curve: LizaThemes.animationCurve,
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: noBubble
                                                    ? Colors.transparent
                                                    : color,
                                                borderRadius: borderRadius,
                                              ),
                                              clipBehavior: Clip.antiAlias,
                                              child: BubbleBackground(
                                                colors: colors,
                                                ignore:
                                                    noBubble ||
                                                    !ownMessage ||
                                                    MediaQuery.highContrastOf(
                                                      context,
                                                    ),
                                                scrollController:
                                                    scrollController,
                                                child: Container(
                                                  decoration: BoxDecoration(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          AppConfig
                                                              .borderRadius,
                                                        ),
                                                  ),
                                                  constraints:
                                                      const BoxConstraints(
                                                        maxWidth:
                                                            LizaThemes
                                                                .columnWidth *
                                                            1.5,
                                                      ),
                                                  child: Column(
                                                    mainAxisSize: .min,
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: <Widget>[
                                                      // Плашка «Переслано [от X]»
                                                      // (LABA-1991) — ПЕРВЫМ ребёнком
                                                      // общего Column, над ЛЮБОЙ
                                                      // веткой контента (текст/медиа/
                                                      // аудио/файл/канал), поэтому одна
                                                      // точка вставки покрывает все
                                                      // msgtype. Подавляем в relay-
                                                      // комнате «Входящие»: там автора
                                                      // уже подменяет com.liza.relay,
                                                      // две атрибуции путали бы.
                                                      if (_isForwarded(event) &&
                                                          _relayName(event) ==
                                                              null)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                left: 16,
                                                                right: 16,
                                                                top: 8,
                                                              ),
                                                          child: ForwardedContent(
                                                            name:
                                                                _forwardedName(
                                                                  event,
                                                                ),
                                                            ownMessage:
                                                                ownMessage,
                                                          ),
                                                        ),
                                                      // ТЕКСТ: reply + контент +
                                                      // единый футер (время+статус+
                                                      // «изменено») под ОДНИМ
                                                      // IntrinsicWidth — пузырь
                                                      // держит ширину по максимуму
                                                      // {reply, текст, футер}, а
                                                      // футер (Align.centerRight)
                                                      // прижат к правому краю ВСЕГО
                                                      // пузыря, а не узкого текста.
                                                      if (textCornerFooter)
                                                        IntrinsicWidth(
                                                          child: Column(
                                                            mainAxisSize: .min,
                                                            crossAxisAlignment:
                                                                CrossAxisAlignment
                                                                    .start,
                                                            children: [
                                                              if (replyWidget !=
                                                                  null)
                                                                replyWidget,
                                                              content,
                                                              textCornerFooterWidget(),
                                                            ],
                                                          ),
                                                        ),
                                                      if (!textCornerFooter &&
                                                          replyWidget != null)
                                                        replyWidget,
                                                      if (!textCornerFooter)
                                                        content,
                                                      // ТЕКСТ несёт «изменено» в
                                                      // едином футере пузыря
                                                      // (textCornerFooterWidget) —
                                                      // на одной строке со временем
                                                      // и справа. Отдельный edit-Row
                                                      // остаётся только НЕ-тексту
                                                      // (медиа/аудио/файл/канал).
                                                      if (!textCornerFooter &&
                                                          isEdited)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                bottom: 8.0,
                                                                left: 16.0,
                                                                right: 16.0,
                                                              ),
                                                          child: Row(
                                                            mainAxisSize:
                                                                MainAxisSize
                                                                    .min,
                                                            spacing: 4.0,
                                                            children: [
                                                              Icon(
                                                                Icons
                                                                    .edit_outlined,
                                                                color: textColor
                                                                    .withAlpha(
                                                                      164,
                                                                    ),
                                                                size: 14,
                                                              ),
                                                              Text(
                                                                displayEvent
                                                                    .originServerTs
                                                                    .localizedTimeShort(
                                                                      context,
                                                                    ),
                                                                style: TextStyle(
                                                                  color: textColor
                                                                      .withAlpha(
                                                                        164,
                                                                      ),
                                                                  fontSize: 11,
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        ),
                                                      if (belowFooter)
                                                        Padding(
                                                          padding:
                                                              const EdgeInsets.only(
                                                                left: 16.0,
                                                                right: 12.0,
                                                                top: 2.0,
                                                                bottom: 6.0,
                                                              ),
                                                          child: Align(
                                                            alignment: Alignment
                                                                .centerRight,
                                                            child:
                                                                messageFooter(
                                                                  overlay:
                                                                      false,
                                                                ),
                                                          ),
                                                        ),
                                                      // Низ поста канала — ВНУТРИ
                                                      // пузыря (Liza-стиль).
                                                      // Отдельным виджетом: тут
                                                      // уже 25 уровней вложенности,
                                                      // и форматтер рвёт гейт по
                                                      // словам.
                                                      // `!event.redacted` —
                                                      // защита в глубину: лента
                                                      // канала уже вырезает
                                                      // удалённые посты
                                                      // (isRedactedChannelPost),
                                                      // но у надгробия не должно
                                                      // быть реакций и кнопки
                                                      // «Прокомментировать» ни
                                                      // при каком пути рендера.
                                                      if (isChannelPost(
                                                            event,
                                                          ) &&
                                                          !event.redacted)
                                                        ChannelPostFooter(
                                                          event: event,
                                                          timeline: timeline,
                                                          showReactions:
                                                              showReceiptsRow,
                                                          viewCount: seenByUsers
                                                              .length,
                                                          time: messageTime,
                                                          discussionEvents:
                                                              discussionEvents,
                                                          onMembershipGained:
                                                              onMembershipGained,
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (mediaCaption != null)
                                    GestureDetector(
                                      onTap: longPressSelect
                                          ? () => onSelect(event)
                                          : null,
                                      onLongPressStart: longPressSelect
                                          ? null
                                          : (_) => onContextMenu?.call(event),
                                      onSecondaryTapDown: longPressSelect
                                          ? null
                                          : (_) => onContextMenu?.call(event),
                                      child: Container(
                                        alignment: alignment,
                                        padding: const EdgeInsets.only(
                                          left: 8,
                                          top: 4,
                                        ),
                                        child: BubbleReceiptsSide(
                                          ownMessage: ownMessage,
                                          reserve: showSeenSlot,
                                          cluster: seenByUsers.isNotEmpty
                                              ? (maxWidth) => SeenByAvatars(
                                                  receipts: seenByUsers,
                                                  maxWidth: maxWidth,
                                                )
                                              : null,
                                          child: Container(
                                            constraints: const BoxConstraints(
                                              maxWidth:
                                                  LizaThemes.columnWidth * 1.5,
                                            ),
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: color,
                                                borderRadius:
                                                    BorderRadius.circular(
                                                      AppConfig.borderRadius,
                                                    ),
                                              ),
                                              clipBehavior: Clip.antiAlias,
                                              child: BubbleBackground(
                                                colors: colors,
                                                ignore:
                                                    !ownMessage ||
                                                    MediaQuery.highContrastOf(
                                                      context,
                                                    ),
                                                scrollController:
                                                    scrollController,
                                                child: Padding(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 16,
                                                        vertical: 8,
                                                      ),
                                                  // Подпись с разметкой (XL шлёт
                                                  // <strong>/<em> в formatted_body)
                                                  // → HTML, иначе теги сырые
                                                  // (LABA-2207). Время — inline в
                                                  // конце подписи (Liza-стиль),
                                                  // а не отдельной строкой снизу
                                                  // (иначе Align раздувал пузырь —
                                                  // баг «Перемудрили. Плохо это»).
                                                  // В канале время уже стоит в
                                                  // строке статистики — в хвост
                                                  // подписи его не добавляем.
                                                  child: MediaCaption(
                                                    event: displayEvent,
                                                    textColor: textColor,
                                                    linkColor: linkColor,
                                                    trailingSpan:
                                                        timeInChannelStatsRow
                                                        ? null
                                                        : inlineTimeSpan,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                  );
                },
              ),
              // В канале реакции и просмотры живут ВНУТРИ пузыря
              // (ChannelPostStatsRow выше), поэтому снаружи их не дублируем.
              if (!isChannelPost(event))
                AnimatedSize(
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  alignment: Alignment.bottomCenter,
                  child: !showReceiptsRow
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: EdgeInsets.only(
                            top: 4.0,
                            left: (ownMessage ? 0 : Avatar.defaultSize) + 12.0,
                            right: ownMessage ? 0 : 12.0,
                          ),
                          child: MessageReactions(event, timeline),
                        ),
                ),
              if (enterThread != null)
                AnimatedSize(
                  duration: LizaThemes.animationDuration,
                  curve: LizaThemes.animationCurve,
                  alignment: Alignment.bottomCenter,
                  child: threadChildren.isEmpty
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(
                            top: 2.0,
                            bottom: 8.0,
                            left: Avatar.defaultSize + 8,
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth: LizaThemes.columnWidth * 1.5,
                            ),
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                foregroundColor:
                                    theme.colorScheme.onSecondaryContainer,
                                backgroundColor:
                                    theme.colorScheme.secondaryContainer,
                              ),
                              onPressed: () => enterThread(event.eventId),
                              icon: const Icon(Icons.message),
                              label: Text(
                                '${L10n.of(context).countReplies(threadChildren.length)} | ${threadChildren.first.calcLocalizedBodyFallback(MatrixLocals(L10n.of(context)), withSenderNamePrefix: true, hideReply: true)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ),
                ),
              if (displayReadMarker)
                Row(
                  children: [
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                    Container(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 16.0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          AppConfig.borderRadius / 3,
                        ),
                        color: theme.colorScheme.surface.withAlpha(128),
                      ),
                      child: Text(
                        L10n.of(context).readUpToHere,
                        style: TextStyle(
                          fontSize: 12 * AppSettings.fontSizeFactor.value,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Divider(
                        color: theme.colorScheme.surfaceContainerHighest,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Перекрывающийся стек аватарок участников, прочитавших до этого сообщения.
/// Макс. 10 аватарок + бейдж «+N»; для DM это одна аватарка 16px. По тапу —
/// окно «кто и когда прочитал» (полный список, не обрезанный до 10).
class SeenByAvatars extends StatelessWidget {
  final List<MessageReadReceipt> receipts;

  /// Сколько места сбоку от пузыря (BubbleReceiptsSide): не влезает — шаг
  /// перекрытия сжимается, пузырь не трогаем (заявка №60).
  final double maxWidth;
  const SeenByAvatars({
    required this.receipts,
    this.maxWidth = double.infinity,
    super.key,
  });

  static const double _size = kSeenAvatarSize;
  // До 10 аватарок выводим по тому же принципу, что и первые (overlap-стек),
  // дальше — бейдж «+N» с числом остальных прочитавших (ТЗ заказчика).
  static const int _maxShown = 10;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fit = fitSeenAvatars(
      total: receipts.length,
      maxShown: receipts.length > _maxShown ? _maxShown : receipts.length,
      maxWidth: maxWidth,
    );
    final shown = receipts.length > _maxShown
        ? receipts.sublist(0, _maxShown)
        : receipts;
    final visible = shown.sublist(0, fit.shown);
    final step = fit.step;
    final extra = receipts.length - visible.length;
    final slots = visible.length + (extra > 0 ? 1 : 0);
    final width = _size + (slots - 1) * step;
    return GestureDetector(
      onTap: () => showReadReceiptsSheet(context, receipts),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: width,
        height: _size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            for (var i = 0; i < visible.length; i++)
              Positioned(
                left: i * step,
                child: Avatar(
                  mxContent: visible[i].user.avatarUrl,
                  name: visible[i].user.calcDisplayname(),
                  size: _size,
                  isHexagonal: Matrix.of(context).isAiUser(visible[i].user.id),
                ),
              ),
            if (extra > 0)
              Positioned(
                left: visible.length * step,
                child: SizedBox(
                  width: _size,
                  height: _size,
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHighest,
                    shape: const CircleBorder(),
                    child: Center(
                      child: Text(
                        '+$extra',
                        style: const TextStyle(fontSize: 9),
                      ),
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

/// Счётчик просмотров поста канала — замена кластеру аватарок «прочитал».
///
/// Считается по read receipts (данные уже есть в Matrix, серверного счётчика
/// нет). Важно понимать масштаб приближения: Matrix хранит ОДНУ границу
/// прочтения на участника — она стоит под его последним прочитанным событием.
/// Поэтому ненулевое число практически всегда только у самого свежего поста, а
/// у более старых счётчик пустеет по мере того, как читатели уходят дальше по
/// ленте. Это не «просмотры» в смысле Liza, а «чья граница чтения стоит
/// здесь и сейчас» — осознанный компромисс вместо отдельного серверного
/// счётчика с собственной таблицей.
class ChannelViewCount extends StatelessWidget {
  final int count;
  const ChannelViewCount({required this.count, super.key});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.visibility_outlined,
          size: 12,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Text(
          L10n.of(context).channelViewCount(count),
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 11,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Строка статистики поста канала: полоса реакций во всю ширину, «просмотры и
/// время» обтекают её последнюю строку.
///
/// Строка рисуется, даже когда реакций ещё нет: иначе низ поста прыгал бы при
/// появлении первой реакции. Время в постах канала живёт здесь, а не в хвосте
/// текста — так же, как в Liza.
class ChannelPostStatsRow extends StatelessWidget {
  /// Готовые чипы реакций ОТДЕЛЬНЫМИ виджетами, а не собранный `Wrap`:
  /// раскладывать их обязан этот виджет, чтобы счётчик попал в тот же поток.
  final List<Widget>? reactionChips;
  final int viewCount;
  final String time;

  const ChannelPostStatsRow({
    required this.reactionChips,
    required this.viewCount,
    required this.time,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      // Чипы реакций и блок «просмотры + время» лежат в ОДНОМ потоке Wrap:
      // полоса реакций занимает всю ширину поста, а счётчик обтекает её
      // последнюю строку (как в Liza). Прежний Row с Expanded зажимал
      // реакции в узкую колонку слева, и при десятке реакций они уходили в
      // столбик. Чипы приходят СПИСКОМ, а не готовым Wrap: вложенный Wrap
      // схлопнулся бы в свою минимальную ширину и снова дал столбик.
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.end,
        children: [
          ...?reactionChips,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChannelViewCount(count: viewCount),
              const SizedBox(width: 6),
              Text(
                time,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 11,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Низ поста канала одним блоком ВНУТРИ пузыря (Liza-стиль): строка
/// статистики (реакции слева, просмотры и время справа), под ней сепаратор и
/// кнопка комментариев во всю ширину.
///
/// Раньше эти блоки жили снаружи `Message` — каждый со своими отступами, а
/// кнопка комментариев вообще рендерилась в `chat_event_list`. Из-за этого низ
/// поста разъезжался: кнопка уходила влево за границу пузыря.
class ChannelPostFooter extends StatelessWidget {
  final Event event;
  final Timeline timeline;

  /// У поста есть реакции. Строка статистики рисуется в любом случае: иначе
  /// низ поста прыгал бы при появлении первой реакции.
  final bool showReactions;
  final int viewCount;
  final String time;
  final List<Map<String, dynamic>> discussionEvents;
  final VoidCallback? onMembershipGained;

  const ChannelPostFooter({
    required this.event,
    required this.timeline,
    required this.showReactions,
    required this.viewCount,
    required this.time,
    required this.discussionEvents,
    required this.onMembershipGained,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final onMembershipGained = this.onMembershipGained;
    // Удалённый пост канала футера не получает вовсе: `event.type` после
    // redaction остаётся `m.room.message`, поэтому проверка типа ниже его НЕ
    // отсекает. Дублирует гейт в chat_event_list — событие сюда доехать не
    // должно, но у надгробия не может быть ни реакций, ни комментариев.
    if (event.redacted) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ChannelPostStatsRow(
          reactionChips: showReactions
              ? MessageReactions.chipsFor(context, event, timeline)
              : null,
          viewCount: viewCount,
          time: time,
        ),
        if (event.room.hasComments && event.type == EventTypes.Message)
          ChannelPostComments(
            room: event.room,
            post: event,
            discussionEvents: discussionEvents,
            onMembershipGained: onMembershipGained ?? () {},
          ),
      ],
    );
  }
}

class BubbleBackground extends StatelessWidget {
  const BubbleBackground({
    super.key,
    required this.scrollController,
    required this.colors,
    required this.ignore,
    required this.child,
  });

  final ScrollController scrollController;
  final List<Color> colors;
  final bool ignore;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ignore) return child;
    return CustomPaint(
      painter: BubblePainter(
        repaint: scrollController,
        colors: colors,
        context: context,
      ),
      child: child,
    );
  }
}

class BubblePainter extends CustomPainter {
  BubblePainter({
    required this.context,
    required this.colors,
    required super.repaint,
  });

  final BuildContext context;
  final List<Color> colors;
  ScrollableState? _scrollable;

  @override
  void paint(Canvas canvas, Size size) {
    final scrollable = _scrollable ??= Scrollable.of(context);
    final scrollableBox = scrollable.context.findRenderObject() as RenderBox;
    final scrollableRect = Offset.zero & scrollableBox.size;
    final bubbleBox = context.findRenderObject() as RenderBox;

    final origin = bubbleBox.localToGlobal(
      Offset.zero,
      ancestor: scrollableBox,
    );
    final paint = Paint()
      ..shader = ui.Gradient.linear(
        scrollableRect.topCenter,
        scrollableRect.bottomCenter,
        colors,
        [0.0, 1.0],
        TileMode.clamp,
        Matrix4.translationValues(-origin.dx, -origin.dy, 0.0).storage,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(BubblePainter oldDelegate) {
    final scrollable = Scrollable.of(context);
    final oldScrollable = _scrollable;
    _scrollable = scrollable;
    return scrollable.position != oldScrollable?.position;
  }
}
