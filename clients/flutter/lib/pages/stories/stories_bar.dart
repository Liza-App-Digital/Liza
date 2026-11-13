import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import '../../l10n/l10n.dart';
import '../../utils/channel_stories.dart';
import '../../utils/stories/active_stories_provider.dart';
import '../../utils/stories/deleted_stories_store.dart';
import '../../utils/stories/frequent_contacts.dart';
import '../../utils/stories/stories_bar_order.dart';
import '../../utils/stories/stories_extension.dart';
import '../../utils/stories/stories_seen_store.dart';
import '../../utils/stories/story_media_picker.dart';
import '../../widgets/avatar.dart';
import '../../widgets/horizontal_mouse_wheel.dart';
import '../../widgets/matrix.dart';
import '../../widgets/online_dot.dart';
import '../../widgets/story_avatar_ring.dart';
import 'story_viewer.dart';

/// Горизонтальная лента сторисов (первый элемент: "Мой сторис [+]").
/// Заменяет presence-ленту StatusMessageList в chat_list_body.
class StoriesBar extends StatefulWidget {
  const StoriesBar({super.key});

  /// Размер аватарки в ленте. Было 76; уменьшено на 15% по просьбе владельца
  /// (02.11.2026), высота ленты — те же -15% (96 → 82).
  static const double avatarSize = 65;

