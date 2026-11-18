import 'package:flutter/material.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/emoji_history_store.dart';

/// Снимок пяти реакций на время открытого меню: кнопки не прыгают под мышью.
class EmojiQuickReactions extends StatefulWidget {
  const EmojiQuickReactions({
    required this.history,
    required this.defaults,
    required this.sentReactions,
    required this.onSelected,
    required this.onMore,
    super.key,
  });

  final EmojiHistoryStore history;
  final List<String> defaults;
  final Set<String> sentReactions;
  final ValueChanged<String> onSelected;
  final VoidCallback onMore;

  @override
  State<EmojiQuickReactions> createState() => _EmojiQuickReactionsState();
}

class _EmojiQuickReactionsState extends State<EmojiQuickReactions> {
  late List<String> _emojis;

  @override
  void initState() {
    super.initState();
    _emojis = widget.history.quickReactions(widget.defaults);
  }

  @override
  void didUpdateWidget(EmojiQuickReactions oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.history.userId != widget.history.userId ||
        oldWidget.history.usage != widget.history.usage ||
        !identical(oldWidget.history.prefs, widget.history.prefs)) {
      _emojis = widget.history.quickReactions(widget.defaults);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final emoji in _emojis)
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: Opacity(
            opacity: widget.sentReactions.contains(emoji) ? 0.4 : 1,
            child: Text(emoji, style: const TextStyle(fontSize: 24)),
          ),
          onPressed: () => widget.onSelected(emoji),
        ),
      IconButton(
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.add_reaction_outlined),
        tooltip: L10n.of(context).customReaction,
        onPressed: widget.onMore,
      ),
    ],
  );
}
