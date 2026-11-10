import 'package:flutter/material.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';

class TwoColumnLayout extends StatelessWidget {
  final Widget mainView;
  final Widget sideView;

  /// Левая колонка — список чатов, который сворачивается до аватарок рядом с
  /// широкой панелью mini App. У настроек — false.
  final bool compactable;

  const TwoColumnLayout({
    super.key,
    required this.mainView,
    required this.sideView,
    this.compactable = false,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = compactable && MiniAppHostScope.compactChatListOf(context);

    return ScaffoldMessenger(
      child: Scaffold(
        body: Row(
          children: [
            // Без анимации ширины: иначе полный список при разворачивании
            // раскладывался бы на каждом кадре в 72…400 px (overflow, лаги).
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(),
              width: compact
                  ? LizaThemes.navRailWidth + 1 + kCompactChatListWidth
                  : LizaThemes.columnWidth + LizaThemes.navRailWidth,
              child: mainView,
            ),
            Container(width: 1.0, color: theme.dividerColor),
            Expanded(child: ClipRRect(child: sideView)),
          ],
        ),
      ),
    );
  }
}