  /// Высота виджета: аватарка 65px + ListView padding vertical:8 = 81px.
  static const double height = 82;

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar>
    with AutomaticKeepAliveClientMixin {
  /// Лента живёт в ленивом SliverList списка чатов: без keep-alive при
  /// прокрутке чатов вниз и обратно State пересоздавался — горизонтальная
  /// позиция аватаров сбрасывалась в начало (виделось как «автоскролл»).
  @override
  bool get wantKeepAlive => true;

  /// Кеш активных сторисов: roomId -> список Event.
  /// Заполняется асинхронно, build читает синхронно.
  final Map<String, List<Event>> _activeByRoom = {};

  /// Активность личных чатов для блока «частые собеседники». Считается в
  /// [FrequentContactsCache] (TTL, без сети), build только ранжирует.
  List<DmActivity> _dmActivity = const [];

  /// Все годные личные чаты (без окна и порога сообщений): из них берётся
  /// категория «онлайн» — человек онлайн виден, даже если давно не переписывались.
  List<DmActivity> _dmCandidates = const [];

  /// Ленивый singleton для текущего State-цикла.
  /// Инициализируется при первом вызове build, не пересоздаётся при перестройках.
  StoriesSeenStore? _seenStore;
  StoriesSeenStore _seenStoreOf(BuildContext context) =>
      _seenStore ??= StoriesSeenStore(
        Matrix.of(context).store,
        scope: Matrix.of(context).client.userID,
      );

  /// Контроллер ленты нужен [HorizontalMouseWheel]: без него вертикальное
  /// колесо мыши (Windows/Linux) над аватарками уходит родительскому списку
  /// чатов и лента «залипает» (остальные горизонтальные ряды списка чатов
  /// обёрнуты с LABA-2240, этот был пропущен).
  final ScrollController _scrollController = ScrollController();

  /// Подписка на Matrix-синхронизацию: лента обновляется сама при новых
  /// сторисах/протухании, без захода в чат и обратно.
  StreamSubscription? _syncSub;
  StreamSubscription? _presenceSub;
  Timer? _reloadDebounce;

  /// Кто сейчас онлайн -> с какого момента (для порядка «вышел — левее всех»).
  /// Наполняется из sync-presence без сети; уже онлайн на старте — по времени
  /// последней активности.
  final Map<String, DateTime> _onlineSince = {};

  /// Роли (ai → шестиугольник) грузятся асинхронно: без подписки тайл бота
  /// оставался круглым до следующей перезагрузки ленты.
  ValueNotifier<int>? _rolesVersion;

  /// Кому уже запрошена роль за жизнь ленты: префетч при старте берёт только
  /// DM-партнёров, а автор-бот сторис может им не быть. Запрос — один раз на
  /// id, иначе сбой сервера ролей повторялся бы на каждом sync.
  final Set<String> _rolesRequested = {};

  void _onRolesChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final client = Matrix.of(context).client;
      // Принять входящие инвайты в сторис-комнаты.
      await client.autoJoinStoryInvites();
      if (!mounted) return;
      await _loadActiveStories();
      if (!mounted) return;
      // Реагируем на каждый sync: подхватываем новые/протухшие сторисы
      // автоматически. Дебаунс 3с, чтобы не перезагружать на каждое мелкое
      // событие синхронизации.
      _syncSub = client.onSync.stream.listen((_) => _scheduleReload());
      _seedOnline(client);
      _presenceSub = client.onPresenceChanged.stream.listen(_onPresence);
      _rolesVersion = Matrix.of(context).userRoleService.rolesVersion
        ..addListener(_onRolesChanged);
    });
  }

  void _seedOnline(Client client) {
    // ignore: deprecated_member_use
    for (final p in client.presences.values) {
      if (p.presence == PresenceType.online) {
        _onlineSince.putIfAbsent(
          p.userid,
          () => p.lastActiveTimestamp ?? DateTime.now(),
        );
      }
    }
    if (_onlineSince.isNotEmpty && mounted) setState(() {});
  }

  void _onPresence(CachedPresence p) {
    if (!mounted) return;
    final wasOnline = _onlineSince.containsKey(p.userid);
    final isOnline = p.presence == PresenceType.online;
    if (isOnline == wasOnline) return;
    setState(() {
      if (isOnline) {
        _onlineSince[p.userid] = DateTime.now();
      } else {
        _onlineSince.remove(p.userid);
      }
    });
  }

  void _scheduleReload() {
    _reloadDebounce?.cancel();
    _reloadDebounce = Timer(const Duration(seconds: 3), () {
      if (mounted) _loadActiveStories();
    });
  }

  @override
  void dispose() {
    _syncSub?.cancel();
    _presenceSub?.cancel();
    _reloadDebounce?.cancel();
    _rolesVersion?.removeListener(_onRolesChanged);
    _scrollController.dispose();
    super.dispose();
  }

  /// Загружает активные сторисы для всех сторис-комнат и кеширует.
  Future<void> _loadActiveStories() async {
    if (!mounted) return;
    final client = Matrix.of(context).client;
    _seenStore?.invalidateCache();
    final deleted = DeletedStoriesStore(
      Matrix.of(context).store,
      scope: client.userID,
    );
    final rooms = client.storiesRooms;
    final result = <String, List<Event>>{};
    for (final room in rooms) {
      final events = await client.activeStoriesOf(room, deleted: deleted);
      if (!mounted) return;
      result[room.id] = events;
      ActiveStoriesProvider.instance.setRoomActive(
        room.id,
        client.storyOwnerOf(room),
        events,
      );
    }
    if (!mounted) return;
    final activity = await FrequentContactsCache.instance.refreshIfStale(
      client,
    );
    if (!mounted) return;
    setState(() {
      _activeByRoom
        ..clear()
        ..addAll(result);
      _dmActivity = activity;
      _dmCandidates = _collectDmCandidates(client);
    });
    _requestRoles([
      for (final room in rooms) ?client.storyOwnerOf(room),
      for (final d in _dmCandidates) d.userId,
    ]);
  }

  void _requestRoles(Iterable<String> userIds) {
    final fresh = userIds.where(_rolesRequested.add).toList();
    if (fresh.isEmpty) return;
    unawaited(
      Matrix.of(context).userRoleService.refreshIfStale(fresh).catchError((
        Object e,
      ) {
        // Повторить со следующей загрузкой ленты, а не никогда.
        _rolesRequested.removeAll(fresh);
        Logs().w('[StoriesBar] роли авторов не загружены', e);
      }),
    );
  }

  /// Личные чаты-кандидаты без сети: время — по последнему событию комнаты.
  List<DmActivity> _collectDmCandidates(Client client) => [
    for (final room in client.rooms)
      if (isFrequentContactCandidateRoom(room))
        DmActivity(
          userId: room.directChatMatrixID!,
          roomId: room.id,
          messageCount: 0,
          lastMessageTs: _liveLastTs(room),
        ),
  ];

  /// Время последнего сообщения комнаты из живого состояния SDK (обновляется
  /// каждым sync), а не из 10-минутного кэша активности.
  int _liveLastTs(Room room) =>
      room.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0;

  /// [DmActivity] с временем не старше живого последнего события комнаты.
  DmActivity _fresh(Client client, DmActivity d) {
    final room = client.getRoomById(d.roomId);
    final live = room == null ? 0 : _liveLastTs(room);
    if (live <= d.lastMessageTs) return d;
    return DmActivity(
      userId: d.userId,
      roomId: d.roomId,
      messageCount: d.messageCount,
      lastMessageTs: live,
    );
  }

  bool _isBot(MatrixState matrix, String userId) =>
      matrix.isBotOrAiUser(userId);

  Future<void> _addStory() async {
    final composer = await pickStoryMediaComposer(context);
    if (composer == null || !mounted) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => composer));
    if (mounted) await _loadActiveStories();
  }

  void _openViewer(String roomId) {
    final client = Matrix.of(context).client;
    final queue = ActiveStoriesProvider.instance.orderedRoomsWithActive(client);
    var start = queue.indexWhere((r) => r.id == roomId);
    final roomIds = start >= 0
        ? queue.map((r) => r.id).toList()
        : [roomId]; // кеш не прогрет - деградация до одного автора
    if (start < 0) start = 0;
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => StoryViewer(roomIds: roomIds, initialIndex: start),
          ),
        )
        .then((_) {
          // Перезагрузить после просмотра (кольцо seen/unseen обновится).
          if (mounted) _loadActiveStories();
        });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final client = Matrix.of(context).client;
    final seenStore = _seenStoreOf(context);
    final myRoom = client.myStoriesRoom;

    // Есть ли у меня активные сторисы (баг №3: кольцо и тап).
    final myActiveEvents = myRoom != null
        ? (_activeByRoom[myRoom.id] ?? const [])
        : const <Event>[];
    final hasMyActiveStories = myActiveEvents.isNotEmpty;

    // Кольцо моего тайла через единый предикат (Task 2/3, позиционная семантика).
    final myRing = myRoom == null
        ? StoryRingState.none
        : client.ringStateFromActive(myRoom, myActiveEvents, seenStore);

    // Комнаты с непустым кешем активных сторисов (кроме своей комнаты).
    // Категория 1: авторы сторис, свежая публикация — левее (боты наравне).
    final otherRooms = sortByLatestStory<Room>(
      client.storiesRooms
          .where((r) => r.id != myRoom?.id)
          .where((r) => (_activeByRoom[r.id]?.isNotEmpty) == true),
      latestTs: (r) => latestStoryTs(_activeByRoom[r.id] ?? const []),
      tiebreak: (r) => r.id,
    );

    // Категория 2 — онлайн (без ботов), 3 — остальные по последнему
    // сообщению в личке (боты считаются). Без дублей с вышестоящими.
    final matrix = Matrix.of(context);
    final shown = <String>{
      ?client.userID,
      for (final room in otherRooms) ?client.storyOwnerOf(room),
    };
    final online = rankOnlineContacts(
      _dmCandidates,
      onlineSince: _onlineSince,
      excludedUserIds: shown,
      isBot: (id) => _isBot(matrix, id),
    );
    final recentCutoff = DateTime.now()
        .subtract(frequentContactsWindow)
        .millisecondsSinceEpoch;
    final recent = rankRecentDialogs(
      [
        ..._dmActivity.map((d) => _fresh(client, d)),
        // Новый диалог/сообщение, которых ещё нет в 10-минутном кэше.
        ..._dmCandidates.where((d) => d.lastMessageTs >= recentCutoff),
      ],
      excludedUserIds: {...shown, for (final c in online) c.userId},
    );
    final onlineIds = {for (final c in online) c.userId};
    final frequent = [...online, ...recent];

    return SizedBox(
      height: StoriesBar.height,
      child: HorizontalMouseWheel(
        controller: _scrollController,
        child: ListView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          children: [
            _StoryTile(
              // Создание сторис доступно на ВСЕХ платформах, включая desktop и
              // web (прежний запрет "только смотреть" снят). Редактор режет
              // кадр под 9:16 на широком окне - см. storyFrameRect(maxAspect).
              showAdd: true,
              // Аватарка из синхронизированного стейта, без сетевого профиля:
              // не мерцает на авто-reload ленты и не обнуляется при сбое сети.
              // Кольцо рисует сам Avatar (storyRing) - та же модель, что везде,
              // концентрично и без рассинхрона размеров (бокс всегда avatarSize).
              avatar: Avatar(
                mxContent: client.myAvatarFromState(),
                name: client.userID?.localpart ?? client.userID,
                size: StoriesBar.avatarSize,
                isHexagonal:
                    client.userID != null && matrix.isAiUser(client.userID!),
                storyRing: myRing == StoryRingState.none ? null : myRing,
              ),
              // Баг №3: тап по аватарке-кольцу открывает просмотр если есть
              // сторисы, иначе добавление (на всех платформах).
              onTap: hasMyActiveStories && myRoom != null
                  ? () => _openViewer(myRoom.id)
                  : _addStory,
              // Кнопка-плюс ВСЕГДА открывает добавление.
              onAddPressed: _addStory,
            ),
            for (final room in otherRooms)
              Builder(
                builder: (context) {
                  final events = _activeByRoom[room.id] ?? const <Event>[];
                  // Баг №1: показываем аватарку/имя автора, а не имя комнаты
                  // "Stories". Источник — синхронизированный стейт (m.room.member
                  // автора → room.avatar), БЕЗ сетевого getProfileFromUserId,
                  // который падал M_INVALID_PARAM/таймаутом и обнулял аватарку
                  // в букву → «пропали все аватарки кроме моей».
                  //
                  // Истории канала (маркер com.liza.channel.stories_of в
                  // creation_content) — исключение: тайл должен показывать
                  // аватар/имя КАНАЛА, а не создателя служебной stories-комнаты
                  // (создатель — бот/сервисный аккаунт, не сам канал).
                  final channelId = room.channelIdOfStoriesRoom;
                  final channelRoom = channelId == null
                      ? null
                      : client.getRoomById(channelId);
                  final owner = client.storyOwnerOf(room);
                  final ring = client.ringStateFromActive(
                    room,
                    events,
                    seenStore,
                  );
                  return _StoryTile(
                    showAdd: false,
                    avatar: Avatar(
                      mxContent: channelRoom != null
                          ? channelRoom.avatar
                          : client.storyOwnerAvatar(room, owner),
                      name: channelRoom != null
                          ? channelRoom.getLocalizedDisplayname()
                          : client.storyOwnerName(room, owner),
                      size: StoriesBar.avatarSize,
                      // Бот — сотой, как везде (Роман 13.11); канал — круг.
                      isHexagonal:
                          channelRoom == null &&
                          owner != null &&
                          matrix.isAiUser(owner),
                      storyRing: ring == StoryRingState.none ? null : ring,
                    ),
                    onTap: () => _openViewer(room.id),
                    // Автор активной сторис тоже может быть онлайн: точка
                    // рисуется и у него (у каналов и ботов её нет).
                    onlineDotKey:
                        channelId == null &&
                            owner != null &&
                            _onlineSince.containsKey(owner) &&
                            !_isBot(matrix, owner)
                        ? ValueKey('onlineDot:$owner')
                        : null,
                  );
                },
              ),
            for (final contact in frequent)
              _FrequentContactTile(
                key: ValueKey('frequentContact:${contact.userId}'),
                contact: contact,
                online: onlineIds.contains(contact.userId),
              ),
          ],
        ),
      ),
    );
  }
}

