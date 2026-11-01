import 'package:flutter/material.dart';

import 'package:liza/utils/bot_interactive_markup.dart';

/// Один и тот же renderer используется в композере и golden-стражах.
class InteractiveReplyKeyboard extends StatelessWidget {
  final List<List<BotKeyboardButton>> rows;
  final bool busy;
  final String semanticsLabel;
  final ValueChanged<BotKeyboardButton> onTap;
  const InteractiveReplyKeyboard({
    required this.rows,
    required this.busy,
    required this.semanticsLabel,
    required this.onTap,
    super.key,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticsLabel,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows)
            Row(
              children: [
                for (final button in row)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: OutlinedButton(
                        onPressed: busy ? null : () => onTap(button),
                        child: Text(
                          button.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
        ],
      ),
    ),
  );
}
