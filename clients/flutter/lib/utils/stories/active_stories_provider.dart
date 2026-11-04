import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/story_avatar_ring.dart';
import 'stories_bar_order.dart';
import 'stories_extension.dart';
import 'stories_seen_store.dart';

/// Глобальный sync-кеш активных сторисов: roomId -> (ownerUserId, активные
/// события). Наполняется StoriesBar по sync; аватарки во всех местах читают
/// состояние кольца синхронно (matrix-sdk не отдаёт room.timeline синхронно,
/// грузить getTimeline на каждый рендер аватарки в списке чатов нельзя).
class ActiveStoriesProvider extends ChangeNotifier {
  ActiveStoriesProvider._();
  static final ActiveStoriesProvider instance = ActiveStoriesProvider._();

  final Map<String, String?> _ownerByRoom = {};
  final Map<String, List<Event>> _activeByRoom = {};

  void setRoomActive(String roomId, String? ownerUserId, List<Event> active) {
    _ownerByRoom[roomId] = ownerUserId;
    _activeByRoom[roomId] = active;
    notifyListeners();
  }

  void clear() {
    _ownerByRoom.clear();
    _activeByRoom.clear();
    notifyListeners();
  }

  /// Очередь авторов для viewer: мой room первым (если есть активные),
  /// далее чужие с непустыми активными — свежая публикация левее.
  /// Единый источник порядка для StoriesBar и StoryViewer.
  List<Room> orderedRoomsWithActive(Client client) {
    bool hasActive(Room r) => (_activeByRoom[r.id]?.isNotEmpty) == true;
    final my = client.myStoriesRoom;
    return [
      if (my != null && hasActive(my)) my,
      ...sortByLatestStory<Room>(
        client.storiesRooms.where((r) => r.id != my?.id).where(hasActive),
        latestTs: (r) => latestStoryTs(_activeByRoom[r.id] ?? const []),
        tiebreak: (r) => r.id,
      ),
    ];
  }

  /// Состояние кольца для userId (синхронно). none, если нет данных.
  StoryRingState ringForUser(
    String userId,
    Client client,
    StoriesSeenStore seen,
  ) {
    for (final entry in _ownerByRoom.entries) {
      if (entry.value != userId) continue;
      final room = client.getRoomById(entry.key);
      if (room == null) return StoryRingState.none;
      final active = _activeByRoom[entry.key] ?? const <Event>[];
      return client.ringStateFromActive(room, active, seen);
    }
    return StoryRingState.none;
  }
}
