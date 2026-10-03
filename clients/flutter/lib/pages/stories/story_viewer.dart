import 'dart:async';

import 'package:collection/collection.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/direct_chat_draft.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:matrix/matrix.dart';

import '../../utils/adaptive_bottom_sheet.dart';
import '../../utils/show_scaffold_dialog.dart';
import '../../utils/stories/active_stories_provider.dart';
import '../../utils/stories/deleted_stories_store.dart';
import '../../utils/stories/stories_extension.dart';
import '../../utils/stories/stories_seen_store.dart';
import '../../utils/stories/story_link_copier.dart';
import '../../utils/stories/story_link_service.dart';
import '../../utils/stories/story_model.dart';
import '../../utils/stories/story_reactions.dart';
import '../../utils/stories/story_seen_logic.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/matrix.dart';
import '../../widgets/share_scaffold_dialog.dart';
import 'story_link_dialog.dart';
import 'story_viewer_view.dart';
import 'story_viewers_sheet.dart';

class StoryViewer extends StatefulWidget {
  const StoryViewer({
    required this.roomIds,
    this.initialIndex = 0,
    this.initialEventId,
    super.key,
  });

  /// Очередь сторис-комнат (порядок StoriesBar, от стартового автора до конца).
  final List<String> roomIds;
  final int initialIndex;

  /// Открыть конкретный сегмент (карточка/ссылка). Null - первый непросмотренный.
  final String? initialEventId;

  @override
  State<StoryViewer> createState() => StoryViewerController();
}

