import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/story_avatar_ring.dart';
import '../channel_stories.dart';
import '../chat_topology.dart';
import '../monitoring.dart';
import 'deleted_stories_store.dart';
import 'stories_seen_store.dart';
import 'story_model.dart';
import 'story_seen_logic.dart';

/// Стейт-ключ на комнате-канале, хранящий id её сторис-комнаты (idempotency
/// для [StoriesExtension.ensureChannelStoriesRoom]).
const String channelStoriesStateKey = 'com.liza.channel.stories';

/// LABA-1970: имя (единственный path-сегмент) override-правила пуша на
/// публикацию сторис для комнаты [storyRoomId]. Полный rule_id на сервере —
/// `global/override/` + это имя; клиентский `setPushRuleEnabled` шлёт только имя.
///
/// Формат ОБЯЗАН совпадать с серверным
/// (`servers/synapse/modules/stories_membership/_logic.py:story_notify_rule_name`):
/// `com.liza.story_notify.{roomId}`. Разделитель — точка, НЕ слэш: сегмент не
/// должен содержать `/`, иначе URL push-rule распадётся и тумблер не найдёт
/// правило. Чистая функция — под юнит-страж контракта клиент↔сервер.
String storyNotifyRuleName(String storyRoomId) =>
    'com.liza.story_notify.$storyRoomId';

/// power_levels личной сторис-комнаты пользователя ([ensureMyStoriesRoom]).
///
/// Порог `com.liza.chat.topology: 100` — своя защита комнаты (только
/// владелец может скрыть/раскрыть топологию). Шаблонные пороги переносим
/// явно — см. [synapseDefaultEventPowerLevels]: Synapse применяет override
/// через shallow-merge, ключ `events` иначе стирается целиком, и
/// state_default:50 открывает `m.room.power_levels` кому угодно с PL 50.
Map<String, Object?> myStoriesRoomPowerLevelOverride() => {
  'events': {...synapseDefaultEventPowerLevels, 'com.liza.chat.topology': 100},
};

/// power_levels сторис-комнаты КАНАЛА ([ensureChannelStoriesRoom]).
///
/// `events_default: 100` — постить сторис может только админ канала (как и
/// в самом канале). `com.liza.chat.topology: 100` — своя защита комнаты.
/// Шаблонные пороги переносим явно — см. [synapseDefaultEventPowerLevels]
/// (то же обоснование, что у [myStoriesRoomPowerLevelOverride]).
Map<String, Object?> channelStoriesRoomPowerLevelOverride() => {
  'events_default': 100,
  'events': {...synapseDefaultEventPowerLevels, 'com.liza.chat.topology': 100},
};

/// Нужно ли догружать ещё историю сторис-комнаты. Останавливаемся, когда
/// самое старое загруженное событие стало старше [cutoffTs] (за ним активных
/// сторис заведомо нет: TTL фиксирован 24ч, timeline упорядочен по времени),
/// либо кончилась история, либо достигнут cap [maxPages]. Null oldestLoadedTs
/// (пустой timeline) - тоже стоп.
bool shouldRequestMoreStoryHistory({
  required int? oldestLoadedTs,
  required int cutoffTs,
  required bool canRequestHistory,
  required int pagesLoaded,
  required int maxPages,
}) {
  if (oldestLoadedTs == null) return false;
  if (!canRequestHistory) return false;
  if (pagesLoaded >= maxPages) return false;
  return oldestLoadedTs >= cutoffTs;
}

/// Показывать ли событие сегментом сторис. Удалённое отсекается ЯВНО
/// (`redacted` + список удалённых автором, [DeletedStoriesStore]), а не только
/// косвенно через пустой content: LABA-2618 — копия в локальной БД «ожила» с
/// полным content, проходила фильтр, и автор удалял её снова и снова.
bool isActiveStoryEvent(
  Event event, {
  required int nowMs,
  Set<String> deletedIds = const {},
}) {
  if (event.type != EventTypes.Message) return false;
  if (event.redacted || deletedIds.contains(event.eventId)) return false;
  final story = StoryContent.fromContent(event.content);
  return story != null && storyIsActive(story, nowMs);
}