/// Тайл частого собеседника: аватар без кольца, зелёная точка «в сети» только
/// у категории «онлайн» (Надежда 05.11 — иначе порядок не проверить), тап — его личный чат. Аватар и имя — из
/// member-стейта DM без сетевого профиля (тот же источник, что у авторов,
/// RL-stories-bar-avatar).
class _FrequentContactTile extends StatelessWidget {
  const _FrequentContactTile({
    super.key,
    required this.contact,
    required this.online,
  });

  final DmActivity contact;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final room = client.getRoomById(contact.roomId);
    final name = room == null
        ? contact.userId.localpart ?? contact.userId
        : client.storyOwnerName(room, contact.userId) ?? contact.userId;
    return Semantics(
      button: true,
      label: L10n.of(context).storiesBarOpenChatWith(name),
      excludeSemantics: true,
      child: _StoryTile(
        showAdd: false,
        avatar: Avatar(
          mxContent: room == null
              ? null
              : client.storyOwnerAvatar(room, contact.userId),
          name: name,
          size: StoriesBar.avatarSize,
          isHexagonal: Matrix.of(context).isAiUser(contact.userId),
        ),
        onTap: () => context.go('/rooms/${contact.roomId}'),
        onlineDotKey: online ? ValueKey('onlineDot:${contact.userId}') : null,
      ),
    );
  }
}

class _StoryTile extends StatelessWidget {
  const _StoryTile({
    required this.avatar,
    required this.onTap,
    required this.showAdd,
    this.onAddPressed,
    this.onlineDotKey,
  });

  /// Не null — рисуем зелёную точку «в сети» (ключ нужен стражу).
  final Key? onlineDotKey;

  /// Аватарка уже с кольцом (Avatar.storyRing) - концентрично, бокс avatarSize.
  final Widget avatar;

  /// Null - тайл неактивен (сейчас не используется: создание доступно на всех
  /// платформах, поэтому тап всегда ведёт в просмотр или в добавление).
  final VoidCallback? onTap;
  final bool showAdd;

  /// Колбэк кнопки-плюс. Если null и showAdd=true - используется onTap.
  final VoidCallback? onAddPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          alignment: Alignment.bottomRight,
          children: [
            avatar,
            if (onlineDotKey != null)
              Positioned(
                right: 2,
                bottom: 2,
                child: OnlineDot(key: onlineDotKey, size: 16),
              ),
            if (showAdd)
              SizedBox(
                width: 24,
                height: 24,
                child: FloatingActionButton.small(
                  heroTag: null,
                  onPressed: onAddPressed ?? onTap,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.add_outlined, size: 16),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
