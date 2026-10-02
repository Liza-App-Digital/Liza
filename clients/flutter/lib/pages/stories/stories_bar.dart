import 'dart:async';

import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

import '../../utils/channel_stories.dart';
import '../../utils/stories/active_stories_provider.dart';
import '../../utils/stories/deleted_stories_store.dart';
import '../../utils/stories/stories_extension.dart';
import '../../utils/stories/stories_seen_store.dart';
import '../../utils/stories/story_media_picker.dart';
import '../../widgets/avatar.dart';
import '../../widgets/matrix.dart';
import '../../widgets/story_avatar_ring.dart';
import 'story_viewer.dart';

/// Горизонтальная лента сторисов (первый элемент: "Мой сторис [+]").
/// Заменяет presence-ленту StatusMessageList в chat_list_body.
class StoriesBar extends StatefulWidget {
  const StoriesBar({super.key});

  /// Высота виджета: аватарка 76px + ring ~4px + ListView padding vertical:8 = ~92px.
  /// Было 116 когда под аватарками были подписи; подписи убраны, зазор уменьшен.
  static const double height = 96;

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar> {
  /// Кеш активных сторисов: roomId -> список Event.
  /// Заполняется асинхронно, build читает синхронно.
  final Map<String, List<Event>> _activeByRoom = {};

  /// Ленивый singleton для текущего State-цикла.
  /// Инициализируется при первом вызове build, не пересоздаётся при перестройках.
  StoriesSeenStore? _seenStore;
  StoriesSeenStore _seenStoreOf(BuildContext context) =>
      _seenStore ??= StoriesSeenStore(
        Matrix.of(context).store,
        scope: Matrix.of(context).client.userID,
      );

  /// Подписка на Matrix-синхронизацию: лента обновляется сама при новых
  /// сторисах/протухании, без захода в чат и обратно.
  StreamSubscription? _syncSub;
  Timer? _reloadDebounce;

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
    _reloadDebounce?.cancel();
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
    setState(() {
      _activeByRoom
        ..clear()
        ..addAll(result);
    });
  }

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
    final otherRooms = client.storiesRooms
        .where((r) => r.id != myRoom?.id)
        .where((r) => (_activeByRoom[r.id]?.isNotEmpty) == true)
        .toList();

    return SizedBox(
      height: StoriesBar.height,
      child: ListView(
        scrollDirection: Axis.horizontal,
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
            // концентрично и без рассинхрона размеров (бокс всегда 76).
            avatar: Avatar(
              mxContent: client.myAvatarFromState(),
              name: client.userID?.localpart ?? client.userID,
              size: 76,
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
                    size: 76,
                    storyRing: ring == StoryRingState.none ? null : ring,
                  ),
                  onTap: () => _openViewer(room.id),
                );
              },
            ),
        ],
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
  });

  /// Аватарка уже с кольцом (Avatar.storyRing) - концентрично, бокс 76.
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