/// Удалённая автором сторис, у которой в локальной БД НЕТ следа редакции —
/// ровно то состояние, из-за которого она возвращалась (LABA-2618).
bool isResurrectedStoryEvent(Event event, Set<String> deletedIds) =>
    deletedIds.contains(event.eventId) &&
    !event.redacted &&
    StoryContent.fromContent(event.content) != null;

/// Датчик `[stories-resurrected]`: один warning на eventId за процесс. Корень
/// LABA-2618 не установлен — фильтр по списку удалённых лечит симптом, а этот
/// сигнал сохраняет улику (платформа и статус события; без id — PII).
final Set<String> _reportedResurrected = {};

@visibleForTesting
void resetResurrectedStoryReports() => _reportedResurrected.clear();

@visibleForTesting
void Function(String message) reportResurrectedStory =
    Monitoring.captureMessage;

void _reportIfResurrected(Event event, Set<String> deletedIds) {
  if (!isResurrectedStoryEvent(event, deletedIds)) return;
  if (!_reportedResurrected.add(event.eventId)) return;
  Logs().w('Удалённая сторис вернулась в локальную БД: ${event.eventId}');
  reportResurrectedStory(
    '[stories-resurrected] web=$kIsWeb status=${event.status.name}',
  );
}

extension StoriesExtension on Client {
  static const String storiesTag = 'com.liza.stories';

  /// Комната пользователя для публикации сторисов (помечена account-data тегом).
  Room? get myStoriesRoom {
    final data = accountData[storiesTag]?.content;
    final roomId = data?.tryGet<String>('room_id');
    if (roomId == null) return null;
    return getRoomById(roomId);
  }

  /// Все комнаты сторисов, в которых пользователь состоит.
  List<Room> get storiesRooms => rooms
      .where(
        (r) => r.membership == Membership.join && r.lizaChatType == 'stories',
      )
      .toList();

  /// Окно таймлайна для поиска активных сторисов. Больше SDK-дефолта
  /// (Room.defaultHistoryCount = 30): сторис-комната может накопить много
  /// не-сторис событий (redaction, join/leave и т.п.) между двумя открытиями
  /// приложения, и дефолтное окно вытесняет ещё не истёкший сториc за
  /// пределы видимости, хотя expires_ts в БД остаётся корректным.
  static const int _activeStoriesTimelineLimit = 200;

  /// Активные сторисы + Timeline комнаты (нужен для реакций/агрегации).
  /// Вызывающий обязан позвать timeline.cancelSubscriptions(), когда закончит.
  /// Null при membership != join или ошибке загрузки таймлайна.
  /// [deleted] — сторис, удалённые автором с этого устройства; отсекаются,
  /// даже если редакция не применилась к локальной копии.
  Future<(Timeline, List<Event>)?> activeStoriesWithTimeline(
    Room room, {
    DeletedStoriesStore? deleted,
  }) async {
    // Комнаты с membership != join (invite, leave) не имеют доступного таймлайна.
    if (room.membership != Membership.join) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    // Активная сторис создана не раньше now-24ч; запас 1ч на рассинхрон часов
    // устройств. Старше cutoff активных сторис заведомо нет.
    const ttlMs = 86400000;
    const clockSkewMs = 3600000;
    final cutoff = now - ttlMs - clockSkewMs;
    final Timeline timeline;
    try {
      timeline = await room.getTimeline(limit: _activeStoriesTimelineLimit);
    } catch (e, s) {
      Logs().w(
        'activeStoriesWithTimeline: getTimeline failed for ${room.id}',
        e,
        s,
      );
      return null;
    }
    // Догружаем историю, пока не дойдём до события старше cutoff. Догрузку
    // фильтруем только по m.room.message: member/redaction-шум не занимает
    // страницы, до сторис добираемся за 1-2 итерации даже при длинном хвосте.
    const maxPages = 5;
    final historyFilter = StateFilter(types: const [EventTypes.Message]);
    var pages = 0;
    while (shouldRequestMoreStoryHistory(
      oldestLoadedTs: timeline.events.isEmpty
          ? null
          : timeline.events.last.originServerTs.millisecondsSinceEpoch,
      cutoffTs: cutoff,
      canRequestHistory: timeline.canRequestHistory,
      pagesLoaded: pages,
      maxPages: maxPages,
    )) {
      try {
        // Именно timeline.requestHistory (не room.requestHistory): пополняет
        // ТОТ открытый timeline-объект, чьи events читает цикл. filter
        // ограничивает догрузку сообщениями.
        await timeline.requestHistory(
          historyCount: _activeStoriesTimelineLimit,
          filter: historyFilter,
        );
      } catch (e, s) {
        Logs().w(
          'activeStoriesWithTimeline: requestHistory failed for ${room.id}',
          e,
          s,
        );
        break;
      }
      pages++;
    }
    if (pages >= maxPages &&
        timeline.events.isNotEmpty &&
        timeline.events.last.originServerTs.millisecondsSinceEpoch >= cutoff) {
      // Упёрлись в cap, не дойдя до границы: активная сторис могла остаться
      // недогруженной. Не молчим (e2e-дисциплина: не маскировать неполноту).
      Logs().w(
        'activeStoriesWithTimeline: hit maxPages cap for ${room.id}, '
        'active story may be missing',
      );
    }
    final deletedIds = deleted?.ids ?? const <String>{};
    final settledIds = deleted?.settledIds ?? const <String>{};
    for (final e in timeline.events) {
      _reportIfResurrected(e, settledIds);
    }
    final result = timeline.events
        .where((e) => isActiveStoryEvent(e, nowMs: now, deletedIds: deletedIds))
        .toList();
    result.sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
    return (timeline, result);
  }