class StoryViewerController extends State<StoryViewer>
    with TickerProviderStateMixin {
  int index = 0;
  List<Event> segments = const [];

  int authorIndex = 0;
  late final PageController pageController;
  Timeline? timeline;
  StreamSubscription<SyncUpdate>? _reactionSyncSub;
  // prevAuthor: открыть последний сегмент предыдущего автора (естественный
  // порядок навигации назад), а не первый непросмотренный.
  bool _startAtEnd = false;

  // Монотонный счётчик запусков _loadAuthor. При быстрых свайпах (страница
  // N -> N+1 -> N+2 до завершения предыдущего await) более ранний вызов может
  // завершиться позже более позднего - без guard'а его setState перезапишет
  // segments/timeline устаревшим автором поверх уже корректных.
  int _loadSeq = 0;

  late final AnimationController _animController;

  // Экспонируем анимацию прогресса во view.
  Animation<double> get progress => _animController;

  bool holdDown = false;

  bool captionExpanded = false;

  /// Общий на весь сеанс просмотра переключатель «звук видео-сториса выключен».
  /// Дефолт — приглушено (требование ②: у зрителей звук по умолчанию выкл).
  /// Живёт в контроллере (не в плеере) — переживает пересоздание плеера по
  /// `ValueKey` при переходе к следующей истории, поэтому mute «распространяется
  /// на остальные истории» сессии (③). Кнопка-грамофон в шапке вьюера правит
  /// этот notifier; [EventVideoPlayer] его читает и применяет громкость.
  final ValueNotifier<bool> storyMuted = ValueNotifier<bool>(true);

  void expandCaption() {
    if (_closing) return;
    setState(() => captionExpanded = true);
    pause();
  }

  void collapseCaption() {
    if (!captionExpanded) return;
    setState(() => captionExpanded = false);
    if (_shouldStayPaused) return;
    resume();
  }

  final TextEditingController replyController = TextEditingController();
  late final FocusNode replyFocus = FocusNode()
    ..addListener(() {
      if (mounted) setState(() {}); // перерисовать хром (chromeHidden)
      if (replyFocus.hasFocus) {
        pause();
      } else if (!_shouldStayPaused) {
        resume();
      }
    });

  /// UI-хром (таймлайн, строка автора) скрыт ТОЛЬКО при наборе комментария
  /// (фокус на поле ответа). Удержание пальца НЕ скрывает UI - оно лишь
  /// "замораживает" сторис (пауза), весь интерфейс остаётся на месте.
  bool get chromeHidden => replyFocus.hasFocus;

  void _onReplyTextChanged() {
    if (mounted) setState(() {});
  }

  bool reactionRowOpen = false;

  void toggleReactionRow() {
    setState(() => reactionRowOpen = !reactionRowOpen);
    if (reactionRowOpen) {
      pause();
    } else if (!_shouldStayPaused) {
      resume();
    }
  }

  /// Есть ли ещё причина держать паузу помимо только что снятой. Приоритет
  /// нескольких независимых "держателей" паузы (hold/caption/reactions/focus) -
  /// resume() должен звать только тот, кто снимает ПОСЛЕДНЮЮ причину.
  bool get _shouldStayPaused =>
      holdDown ||
      captionExpanded ||
      reactionRowOpen ||
      viewersSheetOpen ||
      replyFocus.hasFocus;

  /// resume(), только если ни один другой держатель паузы не активен.
  /// Публичная обёртка _shouldStayPaused для колбэков во view (например,
  /// закрытие меню "...": onCanceled не должен резюмить поверх открытой
  /// подписи/реакций/фокуса на поле ответа).
  void resumeIfIdle() {
    if (!_shouldStayPaused) resume();
  }

  int get roomIdsCount => widget.roomIds.length;

  Room? get room {
    if (authorIndex < 0 || authorIndex >= widget.roomIds.length) return null;
    return Matrix.of(context).client.getRoomById(widget.roomIds[authorIndex]);
  }

  @override
  void initState() {
    super.initState();
    authorIndex = widget.initialIndex;
    replyController.addListener(_onReplyTextChanged);
    pageController = PageController(initialPage: widget.initialIndex);
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    );
    _animController.addStatusListener(_onAnimationStatus);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadAuthor();
      // Живое обновление агрегата реакций у своих сторис: чужие реакции
      // приходят по sync, без подписки статистика зависает до следующего
      // ручного setState (смена сегмента/автора).
      _reactionSyncSub = Matrix.of(context).client.onSync.stream.listen((sync) {
        final r = room;
        if (!mounted || r == null || !isOwnStory) return;
        if (sync.rooms?.join?.containsKey(r.id) != true) return;
        setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _animController.removeStatusListener(_onAnimationStatus);
    _animController.dispose();
    timeline?.cancelSubscriptions();
    _reactionSyncSub?.cancel();
    pageController.dispose();
    replyController.removeListener(_onReplyTextChanged);
    replyController.dispose();
    replyFocus.dispose();
    storyMuted.dispose();
    super.dispose();
  }

  void _onAnimationStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      next();
    }
  }

  // Запускает анимацию прогресса для текущего сегмента.
  // duration - длительность в миллисекундах (null = 5 с по умолчанию).
  void _startProgress({int? durationMs}) {
    final dur = durationMs != null && durationMs > 0
        ? Duration(milliseconds: durationMs)
        : const Duration(seconds: 5);
    _animController.duration = dur;
    _animController.forward(from: 0);
  }

  Future<void> _loadAuthor() async {
    final seq = ++_loadSeq;
    _animController.stop();
    timeline?.cancelSubscriptions();
    timeline = null;
    _serverReactions = const {};
    final r = room;
    final client = Matrix.of(context).client;
    if (r == null) return _skipAuthorForward();
    final loaded = await client.activeStoriesWithTimeline(
      r,
      deleted: deletedStore,
    );
    if (!mounted || seq != _loadSeq) {
      loaded?.$1.cancelSubscriptions();
      return;
    }
    if (loaded == null || loaded.$2.isEmpty) return _skipAuthorForward();
    final startAtEnd = _startAtEnd;
    _startAtEnd = false;
    setState(() {
      timeline = loaded.$1;
      segments = loaded.$2;
      final initial = widget.initialEventId;
      if (initial != null && authorIndex == widget.initialIndex) {
        final i = segments.indexWhere((e) => e.eventId == initial);
        index = i >= 0 ? i : 0;
      } else if (startAtEnd) {
        index = segments.length - 1;
      } else {
        index = firstUnseenIndex(
          segmentIds: segments.map((e) => e.eventId).toList(),
          receiptIndex: client.myReceiptIndexIn(r, segments),
          isLocallySeen: seenStore.isSeen,
        );
      }
    });
    _onSegmentShown();
    _startProgress(durationMs: _currentSegmentDurationMs());
    if (isOwnStory) _loadServerReactions(seq, r, segments);
  }

  /// Реакции на свою сторис с сервера (LABA-2616): лента автора их теряет
  /// после limited sync. Только активные сегменты (удалённые отсечены в
  /// [Client.activeStoriesWithTimeline]); ошибка — остаются реакции из ленты.
  Future<void> _loadServerReactions(
    int seq,
    Room room,
    List<Event> forSegments,
  ) async {
    final results = await Future.wait([
      for (final segment in forSegments)
        fetchStoryReactions(room, segment.eventId)
            .timeout(const Duration(seconds: 15))
            .catchError((Object e, StackTrace s) {
              Logs().w('Story reactions fetch failed', e, s);
              return const <String, StoryReaction>{};
            }),
    ]);
    if (!mounted || seq != _loadSeq) return;
    setState(() {
      _serverReactions = {for (final r in results) ...r};
    });
  }

  /// Автор без активных сегментов (протух между баром и открытием) - дальше.
  void _skipAuthorForward() {
    if (authorIndex >= widget.roomIds.length - 1) {
      // Дошли до конца очереди и НИ ОДНОГО сегмента так и не показали (частый
      // cold-start-край: тапнули по пушу, но сторис уже протухла и у автора
      // больше нет активных). Не выбрасываем молча - объясняем снэкбаром, как
      // openStoryByRef. Если контент уже показывали - это штатный конец, тихо.
      if (!_anyShown && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).storyUnavailable)),
        );
      }
      close();
    } else {
      nextAuthor();
    }
  }

  void nextAuthor() {
    if (_closing) return;
    if (authorIndex >= widget.roomIds.length - 1) {
      close();
      return;
    }
    pageController.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  void prevAuthor() {
    if (_closing || authorIndex == 0) return;
    _startAtEnd = true;
    pageController.previousPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
    );
  }

  /// Колбэк PageView (и свайп, и programmatic animateTo).
  void onAuthorPageChanged(int page) {
    if (page == authorIndex) return;
    setState(() {
      authorIndex = page;
      segments = const [];
      index = 0;
      captionExpanded = false;
      reactionRowOpen = false;
    });
    _loadAuthor();
  }

  // Возвращает длительность текущего сегмента из метаданных события (мс).
  // Для фото и неизвестных форматов возвращает null (фоллбэк 5 с в _startProgress).
  int? _currentSegmentDurationMs() {
    if (segments.isEmpty) return null;
    final event = segments[index];
    final isVideo = event.content['msgtype'] == 'm.video';
    if (!isVideo) return null;
    final info = event.content['info'];
    if (info is Map) {
      final dur = info['duration'];
      if (dur is int && dur > 0) return dur;
      if (dur is double && dur > 0) return dur.toInt();
    }
    return null;
  }

  /// Видео сообщило фактическую длительность — перезапускаем прогресс по ней.
  void onVideoDuration(Duration d) {
    if (!mounted || segments.isEmpty) return;
    final event = segments[index];
    if (event.content['msgtype'] != 'm.video') return;
    _startProgress(durationMs: d.inMilliseconds);
  }

  void next() {
    if (_closing) return;
    if (index >= segments.length - 1) {
      nextAuthor();
    } else {
      setState(() {
        index++;
        captionExpanded = false;
        reactionRowOpen = false;
      });
      _startProgress(durationMs: _currentSegmentDurationMs());
      _onSegmentShown();
    }
  }

  void prev() {
    if (_closing) return;
    if (index > 0) {
      setState(() {
        index--;
        captionExpanded = false;
        reactionRowOpen = false;
      });
      _startProgress(durationMs: _currentSegmentDurationMs());
    } else {
      prevAuthor();
    }
  }

  // Идемпотентный флаг: на последнем видео-сегменте next() прилетает СРАЗУ из
  // двух источников в одном кадре - таймер прогресса (_onAnimationStatus) и
  // completed-стрим видео (onStoryEnded). Без гарда оба делают Navigator.pop():
  // первый закрывает viewer, второй снимает последнюю страницу -> краш
  // "popped the last page". Гард пускает close() ровно один раз.
  bool _closing = false;

  // Показали ли хоть один сегмент за сессию вьюера. Гейт снэкбара «История
  // недоступна» в _skipAuthorForward: снэкбар только когда открылись и не
  // показали НИЧЕГО (протухший single-author), а не в штатном конце просмотра.
  bool _anyShown = false;

  void close() {
    if (_closing) return;
    _closing = true;
    _animController.stop();
    if (mounted) Navigator.of(context).pop();
  }

  // Пауза/возобновление таймлайна на время открытого асинхронного диалога
  // (например, подтверждения удаления). Без паузы таймер сегмента мог
  // истечь под диалогом и вызвать next()/close(), пока пользователь ещё
  // читает диалог - см. регрессию на стыке удаления и подтверждения.
  //
  // _paused управляет ещё и видео-сегментом: StoryViewerView пробрасывает
  // isActive: !isPaused в EventVideoPlayer, тот же проп, что карусель уже
  // использует для остановки звука на невидимой странице. Без этого видео
  // физически доигрывает до конца под диалогом и его отдельный канал
  // завершения (_player.stream.completed -> onStoryEnded) вызывает next()
  // в обход паузы _animController - фото и видео делят один и тот же
  // pause()/resume(), но у видео завершение идёт по другому каналу.
  bool _paused = false;

  bool get isPaused => _paused;

  StoriesSeenStore? _seenStore;
  StoriesSeenStore get seenStore => _seenStore ??= StoriesSeenStore(
    Matrix.of(context).store,
    scope: Matrix.of(context).client.userID,
  );

  DeletedStoriesStore? _deletedStore;
  DeletedStoriesStore get deletedStore => _deletedStore ??= DeletedStoriesStore(
    Matrix.of(context).store,
    scope: Matrix.of(context).client.userID,
  );

  /// Пункт «Удалить»: своя сторис, ещё не удалённая (LABA-2618 — повторное
  /// удаление уже удалённой недоступно).
  bool get canDeleteCurrent =>
      isOwnStory &&
      segments.isNotEmpty &&
      !Matrix.of(
        context,
      ).client.isStoryAlreadyDeleted(segments[index], deletedStore);

  /// Отметить показанный сегмент: локально мгновенно + public receipt
  /// (только вперёд и только для чужих комнат). Fire-and-forget.
  void _onSegmentShown() {
    if (segments.isEmpty) return;
    _anyShown = true;
    final event = segments[index];
    seenStore.markSeen(event.eventId);
    final r = room;
    if (r == null || isOwnStory) return;
    final client = Matrix.of(context).client;
    if (index <= client.myReceiptIndexIn(r, segments)) return; // не откатываем
    r
        .setReadMarker(event.eventId, mRead: event.eventId, public: true)
        .catchError((Object e, StackTrace s) {
          Logs().w('Story receipt failed', e, s);
        });
  }

  void pause() {
    _animController.stop();
    setState(() => _paused = true);
  }

  void resume() {
    if (_closing) return;
    setState(() => _paused = false);
    if (segments.isEmpty) return;
    if (_animController.status == AnimationStatus.completed) return;
    _animController.forward();
  }

  void onHoldStart() {
    if (_closing) return;
    setState(() => holdDown = true);
    pause();
  }

  void onHoldEnd() {
    if (!holdDown) return;
    setState(() => holdDown = false);
    // Другие держатели паузы (подпись/реакции/фокус на ответе) приоритетнее:
    // не резюмим, пока их владелец сам не снимет паузу через _shouldStayPaused.
    if (_shouldStayPaused) return;
    resume();
  }

  void openLink(String url) => UrlLauncher(context, url).launchUrl();

  /// True, если просматривается собственная сторис-комната пользователя.
  bool get isOwnStory {
    final client = Matrix.of(context).client;
    final myRoom = client.myStoriesRoom;
    final r = room;
    return r != null && myRoom != null && r.id == myRoom.id;
  }

  /// Может ли зритель поставить реакцию (в сторис канала — нет).
  /// power_levels ещё не загружены — кнопку не прячем.
  bool get canReactToCurrent {
    final r = room;
    if (r == null) return false;
    if (r.getState(EventTypes.RoomPowerLevels) == null) return true;
    return r.canSendEvent(EventTypes.Reaction);
  }

  bool _reactionBusy = false;

  Event? _myReactionEvent(Event segment) {
    final tl = timeline;
    if (tl == null) return null;
    final myId = Matrix.of(context).client.userID;
    return segment
        .aggregatedEvents(tl, RelationshipTypes.reaction)
        .where((e) => e.senderId == myId && e.type == EventTypes.Reaction)
        .firstOrNull;
  }

  /// Emoji моей активной реакции на текущий сегмент (null - нет).
  String? get myReactionOnCurrent {
    if (segments.isEmpty) return null;
    return _myReactionEvent(segments[index])?.content
        .tryGetMap<String, Object?>('m.relates_to')
        ?.tryGet<String>('key');
  }

  // Позиции и якоря таймлайна для счётчика просмотров: геттер зовётся из build
  // на каждый sync, пересобираем только при смене таймлайна/его длины/головы.
  ({Object? key, Map<String, int> positions, Set<String> anchors})? _viewsIndex;

  /// Реакции на свою сторис, загруженные с сервера: eventId -> реакция.
  Map<String, StoryReaction> _serverReactions = const {};

  ({Object? key, Map<String, StoryReaction> value})? _reactionsCache;

  /// Единый источник реакций для строки статистики, счётчика просмотров и
  /// листа «Просмотры»: лента ∪ снимок сервера без снятых. Новая реакция и
  /// редакция вставляются в ленту, поэтому длины и головы достаточно для ключа.
  Map<String, StoryReaction> get _currentReactions {
    final tl = timeline;
    final r = room;
    final events = tl != null && r != null && tl.room.id == r.id
        ? tl.events
        : const <Event>[];
    final key = (
      tl,
      events.length,
      events.firstOrNull?.eventId,
      _serverReactions,
    );
    final cached = _reactionsCache;
    if (cached != null && cached.key == key) return cached.value;
    final inTimeline = storyReactionsInTimeline(events);
    final value = mergeStoryReactions(
      live: inTimeline.live,
      server: _serverReactions,
      redacted: inTimeline.redacted,
    );
    _reactionsCache = (key: key, value: value);
    return value;
  }

  /// Число зрителей текущего сегмента (без автора и AI-ботов).
  int get currentViewsCount => _viewersOfCurrent(_currentReactions).length;

  /// Зрители текущего сегмента (без автора и AI-ботов).
  Set<String> _viewersOfCurrent(Map<String, StoryReaction> reactions) {
    final r = room;
    if (r == null || segments.isEmpty) return const {};
    final matrix = Matrix.of(context);
    final owner = matrix.client.storyOwnerOf(r);
    final tl = timeline;
    // Без таймлайна этой комнаты — только сегменты (прежняя логика точного
    // совпадения); порядок newest-first, как у Timeline.events.
    final events = tl != null && tl.room.id == r.id
        ? tl.events
        : segments.reversed.toList();
    final key = (tl, events.length, events.firstOrNull?.eventId);
    final cached = _viewsIndex;
    final views = cached != null && cached.key == key
        ? cached
        : _viewsIndex = (
            key: key,
            positions: timelinePositions([for (final e in events) e.eventId]),
            anchors: {
              // Все сообщения комнаты, включая удалённые: писать в сторис-
              // комнату могут только автор/админы канала (events_default 100).
              for (final e in events)
                if (e.type == EventTypes.Message) e.eventId,
            },
          );
    final segmentId = segments[index].eventId;
    return viewersInTimeline(
      positions: views.positions,
      segmentId: segmentId,
      anchorIds: views.anchors,
      viewerReceipts: matrix.client.viewerReceiptEventIds(r),
      // Реакции не мемоизируем: снятие реакции (redact) меняет событие на
      // месте, не трогая длину и голову таймлайна.
      reactions: {
        for (final e in reactions.entries)
          e.key: (sender: e.value.sender, target: e.value.target),
      },
      reactors: storyReactorsOf(reactions, segmentId),
      isExcluded: (userId) => userId == owner || matrix.isAiUser(userId),
    );
  }

  /// emoji -> количество реакций по текущему сегменту.
  Map<String, int> get reactionsAggregateOnCurrent {
    if (segments.isEmpty) return const {};
    return storyReactionsAggregate(_currentReactions, segments[index].eventId);
  }

  bool viewersSheetOpen = false;

  /// Лист «Просмотры» своей сторис: зрители текущего сегмента и их реакции.
  /// Сторис на паузе, пока лист открыт.
  Future<void> openViewersSheet() async {
    final r = room;
    if (r == null || segments.isEmpty || !isOwnStory || _closing) return;
    final reactions = _currentReactions;
    final rows = storyViewerRows(
      viewers: _viewersOfCurrent(reactions),
      reactions: reactions,
      segmentId: segments[index].eventId,
    );
    setState(() => viewersSheetOpen = true);
    pause();
    await showStoryViewersSheet(context, room: r, rows: rows);
    if (!mounted) return;
    setState(() => viewersSheetOpen = false);
    resumeIfIdle();
  }

  /// Одна активная реакция на сегмент: та же emoji - снять, другая -
  /// redact старой + отправить новую.
  Future<void> toggleStoryReaction(String emoji) async {
    if (_reactionBusy || segments.isEmpty) return;
    _reactionBusy = true;
    try {
      final segment = segments[index];
      final existing = _myReactionEvent(segment);
      final existingKey = existing?.content
          .tryGetMap<String, Object?>('m.relates_to')
          ?.tryGet<String>('key');
      if (existing != null) await existing.redactEvent();
      if (existingKey != emoji) {
        await segment.room.sendReaction(segment.eventId, emoji);
      }
      if (mounted) setState(() {});
    } catch (e, s) {
      Logs().w('Story reaction failed', e, s);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
        );
      }
    } finally {
      _reactionBusy = false;
    }
  }

  Future<void> pickCustomStoryReaction() async {
    pause();
    final emoji = await showAdaptiveBottomSheet<String>(
      context: context,
      builder: (context) => Scaffold(
        appBar: AppBar(
          title: Text(L10n.of(context).customReaction),
          leading: CloseButton(onPressed: () => Navigator.of(context).pop()),
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
              // По дефолту открывать смайлики, а не "недавние".
              categoryViewConfig: const CategoryViewConfig(
                initCategory: Category.SMILEYS,
              ),
            ),
          ),
        ),
      ),
    );
    if (emoji != null) await toggleStoryReaction(emoji);
    if (mounted) {
      setState(() => reactionRowOpen = false);
      if (!_shouldStayPaused) resume();
    }
  }

  /// Открывает пикер комнат и пересылает текущий сегмент карточкой-цитатой.
  /// Паузит таймлайн на время диалога. НЕ закрываем вьюер сами: выбор комнаты
  /// уводит навигацию через go_router (context.go в ShareScaffoldDialog), и он
  /// сам снимет маршрут вьюера из корневого Navigator. Лишний Navigator.pop
  /// здесь рассинхронит стек и оставит чёрный экран (регрессия C2). При отмене
  /// диалога - просто резюмим таймлайн.
  Future<void> shareStory() async {
    if (segments.isEmpty) return;
    pause();
    await showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: [ContentShareItem(currentStoryRefContent())],
      ),
    );
    if (mounted) resumeIfIdle();
  }

  late final StoryLinkCopier _storyLinkCopier = StoryLinkCopier(
    createLink: (ref) async {
      final accessToken = Matrix.of(context).client.accessToken;
      if (accessToken == null) throw Exception('no access token');
      return StoryLinkService().createLink(ref: ref, accessToken: accessToken);
    },
  );

  /// Ссылка на текущий сегмент; null — ссылку не выдать (нет ref или история
  /// уже протухла: сервер клампит срок к now, ссылка умерла бы сразу).
  StoryRef? _currentStoryLinkRef() {
    if (segments.isEmpty) return null;
    final ref = StoryRef.fromContent(currentStoryRefContent());
    if (ref == null) return null;
    if (ref.expiresTs <= DateTime.now().millisecondsSinceEpoch) return null;
    return ref;
  }

  /// Запрашивает ссылку заранее, при открытии меню «⋯»: к выбору пункта она
  /// уже готова и пишется в буфер внутри жеста тапа (LABA-2615).
  void prefetchStoryLink() {
    final ref = _currentStoryLinkRef();
    if (ref != null) unawaited(_storyLinkCopier.prefetch(ref));
  }

  /// Кладёт короткую ссылку на текущий сегмент в буфер обмена. Если браузер
  /// запись отверг — показывает ссылку в диалоге для ручного копирования.
  /// Меню паузит таймлайн, а onCanceled при выборе пункта не вызывается —
  /// возобновляем сами.
  Future<void> copyStoryLink() async {
    if (segments.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    try {
      final ref = _currentStoryLinkRef();
      if (ref == null) throw Exception('нет ссылки для текущего сегмента');
      final result = await _storyLinkCopier.copy(
        ref,
        setClipboard: (text) => Clipboard.setData(ClipboardData(text: text)),
      );
      if (!mounted) return;
      final copied =
          result.copied || await StoryLinkDialog.show(context, result.url);
      if (!mounted || !copied) return;
      messenger.showSnackBar(SnackBar(content: Text(l10n.storyLinkCopied)));
    } catch (e, s) {
      Logs().w('Story link copy failed', e, s);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.oopsSomethingWentWrong)),
      );
    } finally {
      if (mounted) resumeIfIdle();
    }
  }

  /// Имя (path-сегмент) override-правила пуша на сторис текущего автора.
  /// Формат ОБЯЗАН совпадать с серверным (stories_membership/_logic.py:
  /// story_notify_rule_name): "com.liza.story_notify.{roomId}". Полный rule_id
  /// на сервере — "global/override/" + это имя; клиентский API шлёт только имя.
  String? get _storyNotifyRuleName {
    final r = room;
    if (r == null) return null;
    return storyNotifyRuleName(r.id);
  }

  /// Включены ли уведомления о новых сторис текущего контакта.
  /// Правило создаёт сервер (enabled по умолчанию); если его ещё нет в кэше
  /// push-rules (бэкфилл мог не долететь) — считаем включённым (дефолт ON).
  bool get isStoryNotifyEnabled {
    final name = _storyNotifyRuleName;
    if (name == null) return true;
    final rule = Matrix.of(context).client.globalPushRules?.override
        ?.firstWhereOrNull((r) => r.ruleId == name);
    return rule?.enabled ?? true;
  }

  /// Имя автора текущей сторис (для тостов вкл/выкл уведомлений).
  String get _currentStoryOwnerName {
    final r = room;
    final client = Matrix.of(context).client;
    if (r == null) return '';
    final owner =
        client.storyOwnerOf(r) ??
        (segments.isNotEmpty ? segments[index].senderId : '');
    return client.storyOwnerName(r, owner) ?? owner;
  }

  bool _storyNotifyBusy = false;

  /// Тумблер «Уведомлять об историях» контакта: enable/disable серверного
  /// override-правила пуша. Push-rules — account-global, синхронизируются через
  /// /sync → настройка применяется на всех устройствах аккаунта (AC-5).
  /// Правила ещё нет (легаси/бэкфилл не дошёл) — создаём его с нужным
  /// состоянием, тем же условием (type=m.room.message ∧ room_id), что и сервер.
  Future<void> toggleStoryNotify() async {
    if (_storyNotifyBusy) return;
    final r = room;
    final name = _storyNotifyRuleName;
    if (r == null || name == null) return;
    _storyNotifyBusy = true;
    final client = Matrix.of(context).client;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    final ownerName = _currentStoryOwnerName;
    final newValue = !isStoryNotifyEnabled;
    try {
      try {
        await client.setPushRuleEnabled(PushRuleKind.override, name, newValue);
      } on MatrixException {
        // M_NOT_FOUND: правила ещё нет — создаём (enabled), затем при
        // необходимости выключаем.
        await client.setPushRule(
          PushRuleKind.override,
          name,
          [
            'notify',
            {'set_tweak': 'sound', 'value': 'default'},
          ],
          conditions: [
            PushCondition(
              kind: 'event_match',
              key: 'type',
              pattern: 'm.room.message',
            ),
            PushCondition(kind: 'event_match', key: 'room_id', pattern: r.id),
          ],
        );
        if (!newValue) {
          await client.setPushRuleEnabled(PushRuleKind.override, name, false);
        }
      }
      if (!mounted) return;
      setState(() {});
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            newValue
                ? l10n.storyNotifyEnabled(ownerName)
                : l10n.storyNotifyDisabled(ownerName),
          ),
        ),
      );
    } catch (e, s) {
      Logs().w('Story notify toggle failed', e, s);
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text(l10n.oopsSomethingWentWrong)),
        );
      }
    } finally {
      _storyNotifyBusy = false;
    }
  }

  bool _replySending = false;

  /// Content карточки-цитаты для текущего сегмента.
  Map<String, Object?> currentStoryRefContent({String? userText}) {
    final client = Matrix.of(context).client;
    final r = room!;
    final segment = segments[index];
    final owner = client.storyOwnerOf(r) ?? segment.senderId;
    final story = StoryContent.fromContent(segment.content);
    final info = segment.content.tryGetMap<String, Object?>('info');
    final isImage = segment.content['msgtype'] == 'm.image';
    final thumbMxc = info?.tryGetMap<String, Object?>('thumbnail_info') != null
        ? info?.tryGet<String>('thumbnail_url')
        : (isImage ? segment.content.tryGet<String>('url') : null);
    final name = client.storyOwnerName(r, owner) ?? owner;
    final fallback = L10n.of(context).storyCardFallback(name);
    final body = userText == null || userText.isEmpty
        ? fallback
        : '$fallback\n$userText';
    return StoryRef(
      roomId: r.id,
      eventId: segment.eventId,
      authorId: owner,
      thumbnailMxc: thumbMxc,
      expiresTs: story?.expiresTs ?? 0,
    ).buildMessageContent(body: body);
  }

  /// Отправляет текст поля ответа как карточку-цитату автору сегмента в ЛС.
  /// Недоступно для собственных сторис (isOwnStory) - guard в начале.
  Future<void> sendReplyToAuthor() async {
    final text = replyController.text.trim();
    if (text.isEmpty || _replySending || segments.isEmpty || isOwnStory) {
      return;
    }
    _replySending = true;
    final client = Matrix.of(context).client;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    try {
      final owner = client.storyOwnerOf(room!) ?? segments[index].senderId;
      final dmRoomId =
          client.getDirectChatFromUserId(owner) ??
          await client.ensureDirectChat(owner);
      final dm = client.getRoomById(dmRoomId);
      if (dm == null) throw Exception('DM room not found after create');
      await dm.sendEvent(currentStoryRefContent(userText: text));
      replyController.clear();
      replyFocus.unfocus();
      messenger.showSnackBar(SnackBar(content: Text(l10n.storyReplySent)));
    } catch (e, s) {
      Logs().w('Story reply failed', e, s);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.oopsSomethingWentWrong)),
      );
    } finally {
      _replySending = false;
    }
  }

  /// Клик по автору вверху сторис: закрыть вьюер и открыть/создать ЛС с автором.
  /// Только для чужих сторис (для своих - no-op: ЛС с самим собой не имеет смысла).
  void openAuthorDm() {
    if (segments.isEmpty || isOwnStory) return;
    final client = Matrix.of(context).client;
    final owner = client.storyOwnerOf(room!) ?? segments[index].senderId;
    // Чат/приглашение — только с первым сообщением: существующий DM открываем
    // сразу, иначе ведём в черновик (комната родится при отправке ответа).
    // Вьюер запушен через Navigator.push в корневой Navigator; router.go сам
    // заменяет стек и снимает вьюер, отдельный Navigator.pop не нужен.
    openDirectChatOrDraft(GoRouter.of(context), client, owner);
  }

  bool _deleting = false;

  /// Удаляет текущий сегмент (redaction), затем переходит к следующему
  /// или закрывает viewer, если сегментов не осталось.
  Future<void> deleteCurrent() async {
    if (_deleting || segments.isEmpty) return;
    _deleting = true;
    _animController.stop();
    final event = segments[index];
    final client = Matrix.of(context).client;
    final r = room;
    try {
      await client.deleteStory(event, deleted: deletedStore);
      // За время PUT пользователь мог свайпнуть к другому автору — тогда
      // segments уже чужие, трогать их и кольцо этой комнаты нельзя.
      if (!mounted || r == null || room?.id != r.id) return;
      // По eventId, а не по index: index мог сдвинуться за время await.
      final remaining = segments
          .where((s) => s.eventId != event.eventId)
          .toList();
      // Кольцо автора (лента, аватарки) читает ActiveStoriesProvider — без
      // этого удалённая сторис светится в нём до следующего sync-дебаунса.
      ActiveStoriesProvider.instance.setRoomActive(
        r.id,
        client.storyOwnerOf(r),
        remaining,
      );
      setState(() {
        segments = remaining;
        if (index >= segments.length && index > 0) index--;
        // Диалог подтверждения удаления паузил таймлайн (см. pause()); при
        // подтверждённом удалении explicit resume() не вызывается - сбрасываем
        // здесь, иначе следующий сегмент (если видео) получит isActive=false
        // и останется на паузе навсегда.
        _paused = false;
      });
      if (segments.isEmpty) {
        // deleteCurrent доступен только для своих сторис: удаление последнего
        // своего сегмента должно закрывать viewer, а не уводить в чужую ленту.
        close();
      } else {
        _startProgress(durationMs: _currentSegmentDurationMs());
      }
    } catch (e, s) {
      Logs().w('Story delete failed', e, s);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
        );
      }
    } finally {
      _deleting = false;
    }
  }

  @override
  Widget build(BuildContext context) => StoryViewerView(this);
}
