import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:collection/collection.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:matrix/matrix.dart';
import 'package:scroll_to_index/scroll_to_index.dart';

import 'package:liza/utils/news_poll.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/channel_subscribe_bar.dart';
import 'package:liza/pages/chat/chat_view.dart';
import 'package:liza/pages/chat/event_info_dialog.dart';
import 'package:liza/pages/chat/events/message.dart';
import 'package:liza/pages/chat/events/message_context_menu.dart';
import 'package:liza/pages/chat/start_poll_bottom_sheet.dart';
import 'package:liza/pages/chat_details/chat_details.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/channel_discussion.dart';
import 'package:liza/utils/clipboard_paste.dart';
import 'package:liza/utils/channel_peek.dart';
import 'package:liza/pages/chat/events/gallery.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/composer_prefill.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/xl_credentials.dart';
import 'package:liza/utils/copy_media_eligibility.dart';
import 'package:liza/utils/direct_chat_draft.dart';
import 'package:liza/utils/edit_prefill.dart';
import 'package:liza/utils/formatting_text_controller.dart';
import 'package:liza/utils/error_reporter.dart';
import 'package:liza/utils/file_description.dart';
import 'package:liza/utils/file_selector.dart';
import 'package:liza/utils/upload_error_classifier.dart';
import 'package:liza/utils/resend_failed_media.dart';
import 'package:liza/utils/upload_progress_tracker.dart';
import 'package:liza/utils/unseen_messages.dart';
import 'package:liza/pages/chat/events/audio_autoplay_service.dart';
import 'package:liza/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_file_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/post_join_backfill.dart';
import 'package:liza/utils/message_link.dart';
import 'package:liza/utils/other_party_can_receive.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/read_marker_logic.dart';
import 'package:liza/utils/read_marker_sender.dart';
import 'package:liza/utils/reply_draft_store.dart';
import 'package:liza/utils/stories/story_media_picker.dart';
import 'package:liza/utils/typed_mention_resolver.dart';
import 'package:liza/utils/video_prefetch_manager.dart';
import 'package:liza/utils/voice_recording_codec.dart';
import 'package:liza/utils/show_scaffold_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/share_scaffold_dialog.dart';
import '../../utils/account_bundles.dart';
import '../../utils/localized_exception_extension.dart';
import '../../utils/room_status_extension.dart';
import '../../utils/screen_lock_state.dart';
import '../../utils/update_policy.dart';
import '../../widgets/update_read_only_bar.dart';
import 'send_file_dialog.dart';
import 'send_location_dialog.dart';

class ChatPage extends StatelessWidget {
  final String roomId;
  final List<ShareItem>? shareItems;
  final String? eventId;

  const ChatPage({
    super.key,
    required this.roomId,
    this.eventId,
    this.shareItems,
  });

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(context).client.getRoomById(roomId);
    if (room == null) {
      // Комнаты нет в локальном сторе — это либо открытый канал, который мы
      // читаем БЕЗ вступления (Liza-модель), либо закрытая комната.
      // Отличить заранее нечем: resolveChannelHandle не отдаёт join_rule.
      // Поэтому пробуем peek, а заглушку показываем по факту отказа —
      // её текст остаётся прежним (youAreNoLongerParticipatingInThisChat).
      return ChannelPeekPage(roomId: roomId, eventId: eventId);
    }

    return ChatPageWithRoom(
      key: Key('chat_page_${roomId}_$eventId'),
      room: room,
      shareItems: shareItems,
      eventId: eventId,
    );
  }
}

class ChatPageWithRoom extends StatefulWidget {
  final Room room;
  final List<ShareItem>? shareItems;
  final String? eventId;

  const ChatPageWithRoom({
    super.key,
    required this.room,
    this.shareItems,
    this.eventId,
  });

  @override
  ChatController createState() => ChatController();
}

