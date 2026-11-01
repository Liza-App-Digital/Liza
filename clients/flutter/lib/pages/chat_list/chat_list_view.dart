import 'package:flutter/material.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/widgets/navigation_rail.dart';
import 'package:liza/widgets/notification_health_panel.dart';
import 'chat_list_body.dart';

class ChatListView extends StatelessWidget {
  final ChatListController controller;

  const ChatListView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !controller.isSearchMode && controller.activeSpaceId == null,
      onPopInvokedWithResult: (pop, _) {
        if (pop) return;
        if (controller.activeSpaceId != null) {
          controller.clearActiveSpace();
          return;
        }
        if (controller.isSearchMode) {
          controller.cancelSearch();
          return;
        }
      },
      child: Row(
        children: [
          if (LizaThemes.isColumnMode(context) ||
              AppSettings.displayNavigationRail.value) ...[
            SpacesNavigationRail(
              activeSpaceId: controller.activeSpaceId,
              onGoToChats: controller.clearActiveSpace,
              onGoToSpaceId: controller.setActiveSpace,
            ),
            Container(color: Theme.of(context).dividerColor, width: 1),
          ],
          Expanded(
            child: GestureDetector(
              onTap: FocusManager.instance.primaryFocus?.unfocus,
              excludeFromSemantics: true,
              behavior: HitTestBehavior.translucent,
              child: Scaffold(
                body: Column(
                  children: [
                    const NotificationHealthPanel(compact: true),
                    Expanded(child: ChatListViewBody(controller)),
                  ],
                ),
                // floatingActionButton:
                //     !controller.isSearchMode && controller.activeSpaceId == null
                //     ? FloatingActionButton.extended(
                //         onPressed: () => context.go('/rooms/newprivatechat'),
                //         icon: const Icon(Icons.add_outlined),
                //         label: Text(
                //           L10n.of(context).chat,
                //           overflow: TextOverflow.fade,
                //         ),
                //       )
                //     : const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
