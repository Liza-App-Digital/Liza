import 'package:liza/utils/push_contract_frame.dart';
import 'package:liza/utils/confirmed_read_state.dart';
import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/utils/news_audience.dart';
import 'package:liza/utils/unseen_messages.dart';

class UnreadBubble extends StatelessWidget {
  final Room room;
  final String surface;
  const UnreadBubble({
    required this.room,
    this.surface = 'room_list',
    super.key,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ConfirmedReadState.forClient(room.client).revision,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    // Хвост — пост Liza News для других платформ: серверный счётчик вырос, но
    // на этом устройстве читать нечего (см. hasNewsAudienceHiddenTail).
    final newsHiddenTail = room.hasNewsAudienceHiddenTail;
    final unread = room.isUnread && !newsHiddenTail;
    final hasNotifications = room.notificationCount > 0 && !newsHiddenTail;
    // Порядковый hasUnseenMessages, а не SDK-hasNewMessages: тот сравнивает ts
    // КВИТАНЦИИ с ts события и залипает точкой у прочитанной комнаты.
    final hasNewMessages = room.hasUnseenMessages && !newsHiddenTail;
    final displayCount = hasNotifications ? room.notificationCount : null;
    final unreadBubbleSize = unread || hasNewMessages
        ? room.notificationCount > 0
              ? 20.0
              : 14.0
        : 0.0;
    return PushContractFrame.row(
      room,
      surface,
      displayCount ?? 0,
      unreadBubbleSize > 0,
      AnimatedContainer(
        duration: LizaThemes.animationDuration,
        curve: LizaThemes.animationCurve,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        height: unreadBubbleSize,
        width: !hasNotifications && !unread && !hasNewMessages
            ? 0
            : (unreadBubbleSize - 9) *
                      room.notificationCount.toString().length +
                  9,
        decoration: BoxDecoration(
          color: room.highlightCount > 0
              ? theme.colorScheme.error
              : hasNotifications || room.markedUnread
              ? theme.colorScheme.primary
              : theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(7),
        ),
        child: displayCount != null
            ? Text(
                displayCount.toString(),
                style: TextStyle(
                  color: room.highlightCount > 0
                      ? theme.colorScheme.onError
                      : hasNotifications
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onPrimaryContainer,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              )
            : const SizedBox.shrink(),
      ),
    );
  }
}
