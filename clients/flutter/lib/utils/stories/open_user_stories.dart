import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import '../../pages/stories/story_viewer.dart';
import '../../widgets/matrix.dart';
import 'active_stories_provider.dart';
import 'deleted_stories_store.dart';
import 'stories_extension.dart';
import 'story_model.dart';

/// Открыть сторис-просмотрщик для [userId], если у пользователя есть
/// сторис-комната. Используется тапом по аватарке с активным кольцом в
/// списке чатов, деталях, участниках и диалогах. Если комнаты нет - no-op.
void openUserStories(BuildContext context, String userId) {
  final client = Matrix.of(context).client;
  // Клик на себя - идём напрямую в myStoriesRoom, не полагаясь на
  // storiesRoomOfUser/storyOwnerOf (баг: открывалась чужая история).
  final room = userId == client.userID
      ? client.myStoriesRoom
      : client.storiesRoomOfUser(userId);
  if (room == null) return;
  final queue = ActiveStoriesProvider.instance.orderedRoomsWithActive(client);
  var start = queue.indexWhere((r) => r.id == room.id);
  final roomIds = start >= 0
      ? queue.map((r) => r.id).toList()
      : [room.id]; // кеш не прогрет - деградация до одного автора
  if (start < 0) start = 0;
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => StoryViewer(roomIds: roomIds, initialIndex: start),
    ),
  );
}

/// Открыть сегмент по ссылке/карточке. Комнаты нет (не участник) или сегмент
/// протух/удалён - снэкбар "История недоступна".
Future<void> openStoryByRef(BuildContext context, StoryRef ref) async {
  final client = Matrix.of(context).client;
  final messenger = ScaffoldMessenger.of(context);
  final l10n = L10n.of(context);
  final room = client.getRoomById(ref.roomId);
  if (room != null) {
    final active = await client.activeStoriesOf(
      room,
      deleted: DeletedStoriesStore(
        Matrix.of(context).store,
        scope: client.userID,
      ),
    );
    final alive = active.any((e) => e.eventId == ref.eventId);
    if (alive && context.mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              StoryViewer(roomIds: [room.id], initialEventId: ref.eventId),
        ),
      );
      return;
    }
  }
  messenger.showSnackBar(SnackBar(content: Text(l10n.storyUnavailable)));
}
