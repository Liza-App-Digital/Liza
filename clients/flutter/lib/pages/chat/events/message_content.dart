import 'dart:math';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/events/poll.dart';
import 'package:liza/pages/chat/events/video_player.dart';
import 'package:liza/utils/formatting_text_controller.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/date_time_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/message_link.dart';
import 'package:liza/utils/stories/story_model.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';
import '../../../config/app_config.dart';
import '../../../utils/event_checkbox_extension.dart';
import '../../../utils/platform_infos.dart';
import '../../../utils/url_launcher.dart';
import 'audio_player.dart';
import 'bot_invoice_content.dart';
import 'cute_events.dart';
import 'gallery.dart';
import 'html_message.dart';
import 'xl_buttons_content.dart';
import 'image_bubble.dart';
import 'map_bubble.dart';
import 'message_download_content.dart';
import 'message_link_preview.dart';
import 'mini_app_choice_content.dart';
import 'mini_app_data_content.dart';
import 'mini_app_launch_content.dart';
import 'mini_app_list_content.dart';
import 'news_poll_content.dart';
import 'story_ref_card.dart';

class MessageContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;
  final void Function(Event)? onInfoTab;
  final BorderRadius borderRadius;
  final Timeline timeline;
  final bool selected;
  final bool longPressSelect;
  final Set<String> selectedEventIds;
  final void Function(Event)? onSelect;

  /// Время сообщения (Liza-стиль): голос/файл — в правом нижнем углу пузыря;
  /// медиа — плашкой-оверлеем; текст и текст-карточки — строкой в правом нижнем
  /// углу под контентом.
  final Widget? trailingTime;

  const MessageContent(
    this.event, {
    this.onInfoTab,
    super.key,
    required this.timeline,
    required this.textColor,
    required this.linkColor,
    required this.borderRadius,
    required this.selected,
    this.longPressSelect = false,
    this.selectedEventIds = const {},
    this.onSelect,
    this.trailingTime,
  });

  /// Оборачивает текст-карточку в колонку с временем под ней (когда время
  /// нельзя встроить inline). No-op, если [trailingTime] не задан.
  Widget _withBelowTime(Widget child) {
    final trailingTime = this.trailingTime;
    if (trailingTime == null) return child;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 12,
            top: 2,
            bottom: 6,
          ),
          child: Align(alignment: Alignment.centerRight, child: trailingTime),
        ),
      ],
    );
  }

  /// Как [_withBelowTime], но для ОБЫЧНОГО текста (HtmlMessage). Раньше время
  /// текста встраивалось inline в конец последней строки; по просьбе
  /// пользователя оно вынесено в правый НИЖНИЙ угол пузыря — единообразно с
  /// голосовыми/файлами. `IntrinsicWidth` держит пузырь по ширине контента:
  /// без него `Align(centerRight)` растянул бы КОРОТКОЕ сообщение на всю
  /// максимальную ширину (баг «Перемудрили»); он же поднимает минимальную
  /// ширину до времени, когда сам текст короче строки времени. No-op, если
  /// [trailingTime] не задан.
  Widget _withCornerTime(Widget child) {
    final trailingTime = this.trailingTime;
    if (trailingTime == null) return child;
    return CornerTimeLayout(content: child, time: trailingTime);
  }

  void _verifyOrRequestKey(BuildContext context) async {
    final l10n = L10n.of(context);
    Logs().d(
      '[encrypted-placeholder] tap eventId=${event.eventId} '
      'type=${event.type} msgType=${event.messageType} '
      'canReq=${event.content['can_request_session']} '
      'session=${event.content['session_id']} '
      'sender=${event.senderId}',
    );
    if (event.content['can_request_session'] != true) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(event.calcLocalizedBodyFallback(MatrixLocals(l10n))),
        ),
      );
      return;
    }
    final client = Matrix.of(context).client;
    if (client.isUnknownSession && client.encryption!.crossSigning.enabled) {
      final success = await context.push('/backup');
      if (success != true) return;
    }
    event.requestKey();
    final sender = event.senderFromMemoryOrFallback;
    await showAdaptiveBottomSheet(
      context: context,
      builder: (context) => Scaffold(
        appBar: AppBar(
          leading: CloseButton(onPressed: Navigator.of(context).pop),
          title: Text(
            l10n.whyIsThisMessageEncrypted,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Avatar(
                  mxContent: sender.avatarUrl,
                  name: sender.calcDisplayname(),
                  presenceUserId: sender.stateKey,
                  client: event.room.client,
                ),
                title: Text(sender.calcDisplayname()),
                subtitle: Text(event.originServerTs.localizedTime(context)),
                trailing: const Icon(Icons.lock_outlined),
              ),
              const Divider(),
              Text(event.calcLocalizedBodyFallback(MatrixLocals(l10n))),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final fontSize =
        AppConfig.messageFontSize * AppSettings.fontSizeFactor.value;
    final buttonTextColor = textColor;
    switch (event.type) {
      case EventTypes.Message:
      case EventTypes.Encrypted:
      case EventTypes.Sticker:
        switch (event.messageType) {
          case MessageTypes.Image:
          case MessageTypes.Sticker:
            if (event.redacted) continue textmessage;
            // Альбом: событие с полем `com.liza.gallery` рендерится
            // сеткой. Сюда попадает только anchor — не-anchor события
            // скрыты в `chat_event_list.dart` (media-v-format.md §8.5).
            if (event.messageType == MessageTypes.Image &&
                event.galleryId != null) {
              return GalleryBubble(
                event,
                timeline: timeline,
                longPressSelect: longPressSelect,
                selectedEventIds: selectedEventIds,
                onSelect: onSelect,
                timeOverlay: trailingTime,
              );
            }
            final maxSize = event.messageType == MessageTypes.Sticker
                ? 128.0
                : 256.0;
            final w = event.content
                .tryGetMap<String, Object?>('info')
                ?.tryGet<int>('w');
            final h = event.content
                .tryGetMap<String, Object?>('info')
                ?.tryGet<int>('h');
            var width = maxSize;
            var height = maxSize;
            var fit = event.messageType == MessageTypes.Sticker
                ? BoxFit.contain
                : BoxFit.cover;
            if (w != null && h != null) {
              fit = BoxFit.contain;
              if (w > h) {
                width = maxSize;
                height = max(32, maxSize * (h / w));
              } else {
                height = maxSize;
                width = max(32, maxSize * (w / h));
              }
            }
            return ImageBubble(
              event,
              width: width,
              height: height,
              fit: fit,
              borderRadius: borderRadius,
              timeline: timeline,
              textColor: textColor,
              linkColor: linkColor,
              timeOverlay: trailingTime,
              longPressSelect: longPressSelect,
            );
          case BotInvoiceContent.msgType:
            return _withBelowTime(
              BotInvoiceContent(event: event, textColor: textColor),
            );
          case MiniAppLaunchContent.msgType:
            return MiniAppLaunchContent(event: event, textColor: textColor);
          case MiniAppChoiceContent.msgType:
            return MiniAppChoiceContent(
              event: event,
              timeline: timeline,
              textColor: textColor,
            );
          case MiniAppListContent.msgType:
            return MiniAppListContent(event: event, textColor: textColor);
          case NewsPollContent.msgType:
            return NewsPollContent(
              event: event,
              textColor: textColor,
              linkColor: linkColor,
            );
          case MiniAppDataContent.msgType:
            return MiniAppDataContent(event: event, textColor: textColor);
          case CuteEventContent.eventType:
            return CuteContent(event);
          case MessageTypes.Audio:
            if (PlatformInfos.isMobile ||
                PlatformInfos.isMacOS ||
                PlatformInfos.isWeb ||
                PlatformInfos.isWindows ||
                PlatformInfos.isLinux) {
              return AudioPlayerWidget(
                event,
                color: textColor,
                linkColor: linkColor,
                fontSize: fontSize,
                trailing: trailingTime,
              );
            }
            return MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
              trailing: trailingTime,
            );
          case MessageTypes.Video:
            if (event.galleryId != null) {
              return GalleryBubble(
                event,
                timeline: timeline,
                longPressSelect: longPressSelect,
                selectedEventIds: selectedEventIds,
                onSelect: onSelect,
                timeOverlay: trailingTime,
              );
            }
            return EventVideoPlayer(
              event,
              textColor: textColor,
              linkColor: linkColor,
              timeline: timeline,
              timeOverlay: trailingTime,
            );
          case MessageTypes.File:
            return MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
              trailing: trailingTime,
            );
          case MessageTypes.BadEncrypted:
          case EventTypes.Encrypted:
            _logEncryptedRenderOnce(event);
            _autoRequestKeyIfNeeded(event);
            return _ButtonContent(
              textColor: buttonTextColor,
              onPressed: () => _verifyOrRequestKey(context),
              icon: '🔒',
              label: L10n.of(context).encrypted,
              fontSize: fontSize,
            );
          case MessageTypes.Location:
            final geoUri = Uri.tryParse(
              event.content.tryGet<String>('geo_uri')!,
            );
            if (geoUri != null && geoUri.scheme == 'geo') {
              final latlong = geoUri.path
                  .split(';')
                  .first
                  .split(',')
                  .map((s) => double.tryParse(s))
                  .toList();
              if (latlong.length == 2 &&
                  latlong.first != null &&
                  latlong.last != null) {
                return Column(
                  mainAxisSize: .min,
                  children: [
                    MapBubble(
                      latitude: latlong.first!,
                      longitude: latlong.last!,
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      icon: Icon(Icons.location_on_outlined, color: textColor),
                      onPressed: UrlLauncher(
                        context,
                        geoUri.toString(),
                      ).launchUrl,
                      label: Text(
                        L10n.of(context).openInMaps,
                        style: TextStyle(color: textColor),
                      ),
                    ),
                  ],
                );
              }
            }
            continue textmessage;
          case MessageTypes.Text:
          case MessageTypes.Notice:
          case MessageTypes.Emote:
          case MessageTypes.None:
          textmessage:
          default:
            if (event.redacted) {
              return RedactionWidget(
                event: event,
                buttonTextColor: buttonTextColor,
                onInfoTab: onInfoTab,
                fontSize: fontSize,
              );
            }
            if (event.content.containsKey(storyRefKey)) {
              // Те же отступы, что у обычного текстового сообщения ниже
              // (horizontal 16, vertical 8), иначе карточка прилипает к краям
              // бабла.
              return _withBelowTime(
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: StoryRefCard(event: event, textColor: textColor),
                ),
              );
            }
            // Кнопки XL (Liza reply_markup) → нативный виджет: текст + тап-кнопки.
            if (event.content.containsKey(XlButtonsContent.contentKey)) {
              return _withBelowTime(
                XlButtonsContent(
                  event: event,
                  textColor: textColor,
                  linkColor: linkColor,
                ),
              );
            }
            // Тело — голая ссылка-на-сообщение и комната доступна локально →
            // карточка-превью вместо сырого URL (паритет с Liza).
            final bareLink = event.messageType == MessageTypes.Text
                ? MessageLink.bareLinkFrom(event.body)
                : null;
            if (bareLink != null &&
                event.room.client.getRoomById(bareLink.roomId) != null) {
              return _withBelowTime(
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: MessageLinkPreview(
                    link: bareLink,
                    client: event.room.client,
                    onTap: () =>
                        UrlLauncher(context, bareLink.url()).launchUrl(),
                  ),
                ),
              );
            }
            // Отправитель прислал форматированный текст (formatted_body) →
            // рендерим его как HTML: HtmlMessage санитайзит по allowlist и
            // игнорит mx-reply. Иначе жирный/курсив/списки/ссылки от XL и
            // любого Matrix-клиента терялись — рисовался экранированный
            // плейн-body (LABA-2118 §3). Плейн-путь (mentions→пиллы) — фолбэк.
            var html =
                event.content['format'] == 'org.matrix.custom.html' &&
                    event.formattedText.isNotEmpty &&
                    !isForcedListArtifact(event.body, event.formattedText)
                ? event.formattedText
                : _convertMentionsToHtml(
                    event
                        .calcUnlocalizedBody(hideReply: true)
                        .replaceAll('<', '&lt;')
                        .replaceAll('>', '&gt;'),
                    event.room,
                  );
            if (event.messageType == MessageTypes.Emote) {
              html = '* $html';
            }

            final bigEmotes =
                event.onlyEmotes &&
                event.numberEmotes > 0 &&
                event.numberEmotes <= 3;
            // Время — в правом НИЖНЕМ углу пузыря (строкой под текстом), как у
            // голосовых/файлов (по просьбе пользователя), а не inline в конце
            // последней строки. `_withCornerTime` держит ширину пузыря по
            // содержимому через `IntrinsicWidth`.
            return _withCornerTime(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
                child: HtmlMessage(
                  html: html,
                  textColor: textColor,
                  room: event.room,
                  trailingSpan: null,
                  fontSize:
                      AppSettings.fontSizeFactor.value *
                      AppConfig.messageFontSize *
                      (bigEmotes ? 5 : 1),
                  limitHeight: !selected,
                  linkStyle: TextStyle(
                    color: linkColor,
                    fontSize:
                        AppSettings.fontSizeFactor.value *
                        AppConfig.messageFontSize,
                    decoration: TextDecoration.underline,
                    decorationColor: linkColor,
                  ),
                  onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
                  eventId: event.eventId,
                  checkboxCheckedEvents: event.aggregatedEvents(
                    timeline,
                    EventCheckboxRoomExtension.relationshipType,
                  ),
                ),
              ),
            );
        }
      case PollEventContent.startType:
        if (event.redacted) {
          return RedactionWidget(
            event: event,
            buttonTextColor: buttonTextColor,
            onInfoTab: onInfoTab,
            fontSize: fontSize,
          );
        }
        return PollWidget(
          event: event,
          timeline: timeline,
          textColor: textColor,
          linkColor: linkColor,
        );
      case EventTypes.CallInvite:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).startedACall(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
              ),
              icon: '📞',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab!(event),
              fontSize: fontSize,
            );
          },
        );
      default:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).userSentUnknownEvent(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
                event.type,
              ),
              icon: 'ℹ️',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab!(event),
              fontSize: fontSize,
            );
          },
        );
    }
  }
}