class ChatController extends State<ChatPageWithRoom>
    with WidgetsBindingObserver {
  Room get room => sendingClient.getRoomById(roomId) ?? widget.room;

  late Client sendingClient;

  /// Ссылка на глобальный сервис автозапуска аудио — храним из initState, чтобы
  /// снять резолвер в dispose (там Matrix.of(context) уже небезопасен).
  AudioAutoPlayService? _audioAutoPlayService;

  /// Резолвер «следующего подряд идущего аудио» для сервиса автозапуска. Читает
  /// АКТУАЛЬНЫЕ timeline/activeThreadId лениво. `filterByVisibleInGui` (а не сырой
  /// events) — иначе скрытые/служебные события наврут «подряд». Не резолвим на
  /// исторической позиции (`canRequestFuture`): следующее может быть вне окна.
  Event? _resolveNextAudioEvent(String currentEventId) {
    final timeline = this.timeline;
    if (timeline == null || timeline.canRequestFuture) return null;
    final events = timeline.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    return nextAudioEventInChain(events, currentEventId);
  }

  Timeline? timeline;

  /// Живой таймлайн привязанного чата — только когда пользователь уже член
  /// чата. Не-члену комментарии подтягиваются разовым peek'ом
  /// ([_peekedDiscussionEvents]): держать Timeline без `join` Matrix не даёт.
  Timeline? discussionTimeline;

  List<Map<String, dynamic>> _peekedDiscussionEvents = const [];

  /// События привязанного чата в форме, которую понимают findMirrorEventId /
  /// countReplies. Один общий источник на всю ленту, а не N подписок.
  List<Map<String, dynamic>> get discussionEvents =>
      discussionTimeline?.events
          .map((e) => {'event_id': e.eventId, 'content': e.content})
          .toList() ??
      _peekedDiscussionEvents;

  String? activeThreadId;

  String readMarkerEventId = '';

  String get roomId => widget.room.id;

  final AutoScrollController scrollController = AutoScrollController();

  late final FocusNode inputFocus;

  Timer? typingCoolDown;
  Timer? typingTimeout;
  bool currentlyTyping = false;
  bool dragging = false;

  void onDragEntered(dynamic _) => setState(() => dragging = true);

  void onDragExited(dynamic _) => setState(() => dragging = false);

  void onDragDone(DropDoneDetails details) async {
    if (_blockedByUpdate()) return;
    setState(() => dragging = false);
    if (details.files.isEmpty) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: details.files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  static const Set<String> _saveableMessageTypes = {
    MessageTypes.Video,
    MessageTypes.Image,
    MessageTypes.Sticker,
    MessageTypes.Audio,
    MessageTypes.File,
  };

  bool get canSaveSelectedEvents =>
      selectedEvents.any((e) => _saveableMessageTypes.contains(e.messageType));

  /// Скачивает все выбранные вложения одним действием (мультивыбор). На desktop
  /// спрашивает папку назначения один раз на всю пачку (диалог выбора каталога),
  /// затем сохраняет туда все файлы; на web — прямой загрузкой браузером; на
  /// mobile — системным диалогом на каждый файл (там нет общего каталога).
  Future<void> saveSelectedFiles(BuildContext context) async {
    // Гейт в самом методе, а не только на кнопке (см. copyEventsAction).
    if (room.isContentProtected) return;
    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final events = selectedEvents
        .where((event) => _saveableMessageTypes.contains(event.messageType))
        .toList();
    clearSelectedEvents();
    if (events.isEmpty) return;

    // Desktop: один диалог выбора папки на всю пачку (вместо тихого сохранения в
    // «Загрузки»). Отмена диалога — отменяет скачивание. На mobile/web directory
    // остаётся null → saveToDisk сам решает (SAF-диалог на файл / браузер).
    Directory? directory;
    if (PlatformInfos.isDesktop) {
      final selectedDir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.saveFile,
      );
      if (selectedDir == null) return;
      directory = Directory(selectedDir);
    }

    final result = await showFutureLoadingDialog<List<String>>(
      context: context,
      future: () async {
        final paths = <String>[];
        Object? lastError;
        StackTrace? lastStackTrace;
        // Устойчивость к обрыву на одном файле: не роняем всю пачку из-за одного
        // неудачного скачивания (частый кейс — транзиентный TLS/HandshakeException
        // при перезапуске сервера). Сохраняем что удалось; если не удалось НИЧЕГО
        // — пробрасываем последнюю ошибку, чтобы диалог показал её локализованно
        // (а не пустой результат).
        for (final event in events) {
          try {
            final file = await event.downloadAndDecryptAttachmentHealed();
            final path = await file.saveToDisk(context, directory: directory);
            if (path != null) paths.add(path);
          } catch (e, s) {
            lastError = e;
            lastStackTrace = s;
            Logs().w('Failed to download/save selected attachment', e, s);
          }
        }
        if (paths.isEmpty && lastError != null) {
          Error.throwWithStackTrace(
            lastError,
            lastStackTrace ?? StackTrace.current,
          );
        }
        return paths;
      },
    );

    final paths = result.result;
    if (paths == null || paths.isEmpty) return;

    scaffoldMessenger.showSnackBar(
      SnackBar(
        content: Text(
          paths.length == 1
              ? l10n.fileHasBeenSavedAt(paths.single)
              : l10n.filesHaveBeenSaved(paths.length),
        ),
      ),
    );
  }

  List<Event> selectedEvents = [];

  final Set<String> unfolded = {};

  Event? replyEvent;

  Event? editEvent;

  /// Распознанная ссылка-на-сообщение в тексте композера — для превью над
  /// инпутом (аналог Liza). null, пока в тексте нет такой ссылки.
  MessageLink? messageLinkPreview;

  /// Ссылка, превью которой пользователь закрыл крестиком: не показываем
  /// снова, пока ссылка в тексте не сменится на другую.
  MessageLink? _dismissedLinkPreview;

  bool _scrolledUp = false;

  /// Открытие ещё не решило, куда позиционироваться (LABA-2632). Лента уже
  /// смонтирована ВНИЗУ, а `_scrolledUp == false`, поэтому любой реактивный
  /// вызов (`updateView` от `requestHistory` при >30 непрочитанных, sync,
  /// `resumed`, `markAtBottom`) слал бы ПОЛНУЮ квитанцию до прокрутки к
  /// сепаратору. Пока флаг поднят, `_sendReadMarkerNow` молчит на всё — финал
  /// `_tryLoadTimeline` досылает квитанцию сам.
  bool _openPositioningPending = false;

  bool get showScrollDownButton =>
      _scrolledUp || timeline?.allowNewEvent == false;

  /// Реально ли на экране новейшие сообщения (по живым scroll-метрикам), а не по
  /// возможно залипшему `_scrolledUp`. Нужен, чтобы гейт в `_sendReadMarkerNow`
  /// не глушил квитанцию, когда новейшее сообщение видно, но флаг застрял в true
  /// (mount/клавиатура в маленьком чате). Логика — `newestMessagesVisible`.
  bool get _newestMessagesVisible {
    if (!scrollController.hasClients) return false;
    final position = scrollController.position;
    return newestMessagesVisible(
      maxScrollExtent: position.maxScrollExtent,
      pixels: position.pixels,
      allowNewEvent: timeline?.allowNewEvent ?? true,
    );
  }

  /// Новейшее событие, реально попавшее на экран, — цель частичной квитанции
  /// (Telegram-модель «прочитано = увидено»). `null` — считать нельзя или
  /// не нужно: авто-скролл (иначе квитанция на промежуточный viewport и цикл
  /// «тряски» через смену layout), тред, исторический контекст по ссылке
  /// (`!allowNewEvent`), лента ещё не смонтирована. eventId берём из `ValueKey`
  /// тега, не из `events[index]`: индексы tagMap сдвигаются между вставкой
  /// события и rebuild'ом. Геометрия — `localToGlobal` относительно viewport'а
  /// (Flutter сам учитывает reverse-направление), решение — чистая
  /// `newestVisibleEventId`.
  String? _newestVisibleEventId() {
    if (activeThreadId != null) return null;
    final timeline = this.timeline;
    if (timeline == null || !timeline.allowNewEvent) return null;
    if (!scrollController.hasClients || scrollController.isAutoScrolling) {
      return null;
    }
    RenderBox? viewport;
    final tags = <VisibleTag>[];
    for (final entry in scrollController.tagMap.entries) {
      final key = entry.value.widget.key;
      if (key is! ValueKey<String>) continue;
      final ctx = entry.value.context;
      if (!ctx.mounted) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if (viewport == null) {
        // На раннем кадре viewport'а может ещё не быть — пропускаем тик,
        // следующий триггер досчитает.
        try {
          final RenderObject vp = RenderAbstractViewport.of(box);
          if (vp is! RenderBox) return null;
          viewport = vp;
        } catch (_) {
          return null;
        }
      }
      final origin = box.localToGlobal(Offset.zero, ancestor: viewport);
      tags.add((index: entry.key, eventId: key.value, rect: origin & box.size));
    }
    if (viewport == null) return null;
    final candidate = newestVisibleEventId(tags, viewport.size);
    if (candidate == null) return null;
    // Квитанция — только на событие из видимой ленты этого контекста.
    final visible = timeline.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    return visible.any((e) => e.eventId == candidate) ? candidate : null;
  }

  /// Позиция сепаратора «Непрочитанное» при открытии: `m.fully_read` (или
  /// корень треда, если последнее событие — из треда), когда есть чужие
  /// сообщения новее моей квитанции. Порядковый `hasUnseenMessages`, а не
  /// SDK-`hasNewMessages`: после частичной квитанции тот врёт «всё прочитано».
  String _initialReadMarkerEventId() {
    if (!room.hasUnseenMessages) return '';
    final lastEventThreadId =
        room.lastEvent?.relationshipType == RelationshipTypes.thread
        ? room.lastEvent?.relationshipEventId
        : null;
    return lastEventThreadId ?? room.fullyRead;
  }

  bool get selectMode => selectedEvents.isNotEmpty;

  final int _loadHistoryCount = 100;

  String pendingText = '';

  /// Форматирование отложенного черновика — парно к [pendingText]. Без него
  /// спаны черновика оставались бы в контроллере на время правки и уезжали в
  /// чужое сообщение, а свой формат черновик терял (INV-E8 спеки
  /// `2026-09-04-edit-preserves-formatting-design.md`).
  List<FormatSpan> pendingSpans = const [];

  bool showEmojiPicker = false;

  String? get threadLastEventId {
    final threadId = activeThreadId;
    if (threadId == null) return null;
    return timeline?.events
        .filterByVisibleInGui(threadId: threadId)
        .firstOrNull
        ?.eventId;
  }

  void enterThread(String eventId) => setState(() {
    activeThreadId = eventId;
    selectedEvents.clear();
  });

  void closeThread() => setState(() {
    activeThreadId = null;
    selectedEvents.clear();
  });

  void recreateChat() async {
    final room = this.room;
    final userId = room.directChatMatrixID;
    if (userId == null) {
      throw Exception(
        'Try to recreate a room with is not a DM room. This should not be possible from the UI!',
      );
    }
    // Живой DM с тем же партнёром уже есть — открываем его, а не возвращаем
    // собеседника в брошенную комнату вторым чатом (LABA-2633).
    final live = findLiveDirectChat(room.client, userId, exclude: room);
    if (live != null) {
      context.go('/rooms/${live.id}');
      return;
    }
    await showFutureLoadingDialog(
      context: context,
      future: () => room.invite(userId),
    );
  }

  void leaveChat() async {
    final success = await showFutureLoadingDialog(
      context: context,
      future: room.leave,
    );
    if (success.error != null) return;
    context.go('/rooms');
  }

  void requestHistory([dynamic _]) async {
    Logs().v('Requesting history...');
    await timeline?.requestHistory(historyCount: _loadHistoryCount);
  }

  void requestFuture() async {
    final timeline = this.timeline;
    if (timeline == null) return;
    Logs().v('Requesting future...');

    final mostRecentEvent = timeline.events.filterByVisibleInGui().firstOrNull;

    await timeline.requestFuture(historyCount: _loadHistoryCount);

    if (mostRecentEvent != null) {
      setReadMarker(eventId: mostRecentEvent.eventId);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final index = timeline.events.filterByVisibleInGui().indexOf(
          mostRecentEvent,
        );
        if (index >= 0) {
          scrollController.scrollToIndex(
            index,
            preferPosition: AutoScrollPosition.begin,
          );
        }
      });
    }
  }

  void _updateScrollController() {
    if (!mounted) {
      return;
    }
    if (!scrollController.hasClients) return;
    // Решение вынесено в чистую scrollControllerUpdateAction (покрыто тестом).
    // Ключевой инвариант: во время программного авто-скролла (scrollToIndex к
    // сепаратору «Непрочитанное») listener НЕ трогает layout — иначе сброс
    // readMarkerEventId убирал сепаратор (~48px), геометрия менялась, и
    // scrollToIndex прыгал заново → экран «трясётся» в цикле. Пороги 2.0/1.0 —
    // прежний гистерезис против subpixel-осцилляции pixels около 0.
    final action = scrollControllerUpdateAction(
      maxScrollExtent: scrollController.position.maxScrollExtent,
      pixels: scrollController.position.pixels,
      allowNewEvent: timeline?.allowNewEvent ?? true,
      scrolledUp: _scrolledUp,
      isAutoScrolling: scrollController.isAutoScrolling,
    );
    switch (action) {
      case ScrollUpdateAction.none:
        break;
      case ScrollUpdateAction.setScrolledUpTrue:
        setState(() => _scrolledUp = true);
      case ScrollUpdateAction.setScrolledUpFalseAndMark:
        setState(() => _scrolledUp = false);
        setReadMarker();
      case ScrollUpdateAction.markAtBottom:
        // Контент помещается целиком у низа: сбрасываем залипший флаг «вниз»
        // (mount/клавиатура давали maxScrollExtent на миг > 0) и досылаем
        // квитанцию на свежее чужое сообщение.
        if (_scrolledUp) setState(() => _scrolledUp = false);
        setReadMarker();
    }
    // Telegram-модель «прочитано = увидено»: выше низа квитанция уходит на
    // новейшее видимое событие, когда прокрутка УСТОЯЛАСЬ (дебаунс —
    // геометрия tagMap на каждый пиксель не нужна; во время авто-скролла
    // _newestVisibleEventId молчит сам). Слушатель ничего не рисует.
    if (_scrolledUp && !scrollController.isAutoScrolling) {
      _viewportReadDebounce?.cancel();
      _viewportReadDebounce = Timer(_viewportReadDebounceDuration, () {
        if (!mounted || !_scrolledUp) return;
        setReadMarker();
      });
    }
  }

  static const Duration _viewportReadDebounceDuration = Duration(
    milliseconds: 250,
  );
  Timer? _viewportReadDebounce;

  void _loadDraft() async {
    final prefs = Matrix.of(context).store;
    final draft = prefs.getString('draft_$roomId');
    if (draft != null && draft.isNotEmpty) {
      sendController.text = draft;
      // Восстанавливаем и явное форматирование черновика (спаны), иначе при
      // возврате в чат текст есть, а формат пропал.
      sendController.restoreSpans(
        prefs.getString('draftfmt_$roomId'),
        draft.length,
      );
    }
  }

  ReplyDraftStore get _replyDraftStore =>
      ReplyDraftStore(Matrix.of(context).store);

  /// Сохраняет/снимает связку «отвечаю на событие» рядом с текстовым черновиком.
  /// Без этого при переключении чата (ChatController пересоздаётся) текст ответа
  /// оставался в поле, а сам reply слетал — см. `_restoreReplyDraft`.
  void _persistReplyDraft() =>
      _replyDraftStore.save(roomId, replyEvent?.eventId);

  /// Восстанавливает reply из черновика после загрузки таймлайна. Вызывается
  /// когда timeline уже готов — иначе события ещё нет в памяти.
  Future<void> _restoreReplyDraft() async {
    if (replyEvent != null) return;
    final id = _replyDraftStore.read(roomId);
    if (id == null) return;
    final event = await (timeline?.getEventById(id) ?? room.getEventById(id));
    if (!mounted || event == null) return;
    setState(() => replyEvent = event);
  }

  void _shareItems([dynamic _]) {
    final shareItems = widget.shareItems;
    if (shareItems == null || shareItems.isEmpty) return;
    // Проверка ПОСЛЕ пустого списка: метод зовётся на каждом входе в чат.
    if (_blockedByUpdate()) return;
    // LABA-2242: удалённому боту не шлём и через системный share-sheet (этот путь
    // в обход скрытого композера; otherPartyCanReceiveMessages для бот-DM = true).
    final deletedBot = isDeletedBotDm(room);
    if (deletedBot || !room.otherPartyCanReceiveMessages) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            deletedBot
                ? L10n.of(context).deletedAccountCannotWrite
                : L10n.of(context).otherPartyNotLoggedIn,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          showCloseIcon: true,
        ),
      );
      return;
    }
    for (final item in shareItems) {
      if (item is FileShareItem) continue;
      if (item is TextShareItem) room.sendTextEvent(item.value);
      if (item is ContentShareItem) room.sendEvent(item.value);
    }
    final files = shareItems
        .whereType<FileShareItem>()
        .map((item) => item.value)
        .toList();
    if (files.isEmpty) return;
    showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  KeyEventResult _customEnterKeyHandling(FocusNode node, KeyEvent evt) {
    if (evt is KeyDownEvent &&
        evt.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      _handleClipboardPaste();
      return KeyEventResult.handled;
    }

    // Хоткеи форматирования (desktop): Ctrl/Cmd + B/I/U, +Shift для
    // strike/mono/spoiler. Матчим по logicalKey, а не по символу — на русской
    // раскладке символ был бы «Б/И/У», а logicalKey остаётся keyB/keyI/keyU.
    // Формат применяется только к непустому выделению (toggleFormat гарантирует).
    if (evt is KeyDownEvent &&
        (HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isControlPressed)) {
      final shift = HardwareKeyboard.instance.isShiftPressed;
      MessageFormat? format;
      if (!shift && evt.logicalKey == LogicalKeyboardKey.keyB) {
        format = MessageFormat.bold;
      } else if (!shift && evt.logicalKey == LogicalKeyboardKey.keyI) {
        format = MessageFormat.italic;
      } else if (!shift && evt.logicalKey == LogicalKeyboardKey.keyU) {
        format = MessageFormat.underline;
      } else if (shift && evt.logicalKey == LogicalKeyboardKey.keyX) {
        format = MessageFormat.strikethrough;
      } else if (shift && evt.logicalKey == LogicalKeyboardKey.keyM) {
        format = MessageFormat.monospace;
      } else if (shift && evt.logicalKey == LogicalKeyboardKey.keyP) {
        format = MessageFormat.spoiler;
      }
      if (format != null) {
        if (!sendController.selection.isCollapsed) {
          sendController.toggleFormat(format);
        }
        return KeyEventResult.handled;
      }
    }

    // Проверяем Enter по logicalKey, а не по keyLabel: keyLabel зависит
    // от раскладки/IME — на macOS c RU-раскладкой может прийти не "Enter".
    final isEnter =
        evt.logicalKey == LogicalKeyboardKey.enter ||
        evt.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    // Любой модификатор + Enter — перенос строки. Возвращаем ignored до
    // других проверок, чтобы TextField сам вставил \n.
    final hasModifier =
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    if (hasModifier) return KeyEventResult.ignored;

    if (!PlatformInfos.isMobile) {
      if (evt is KeyDownEvent) send();
      return KeyEventResult.handled;
    }

    if (evt is KeyDownEvent) {
      final currentLineNum =
          sendController.text
              .substring(0, sendController.selection.baseOffset)
              .split('\n')
              .length -
          1;
      final currentLine = sendController.text.split('\n')[currentLineNum];

      for (final pattern in [
        '- [ ] ',
        '- [x] ',
        '* [ ] ',
        '* [x] ',
        '- ',
        '* ',
        '+ ',
      ]) {
        if (currentLine.startsWith(pattern)) {
          if (currentLine == pattern) {
            return KeyEventResult.ignored;
          }
          sendController.text += '\n$pattern';
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  void initState() {
    // sendingClient должен быть присвоен до первого использования геттера
    // `room` — иначе LateInitializationError валит initState и чат рендерится
    // как серый экран.
    sendingClient = Matrix.of(context).client;

    inputFocus = FocusNode(onKeyEvent: _customEnterKeyHandling);

    scrollController.addListener(_updateScrollController);
    inputFocus.addListener(_inputFocusListener);
    composerPrefill.addListener(_applyComposerPrefill);
    UpdatePolicyController.current.addListener(_onUpdatePolicy);

    // Автозапуск цепочки голосовых/аудио: регистрируем резолвер «следующего
    // подряд идущего аудио» — только ChatController знает activeThreadId+timeline,
    // а подписка на завершение живёт в глобальном сервисе (переживает уход из
    // чата). Вне открытого чата резолвера нет → цепочка обрывается (дефолт).
    _audioAutoPlayService = Matrix.of(context).audioAutoPlayService
      ..registerResolver(roomId, _resolveNextAudioEvent);

    _loadDraft();
    WidgetsBinding.instance.addPostFrameCallback(_shareItems);
    super.initState();
    _displayChatDetailsColumn = ValueNotifier(
      AppSettings.displayChatDetailsColumn.value,
    );

    readMarkerEventId = _initialReadMarkerEventId();
    WidgetsBinding.instance.addObserver(this);
    VideoPrefetchManager.instance.setActiveRoom(room);
    // Чужие квитанции приходят ephemeral'ом m.receipt и не триггерят
    // timeline.onUpdate — без подписки галочки done/done_all и аватарки
    // «прочитал до сюда» обновлялись бы только со следующим событием в комнате.
    // Коалесинг через microtask: при открытии/чтении группы сервер шлёт
    // ПАЧКУ m.receipt (по одному на участника, иногда в нескольких батчах) —
    // без схлопывания каждый дёргал бы полный rebuild списка → мерцание и
    // дёрганье прокрутки (баг #3). Один rebuild в конце microtask достаточен.
    _receiptsSubscription = Matrix.of(context).client.onSync.stream
        .where(
          (syncUpdate) =>
              syncUpdate.rooms?.join?[roomId]?.ephemeral?.any(
                (ephemeral) => ephemeral.type == 'm.receipt',
              ) ??
              false,
        )
        .listen((_) {
          if (!mounted || _receiptUpdateScheduled) return;
          _receiptUpdateScheduled = true;
          Future.microtask(() {
            _receiptUpdateScheduled = false;
            if (mounted) setState(() {});
          });
        });
    // Запрет сохранения контента живёт room state'ом, а `SecureScreenGuard`
    // стоит НАД StreamBuilder'ом на onRoomState и FutureBuilder'ом таймлайна
    // (`chat_view.dart`) — их перестройка `enabled:` не перечитывает. Без этой
    // подписки включение запрета владельцем, пока участник уже сидит в чате, не
    // применялось бы до посторонней перерисовки (LABA-2541). Фильтр узкий:
    // общий rebuild на любое state-событие комнаты дал бы перестроечный шторм.
    _contentProtectionSubscription = Matrix.of(context)
        .client
        .onRoomState
        .stream
        .where(
          (update) =>
              update.roomId == roomId &&
              update.state.type == channelNoForwardsState,
        )
        .listen((_) {
          if (mounted) setState(() {});
        });
    _tryLoadTimeline();
    reloadDiscussionEvents();
    // Своё действие (композер / кнопка карточки бота / XL-кнопка) → прокрутка
    // к низу, чтобы ответ бота был виден. Слушаем local-echo на уровне клиента,
    // а не `Timeline.onInsert`: тот молчит при `allowNewEvent == false`
    // (чат открыт по ссылке на старое событие), а прыжок нужен и там.
    final client = Matrix.of(context).client;
    _ownEchoSubscription = client.onTimelineEvent.stream
        .where(
          (event) => shouldScrollDownOnOwnEcho(
            event,
            myUserId: client.userID,
            roomId: roomId,
            activeThreadId: activeThreadId,
          ),
        )
        .listen(_onOwnEcho);
    // Бот XL держит ключ только в памяти процесса — после его рестарта
    // мерчант увидел бы просьбу подключить интеграцию заново без этого.
    maybeResendXlKey(sendingClient, room);
  }

  /// Подтягивает ленту привязанного чата ради счётчиков комментариев под
  /// постами. Членство НЕ навязываем: тихий join — только по явному действию
  /// пользователя (тап по плашке), иначе простое открытие канала записывало бы
  /// в чат каждого читателя.
  ///
  /// Перечитывается не только на входе в канал: после тихого join (тап по
  /// плашке) членство уже есть, и снимок peek'а надо заменить живым таймлайном
  /// — иначе оставленный комментарий не долетит до счётчика, и плашка так и
  /// будет показывать «ноль» до пересоздания экрана.
  Future<void> reloadDiscussionEvents() async {
    if (!room.isChannel || !room.hasComments) return;
    final discussion = room.discussionRoom;
    if (discussion != null && discussion.membership == Membership.join) {
      // Уже живём на таймлайне — второй раз поднимать не нужно: он сам
      // реактивен, а лишний getTimeline оставил бы висеть подписку.
      if (discussionTimeline != null) return;
      final timeline = await discussion.getTimeline(onUpdate: updateView);
      if (!mounted) {
        timeline.cancelSubscriptions();
        return;
      }
      setState(() {
        discussionTimeline?.cancelSubscriptions();
        discussionTimeline = timeline;
      });
      return;
    }
    // Не-член читает комментарии через /messages: у открытого канала чат
    // world_readable, так что peek отдаёт и зеркала постов, и ответы на них.
    try {
      final response = await room.client.getRoomEvents(
        room.discussionRoomId!,
        Direction.b,
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _peekedDiscussionEvents = response.chunk
            .map((e) => {'event_id': e.eventId, 'content': e.content})
            .toList();
      });
    } catch (e, s) {
      // Закрытый канал без инвайта — peek законно запрещён, плашка просто
      // покажет ноль комментариев.
      Logs().w('Не удалось прочитать чат-обсуждение ${room.id}', e, s);
    }
  }

  StreamSubscription? _receiptsSubscription;
  StreamSubscription? _contentProtectionSubscription;
  bool _receiptUpdateScheduled = false;

  final Set<String> expandedEventIds = {};

  void expandEventsFrom(Event event, bool expand) {
    final events = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    final start = events.indexOf(event);
    setState(() {
      for (var i = start; i < events.length; i++) {
        final event = events[i];
        if (!event.isCollapsedState) return;
        if (expand) {
          expandedEventIds.add(event.eventId);
        } else {
          expandedEventIds.remove(event.eventId);
        }
      }
    });
  }

  void _tryLoadTimeline() async {
    final initialEventId = widget.eventId;
    // До _getTimeline: onUpdate возможен уже при загрузке ленты.
    _openPositioningPending = true;
    loadTimelineFuture = _getTimeline();
    try {
      await loadTimelineFuture;
      // Восстанавливаем reply-черновик: событие уже в памяти таймлайна.
      await _restoreReplyDraft();
      // We launched the chat with a given initial event ID:
      if (initialEventId != null) {
        // Открытие по ссылке — прежнее поведение: финального вызова, который
        // дослал бы квитанцию, в этой ветке нет.
        _openPositioningPending = false;
        scrollToEventId(initialEventId);
        return;
      }

      // LABA-1898: свежепринятый инвайт приходит limited-sync'ом → SDK вычищает
      // локальную ленту (deleteTimelineForRoom), а сообщение, отправленное до
      // нашего join, остаётся за prev_batch-гэпом: в списке чатов превью есть
      // (room.lastEvent докачан серверным /messages), а таймлайн пуст. Догружаем
      // историю разово (с малым потолком батчей). Ставим ДО read-marker-логики —
      // иначе openChatReadMarkerPlan посчитается по пустой ленте (регресс
      // LABA-1894). initialEventId==null гарантирован ранним return выше.
      await _backfillEmptyTimelineAfterJoin();
      if (!mounted) return;

      // Порядок «квитанция vs lastEvent» из локальной БД: initState мог решить
      // по ts-фолбэку SDK (частичная квитанция с другого устройства выглядит
      // как «всё прочитано»), теперь досчитываем честно.
      await UnseenOrderCache.reconcileRoom(room);
      if (!mounted) return;
      if (readMarkerEventId.isEmpty) {
        readMarkerEventId = _initialReadMarkerEventId();
      }

      // Продвигаем сепаратор «Непрочитанное» за свои сообщения: иначе он висит
      // над своим свежим сообщением (п.2.3). hasNewMessages из SDK не различает
      // эту ситуацию для thread'ов и старых receipts, поэтому правим явно.
      _advanceReadMarkerPastMine();

      var readMarkerEventIndex = readMarkerEventId.isEmpty
          ? -1
          : timeline!.events
                .filterByVisibleInGui(
                  exceptionEventId: readMarkerEventId,
                  threadId: activeThreadId,
                )
                .indexWhere((e) => e.eventId == readMarkerEventId);

      // Read marker is existing but not found in first events. Try a single
      // requestHistory call before opening timeline on event context:
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        await timeline?.requestHistory(historyCount: _loadHistoryCount);
        readMarkerEventIndex = timeline!.events
            .filterByVisibleInGui(
              exceptionEventId: readMarkerEventId,
              threadId: activeThreadId,
            )
            .indexWhere((e) => e.eventId == readMarkerEventId);
      }

      final lastEventId = timeline?.room.lastEvent?.eventId;
      final plan = openChatReadMarkerPlan(
        readMarkerEventIndex: readMarkerEventIndex,
        canMarkLastEvent:
            timeline?.allowNewEvent == true && lastEventId != null,
      );

      if (plan.scrollToDivider) {
        // Маркер уехал вверх: позиционируемся на сепараторе «Непрочитанное» и
        // после позиционирования шлём квитанцию на новейшее ВИДИМОЕ событие
        // (Telegram-модель «прочитано = увидено», запрос Саши Н. 2026-09-17).
        // До этого здесь была квитанция на ПОСЛЕДНЕЕ событие (LABA-1894): бейдж
        // гас сразу, но сервер считал всё прочитанным, и при возврате чат
        // открывался снизу без сепаратора. Квитанция ОБЯЗАНА уйти (корень
        // LABA-1894 — ранний return без квитанции вовсе), но только за то, что
        // на экране: остаток честно остаётся непрочитанным и в бейдже.
        Logs().v('Scroll up to visible event', readMarkerEventId);
        await scrollToEventId(readMarkerEventId, highlightEvent: false);
        if (!mounted) return;
        if (plan.markVisibleAfterPosition) {
          // scrollToIndex завершился, но геометрия последнего кадра могла ещё
          // не устояться — ждём кадр; гейт в _sendReadMarkerNow при
          // isAutoScrolling молчит сам (ScrollEnd-дебаунс догонит).
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted) return;
          _openPositioningPending = false;
          // Только ЯВНАЯ частичная: голый setReadMarker() при неудавшемся
          // позиционировании (лента осталась внизу, _scrolledUp == false) дал
          // бы полную. null — геометрии нет, догонит дебаунс ScrollEnd.
          final visibleEventId = _newestVisibleEventId();
          if (visibleEventId != null) setReadMarker(eventId: visibleEventId);
        }
        return;
      }
      if (readMarkerEventId.isNotEmpty && readMarkerEventIndex == -1) {
        _showScrollUpMaterialBanner(readMarkerEventId);
      }

      // Сбрасываем _scrolledUp: layout-фреймы между mount и загрузкой
      // timeline могли выставить его в true и заблокировать setReadMarker.
      _scrolledUp = false;
      _openPositioningPending = false;

      // Гибрид «по открытию»: если мы внизу таймлайна и есть последнее
      // событие — принудительно отправляем маркер на него, минуя проверку
      // _scrolledUp (но не lifecycle и не scrollUpBanner).
      if (plan.markLastEvent) {
        setReadMarker(eventId: lastEventId, force: true);
      } else {
        setReadMarker();
      }

      if (!mounted) return;
      // Безусловная перерисовка после загрузки таймлайна. `getTimeline()` внутри
      // делает `room.postLoad()` — именно там partial-комната добирает
      // «неважные» room state. До этой строки счастливый путь не делал ни одного
      // setState, и `SecureScreenGuard(enabled: room.isContentProtected)` в
      // `chat_view.dart` мог остаться со значением первого кадра до случайной
      // посторонней перерисовки (LABA-2541). Defense-in-depth к тому, что тип
      // флага теперь в importantStateEvents.
      setState(() {});
    } catch (e, s) {
      ErrorReporter(context, 'Unable to load timeline').onErrorCallback(e, s);
      rethrow;
    } finally {
      // Backstop для исключения и ранних return: залипший флаг глушил бы
      // квитанции навсегда (рецидив LABA-1894 — бейдж не гаснет).
      _openPositioningPending = false;
    }
  }

  /// Потолок батчей догрузки при пустой ленте (LABA-1898): защита от «в первом
  /// батче только state-события» и одновременно жёсткая граница против цикла.
  static const int _postJoinBackfillMaxBatches = 3;

  /// LABA-1898: если после открытия чата видимая лента пуста, но у комнаты есть
  /// реальное последнее событие — разово догружаем историю (см.
  /// [backfillEmptyTimelineAfterJoin]), чтобы приглашённый увидел сообщения,
  /// отправленные ДО его join. Логика и гейты — в тестируемом хелпере.
  Future<void> _backfillEmptyTimelineAfterJoin() async {
    final t = timeline;
    if (t == null) return;
    await backfillEmptyTimelineAfterJoin(
      t,
      threadId: activeThreadId,
      isMounted: () => mounted,
      maxBatches: _postJoinBackfillMaxBatches,
      historyCount: _loadHistoryCount,
    );
  }

  String? scrollUpBannerEventId;

  void discardScrollUpBannerEventId() => setState(() {
    scrollUpBannerEventId = null;
  });

  void _showScrollUpMaterialBanner(String eventId) => setState(() {
    scrollUpBannerEventId = eventId;
  });

  bool _updateViewScheduled = false;

  void updateView() {
    if (!mounted) return;
    // Coalesce: SDK может вызвать onUpdate несколько раз за один sync batch
    // (typing, receipts, events). Одного rebuild в конце microtask достаточно.
    if (_updateViewScheduled) return;
    _updateViewScheduled = true;
    Future.microtask(() {
      if (!mounted) return;
      _updateViewScheduled = false;
      // Реактивно, а не только при открытии: свои новые сообщения после
      // readMarker не должны держать над собой сепаратор «Непрочитанное».
      _advanceReadMarkerPastMine();
      setReadMarker();
      setState(() {});
      if (_pendingScrollDownAfterEcho) {
        _pendingScrollDownAfterEcho = false;
        // Прыгать только ПОСЛЕ кадра с новым элементом: синхронный jumpTo(0)
        // в момент echo клэмпится к старому maxScrollExtent и даёт второй
        // прыжок, когда список дорастёт.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) scrollDown();
        });
      }
    });
  }

  /// Флаг «после ближайшего rebuild прыгнуть к низу» — ставится по своему
  /// local-echo (см. [_onOwnEcho]), исполняется в [updateView].
  bool _pendingScrollDownAfterEcho = false;

  StreamSubscription<Event>? _ownEchoSubscription;

  void _onOwnEcho(Event _) {
    if (!mounted) return;
    switch (ownEchoScrollAction(allowNewEvent: timeline?.allowNewEvent)) {
      case OwnEchoScrollAction.deferJumpToBottom:
        _pendingScrollDownAfterEcho = true;
      case OwnEchoScrollAction.reloadToLiveEnd:
        // Исторический контекст (открыт по ссылке): в такой таймлайн echo не
        // попадает вовсе — единственный способ его увидеть — перезагрузка на
        // живой конец, это и делает scrollDown().
        scrollDown();
      case OwnEchoScrollAction.none:
        break;
    }
  }

  /// Продвигает сепаратор «Непрочитанное» за собственные сообщения. Сервер не
  /// шлёт m.read автору на его же событие, поэтому room.fullyRead отстаёт на
  /// последнее ЧУЖОЕ сообщение, и сепаратор всплывал НАД своим свежим
  /// сообщением (п.2.3, ранее баг #2). Ставим маркер ровно перед первым
  /// непрочитанным ЧУЖИМ сообщением, перешагивая свои; если непрочитанных чужих
  /// нет — снимаем маркер вовсе. timeline.events идут от новых к старым →
  /// «после» маркера = индексы < markerIdx.
  void _advanceReadMarkerPastMine() {
    if (readMarkerEventId.isEmpty || timeline == null) return;
    final myUserId = Matrix.of(context).client.userID;
    if (myUserId == null) return;
    final visibleEvents = timeline!.events.filterByVisibleInGui(
      threadId: activeThreadId,
    );
    readMarkerEventId = advanceReadMarkerPastMine(
      visibleEvents,
      readMarkerEventId,
      myUserId,
    );
  }

  Future<void>? loadTimelineFuture;

  int? animateInEventIndex;

  void onInsert(int i) {
    // setState will be called by updateView() anyway
    if (timeline?.allowNewEvent == true) animateInEventIndex = i;
    // Своё новое сообщение не должно держать над собой сепаратор
    // «Непрочитанное» (баг #2: своё сообщение показывалось непрочитанным и
    // подвисало, пока не переключишь чат и не прокрутишь). updateView
    // коалесцируется в microtask и в гонке с sync-batch мог отработать на
    // ещё не вмердженном таймлайне — поэтому гасим маркер синхронно прямо
    // при вставке СВОЕГО события. _advanceReadMarkerPastMine идемпотентен и
    // оставляет маркер над первым непрочитанным ЧУЖИМ событием.
    final events = timeline?.events;
    if (events != null && i >= 0 && i < events.length) {
      if (events[i].senderId == Matrix.of(context).client.userID) {
        _advanceReadMarkerPastMine();
      }
    }
  }

  Future<void> _getTimeline({String? eventContextId}) async {
    await Matrix.of(context).client.roomsLoading;
    await Matrix.of(context).client.accountDataLoading;
    if (eventContextId != null &&
        (!eventContextId.isValidMatrixId || eventContextId.sigil != '\$')) {
      eventContextId = null;
    }
    try {
      timeline?.cancelSubscriptions();
      timeline = await room.getTimeline(
        onUpdate: updateView,
        eventContextId: eventContextId,
        onInsert: onInsert,
      );
    } catch (e, s) {
      Logs().w('Unable to load timeline on event ID $eventContextId', e, s);
      if (!mounted) return;
      timeline = await room.getTimeline(
        onUpdate: updateView,
        onInsert: onInsert,
      );
      if (!mounted) return;
      if (e is TimeoutException || e is IOException) {
        _showScrollUpMaterialBanner(eventContextId!);
      }
    }
    timeline!.requestKeys(onlineKeyBackupOnly: false);
    if (room.markedUnread) room.markUnread(false);

    return;
  }

  String? scrollToEventIdMarker;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // При уходе в фон iOS замораживает сокеты — HTTP-запросы typing
      // получат ETIMEDOUT (errno 60). Отменяем таймеры, не шлём по сети:
      // сервер сам снимет typing по серверному timeout (30 сек).
      _cancelTyping();
      return;
    }
    if (!mounted) return;
    setReadMarker();
  }

  final ReadMarkerSendCoordinator _readMarkerSender =
      ReadMarkerSendCoordinator();

  void setReadMarker({String? eventId, bool force = false}) {
    if (eventId?.isValidMatrixId == false) return;
    // Читатель без подписки квитанции слать не может: сервер ответит
    // M_FORBIDDEN на каждый скролл ленты. Гейт стоит здесь, а не в
    // _sendReadMarkerNow, чтобы координатор не копил заведомо мёртвые
    // намерения.
    if (room.membership != Membership.join) return;
    // Через координатор: если предыдущий запрос ещё в полёте, намерение НЕ
    // теряется — координатор запоминает самое свежее обращение и повторяет его
    // сразу по завершении текущего. Иначе квитанция на только что прочитанное
    // чужое сообщение молча отбрасывалась guard'ом, и аватарка «прочитал» у
    // собеседника появлялась лишь после нашего ответа (см.
    // ReadMarkerSendCoordinator).
    _readMarkerSender.request(
      () => _sendReadMarkerNow(eventId: eventId, force: force),
    );
  }

  /// originServerTs (millis) события, до которого отправляется read marker:
  /// конкретное [eventId], либо новейшее ОТОБРАЖАЕМОЕ. Для null берём
  /// filterByVisibleInGui (не сырое events.first) — иначе новейшая реакция/
  /// redaction/edit задрала бы оптимистичную границу выше последнего реального
  /// сообщения. null — таймлайн пуст или событие не найдено.
  int? _readMarkerTargetTs(Timeline timeline, String? eventId) {
    final target = eventId == null
        ? timeline.events.filterByVisibleInGui().firstOrNull
        : timeline.events.firstWhereOrNull((e) => e.eventId == eventId);
    return target?.originServerTs.millisecondsSinceEpoch;
  }

  /// Фактическая отправка квитанции после прохождения гейтов. Возвращает future
  /// запроса либо `null`, если гейты заблокировали отправку (координатор по
  /// `null` понимает, что ничего не «в полёте»).
  Future<void>? _sendReadMarkerNow({String? eventId, bool force = false}) {
    if (!mounted) return null;
    // Первым, до force/readableForeground/recordOwnReadMarkerTs: до конца
    // позиционирования при открытии «видимое» ещё не определено (LABA-2632).
    if (_openPositioningPending) return null;
    // `_scrolledUp` залипает в true на переходных layout-фреймах и в маленьком
    // чате не сбрасывается → сверяемся с живыми scroll-метриками: если новейшее
    // сообщение реально на экране, квитанцию НЕ глушим (иначе аватарка
    // «прочитал» у собеседника появлялась только после нашего ответа).
    //
    // Выше низа (Telegram-модель «прочитано = увидено», 2026-09-17): вместо
    // молчания деградируем в ЧАСТИЧНУЮ квитанцию на новейшее видимое событие.
    // Так все реактивные вызовы (resume, updateView, дебаунс скролла,
    // позиционирование на сепараторе) идут через одну точку, а «всё прочитано»
    // остаётся только у низа. null от геометрии (авто-скролл, тред, контекст
    // по ссылке) — по-прежнему молчим.
    if (!force && _scrolledUp && !_newestMessagesVisible) {
      // Явный eventId (requestFuture) — уже частичная квитанция, пропускаем.
      eventId ??= _newestVisibleEventId();
      if (eventId == null) return null;
    }
    if (scrollUpBannerEventId != null) return null;

    // Полная квитанция — только из окна в фокусе (`resumed`); из десктопного
    // окна без фокуса (`inactive`) — лишь частичная по явной прокрутке. Модель
    // и причины — `readableForeground` (read_marker_logic.dart). paused/hidden
    // (свёрнуто/полностью перекрыто) и lock screen блокируют всё.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final readable = readableForeground(
      lifecycle: lifecycle,
      isDesktop: PlatformInfos.isDesktop,
      screenLocked: ScreenLockState.isLocked,
    );
    if (readable == ReadableForeground.none) return null;

    final timeline = this.timeline;
    if (timeline == null || timeline.events.isEmpty) return null;

    // Оптимистично фиксируем позицию ВСЕГДА, когда смотрю низ чата в фокусе —
    // ДАЖЕ если сетевую квитанцию ниже не шлём (отмечать нечего). Иначе при
    // открытии уже-прочитанного чата моя аватарка «прочитал» залипает на моём
    // последнем сообщении вместо последнего сообщения чата (см.
    // RoomStatusExtension.recordOwnReadMarkerTs — двигает мою аватарку сразу,
    // не дожидаясь серверного эха квитанции).
    final markedTs = _readMarkerTargetTs(timeline, eventId);
    // Полная квитанция — «до последнего»: только она гасит счётчик, снимает
    // сепаратор и доставленные уведомления. Частичная (viewport) — нет:
    // остаток честно непрочитан, число придёт из следующего /sync.
    final isFull =
        eventId == null || eventId == timeline.room.lastEvent?.eventId;
    // Отложенную полную квитанцию не фиксируем и оптимистично: сепаратор и
    // счётчик должны честно держаться, пока окно не в фокусе.
    if (readMarkerGate(readable: readable, isFull: isFull) !=
        ReadMarkerGate.send) {
      return null;
    }
    if (!isFull) {
      // Частичная квитанция назад не ходит (Synapse и так игнорирует старее,
      // но зачем сеть): позиция не новее уже отмеченной — молчим.
      final floor = room.optimisticOwnReadTs;
      if (markedTs == null || (floor != null && markedTs <= floor)) return null;
    }
    if (markedTs != null) room.recordOwnReadMarkerTs(markedTs);

    // Сетевую квитанцию не шлём, если отмечать нечего (оптимизация трафика).
    // `hasUnseenMessages`, а не SDK-`hasNewMessages`: после частичной квитанции
    // тот врёт false, и полная квитанция у низа не ушла бы никогда.
    if (eventId == null &&
        !room.hasUnseenMessages &&
        room.notificationCount == 0) {
      return null;
    }

    // lifecycle в логе — замер для решения об idle-гейте (спека 2026-09-18,
    // заявка №31 круг 4): сколько квитанций уходит из `resumed` окна, у которого
    // никого нет (второй Мак).
    Logs().d(
      'Set read marker... kind=${isFull ? 'full' : 'partial'} '
      'lifecycle=${lifecycle?.name} locked=${ScreenLockState.isLocked}',
      eventId,
    );
    final future = timeline
        .setReadMarker(
          eventId: eventId,
          public: AppSettings.sendPublicReadReceipts.value,
        )
        // Зависший без ответа запрос держал бы координатор «в полёте» и не давал
        // догнать актуальную позицию — таймаут гарантированно завершает future.
        .timeout(const Duration(seconds: 30))
        .then((_) {
          if (!isFull) return;
          // Бейдж непрочитанных в СПИСКЕ чатов берётся из
          // room.notificationCount, который обновляется ТОЛЬКО ответом
          // сервера в следующем /sync. Этот round-trip может запаздывать или
          // не вернуть 0 — бейдж «залипал» с числом, хотя в чате всё
          // прочитано (баг #1). Раз квитанция на последнее событие принята
          // сервером — гасим счётчик локально сразу; следующий /sync
          // подтвердит 0 (а не перетрёт обратно, т.к. receipt доехал).
          if (room.notificationCount > 0 || room.highlightCount > 0) {
            room.notificationCount = 0;
            room.highlightCount = 0;
          }
          // Прячем сепаратор «Непрочитанное» немедленно: задержка 300 мс
          // приводила к тому, что свежие сообщения, прилетавшие за это
          // время, рендерились ниже устаревшего readMarkerEventId, и
          // сепаратор визуально оказывался над собственными сообщениями
          // (см. баг с разделителем «Непрочитанное» над своими сообщениями).
          // Дрожание scroll offset из-за изменения высоты сейчас гасится
          // гистерезисом в _updateScrollController (см. там).
          if (mounted && readMarkerEventId.isNotEmpty) {
            setState(() => readMarkerEventId = '');
          }
        })
        .catchError((e) {
          Logs().w('Failed to set read marker', e);
        });
    if (isFull) {
      Matrix.of(context).backgroundPush?.cancelNotification(roomId);
    }
    return future;
  }

  /// Сбросить typing-состояние локально, без сетевого запроса.
  void _cancelTyping() {
    typingCoolDown?.cancel();
    typingCoolDown = null;
    typingTimeout?.cancel();
    typingTimeout = null;
    currentlyTyping = false;
  }

  @override
  void dispose() {
    // Иначе отложенная на 500 мс запись черновика дёргает Matrix.of(context) на
    // уже мёртвом State (гонка «набрал текст → сразу вышел из чата»).
    _storeInputTimeoutTimer?.cancel();
    _viewportReadDebounce?.cancel();
    _cancelTyping();
    _audioAutoPlayService?.unregisterResolver(roomId);
    _receiptsSubscription?.cancel();
    _ownEchoSubscription?.cancel();
    _contentProtectionSubscription?.cancel();
    VideoPrefetchManager.instance.clearActiveRoom();
    timeline?.cancelSubscriptions();
    timeline = null;
    discussionTimeline?.cancelSubscriptions();
    discussionTimeline = null;
    // Парно к addObserver в initState: без этого каждый закрытый чат оставался
    // lifecycle-слушателем и на каждом `resumed` звал setReadMarker (спасал
    // только mounted-гард).
    WidgetsBinding.instance.removeObserver(this);
    _bubbleKeys.clear();
    inputFocus.removeListener(_inputFocusListener);
    composerPrefill.removeListener(_applyComposerPrefill);
    UpdatePolicyController.current.removeListener(_onUpdatePolicy);
    // Раньше sendController и inputFocus не диспоузились — утечка усиливается с
    // FormattingTextEditingController (слушатели/спаны). INV-7 спеки формата.
    sendController.dispose();
    inputFocus.dispose();
    super.dispose();
  }

  /// Предзаполнить композер по запросу карточки (кнопка «Изменить» поддержки),
  /// если запрос адресован ТЕКУЩЕЙ комнате. Ставит текст, курсор в конец, фокус.
  void _applyComposerPrefill() {
    final req = composerPrefill.value;
    if (req == null || req.roomId != roomId) return;
    sendController.text = req.text;
    sendController.selection = TextSelection.collapsed(offset: req.text.length);
    inputFocus.requestFocus();
    composerPrefill.value = null;
  }

  FormattingTextEditingController sendController =
      FormattingTextEditingController();

  void setSendingClient(Client c) {
    // first cancel typing with the old sending client
    if (currentlyTyping) {
      // no need to have the setting typing to false be blocking
      typingCoolDown?.cancel();
      typingCoolDown = null;
      // Typing — fire-and-forget; сетевые ошибки (errno 9/60 после
      // фона) не должны всплывать как unhandled.
      room.setTyping(false).catchError((_) {});
      currentlyTyping = false;
    }
    // then cancel the old timeline
    // fixes bug with read reciepts and quick switching
    loadTimelineFuture = _getTimeline(eventContextId: room.fullyRead).onError(
      ErrorReporter(
        context,
        'Unable to load timeline after changing sending Client',
      ).onErrorCallback,
    );

    // then set the new sending client
    setState(() => sendingClient = c);
  }

  void setActiveClient(Client c) => setState(() {
    Matrix.of(context).setActiveClient(c);
  });

  /// Команды ботов-ассистентов (Лиза «мои приложения» и BotFather: боты, mini
  /// App, конструктор). Не Matrix-команды SDK — их надо слать боту как ТЕКСТ
  /// (`parseCommands:false`), а не резать диалогом «Недопустимая команда».
  /// Имена в нижнем регистре; дефис допустим (`miniapp-constraction`).
  @visibleForTesting
  static const botComposerCommands = {
    'myapps',
    'newapp',
    'createminiapp',
    'miniapp-constraction',
    'miniapp-construction',
    'newbot',
    'mybots',
    'deletebot',
    'cancel',
    'start',
    'menu',
  };

  /// True, если `name` (без ведущего `/`) — команда бота-ассистента из
  /// [botComposerCommands]. Регистронезависимо.
  @visibleForTesting
  static bool isBotComposerCommand(String name) =>
      botComposerCommands.contains(name.toLowerCase());

  /// Паттерн извлечения имени `/`-команды из ввода. `[\w-]+` (НЕ `\w+`), чтобы
  /// захватить дефис (`/miniapp-constraction`) — иначе имя обрезалось до
  /// `miniapp` и команда не находилась в [botComposerCommands].
  @visibleForTesting
  static final composerCommandPattern = RegExp(r'^\/([\w-]+)');

  /// Режим чтения обязательного обновления (howItWoks/lizaUpdates.md): всё,
  /// что пользователь пишет в комнату, отбивается здесь одной проверкой.
  /// Квитанции, typing и обмен ключами E2EE не трогаем — это не отправка.
  bool _blockedByUpdate() => blockedByUpdateReadOnly(context);

  bool _updateReadOnly = UpdatePolicyController.readOnly;

  /// Ответ сервера приходит на каждый resume — перестраиваем чат только когда
  /// режим чтения реально включился или снялся.
  void _onUpdatePolicy() {
    final readOnly = UpdatePolicyController.readOnly;
    if (!mounted || readOnly == _updateReadOnly) return;
    setState(() => _updateReadOnly = readOnly);
  }

  Future<void> send() async {
    if (_blockedByUpdate()) return;
    if (sendController.text.trim().isEmpty) return;
    _storeInputTimeoutTimer?.cancel();
    final prefs = Matrix.of(context).store;
    prefs.remove('draft_$roomId');
    prefs.remove('draftfmt_$roomId');
    _replyDraftStore.clear(roomId);
    // Ведущий пробел — способ отправить «/слово» текстом: команду SDK распознаёт
    // по `startsWith('/')`, и без этого обрезка ниже превратила бы «  /leave» в
    // исполняемую команду (LABA-2623).
    final rawText = sendController.text;
    final startsWithWhitespace = rawText.trimLeft().length != rawText.length;
    var parseCommands = !startsWithWhitespace;

    final commandMatch = composerCommandPattern.firstMatch(rawText);
    if (commandMatch != null &&
        !sendingClient.commands.keys.contains(commandMatch[1]!.toLowerCase())) {
      if (isBotComposerCommand(commandMatch[1]!)) {
        // Команда бота-ассистента (Лиза «мои приложения» / BotFather: боты, mini
        // App, конструктор) — не Matrix-команда, а текст для бота. Шлём как есть.
        parseCommands = false;
      } else {
        final l10n = L10n.of(context);
        final dialogResult = await showOkCancelAlertDialog(
          context: context,
          title: l10n.commandInvalid,
          message: l10n.commandMissing(commandMatch[0]!),
          okLabel: l10n.sendAsText,
          cancelLabel: l10n.cancel,
        );
        if (dialogResult == OkCancelResult.cancel) return;
        parseCommands = false;
      }
    }

    final outgoing = trimOutgoing(rawText, sendController.spans);

    // ignore: unawaited_futures
    if (editEvent != null &&
        editEvent!.getDisplayEvent(timeline!).isMediaEvent) {
      final displayEvent = editEvent!.getDisplayEvent(timeline!);
      final newBody = outgoing.text;
      final content = <String, dynamic>{
        ...displayEvent.content,
        'body': newBody,
      };
      // Remove old formatted_body if present, let the plain text be the body
      content.remove('formatted_body');
      content.remove('format');
      // Remove any previous m.relates_to as sendEvent will add the edit relation
      content.remove('m.relates_to');
      room.sendEvent(
        content,
        editEventId: editEvent?.eventId,
        threadRootEventId: activeThreadId,
      );
    } else {
      // Дорезолвим набранные руками `@Имя` в пилюли `@[Полное имя]`, чтобы SDK
      // положил адресата в m.mentions и у него подсветился чат красным (тег), а
      // не синим. Команды (`/...`) не трогаем — там @токен обрабатывает хэндлер.
      final controller = sendController;
      final text = outgoing.text;
      final isCommand = !startsWithWhitespace && text.startsWith('/');
      final resolvedText = isCommand
          ? text
          : TypedMentionResolver.resolveForRoom(text, room);

      // Явное форматирование (кандидат A брейншторма 2026-08-28): пользователь
      // применил формат к выделению → шлём formatted_body (HTML из спанов)
      // напрямую через sendEvent, сохраняя m.mentions вручную (INV-2).
      // parseMarkdown НЕ трогаем — набранные вручную `* _ ~` остаются буквальными.
      // formatted_body строим из обрезанного text (спаны пересчитаны под него
      // в trimOutgoing), а body — из resolvedText (пилюли упоминаний + текст).
      final formattedHtml = (!isCommand && controller.hasFormatting)
          ? spansToFormattedHtml(text, outgoing.spans)
          : null;

      if (formattedHtml != null) {
        final content = <String, dynamic>{
          'msgtype': MessageTypes.Text,
          'body': resolvedText,
          'format': 'org.matrix.custom.html',
          'formatted_body': formattedHtml,
        };
        final mentions = TypedMentionResolver.buildMentions(
          resolvedText,
          room,
          inReplyTo: replyEvent,
        );
        if (mentions != null) content['m.mentions'] = mentions;
        // ignore: unawaited_futures
        room.sendEvent(
          content,
          inReplyTo: replyEvent,
          editEventId: editEvent?.eventId,
          threadRootEventId: activeThreadId,
        );
      } else {
        room.sendTextEvent(
          resolvedText,
          inReplyTo: replyEvent,
          editEventId: editEvent?.eventId,
          parseCommands: parseCommands,
          parseMarkdown: false,
          threadRootEventId: activeThreadId,
        );
      }
    }
    sendController.value = TextEditingValue(
      text: pendingText,
      selection: const TextSelection.collapsed(offset: 0),
    );
    // Явное форматирование — одноразовое: после отправки сбрасываем спаны, чтобы
    // следующее сообщение начиналось без форматирования.
    sendController.clearFormatting();

    // Отправил сообщение → продвигаем сепаратор «Непрочитанное» за своё
    // сообщение (п.2.3). Если выше остались реально непрочитанные ЧУЖИЕ,
    // сепаратор встаёт над первым из них; иначе снимается.
    _advanceReadMarkerPastMine();

    setState(() {
      sendController.text = pendingText;
      // Отложенный на время правки черновик возвращается СО СВОИМ форматом
      // (после обычной отправки список пуст — это и есть сброс). Порядок
      // «текст → спаны» обязателен, см. `setSpans`.
      sendController.setSpans(pendingSpans, pendingText.length);
      _inputTextIsEmpty = pendingText.isEmpty;
      replyEvent = null;
      editEvent = null;
      messageLinkPreview = null;
      _dismissedLinkPreview = null;
      pendingText = '';
      pendingSpans = const [];
    });
  }

  /// Публикация истории от имени канала — только admin/moderator (PL>=100).
  Future<void> addChannelStory() async {
    if (_blockedByUpdate()) return;
    final composer = await pickStoryMediaComposer(context, channelId: room.id);
    if (composer == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => composer));
  }

  void sendFileAction({FileType type = FileType.any}) async {
    if (_blockedByUpdate()) return;
    final files = await selectFiles(context, allowMultiple: true, type: type);
    if (files.isEmpty) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        // Пункты «Фото»/«Видео» — сжатие по умолчанию (Liza/WhatsApp).
        // Пункт «Файл» (FileType.any) — без сжатия, документом-карточкой.
        compress: type != FileType.any,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  /// «Отправить файл»: на мобильных предлагает выбор источника — файловый
  /// менеджер устройства или системная галерея (как вложение в
  /// Liza/WhatsApp). На desktop/Web галереи нет — сразу открывается
  /// выбор файла.
  void sendFileSourceAction() async {
    if (_blockedByUpdate()) return;
    if (!PlatformInfos.isMobile) {
      sendFileAction();
      return;
    }
    final source = await showModalActionPopup<_FileSource>(
      context: context,
      title: L10n.of(context).sendFile,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: _FileSource.files,
          label: L10n.of(context).chooseFromFiles,
          isDefaultAction: true,
          icon: const Icon(Icons.attachment_outlined),
        ),
        AdaptiveModalAction(
          value: _FileSource.gallery,
          label: L10n.of(context).choosePhotoOrVideo,
          icon: const Icon(Icons.photo_library_outlined),
        ),
      ],
    );
    switch (source) {
      case null:
        return;
      case _FileSource.files:
        sendFileAction();
        return;
      case _FileSource.gallery:
        final files = await selectGalleryMedia(context);
        if (files.isEmpty) return;
        await showAdaptiveDialog(
          context: context,
          builder: (c) => SendFileDialog(
            files: files,
            room: room,
            // Этот выбор — внутри «Отправить файл», поэтому фото/видео из
            // галереи уходят оригиналом (m.file) без сжатия. Сжатые фото —
            // отдельный пункт меню вложений «Изображение» (sendFileAction).
            compress: false,
            outerContext: context,
            threadRootEventId: activeThreadId,
            threadLastEventId: threadLastEventId,
          ),
        );
        return;
    }
  }

  /// Handles Cmd+V / Ctrl+V: tries to paste files or images from clipboard,
  /// falls back to standard text paste if nothing found.
  Future<void> _handleClipboardPaste() async {
    final handled = await handleImagePaste();
    if (!handled) {
      // No file or image in clipboard — perform standard text paste
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        final text = data!.text!;
        final selection = sendController.selection;
        final newText = sendController.text.replaceRange(
          selection.start.clamp(0, sendController.text.length),
          selection.end.clamp(0, sendController.text.length),
          text,
        );
        final newOffset =
            selection.start.clamp(0, sendController.text.length) + text.length;
        sendController.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
        );
        onInputBarChanged(sendController.text);
      }
    }
  }

  /// Returns true if clipboard contained files or images and was handled.
  ///
  /// Логика отбора вынесена в чистую [collectPasteXFiles] (тестируется без
  /// нативного буфера). Контракт «первый непустой источник побеждает»: URL-текст
  /// → файлы → несколько растров → одиночный растр. Несколько файлов И несколько
  /// растров из одного буфера уходят одним альбомом через `SendFileDialog`.
  Future<bool> handleImagePaste() async {
    if (_blockedByUpdate()) return true;
    try {
      final result = await collectPasteXFiles(const SystemPasteboardReader());
      if (!result.handledAsMedia || result.files.isEmpty) return false;
      // Буфер прочитан после await — виджет мог быть размонтирован. Медиа мы
      // распознали, поэтому возвращаем true (текстовую вставку НЕ делаем), но
      // диалог на мёртвом контексте не открываем.
      if (!mounted) return true;
      await showAdaptiveDialog(
        context: context,
        builder: (c) => SendFileDialog(
          files: result.files,
          room: room,
          outerContext: context,
          threadRootEventId: activeThreadId,
          threadLastEventId: threadLastEventId,
        ),
      );
      return true;
    } catch (e, s) {
      Logs().w('Failed to read clipboard', e, s);
    }
    return false;
  }

  void openGalleryAction() async {
    if (_blockedByUpdate()) return;
    // «Выбрать фото или видео» — и на mobile, и на desktop. Раньше desktop
    // уходил в `sendFileAction(type: FileType.image)` → выбор ТОЛЬКО фото,
    // видео в пикере было серым. Теперь оба через selectGalleryMedia
    // (mobile — системный медиа-пикер; desktop — FilePicker без фильтра, см.
    // file_selector.dart). compress:true — фото жмутся как в Liza; видео
    // на desktop не перекодируется, но при отправке получает faststart.
    final files = await selectGalleryMedia(context);
    if (files.isEmpty) return;
    if (!mounted) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: files,
        room: room,
        compress: true,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  void openCameraAction() async {
    if (_blockedByUpdate()) return;
    // Make sure the textfield is unfocused before opening the camera
    FocusScope.of(context).requestFocus(FocusNode());
    final mode = await showModalActionPopup<_CameraMode>(
      context: context,
      title: L10n.of(context).camera,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: _CameraMode.photo,
          label: L10n.of(context).takeAPhoto,
          isDefaultAction: true,
          icon: const Icon(Icons.camera_alt_outlined),
        ),
        AdaptiveModalAction(
          value: _CameraMode.video,
          label: L10n.of(context).recordAVideo,
          icon: const Icon(Icons.videocam_outlined),
        ),
      ],
    );
    if (mode == null) return;

    final XFile? file;
    switch (mode) {
      case _CameraMode.photo:
        file = await ImagePicker().pickImage(source: ImageSource.camera);
      case _CameraMode.video:
        file = await ImagePicker().pickVideo(
          source: ImageSource.camera,
          maxDuration: const Duration(minutes: 1),
        );
    }
    if (file == null) return;

    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendFileDialog(
        files: [file!],
        room: room,
        compress: true,
        outerContext: context,
        threadRootEventId: activeThreadId,
        threadLastEventId: threadLastEventId,
      ),
    );
  }

  Future<void> onVoiceMessageSend(
    String path,
    int duration,
    List<int> waveform,
    String? fileName,
  ) async {
    if (_blockedByUpdate()) return;
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final audioFile = XFile(path);

    final bytesResult = await showFutureLoadingDialog(
      context: context,
      future: audioFile.readAsBytes,
    );
    final bytes = bytesResult.result;
    if (bytes == null) return;

    final name = fileName ?? audioFile.path;
    final file = MatrixAudioFile(
      bytes: bytes,
      name: name,
      mimeType: voiceMimeForFileName(
        name,
        isWeb: PlatformInfos.isWeb,
        isWindows: PlatformInfos.isWindows,
      ),
    );

    // Захватываем reply ДО обнуления — иначе inReplyTo уходил null и голосовое
    // сообщение отправлялось без цитаты.
    final voiceReplyEvent = replyEvent;
    setState(() {
      replyEvent = null;
    });
    _persistReplyDraft();
    // Генерируем txid сами, чтобы при сетевом сбое вернуть плейсхолдер файла
    // в SDK. sendFileEvent (matrix/room.dart) удаляет sendingFilePlaceholders[txid]
    // ДАЖЕ когда отправка провалилась (sendEvent вернул null по таймауту), после
    // чего «отправить повторно» не находит файл, вызывает cancelSend и сообщение
    // ПРОПАДАЕТ вместо повторной отправки (LABA-2239). Возвращаем плейсхолдер —
    // и повторная отправка в той же сессии снова находит байты голосового.
    final txid = room.client.generateUniqueTransactionId();
    room
        .sendFileEvent(
          file,
          txid: txid,
          inReplyTo: voiceReplyEvent,
          threadRootEventId: activeThreadId,
          extraContent: {
            'info': {...file.info, 'duration': duration},
            'org.matrix.msc3245.voice': {},
            'org.matrix.msc1767.audio': {
              'duration': duration,
              'waveform': waveform,
            },
          },
        )
        .then((eventId) {
          if (eventId == null) {
            room.sendingFilePlaceholders[txid] = file;
          }
        })
        .catchError((e) {
          // Всегда возвращаем плейсхолдер (для повтора), даже если чат уже закрыт.
          room.sendingFilePlaceholders[txid] = file;
          final err = e as Object;
          // Класс ошибки нужен авто-ретраю (FailedSendRetryService) — пишем
          // ВСЕГДА, даже если чат закрыт: classifyUploadError чист, context не
          // нужен. Без этой записи голосовое Алексея (сетевой сбой) не
          // классифицировалось бы, а терминальное (413/диск) переретраилось бы.
          UploadProgressTracker.instance.reportErrorKind(
            txid,
            classifyUploadError(err),
          );
          // Коллбэк асинхронный — к этому моменту пользователь мог уйти из чата;
          // toLocalizedString берёт живой context (L10n.of), поэтому под mounted.
          if (!mounted) return;
          // Причина для тултипа пузыря + снекбар — под mounted (нужен context).
          final reason = err.toLocalizedString(context);
          UploadProgressTracker.instance.reportError(txid, reason);
          scaffoldMessenger.showSnackBar(SnackBar(content: Text(reason)));
        });
    return;
  }

  void hideEmojiPicker() {
    setState(() => showEmojiPicker = false);
  }

  void emojiPickerAction() {
    if (showEmojiPicker) {
      inputFocus.requestFocus();
    } else {
      inputFocus.unfocus();
    }
    setState(() => showEmojiPicker = !showEmojiPicker);
  }

  void _inputFocusListener() {
    if (inputFocus.hasFocus) {
      ContextMenuController.removeAny();
      if (showEmojiPicker) {
        setState(() => showEmojiPicker = false);
      }
    }
  }

  void sendLocationAction() async {
    if (_blockedByUpdate()) return;
    await showAdaptiveDialog(
      context: context,
      builder: (c) => SendLocationDialog(room: room),
    );
  }

  String _getSelectedEventString() {
    final matrixLocals = MatrixLocals(L10n.of(context));
    var copyString = '';
    if (selectedEvents.length == 1) {
      return copyTextForEvent(
        selectedEvents.first.getDisplayEvent(timeline!),
        matrixLocals,
      );
    }
    for (final event in selectedEvents) {
      if (copyString.isNotEmpty) copyString += '\n\n';
      copyString += copyTextForEvent(
        event.getDisplayEvent(timeline!),
        matrixLocals,
        withSenderNamePrefix: true,
      );
    }
    return copyString;
  }

  /// Есть ли среди выбранных хоть одно событие с осмысленным текстом.
  ///
  /// Тот же критерий, что и у одиночного пункта «Копировать текст» в
  /// `message_context_menu.dart`: на медиа без подписи копировалась бы
  /// generic-заглушка («Отправил картинку»), а не содержимое.
  bool get canCopySelectedEvents => selectedEvents.any((event) {
    // Гейт считаем на DISPLAY-событии — как и само копирование
    // (`_getSelectedEventString`/`copyEvent`), иначе у отредактированной подписи
    // гейт и действие смотрели бы на разные версии `body`.
    final display = event.getDisplayEvent(timeline!);
    return shouldOfferCopyText(
      isMedia: display.isMediaEvent,
      hasCaption: display.fileDescription != null,
    );
  });

  void copyEventsAction() {
    // Гейт в самом методе, а не только на кнопке: новая точка вызова
    // (горячая клавиша, меню, другой экран) иначе снова обошла бы запрет.
    if (room.isContentProtected) return;
    unawaited(
      Clipboard.setData(ClipboardData(text: _getSelectedEventString())),
    );
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  // Пункт «Скопировать ссылку на сообщение» ВРЕМЕННО СКРЫТ (2026-07-21, по
  // просьбе): пока обсуждается UX ссылок на сообщение (LABA-2217). Гейт для
  // обоих меню (контекстное + режим выделения). Вернуть — восстановить условие
  // `!room.isDirectChat && event.status.isSent`.
  bool canCopyMessageLink(Event event) => false;

  void copyMessageLink(Event event) {
    final link = MessageLink(roomId: room.id, eventId: event.eventId);
    Clipboard.setData(
      ClipboardData(text: link.url(via: room.client.userID?.domain)),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(L10n.of(context).messageLinkCopied)));
  }

  void copyMessageLinkAction() {
    copyMessageLink(selectedEvents.single);
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  void reportEventAction() async {
    if (!await reportEvent(selectedEvents.single)) return;
    if (!mounted) return;
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  void deleteErrorEventsAction() async {
    try {
      if (selectedEvents.any((event) => event.status != EventStatus.error)) {
        throw Exception(
          'Tried to delete failed to send events but one event is not failed to sent',
        );
      }
      for (final event in selectedEvents) {
        await cancelPendingSend(event);
      }
      setState(selectedEvents.clear);
    } catch (e, s) {
      ErrorReporter(
        context,
        'Error while delete error events action',
      ).onErrorCallback(e, s);
    }
  }

  void redactEventsAction() async {
    if (_blockedByUpdate()) return;
    // Сбрасываем выделение только если удаление реально прошло — отмена диалога
    // причины должна СОХРАНИТЬ мультивыбор (как было до рефактора).
    if (!await _redactEvents(selectedEvents)) return;
    if (!mounted) return;
    setState(() {
      showEmojiPicker = false;
      selectedEvents.clear();
    });
  }

  /// Возвращает `true`, если удаление выполнено; `false` — если отменено (или
  /// контроллер размонтирован).
  Future<bool> _redactEvents(List<Event> events) async {
    if (!mounted) return false;
    // Все удаляемые события — медиа (видео/аудио/изображение/файл/стикер)?
    // Тогда заголовок/описание про «контент», а не про «сообщение» (см. l10n).
    final allMedia =
        events.isNotEmpty && events.every((event) => event.isMediaEvent);
    final reasonInput = events.any((event) => event.status.isSent)
        ? await showTextInputDialog(
            context: context,
            title: allMedia
                ? L10n.of(context).redactContent
                : L10n.of(context).redactMessage,
            message: allMedia
                ? L10n.of(context).redactContentDescription
                : L10n.of(context).redactMessageDescription,
            isDestructive: true,
            hintText: L10n.of(context).optionalRedactReason,
            maxLength: 255,
            maxLines: 3,
            minLines: 1,
            okLabel: L10n.of(context).remove,
            cancelLabel: L10n.of(context).cancel,
          )
        : null;
    if (reasonInput == null) return false;
    final reason = normalizeRedactionReason(reasonInput);
    await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) async {
        final count = events.length;
        for (final (i, event) in events.indexed) {
          onProgress(i / count);
          // Рубеж на самом действии (кнопка уже скрыта canRedactEvent): в канале
          // НЕ применяем bundle-fallback ниже (удаление чужого поста от имени
          // аккаунта-автора из бандла) — удалять посты канала может только
          // реальное redact-право. [[RL-channel-no-delete-others-post-nonmod]]
          if (room.isChannel && !event.canRedact) continue;
          if (event.status.isSent) {
            if (event.canRedact) {
              await event.redactEvent(reason: reason);
            } else {
              final client = currentRoomBundle.firstWhere(
                (cl) => event.senderId == cl!.userID,
                orElse: () => null,
              );
              if (client == null) {
                return;
              }
              final room = client.getRoomById(roomId)!;
              await Event.fromJson(
                event.toJson(),
                room,
              ).redactEvent(reason: reason);
            }
          } else {
            await cancelPendingSend(event);
          }
        }
      },
    );
    return true;
  }

  List<Client?> get currentRoomBundle {
    // Без `!`: геттер бандла возвращает список всегда, а элемент списка типизован
    // как `Client?` — `c!` падал бы на первом же null. Оба падения видел прод
    // (GlitchTip 1918: красный экран при построении меню сообщения).
    final clients = List<Client?>.from(Matrix.of(context).currentBundle);
    clients.removeWhere((c) => c?.getRoomById(roomId) == null);
    return clients;
  }

  bool get canRedactSelectedEvents {
    if (isArchived) return false;
    // Единый предикат с одиночным меню: `canRedactEvent` уже несёт гейт канала
    // (только реальное redact-право) и room-filtered bundle-грант для чатов.
    return selectedEvents.every(canRedactEvent);
  }

  bool get canPinSelectedEvents {
    if (isArchived ||
        !room.canChangeStateEvent(EventTypes.RoomPinnedEvents) ||
        selectedEvents.length != 1 ||
        !selectedEvents.single.status.isSent ||
        activeThreadId != null) {
      return false;
    }
    return true;
  }

  bool get canEditSelectedEvents {
    if (isArchived ||
        selectedEvents.length != 1 ||
        !selectedEvents.first.status.isSent) {
      return false;
    }
    return currentRoomBundle.any(
      (cl) => selectedEvents.first.senderId == cl!.userID,
    );
  }

  void forwardEventsAction() async {
    // Гейт в самом методе, а не только на кнопке (см. copyEventsAction).
    if (room.isContentProtected) return;
    if (_blockedByUpdate()) return;
    if (selectedEvents.isEmpty) return;
    final timeline = this.timeline;
    if (timeline == null) return;

    // Помечаем каждое пересланное как forwarded (LABA-1991) той же трубой, что и
    // одиночная пересылка. Галерейные события разворачиваются в ВЕСЬ альбом с
    // новым id/reindex/n=факт (иначе получатель ловит вечные фантом-спиннеры).
    final contents = await buildForwardedContentsForEvents(
      room.client,
      timeline,
      List<Event>.from(selectedEvents),
    );
    if (!mounted) return; // fetchSenderUser — сетевой await, виджет мог уйти
    final items = contents.map(ContentShareItem.new).toList();

    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(items: items),
    );
    if (!mounted) return;
    setState(() => selectedEvents.clear());
  }

  /// Для медиа `Event.sendAgain()` берёт байты из in-memory
  /// `room.sendingFilePlaceholders[txid]`. Если его нет (перезапуск приложения
  /// очистил память), `sendAgain` вызывает `cancelSend` и УДАЛЯЕТ сообщение
  /// вместо повторной отправки (LABA-2239). Общий страж для ВСЕХ точек «отправить
  /// повторно» (панель выделения и контекстное меню): показывает тост и
  /// возвращает true — вызвавший НЕ должен звать `sendAgain`, а оставить событие
  /// в ошибке.
  bool _warnIfUnresendableMissingMedia(Event event) {
    if (!event.isUnresendableMissingMedia) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).fileNoLongerAvailableToResend)),
    );
    return true;
  }

  void sendAgainAction() {
    if (_blockedByUpdate()) return;
    final event = selectedEvents.first;
    if (event.status.isError) {
      if (_warnIfUnresendableMissingMedia(event)) {
        setState(() => selectedEvents.clear());
        return;
      }
      // Общая точка повтора: сброс устаревшего класса ошибки (D-3),
      // анти-дабл-тап и владение серии отправки альбома.
      FailedMediaResender.resend(event);
    }
    final allEditEvents = event
        .aggregatedEvents(timeline!, RelationshipTypes.edit)
        .where((e) => e.status.isError);
    for (final e in allEditEvents) {
      e.sendAgain();
    }
    setState(() => selectedEvents.clear());
  }

  void replyAction({Event? replyTo}) {
    if (_blockedByUpdate()) return;
    setState(() {
      replyEvent = replyTo ?? selectedEvents.first;
      selectedEvents.clear();
    });
    _persistReplyDraft();
    inputFocus.requestFocus();
  }

  static const int _maxScrollToEventRetries = 2;

  Future<void> scrollToEventId(
    String eventId, {
    bool highlightEvent = true,
    int retryDepth = 0,
  }) async {
    final foundEvent = timeline!.events.firstWhereOrNull(
      (event) => event.eventId == eventId,
    );

    final eventIndex = foundEvent == null
        ? -1
        : timeline!.events
              .filterByVisibleInGui(
                exceptionEventId: eventId,
                threadId: activeThreadId,
              )
              .indexOf(foundEvent);

    if (eventIndex == -1) {
      if (retryDepth >= _maxScrollToEventRetries) {
        Logs().w(
          'scrollToEventId: событие $eventId не найдено после '
          '$retryDepth перезагрузок timeline, прекращаю попытки',
        );
        return;
      }
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline(eventContextId: eventId).onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll to ID',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
      // Повтор — после кадра с новым таймлайном; ждём его, чтобы вызывающий
      // (позиционирование на сепараторе) увидел конец всей цепочки.
      final retried = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
        retried.complete(
          scrollToEventId(
            eventId,
            highlightEvent: highlightEvent,
            retryDepth: retryDepth + 1,
          ),
        );
      });
      return retried.future;
    }
    if (highlightEvent) {
      setState(() {
        scrollToEventIdMarker = eventId;
      });
    }
    await scrollController.scrollToIndex(
      eventIndex + 1,
      duration: LizaThemes.animationDuration,
      preferPosition: AutoScrollPosition.middle,
    );
    _updateScrollController();
  }

  void scrollDown() async {
    // `timeline == null` — лента грузится/перезагружается (сюда доходит
    // post-frame прыжок из updateView, если между microtask и кадром
    // scrollToEventId обнулил таймлайн). Перезагружать нечего — только прыжок.
    if (timeline?.allowNewEvent == false) {
      setState(() {
        timeline = null;
        _scrolledUp = false;
        loadTimelineFuture = _getTimeline().onError(
          ErrorReporter(
            context,
            'Unable to load timeline after scroll down',
          ).onErrorCallback,
        );
      });
      await loadTimelineFuture;
    }
    // Лента живёт в FutureBuilder: echo/шаринг могут прилететь до её монтирования.
    if (!scrollController.hasClients) return;
    scrollController.jumpTo(0);
  }

  void onEmojiSelected(dynamic _, Emoji? emoji) {
    typeEmoji(emoji);
    onInputBarChanged(sendController.text);
  }

  void typeEmoji(Emoji? emoji) {
    if (emoji == null) return;
    sendController.value = insertEmojiIntoText(
      sendController.text,
      sendController.selection,
      emoji.emoji,
    );
  }

  /// Вставка эмодзи в текст композера с нормализацией каретки.
  ///
  /// Вынесено публичной статикой ради стража
  /// `ledger:RL-composer-emoji-picker-toggle` (AC-3): нефокусированный/свежий
  /// `TextEditingController` имеет `selection.collapsed(offset:-1)`
  /// (`start==end==baseOffset==-1`). Наивный `replaceRange(-1,-1)` на непустом
  /// тексте бросил бы `RangeError`, а `baseOffset+len` поставил бы курсор ВНУТРЬ
  /// вставленного эмодзи. Кнопка эмодзи на ПК/веб открывает пикер на поле, где
  /// каретки может не быть (autofocus без клика, восстановленный reply-черновик),
  /// поэтому нормализуем: нет валидной каретки — вставляем в конец текста.
  static TextEditingValue insertEmojiIntoText(
    String text,
    TextSelection selection,
    String emoji,
  ) {
    final hasCaret = selection.start >= 0 && selection.end >= 0;
    final start = hasCaret ? selection.start : text.length;
    final end = hasCaret ? selection.end : text.length;
    final newText = text.isEmpty ? emoji : text.replaceRange(start, end, emoji);
    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(
        // UTF-8 combined emoji может иметь length > 1 — курсор ставим ЗА него.
        offset: start + emoji.length,
      ),
    );
  }

  void emojiPickerBackspace() {
    sendController
      ..text = sendController.text.characters.skipLast(1).toString()
      ..selection = TextSelection.fromPosition(
        TextPosition(offset: sendController.text.length),
      );
  }

  void clearSelectedEvents() => setState(() {
    selectedEvents.clear();
    showEmojiPicker = false;
  });

  void clearSingleSelectedEvent() {
    if (selectedEvents.length <= 1) {
      clearSelectedEvents();
    }
  }

  void editSelectedEventAction() {
    if (_blockedByUpdate()) return;
    editEventAction(selectedEvents.first);
    setState(() => selectedEvents.clear());
  }

  void editEventAction(Event event) {
    if (_blockedByUpdate()) return;
    final client = currentRoomBundle.firstWhere(
      (cl) => event.senderId == cl!.userID,
      orElse: () => null,
    );
    if (client == null) {
      return;
    }
    setSendingClient(client);
    setState(() {
      pendingText = sendController.text;
      pendingSpans = sendController.spans;
      editEvent = event;
      // INV-E12: только getDisplayEvent — он подменяет content на m.new_content,
      // где SDK-префикса «* » ещё нет (иначе повторная правка тянула бы его в
      // поле и сдвигала все спаны на два символа).
      final displayEvent = event.getDisplayEvent(timeline!);
      final editBody = displayEvent.fileEditBody;
      final isMedia = displayEvent.isMediaEvent;
      final plainFallback =
          editBody ??
          (isMedia
              ? ''
              : displayEvent.calcLocalizedBodyFallback(
                  MatrixLocals(L10n.of(context)),
                  withSenderNamePrefix: false,
                  hideReply: true,
                ));
      // Восстанавливаем явное форматирование правки (снятие INV-11): текст и
      // спаны разбираются из formatted_body одним проходом, но принимаются лишь
      // при посимвольном совпадении с плоским телом — иначе всё как раньше.
      final prefill = resolveEditPrefill(
        plainFallback: plainFallback,
        format: displayEvent.content['format'] as String?,
        formattedBody: displayEvent.content['formatted_body'] as String?,
        isMedia: isMedia,
      );
      sendController.text = prefill.text;
      // Порядок обязателен: `set value` диффует старые спаны на новый текст,
      // поэтому спаны (в т.ч. ПУСТЫЕ — сброс) ставим строго после текста.
      sendController.setSpans(prefill.spans, prefill.text.length);
    });
    inputFocus.requestFocus();
  }

  // === Контекстное меню в стиле Liza: действия над ОДНИМ сообщением ===
  //
  // Long-press (mobile) / правый клик (desktop) открывает единый заякоренный
  // поповер (`message_context_menu.dart`) с рядом реакций сверху и вертикальным
  // списком действий. Ядро каждого действия — функция от [Event]; поповер НЕ
  // пишет в [selectedEvents] (иначе мерцает select-mode chrome). Мультивыбор
  // (нижняя панель + перекраска AppBar) остаётся, но входится только пунктом
  // «Выбрать» → [onSelectMessage].

  // Стабильные ключи RepaintBoundary пузырей — чтобы синхронно снять снимок
  // пузыря для «вылетающей» анимации поповера.
  final Map<String, GlobalKey> _bubbleKeys = {};

  GlobalKey bubbleKeyOf(String eventId) =>
      _bubbleKeys.putIfAbsent(eventId, GlobalKey.new);

  void onMessageContextMenu(Event event) {
    if (event.redacted) return;
    final timeline = this.timeline;
    if (timeline == null) return;
    final renderObject = bubbleKeyOf(
      event.eventId,
    ).currentContext?.findRenderObject();
    // size.isEmpty — пузырь ещё без layout в этом кадре: снимок 0×0 дал бы
    // деление 0/0 в раскладке поповера.
    if (renderObject is! RenderRepaintBoundary || renderObject.size.isEmpty) {
      return;
    }
    final snapshot = renderObject.toImageSync(
      pixelRatio: MediaQuery.devicePixelRatioOf(context),
    );
    final bubbleRect =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    showMessageContextMenu(
      controller: this,
      event: event,
      timeline: timeline,
      snapshot: snapshot,
      bubbleRect: bubbleRect,
      ownMessage: event.senderId == room.client.userID,
    );
  }

  bool canEditEvent(Event event) =>
      !isArchived &&
      event.status.isSent &&
      currentRoomBundle.any((cl) => event.senderId == cl?.userID);

  bool canRedactEvent(Event event) {
    if (isArchived || !event.status.isSent) return false;
    // В канале удалять пост может только тот, у кого реальное право: свой
    // активный аккаунт (SDK `event.canRedact`) либо redact-PL модератора. Здесь
    // НЕ добираем bundle-грант «пост отправлен другим аккаунтом моего бандла»:
    // у мультиаккаунт-бандла, владеющего админ-аккаунтом канала, `_redactEvents`
    // дослал бы редакцию ОТ ИМЕНИ админа → «обычный» аккаунт реально удалял бы
    // пост. Реальному отдельному подписчику (PL=0) сервер и так отвечает 403.
    // В обычных чатах bundle-грант (удалить своё сообщение с другого аккаунта)
    // сохраняем. [[RL-channel-no-delete-others-post-nonmod]]
    if (room.isChannel) return event.canRedact;
    return event.canRedact ||
        currentRoomBundle.any((cl) => event.senderId == cl?.userID);
  }

  bool canPinEvent(Event event) =>
      !isArchived &&
      room.canChangeStateEvent(EventTypes.RoomPinnedEvents) &&
      event.status.isSent &&
      activeThreadId == null;

  bool canSaveEvent(Event event) => {
    MessageTypes.Video,
    MessageTypes.Image,
    MessageTypes.Sticker,
    MessageTypes.Audio,
    MessageTypes.File,
  }.contains(event.messageType);

  void replyToEvent(Event event) {
    if (_blockedByUpdate()) return;
    setState(() => replyEvent = event);
    _persistReplyDraft();
    inputFocus.requestFocus();
  }

  void copyEvent(Event event) {
    // Гейт в самом методе, а не только на пункте меню (см. copyEventsAction).
    if (room.isContentProtected) return;
    final timeline = this.timeline;
    if (timeline == null) return;
    unawaited(
      Clipboard.setData(
        ClipboardData(
          text: copyTextForEvent(
            event.getDisplayEvent(timeline),
            MatrixLocals(L10n.of(context)),
          ),
        ),
      ),
    );
  }

  /// Кладёт в буфер ФРАГМЕНТ, выделенный пользователем в живом слое поповера
  /// (`SelectableTextOverlay`), — а не всё событие. Жалоба 2026-09-08:
  /// «копирую фразу — копируется всё сообщение целиком».
  void copySelectedText(String text) {
    // Гейт в самом методе, а не только на пункте меню (см. copyEventsAction):
    // это новая точка выноса контента наружу.
    if (room.isContentProtected) return;
    if (text.isEmpty) return;
    unawaited(Clipboard.setData(ClipboardData(text: text)));
  }

  void saveEvent(Event event) {
    // Гейт в самом методе, а не только на пункте меню (см. copyEventsAction).
    if (room.isContentProtected) return;
    event.saveFile(context);
  }

  /// Можно ли скопировать медиа события в системный буфер обмена как картинку.
  ///
  /// Только растровые изображения/стикеры — единственное, что осмысленно ложится
  /// в image-буфер и вставляется картинкой в другое приложение (Liza «Copy
  /// Media»). Видео/аудио/файлы копировать «как медиа» нельзя — для них есть
  /// «Сохранить файл». Web/Linux исключены: `Pasteboard.writeImage` там не
  /// поддержан (Linux — тихий no-op в плагине; web — квирки Clipboard API с
  /// протухающим жестом после await загрузки).
  bool canCopyMedia(Event event) => canCopyMediaDecision(
    messageType: event.messageType,
    isSent: event.status.isSent,
    redacted: event.redacted,
    platformSupportsImageClipboard:
        !PlatformInfos.isWeb && !PlatformInfos.isLinux,
  );

  /// Скачивает (из SDK-кэша или сети) и расшифровывает вложение, кладёт байты
  /// картинки в системный буфер обмена. Прогресс-диалог — оригинал мог быть ещё
  /// не скачан (пользователь видел только превью). Мессенджер/локализацию берём
  /// ДО await — контекст поповера к этому моменту уже закрыт.
  Future<void> copyMediaEvent(Event event) async {
    // Гейт в самом методе, а не только на пункте меню (см. copyEventsAction).
    if (room.isContentProtected) return;
    final l10n = L10n.of(context);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final result = await event.downloadWithProgress(context);
    final file = result.result;
    if (file == null) return; // ошибка уже показана диалогом
    try {
      await Pasteboard.writeImage(file.bytes);
    } catch (e, s) {
      Logs().w('Failed to copy image to clipboard', e, s);
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.oopsSomethingWentWrong)),
      );
      return;
    }
    scaffoldMessenger.showSnackBar(
      SnackBar(content: Text(l10n.imageCopiedToClipboard)),
    );
  }

  Future<void> forwardEvent(Event event) async {
    if (_blockedByUpdate()) return;
    final timeline = this.timeline;
    if (timeline == null) return;
    // Помечаем как пересланное (LABA-1991) единой трубой, общей со всеми путями
    // форварда. Форвард якоря-галереи разворачивает ВЕСЬ альбом (новый id,
    // reindex, n=факт), иначе получатель видит вечные фантом-спиннеры.
    final contents = await buildForwardedContentsForEvents(
      room.client,
      timeline,
      [event],
    );
    if (!mounted) return; // fetchSenderUser — сетевой await, виджет мог уйти
    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: contents.map(ContentShareItem.new).toList(),
      ),
    );
  }

  Future<void> redactEvent(Event event) async {
    if (_blockedByUpdate()) return;
    await _redactEvents([event]);
  }

  // Не голый `cancelSend`: без флага отмены серия отправки дошлёт файл после
  // паузы сети, и удалённое сообщение воскреснет (LABA-2622).
  void deleteLocalEvent(Event event) => cancelPendingSend(event);

  void resendEvent(Event event) {
    if (_blockedByUpdate()) return;
    if (_warnIfUnresendableMissingMedia(event)) return;
    if (event.status.isError) FailedMediaResender.resend(event);
    final timeline = this.timeline;
    if (timeline == null) return;
    for (final editEvent
        in event
            .aggregatedEvents(timeline, RelationshipTypes.edit)
            .where((e) => e.status.isError)) {
      editEvent.sendAgain();
    }
  }

  void togglePinEvent(Event event) {
    if (_blockedByUpdate()) return;
    final pinnedEventIds = room.pinnedEventIds;
    if (pinnedEventIds.contains(event.eventId)) {
      pinnedEventIds.removeWhere((id) => id == event.eventId);
    } else {
      pinnedEventIds.add(event.eventId);
    }
    showFutureLoadingDialog(
      context: context,
      future: () => room.setPinnedEvents(pinnedEventIds),
    );
  }

  /// Возвращает `true`, если жалоба отправлена (не отменена) — вызывающий из
  /// мультивыбора по этому флагу решает, сбрасывать ли выделение.
  Future<bool> reportEvent(Event event) async {
    final score = await showModalActionPopup<int>(
      context: context,
      title: L10n.of(context).reportMessage,
      message: L10n.of(context).howOffensiveIsThisContent,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: -100,
          label: L10n.of(context).extremeOffensive,
        ),
        AdaptiveModalAction(value: -50, label: L10n.of(context).offensive),
        AdaptiveModalAction(value: 0, label: L10n.of(context).inoffensive),
      ],
    );
    if (score == null) return false;
    final reason = await showTextInputDialog(
      context: context,
      title: L10n.of(context).whyDoYouWantToReportThis,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).reason,
    );
    if (reason == null || reason.isEmpty) return false;
    final result = await showFutureLoadingDialog(
      context: context,
      future: () => Matrix.of(context).client.reportEvent(
        event.roomId!,
        event.eventId,
        reason: reason,
        score: score,
      ),
    );
    if (result.error != null) return false;
    if (!mounted) return false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(L10n.of(context).contentHasBeenReported)),
    );
    return true;
  }

  /// Уже отправленные текущим пользователем реакции на [event] — для дедупа в
  /// ряду быстрых реакций поповера (повторный тап снимает реакцию).
  Set<String> sentReactionsOf(Event event) {
    final timeline = this.timeline;
    if (timeline == null) return {};
    return event
        .aggregatedEvents(timeline, RelationshipTypes.reaction)
        .where(
          (e) => e.senderId == room.client.userID && e.type == 'm.reaction',
        )
        .map(
          (e) => e.content
              .tryGetMap<String, Object?>('m.relates_to')
              ?.tryGet<String>('key'),
        )
        .whereType<String>()
        .toSet();
  }

  void toggleReaction(Event event, String emoji) {
    if (_blockedByUpdate()) return;
    final timeline = this.timeline;
    if (timeline == null) return;
    final existing = event
        .aggregatedEvents(timeline, RelationshipTypes.reaction)
        .firstWhereOrNull(
          (e) =>
              e.senderId == room.client.userID &&
              e.type == 'm.reaction' &&
              e.content
                      .tryGetMap<String, Object?>('m.relates_to')
                      ?.tryGet<String>('key') ==
                  emoji,
        );
    if (existing != null) {
      // На старых каналах порог m.room.redaction наследует
      // events_default: 100 — сервер вернёт M_FORBIDDEN. Молча не трогаем
      // реакцию, вместо того чтобы показывать «Нет прав доступа».
      if (!event.room.canRedactOwnReaction) return;
      existing.redactEvent();
    } else {
      event.room.sendReaction(event.eventId, emoji);
    }
  }

  void goToNewRoomAction() async {
    final result = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final users = await room.requestParticipants(
          [Membership.join, Membership.leave],
          true,
          false,
        );
        users.sort((a, b) => a.powerLevel.compareTo(b.powerLevel));
        final via = users
            .map((user) => user.id.domain)
            .whereType<String>()
            .toSet()
            .take(10)
            .toList();
        return room.client.joinRoom(
          room
              .getState(EventTypes.RoomTombstone)!
              .parsedTombstoneContent
              .replacementRoom,
          via: via,
        );
      },
    );
    if (result.error != null) return;
    if (!mounted) return;
    context.go('/rooms/${result.result!}');

    await showFutureLoadingDialog(context: context, future: room.leave);
  }

  void onSelectMessage(Event event) {
    if (!event.redacted) {
      if (selectedEvents.contains(event)) {
        setState(() => selectedEvents.remove(event));
      } else {
        setState(() => selectedEvents.add(event));
      }
      selectedEvents.sort(
        (a, b) => a.originServerTs.compareTo(b.originServerTs),
      );
    }
  }

  int? findChildIndexCallback(Key key, Map<String, int> thisEventsKeyMap) {
    // this method is called very often. As such, it has to be optimized for speed.
    if (key is! ValueKey) {
      return null;
    }
    final eventId = key.value;
    if (eventId is! String) {
      return null;
    }
    // first fetch the last index the event was at
    final index = thisEventsKeyMap[eventId];
    if (index == null) {
      return null;
    }
    // we need to +1 as 0 is the typing thing at the bottom
    return index + 1;
  }

  void onInputBarSubmitted(String _) {
    send();
    FocusScope.of(context).requestFocus(inputFocus);
  }

  void onAddPopupMenuButtonSelected(AddPopupMenuActions choice) {
    room.client.getConfig();

    switch (choice) {
      case AddPopupMenuActions.gallery:
        openGalleryAction();
        return;
      case AddPopupMenuActions.camera:
        openCameraAction();
        return;
      case AddPopupMenuActions.file:
        sendFileSourceAction();
        return;
      case AddPopupMenuActions.poll:
        showAdaptiveBottomSheet(
          context: context,
          builder: (context) => StartPollBottomSheet(
            room: room,
            alwaysDisclosed: isNewsBotDm(room),
          ),
        );
        return;
      case AddPopupMenuActions.location:
        sendLocationAction();
        return;
      case AddPopupMenuActions.createMiniApp:
        // Команда боту BotFather: он отвечает карточкой «Внешний mini App».
        // parseCommands: false — шлём «/newapp» текстом, не как Matrix-команду.
        room.sendTextEvent('/newapp', parseCommands: false);
        return;
    }
  }

  void unpinEvent(String eventId) async {
    if (_blockedByUpdate()) return;
    final response = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).unpin,
      message: L10n.of(context).confirmEventUnpin,
      okLabel: L10n.of(context).unpin,
      cancelLabel: L10n.of(context).cancel,
    );
    if (response == OkCancelResult.ok) {
      final events = room.pinnedEventIds
        ..removeWhere((oldEvent) => oldEvent == eventId);
      showFutureLoadingDialog(
        context: context,
        future: () => room.setPinnedEvents(events),
      );
    }
  }

  void pinEvent() {
    if (_blockedByUpdate()) return;
    final pinnedEventIds = room.pinnedEventIds;
    final selectedEventIds = selectedEvents.map((e) => e.eventId).toSet();
    final unpin =
        selectedEventIds.length == 1 &&
        pinnedEventIds.contains(selectedEventIds.single);
    if (unpin) {
      pinnedEventIds.removeWhere(selectedEventIds.contains);
    } else {
      pinnedEventIds.addAll(selectedEventIds);
    }
    showFutureLoadingDialog(
      context: context,
      future: () => room.setPinnedEvents(pinnedEventIds),
    );
  }

  Timer? _storeInputTimeoutTimer;
  static const Duration _storeInputTimeout = Duration(milliseconds: 500);

  void onInputBarChanged(String text) {
    if (_inputTextIsEmpty != text.isEmpty) {
      setState(() {
        _inputTextIsEmpty = text.isEmpty;
      });
    }

    _updateMessageLinkPreview(text);

    _storeInputTimeoutTimer?.cancel();
    _storeInputTimeoutTimer = Timer(_storeInputTimeout, () async {
      final prefs = Matrix.of(context).store;
      await prefs.setString('draft_$roomId', text);
      final spansJson = sendController.serializeSpans();
      if (spansJson != null) {
        await prefs.setString('draftfmt_$roomId', spansJson);
      } else {
        await prefs.remove('draftfmt_$roomId');
      }
    });
    if (text.endsWith(' ') && Matrix.of(context).hasComplexBundles) {
      final clients = currentRoomBundle;
      for (final client in clients) {
        final prefix = client!.sendPrefix;
        if ((prefix.isNotEmpty) &&
            text.toLowerCase() == '${prefix.toLowerCase()} ') {
          setSendingClient(client);
          setState(() {
            sendController.clear();
          });
          return;
        }
      }
    }
    if (AppSettings.sendTypingNotifications.value) {
      typingCoolDown?.cancel();
      typingCoolDown = Timer(const Duration(seconds: 2), () {
        typingCoolDown = null;
        currentlyTyping = false;
        if (WidgetsBinding.instance.lifecycleState ==
            AppLifecycleState.resumed) {
          // Typing — fire-and-forget; errno 9/60 после фона не должны
          // всплывать как unhandled.
          room.setTyping(false).catchError((_) {});
        }
      });
      typingTimeout ??= Timer(const Duration(seconds: 30), () {
        typingTimeout = null;
        currentlyTyping = false;
      });
      if (!currentlyTyping) {
        currentlyTyping = true;
        // Typing — fire-and-forget.
        room
            .setTyping(
              true,
              timeout: const Duration(seconds: 30).inMilliseconds,
            )
            .catchError((_) {});
      }
    }
  }

  bool _inputTextIsEmpty = true;

  bool get isArchived =>
      {Membership.leave, Membership.ban}.contains(room.membership);

  void showEventInfo([Event? event]) =>
      (event ?? selectedEvents.single).showInfoDialog(context);

  void onPhoneButtonTap() async {
    if (_blockedByUpdate()) return;
    // VoIP required Android SDK 21
    if (PlatformInfos.isAndroid) {
      DeviceInfoPlugin().androidInfo.then((value) {
        if (value.version.sdkInt < 21) {
          Navigator.pop(context);
          showOkAlertDialog(
            context: context,
            title: L10n.of(context).unsupportedAndroidVersion,
            message: L10n.of(context).unsupportedAndroidVersionLong,
            okLabel: L10n.of(context).close,
          );
        }
      });
    }
    final callType = await showModalActionPopup<CallType>(
      context: context,
      title: L10n.of(context).warning,
      message: L10n.of(context).videoCallsBetaWarning,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          label: L10n.of(context).voiceCall,
          icon: const Icon(Icons.phone_outlined),
          value: CallType.kVoice,
        ),
        AdaptiveModalAction(
          label: L10n.of(context).videoCall,
          icon: const Icon(Icons.video_call_outlined),
          value: CallType.kVideo,
        ),
      ],
    );
    if (callType == null) return;

    final voipPlugin = Matrix.of(context).voipPlugin;
    try {
      await voipPlugin!.inviteToCall(room, callType);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
    }
  }

  void cancelReplyEventAction() {
    setState(() {
      if (editEvent != null) {
        sendController.text = pendingText;
        sendController.setSpans(pendingSpans, pendingText.length);
        pendingText = '';
        pendingSpans = const [];
      }
      replyEvent = null;
      editEvent = null;
    });
    _persistReplyDraft();
  }

  /// Пересчитать превью ссылки-на-сообщение по тексту композера.
  void _updateMessageLinkPreview(String text) {
    final link = MessageLink.firstFrom(text);
    if (link == null) {
      _dismissedLinkPreview = null;
      if (messageLinkPreview != null) {
        setState(() => messageLinkPreview = null);
      }
      return;
    }
    if (link != _dismissedLinkPreview) _dismissedLinkPreview = null;
    final next = link == _dismissedLinkPreview ? null : link;
    if (next != messageLinkPreview) {
      setState(() => messageLinkPreview = next);
    }
  }

  /// Крестик на превью: скрыть карточку, текст ссылки оставить (как в Liza).
  void cancelMessageLinkPreview() => setState(() {
    _dismissedLinkPreview = messageLinkPreview;
    messageLinkPreview = null;
  });

  late final ValueNotifier<bool> _displayChatDetailsColumn;

  void toggleDisplayChatDetailsColumn() async {
    await AppSettings.displayChatDetailsColumn.setItem(
      !_displayChatDetailsColumn.value,
    );
    _displayChatDetailsColumn.value = !_displayChatDetailsColumn.value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(child: ChatView(this)),
        ValueListenableBuilder(
          valueListenable: _displayChatDetailsColumn,
          builder: (context, displayChatDetailsColumn, _) =>
              !LizaThemes.isThreeColumnMode(context) ||
                  room.membership != Membership.join ||
                  !displayChatDetailsColumn
              ? const SizedBox(height: double.infinity, width: 0)
              : Container(
                  width: LizaThemes.columnWidth,
                  clipBehavior: Clip.hardEdge,
                  decoration: BoxDecoration(
                    border: Border(
                      left: BorderSide(width: 1, color: theme.dividerColor),
                    ),
                  ),
                  child: ChatDetails(
                    roomId: roomId,
                    embeddedCloseButton: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: toggleDisplayChatDetailsColumn,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

enum AddPopupMenuActions {
  gallery,
  camera,
  file,
  poll,
  location,
  createMiniApp,
}

enum _FileSource { files, gallery }

enum _CameraMode { photo, video }

/// Экран канала для читателя БЕЗ подписки: живая лента + «Подписаться».
///
/// Комната в `client.rooms` не регистрируется — иначе канал попал бы в список
/// чатов, что и было исходной жалобой пользователя.
///
/// Лента здесь намеренно примитивна (`ListTile` с текстом): полноценный рендер
/// через `Message`/`Timeline` — отдельная задача, сначала убеждаемся, что живой
/// хвост вообще доезжает до читателя.
class ChannelPeekPage extends StatefulWidget {
  const ChannelPeekPage({super.key, required this.roomId, this.eventId});

  final String roomId;

  /// Диплинк на конкретный пост канала: после подписки экран обязан открыться
  /// именно на нём, а не в хвосте ленты. `shareItems` намеренно нет — шарить в
  /// канал, где ты не участник, нельзя.
  final String? eventId;

  @override
  State<ChannelPeekPage> createState() => _ChannelPeekPageState();
}

class _ChannelPeekPageState extends State<ChannelPeekPage>
    with WidgetsBindingObserver {
  ChannelPeekSnapshot? _snapshot;
  ChannelPeekStream? _stream;
  Room? _peekRoom;
  bool _loading = true;
  bool _denied = false;
  Client? _client;
  final ScrollController _scrollController = ScrollController();

  /// Таймлайн пересобирается при КАЖДОЙ смене снимка: список событий SDK
  /// правит только из sync, а для не-joined комнаты sync не приходит.
  ///
  /// Строить его в `build()` нельзя: конструктор `Timeline` заводит пять
  /// подписок на клиентские стримы (`timeline.dart:332-351`), и без парного
  /// `cancelSubscriptions()` каждая перерисовка оставляла бы их висеть.
  Timeline? _timeline;

  /// Пересобрать таймлайн под новый список событий, отменив подписки старого.
  void _rebuildTimeline(Room room, List<Event> events) {
    _timeline?.cancelSubscriptions();
    _timeline = buildPeekTimeline(room, events);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Клиента берём здесь, а не в initState: Matrix.of — это Provider.of, и
    // хотя сейчас он с listen:false (в initState формально сработал бы),
    // опираться на это хрупко — смена реализации Matrix.of молча сломала бы
    // экран. didChangeDependencies зовётся до первого build и может повторяться,
    // поэтому загрузку запускаем ровно один раз.
    if (_client != null) return;
    _client = Matrix.of(context).client;
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Долгий peek держит соединение и presence ONLINE — в фоне он не нужен.
    if (state == AppLifecycleState.resumed) {
      _stream?.start();
    } else {
      _stream?.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stream?.dispose();
    _timeline?.cancelSubscriptions();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = _client!;
    final ChannelPeekSnapshot? snapshot;
    try {
      snapshot = await loadChannelPeekSnapshot(client, widget.roomId);
    } catch (e, s) {
      // loadChannelPeekSnapshot глотает только СЕТЕВОЙ отказ (там `null`);
      // ошибка конвертации летит сюда. Без этого catch экран навсегда завис
      // бы в спиннере — тихий баг вместо шумного. Показываем заглушку и лог.
      Logs().e('ChannelPeek: снимок ленты ${widget.roomId} упал', e, s);
      if (mounted) {
        setState(() {
          _loading = false;
          _denied = true;
        });
      }
      return;
    }
    if (!mounted) return;
    if (snapshot == null) {
      setState(() {
        _loading = false;
        _denied = true;
      });
      return;
    }
    // Комнату берём ИЗ снимка, а не строим заново: в ней уже проставлен state
    // канала (`m.room.create`, имя, аватар, привязанный чат). Своя пустая
    // комната сделала бы `isChannel`/`hasComments` ложными — канал рисовался бы
    // как обычный чат, без статистики постов и без плашки комментариев.
    final room = snapshot.room;
    setState(() {
      _peekRoom = room;
      _snapshot = snapshot;
      // `!` — снимок уже проверен на null выше, но promotion не доживает до
      // замыкания setState.
      _rebuildTimeline(room, snapshot!.events);
      _loading = false;
    });
    _stream = ChannelPeekStream(
      client: client,
      roomId: widget.roomId,
      room: room,
      from: snapshot.nextToken,
      onEvents: (events) {
        if (!mounted) return;
        setState(() {
          // Лента рисуется reverse: свежие события идут в НАЧАЛО списка, а
          // long-poll отдаёт их в прямом порядке — отсюда reversed.
          final merged = [...events.reversed, ...?_snapshot?.events];
          _rebuildTimeline(room, merged);
          _snapshot = ChannelPeekSnapshot(
            events: merged,
            nextToken: _stream?.token,
            room: room,
          );
        });
      },
    )..start();
  }

  void _onSubscribed() {
    _stream?.dispose();
    _stream = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // Передача экрана после подписки делается ЗДЕСЬ, а не рассчётом на
    // перестроение ChatPage: тот StatelessWidget и читает клиента через
    // Provider с listen:false, поэтому приезд комнаты в sync его не будит —
    // без этой проверки читатель остался бы в peek-ленте навсегда.
    final joinedRoom = _client?.getRoomById(widget.roomId);
    if (joinedRoom != null) {
      // Ключ ОБЯЗАН совпадать с обычной веткой (routes.dart): иначе Flutter
      // считает это другим экраном и пересоздаёт ChatController с потерей
      // состояния при переходе peek → подписан.
      return ChatPageWithRoom(
        key: Key('chat_page_${widget.roomId}_${widget.eventId}'),
        room: joinedRoom,
        eventId: widget.eventId,
      );
    }
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final peekRoom = _peekRoom;
    if (_denied || peekRoom == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
          ),
        ),
      );
    }
    // Лента канала не показывает системный шум и удалённые посты — как и
    // обычная лента (chat_event_list.dart). Без этого фильтра peek-ветка рисует
    // сырой снимок: удалённый пост (redaction «диагностика») висит надгробием,
    // а редакции/реакции просачиваются отдельными строками. Фильтр применяем
    // при рендере, снимок/токены не трогаем. Устойчив к пустому peek-state:
    // при провале fillPeekRoomState (isChannel=false) валидные посты и «канал
    // создан» остаются, деградирует лишь скрытие удалённых.
    final events = (_snapshot?.events ?? const <Event>[])
        .filterByVisibleInGui();
    final timeline = _timeline;
    if (timeline == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final theme = Theme.of(context);
    final colors = [theme.secondaryBubbleColor, theme.bubbleColor];
    return Scaffold(
      appBar: AppBar(title: Text(peekRoom.getLocalizedDisplayname())),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              reverse: true,
              controller: _scrollController,
              itemCount: events.length,
              itemBuilder: (context, i) => Message(
                events[i],
                // Соседи задают склейку пузырей серии и плашку времени.
                // Ориентация имён — как в chat_event_list.dart:195-196 при том
                // же reverse и том же порядке данных (свежее первым): Message
                // вешает на nextEvent ВЕРХНИЙ скруглённый угол, на
                // previousEvent — нижний, поэтому «next» здесь по БОЛЬШЕМУ
                // индексу, а не по меньшему.
                nextEvent: i + 1 < events.length ? events[i + 1] : null,
                previousEvent: i > 0 ? events[i - 1] : null,
                timeline: timeline,
                scrollController: _scrollController,
                colors: colors,
                // Читателю без подписки взаимодействие недоступно: выделение,
                // ответ, упоминание, правка и переход в тред требуют членства.
                // Пустые замыкания, а не «отключить виджет»: пост обязан
                // выглядеть как в обычной ленте.
                onSelect: (_) {},
                onInfoTab: (_) {},
                scrollToEventId: (_) {},
                onSwipe: () {},
                onMention: () {},
                onEdit: () {},
                enterThread: null,
              ),
            ),
          ),
          ChannelSubscribeBar(
            roomId: widget.roomId,
            client: _client!,
            onSubscribed: _onSubscribed,
          ),
        ],
      ),
    );
  }
}