  /// Активные события-сторисы в комнате (не истёкшие), по возрастанию времени.
  /// Загружает таймлайн при необходимости.
  Future<List<Event>> activeStoriesOf(
    Room room, {
    DeletedStoriesStore? deleted,
  }) async {
    final loaded = await activeStoriesWithTimeline(room, deleted: deleted);
    if (loaded == null) return const [];
    loaded.$1.cancelSubscriptions();
    return loaded.$2;
  }

  /// Найти или создать сторис-комнату пользователя (идемпотентно).
  Future<Room> ensureMyStoriesRoom() async {
    final existing = myStoriesRoom;
    if (existing != null) return existing;

    final roomId = await createRoom(
      // Имя уникально по localpart владельца (было хардкожено 'Stories' у
      // всех - неразличимо в админке/логах). UI никогда не читает
      // room.name (см. storyOwnerOf ниже), формат ориентирован на
      // диагностику, не на конечного пользователя.
      name: 'Stories - ${userID!.localpart}',
      preset: CreateRoomPreset.privateChat,
      creationContent: {
        'com.liza.stories': true,
        'com.liza.chat.type': 'stories',
      },
      visibility: Visibility.private,
      powerLevelContentOverride: myStoriesRoomPowerLevelOverride(),
      // ИНВАРИАНТ: сторис-комната НИКОГДА не E2EE (нет m.room.encryption в
      // initialState). Иначе видео-сторис пойдёт по download-в-RAM пути
      // EventVideoPlayer → OOM на крупном ролике. Non-E2EE — осознанно, ради
      // прогрессивного стриминга видео.
      initialState: [
        StateEvent(type: 'com.liza.chat.topology', content: {'hidden': true}),
      ],
    );
    await setAccountData(userID!, storiesTag, {'room_id': roomId});
    final room = getRoomById(roomId);
    if (room == null) {
      await waitForRoomInSync(roomId);
    }
    final createdRoom = getRoomById(roomId)!;
    try {
      await createdRoom.setPushRuleState(PushRuleState.dontNotify);
    } catch (e, s) {
      Logs().w('Не удалось замьютить сторис-комнату', e, s);
    }
    return createdRoom;
  }