class RedactionWidget extends StatelessWidget {
  const RedactionWidget({
    super.key,
    required this.event,
    required this.buttonTextColor,
    required this.onInfoTab,
    required this.fontSize,
  });

  final Event event;
  final Color buttonTextColor;
  final void Function(Event p1)? onInfoTab;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<User?>(
      future: event.redactedBecause?.fetchSenderUser(),
      builder: (context, snapshot) {
        // Причину нормализуем и при показе: уже записанные на сервере (и от
        // чужих клиентов) бывают с хвостом переносов — пузырь растягивался на
        // весь экран (LABA-2623).
        final reason = normalizeRedactionReason(
          event.redactedBecause?.content.tryGet<String>('reason'),
        );
        final redactedBy =
            snapshot.data?.calcDisplayname() ??
            event.redactedBecause?.senderId.localpart ??
            L10n.of(context).user;
        return _ButtonContent(
          label: reason == null
              ? L10n.of(context).redactedBy(redactedBy)
              : L10n.of(context).redactedByBecause(redactedBy, reason),
          icon: '🗑️',
          textColor: buttonTextColor.withAlpha(128),
          onPressed: () => onInfoTab!(event),
          fontSize: fontSize,
          maxLines: 2,
        );
      },
    );
  }
}

class _ButtonContent extends StatelessWidget {
  final void Function() onPressed;
  final String label;
  final String icon;
  final Color? textColor;
  final double fontSize;
  final int? maxLines;

  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.onPressed,
    required this.fontSize,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onPressed,
        child: Text(
          '$icon  $label',
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
          style: TextStyle(color: textColor, fontSize: fontSize),
        ),
      ),
    );
  }
}

