import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/unread_bubble.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/avatar.dart';

/// Ширина колонки аватарок, до которой сворачивается список чатов рядом с
/// широкой панелью mini App (механика Telegram).
const double kCompactChatListWidth = 72;

/// Список чатов, свёрнутый до колонки аватарок.
///
/// Сверху — кнопка «развернуть список» (точка, если активен фильтр не «Все»:
/// он продолжает работать молча). Тап по аватарке открывает чат, долгое
/// нажатие и правый клик — контекстное меню, как у полной строки.
class CompactChatListColumn extends StatelessWidget {
  final List<Room> rooms;
  final String? activeChat;
  final bool filterActive;
  final ScrollController? scrollController;
  final ValueChanged<Room> onTap;
  final void Function(Room room, BuildContext context) onContextAction;
  final VoidCallback onExpand;

  const CompactChatListColumn({
    required this.rooms,
    required this.activeChat,
    required this.filterActive,
    required this.onTap,
    required this.onContextAction,
    required this.onExpand,
    this.scrollController,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      bottom: false,
      child: CustomScrollView(
        key: const PageStorageKey('compactChatListScrollView'),
        controller: scrollController,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Badge(
                  isLabelVisible: filterActive,
                  smallSize: 8,
                  child: IconButton(
                    key: const ValueKey('compact-chat-list-expand'),
                    tooltip: L10n.of(context).chatListExpand,
                    icon: const Icon(Icons.keyboard_double_arrow_right),
                    color: theme.colorScheme.onSurfaceVariant,
                    onPressed: onExpand,
                  ),
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: rooms.length,
            itemBuilder: (context, i) => _CompactRoomTile(
              key: ValueKey('compact_chat_${rooms[i].id}'),
              room: rooms[i],
              active: rooms[i].id == activeChat,
              onTap: () => onTap(rooms[i]),
              onContextAction: (ctx) => onContextAction(rooms[i], ctx),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactRoomTile extends StatelessWidget {
  final Room room;
  final bool active;
  final VoidCallback onTap;
  final void Function(BuildContext context) onContextAction;

  const _CompactRoomTile({
    required this.room,
    required this.active,
    required this.onTap,
    required this.onContextAction,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = room.getLocalizedDisplayname(MatrixLocals(L10n.of(context)));
    return Tooltip(
      message: name,
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Material(
          borderRadius: BorderRadius.circular(AppConfig.borderRadius),
          clipBehavior: Clip.hardEdge,
          color: active
              ? theme.colorScheme.secondaryContainer
              : Colors.transparent,
          child: GestureDetector(
            onSecondaryTapUp: (_) => onContextAction(context),
            child: InkWell(
              onTap: onTap,
              onLongPress: () {
                HapticFeedback.heavyImpact();
                onContextAction(context);
              },
              child: SizedBox(
                height: 60,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Avatar(
                      mxContent: room.avatar,
                      name: name,
                      size: Avatar.defaultSize,
                    ),
                    Positioned(
                      top: 4,
                      right: 2,
                      child: UnreadBubble(room: room),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