  /// Найти или создать сторис-комнату КАНАЛА (идемпотентно). Идемпотентность
  /// через стейт `com.liza.channel.stories` в самой комнате-канале (а не
  /// account-data владельца, как у личных историй, — канал общий для админов).
  ///
  /// creationContent несёт маркер `com.liza.channel.stories_of` РОВНО в
  /// формате `{'channel_id': channelId}` — серверный модуль channel_stories
  /// матчит create-событие по этому маркеру и пишет маппинг channel→stories-
  /// комната; другой формат = раздача навсегда no-op. `com.liza.stories:true`
  /// обязателен отдельно от `com.liza.chat.type` — по нему серверный
  /// expiry-cleanup находит комнаты с истекающими историями.
  Future<Room> ensureChannelStoriesRoom(String channelId) async {
    final channel = getRoomById(channelId);
    if (channel == null) {
      throw StateError('ensureChannelStoriesRoom: канал $channelId не найден');
    }
    final existingRoomId = channel
        .getState(channelStoriesStateKey)
        ?.content
        .tryGet<String>('room_id');
    if (existingRoomId != null) {
      final existingRoom = getRoomById(existingRoomId);
      if (existingRoom != null) return existingRoom;
    }

    final roomId = await createRoom(
      name: 'Stories - $channelId',
      preset: CreateRoomPreset.privateChat,
      creationContent: {
        'com.liza.chat.type': 'stories',
        'com.liza.stories': true,
        channelStoriesOfKey: {'channel_id': channelId},
      },
      visibility: Visibility.private,
      powerLevelContentOverride: channelStoriesRoomPowerLevelOverride(),
      initialState: [
        StateEvent(type: 'com.liza.chat.topology', content: {'hidden': true}),
      ],
    );
    await setRoomStateWithKey(channel.id, channelStoriesStateKey, '', {
      'room_id': roomId,
    });
    var room = getRoomById(roomId);
    if (room == null) {
      await waitForRoomInSync(roomId);
      room = getRoomById(roomId);
    }
    final createdRoom = room!;
    try {
      await createdRoom.setPushRuleState(PushRuleState.dontNotify);
    } catch (e, s) {
      Logs().w('Не удалось замьютить сторис-комнату канала', e, s);
    }
    return createdRoom;
  }

  /// Автоматически принять входящие инвайты в сторис-комнаты.
  Future<void> autoJoinStoryInvites() async {
    for (final room in rooms) {
      if (room.membership != Membership.invite) continue;
      final isStories = room.lizaChatType == 'stories';
      if (isStories) {
        await room.join();
        try {
          await room.setPushRuleState(PushRuleState.dontNotify);
        } catch (e, s) {
          Logs().w('Не удалось замьютить сторис-комнату после join', e, s);
        }
      }
    }
  }

  /// Владелец сторис-комнаты = создатель (m.room.create sender). Сторис-
  /// комната называется "Stories", поэтому для тайла нужен профиль автора,
  /// а не имя комнаты.
  ///
  /// Баг (клик по своему кольцу открывал чужую историю): если я — creator
  /// (моя собственная сторис-комната), раньше код всё равно проваливался в
  /// фоллбэк "первый join-участник кроме меня" и мог вернуть ЧУЖОЙ id, если
  /// в моей комнате оказался ещё один участник. Теперь creator == userID
  /// возвращается СРАЗУ, без похода в getParticipants.
  String? storyOwnerOf(Room room) {
    final creator = room.getState(EventTypes.RoomCreate)?.senderId;
    if (creator != null) return creator;
    // Фоллбэк только если состояние создателя ещё не догружено (creator ==
    // null): первый join-участник, кроме меня.
    final others = room
        .getParticipants([Membership.join])
        .where((u) => u.id != userID)
        .map((u) => u.id)
        .toList();
    return others.isNotEmpty ? others.first : null;
  }