/// Converts @[DisplayName] and @DisplayName mention pills in plain text
// Временная диагностика: одноразовый лог на каждый event, чтобы оценить
// распределение причин «🔒 encrypted» (Encrypted vs BadEncrypted) и собрать
// session_id для сверки с to-device на сервере. Удалить после диагностики.
final _loggedEncryptedEventIds = <String>{};
void _logEncryptedRenderOnce(Event event) {
  final id = event.eventId;
  if (!_loggedEncryptedEventIds.add(id)) return;
  Logs().d(
    '[encrypted-placeholder] render eventId=$id '
    'type=${event.type} msgType=${event.messageType} '
    'canReq=${event.content['can_request_session']} '
    'session=${event.content['session_id']} '
    'sender=${event.senderId}',
  );
}

// Авто-запрос megolm-ключа для битого события — 1 раз за сессию приложения
// на пару (room_id, session_id). FluffyChat upstream дёргает event.requestKey()
// только по тапу пользователя; у нас сообщения копятся десятками, и без
// фонового запроса они не оживают. После доставки ключа SDK эмиттит апдейт
// timeline → bubble сам перерисуется в нормальный текст.
final _requestedSessions = <String>{};
void _autoRequestKeyIfNeeded(Event event) {
  if (event.content['can_request_session'] != true) return;
  final sessionId = event.content.tryGet<String>('session_id');
  if (sessionId == null) return;
  final key = '${event.room.id}:$sessionId';
  if (!_requestedSessions.add(key)) return;
  Logs().d(
    '[encrypted-placeholder] auto-requestKey session=$sessionId room=${event.room.id}',
  );
  event.requestKey();
}

