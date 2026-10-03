import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/stories/story_reactions.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

/// Лист «Просмотры» своей сторис (LABA-2616, как в Telegram): зрители
/// сегмента и эмодзи их реакций, отреагировавшие сверху. Вёрстка строки —
/// как у «кто прочитал» в чате ([ReadReceiptsList]).
Future<void> showStoryViewersSheet(
  BuildContext context, {
  required Room room,
  required List<StoryViewerRow> rows,
}) {
  return showAdaptiveBottomSheet(
    context: context,
    builder: (context) => StoryViewersList(room: room, rows: rows),
  );
}

class StoryViewersList extends StatelessWidget {
  const StoryViewersList({required this.room, required this.rows, super.key});

  final Room room;
  final List<StoryViewerRow> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(
                  Icons.remove_red_eye_outlined,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  L10n.of(context).storyViewersTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${rows.length}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                L10n.of(context).storyNoViewersYet,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: rows.length,
                itemBuilder: (context, i) => _StoryViewerTile(
                  key: ValueKey(rows[i].userId),
                  room: room,
                  row: rows[i],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StoryViewerTile extends StatefulWidget {
  const _StoryViewerTile({required this.room, required this.row, super.key});

  final Room room;
  final StoryViewerRow row;

  @override
  State<_StoryViewerTile> createState() => _StoryViewerTileState();
}

class _StoryViewerTileState extends State<_StoryViewerTile> {
  // Участники сторис-комнаты грузятся лениво: без запроса у зрителя,
  // ещё не попавшего в память, вместо имени был бы mxid.
  late final Future<User?> _user = widget.room.requestUser(
    widget.row.userId,
    ignoreErrors: true,
  );

  @override
  Widget build(BuildContext context) {
    final fallback = widget.room.unsafeGetUserFromMemoryOrFallback(
      widget.row.userId,
    );
    return FutureBuilder<User?>(
      future: _user,
      initialData: fallback,
      builder: (context, snapshot) {
        final user = snapshot.data ?? fallback;
        final name = user.calcDisplayname();
        return ListTile(
          leading: Avatar(
            mxContent: user.avatarUrl,
            name: name,
            isHexagonal: Matrix.of(context).isAiUser(widget.row.userId),
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: widget.row.keys.isEmpty
              ? null
              : Text(
                  widget.row.keys.join(' '),
                  style: const TextStyle(fontSize: 22),
                ),
        );
      },
    );
  }
}