  // TEST-INVARIANT[RL-stories-bar-avatar]: аватарки авторов в верхней
  // сторис-ленте показаны (не буквы) для всех, включая федеративных авторов —
  // источник синхронный (member-стейт → room.avatar), сбой сети не обнуляет.
  // Эталон: tests/screenshots/stories-bar-avatar/.
  /// Аватарка автора сторис-ленты ИЗ УЖЕ СИНХРОНИЗИРОВАННОГО стейта комнаты,
  /// БЕЗ сетевого `getProfileFromUserId`.
  ///
  /// Почему так (регрессия «пропали все аватарки кроме моей в верхней строке»):
  /// `getProfileFromUserId` для федеративных/невалидных id падает
  /// `M_INVALID_PARAM`/`M_UNKNOWN`/таймаутом (в логах — 142 провала за сессию) и
  /// возвращает `Profile(avatarUrl: null)` → аватарка обнуляется в букву. Своя
  /// (id всегда валиден и закеширован) выживает — отсюда «кроме моей». avatar_url
  /// автора уже лежит в его `m.room.member` (lazy-load), фоллбэк — аватар комнаты.
  Uri? storyOwnerAvatar(Room room, [String? owner]) {
    owner ??= storyOwnerOf(room);
    if (owner != null) {
      final url = room
          .getState(EventTypes.RoomMember, owner)
          ?.asUser(room)
          .avatarUrl;
      if (url != null) return url;
    }
    return room.avatar;
  }

  /// Имя автора сторис-ленты из синхронизированного стейта (без сети). Нужно
  /// только для буквы-плейсхолдера, когда аватарки нет.
  String? storyOwnerName(Room room, [String? owner]) {
    owner ??= storyOwnerOf(room);
    if (owner == null) return null;
    final dn = room
        .getState(EventTypes.RoomMember, owner)
        ?.asUser(room)
        .displayName;
    return (dn != null && dn.isNotEmpty) ? dn : owner.localpart;
  }

  /// Моя аватарка из синхронизированного стейта (member-событие в моей
  /// сторис-комнате, иначе в любой комнате) — без сетевого профиля и без
  /// мерцания на авто-reload ленты. Фоллбэк — null (Avatar отрисует букву).
  Uri? myAvatarFromState() {
    final myId = userID;
    if (myId == null) return null;
    final myRoom = myStoriesRoom;
    if (myRoom != null) {
      final url = myRoom
          .getState(EventTypes.RoomMember, myId)
          ?.asUser(myRoom)
          .avatarUrl;
      if (url != null) return url;
    }
    for (final room in rooms) {
      final url = room
          .getState(EventTypes.RoomMember, myId)
          ?.asUser(room)
          .avatarUrl;
      if (url != null) return url;
    }
    return null;
  }

  /// Данные последнего receipt из глобального и main-таймлайна, максимум по ts.
  LatestReceiptStateData? _mergedReceipt(
    LatestReceiptStateData? a,
    LatestReceiptStateData? b,
  ) {
    if (a == null) return b;
    if (b == null) return a;
    return a.ts >= b.ts ? a : b;
  }

  /// Индекс сегмента, покрытого МОИМ receipt (private или public), или -1.
  int myReceiptIndexIn(Room room, List<Event> segments) {
    final state = room.receiptState;
    final own = _mergedReceipt(
      state.global.latestOwnReceipt,
      state.mainThread?.latestOwnReceipt,
    );
    return indexOfEvent(segments.map((e) => e.eventId).toList(), own?.eventId);
  }

  /// userId -> eventId последнего receipt зрителя (максимум по ts из
  /// глобального и main-таймлайна). Позицию относительно сегментов считает
  /// [viewsCountInTimeline].
  Map<String, String> viewerReceiptEventIds(Room room) {
    final state = room.receiptState;
    final merged = <String, LatestReceiptStateData>{};
    for (final source in [
      state.global.otherUsers,
      state.mainThread?.otherUsers ?? const <String, LatestReceiptStateData>{},
    ]) {
      for (final entry in source.entries) {
        merged[entry.key] = _mergedReceipt(merged[entry.key], entry.value)!;
      }
    }
    return merged.map((userId, data) => MapEntry(userId, data.eventId));
  }

  /// Состояние кольца: unseen, если есть активный сегмент и не покрытый
  /// моим receipt, и не отмеченный локально (позиционная семантика).
  StoryRingState ringStateFromActive(
    Room room,
    List<Event> activeEvents,
    StoriesSeenStore seen,
  ) {
    if (activeEvents.isEmpty) return StoryRingState.none;
    final unseen = hasUnseenPositional(
      segmentIds: activeEvents.map((e) => e.eventId).toList(),
      receiptIndex: myReceiptIndexIn(room, activeEvents),
      isLocallySeen: seen.isSeen,
    );
    return unseen ? StoryRingState.unseen : StoryRingState.seen;
  }