/// to HTML <a> links so that HtmlMessage renders them as MatrixPill widgets.
String _convertMentionsToHtml(String text, Room room) {
  final pillRegex = RegExp(r'@\[([^\]]+)\](?:#\w+)?|@(\w+)(?:#\w+)?');
  return text.replaceAllMapped(pillRegex, (match) {
    final mentionText = match.group(0)!;
    final mxid = room.getMention(mentionText);
    if (mxid == null) return mentionText;
    final displayName = match.group(1) ?? match.group(2) ?? mentionText;
    return '<a href="https://matrix.to/#/$mxid">$displayName</a>';
  });
}

/// Раскладка «время в правом НИЖНЕМ углу» текстового пузыря: контент сверху,
/// строка времени снизу справа (единообразно с голосовыми/файлами; ранее время
/// текста было inline в конце последней строки — заменено по просьбе
/// пользователя). Используется из [MessageContent._withCornerTime].
///
/// ⚠️ Инвариант: `IntrinsicWidth` держит ширину пузыря по СОДЕРЖИМОМУ. Без него
/// `Align(centerRight)` в колонке получает свободные cross-констрейнты и
/// растягивается на всю максимальную ширину пузыря — короткое сообщение «ок»
/// раздувалось бы во всю ширину (баг «Перемудрили. Плохо это»). `IntrinsicWidth`
/// заодно поднимает минимальную ширину до строки времени, когда сам текст короче
/// неё. Виджет публичный и «глупый» (примитивы, без `Event`/Matrix Client),
/// чтобы страж `ledger:RL-message-time-corner` рендерил РЕАЛЬНУЮ вёрстку.
class CornerTimeLayout extends StatelessWidget {
  final Widget content;
  final Widget time;

  const CornerTimeLayout({
    required this.content,
    required this.time,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          content,
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 12, bottom: 6),
            child: Align(alignment: Alignment.centerRight, child: time),
          ),
        ],
      ),
    );
  }
}