  /// Сторис-комната, где [userId] — автор (storyOwnerOf). Кеш userId→roomId,
  /// чтобы не сканировать комнаты на каждый рендер аватарки.
  Room? storiesRoomOfUser(String userId) {
    for (final room in storiesRooms) {
      if (storyOwnerOf(room) == userId) return room;
    }
    return null;
  }

  /// Опубликовать новый сторис (медиафайл + оверлеи + опциональная подпись).
  /// [targetRoom] — куда публиковать; по умолчанию личная сторис-комната
  /// автора (создаётся при необходимости). Публикация от имени канала
  /// передаёт сюда результат [ensureChannelStoriesRoom] (см. [publishChannelStory]).
  Future<void> publishStory({
    required MatrixFile file,
    MatrixImageFile? thumbnail,
    required List<StoryOverlay> overlays,
    String? caption,
    StoryMedia? media,
    int ttlMs = 86400000,
    Room? targetRoom,
  }) async {
    final room = targetRoom ?? await ensureMyStoriesRoom();
    final expiresTs = DateTime.now().millisecondsSinceEpoch + ttlMs;
    await room.sendFileEvent(
      file,
      thumbnail: thumbnail,
      extraContent: {
        // fallback body для старых клиентов/превью — «Story», а не имя файла ОС.
        'body': 'Story',
        storyContentKey: StoryContent(
          expiresTs: expiresTs,
          overlays: overlays,
          caption: caption,
          media: media,
        ).toJson(),
      },
    );
  }

  /// Опубликовать сторис от имени КАНАЛА: находит/создаёт stories-комнату
  /// канала ([ensureChannelStoriesRoom]) и публикует в неё ([publishStory]).
  /// Вызывающий обязан проверить право публикации (PL>=100 в канале) ДО
  /// вызова — здесь прав не проверяем (сервер обеспечит через
  /// events_default:100 в powerLevelContentOverride сторис-комнаты).
  Future<void> publishChannelStory({
    required String channelId,
    required MatrixFile file,
    MatrixImageFile? thumbnail,
    required List<StoryOverlay> overlays,
    String? caption,
    StoryMedia? media,
    int ttlMs = 86400000,
  }) async {
    final room = await ensureChannelStoriesRoom(channelId);
    await publishStory(
      file: file,
      thumbnail: thumbnail,
      overlays: overlays,
      caption: caption,
      media: media,
      ttlMs: ttlMs,
      targetRoom: room,
    );
  }

  /// Удалить событие-сторис. Только своё (вызывающий проверяет владельца).
  ///
  /// Битая сторис (медиа не догрузилось / send упал) остаётся в таймлайне как
  /// локальный echo со status error/sending и eventId = локальный txn-id, а не
  /// серверный `$...`. redactEvent для него уходит на сервер с несуществующим
  /// id → 404 → удаление молча падает. Для несинхронизированного события
  /// правильный примитив — cancelSend (убирает локальный echo из БД/timeline).
  ///
  /// Уже удалённую (redacted или в [deleted]) повторно НЕ редактируем —
  /// LABA-2618: «ожившая» копия давала новый PUT redact на каждое удаление.
  /// В [deleted] id попадает только после успешного PUT: упавшее удаление
  /// должно оставаться доступным для повтора.
  Future<void> deleteStory(Event event, {DeletedStoriesStore? deleted}) async {
    if (!event.status.isSent) return event.cancelSend();
    if (isStoryAlreadyDeleted(event, deleted)) return;
    await event.redactEvent();
    try {
      await deleted?.add(event.eventId);
    } catch (e, s) {
      // На сервере сторис уже удалена — показывать «не удалось» нельзя.
      // Без записи остаётся только косвенный фильтр (пустой content).
      Logs().w('Не удалось запомнить удалённую сторис', e, s);
    }
  }

  bool isStoryAlreadyDeleted(Event event, DeletedStoriesStore? deleted) =>
      event.redacted || (deleted?.contains(event.eventId) ?? false);
}
