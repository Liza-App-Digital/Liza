import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/create_menu_item_label.dart';
import 'package:liza/pages/chat_list/create_menu_sections.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/utils/liza_new_request.dart';
import 'package:liza/pages/chat_list/client_chooser_button.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/sync_status_localization.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import '../../widgets/matrix.dart';

class ChatListHeader extends StatelessWidget implements PreferredSizeWidget {
  final ChatListController controller;
  final bool globalSearch;

  const ChatListHeader({
    super.key,
    required this.controller,
    this.globalSearch = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;

    return SliverAppBar(
      floating: true,
      toolbarHeight: 72,
      pinned: LizaThemes.isColumnMode(context),
      scrolledUnderElevation: 0,
      backgroundColor: Colors.transparent,
      automaticallyImplyLeading: false,
      title: StreamBuilder(
        stream: client.onSyncStatus.stream,
        builder: (context, snapshot) {
          final status =
              client.onSyncStatus.value ??
              const SyncStatusUpdate(SyncStatus.waitingForResponse);
          final hide =
              client.onSync.value != null &&
              status.status != SyncStatus.error &&
              client.prevBatch != null;
          return Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller.searchController,
                  focusNode: controller.searchFocusNode,
                  textInputAction: TextInputAction.search,
                  onChanged: (text) => controller.onSearchEnter(
                    text,
                    globalSearch: globalSearch,
                  ),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: theme.colorScheme.secondaryContainer,
                    border: OutlineInputBorder(
                      borderSide: BorderSide.none,
                      borderRadius: BorderRadius.circular(99),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    hintText: hide
                        ? L10n.of(context).search
                        : status.calcLocalizedString(context),
                    hintStyle: TextStyle(
                      color: status.error != null
                          ? Colors.orange
                          : theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.normal,
                    ),
                    prefixIcon: hide
                        ? controller.isSearchMode
                              ? IconButton(
                                  tooltip: L10n.of(context).cancel,
                                  icon: const Icon(Icons.close_outlined),
                                  onPressed: controller.cancelSearch,
                                  color: theme.colorScheme.onPrimaryContainer,
                                )
                              : IconButton(
                                  onPressed: controller.startSearch,
                                  icon: Icon(
                                    Icons.search_outlined,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                )
                        : Container(
                            margin: const EdgeInsets.all(12),
                            width: 8,
                            height: 8,
                            child: Center(
                              child: CircularProgressIndicator.adaptive(
                                strokeWidth: 2,
                                value: status.progress,
                                valueColor: status.error != null
                                    ? const AlwaysStoppedAnimation<Color>(
                                        Colors.orange,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                    suffixIcon: controller.isSearchMode && globalSearch
                        ? controller.isSearching
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(
                                    vertical: 10.0,
                                    horizontal: 12,
                                  ),
                                  child: SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator.adaptive(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink()
                        : SizedBox(
                            width: 48,
                            child: ClientChooserButton(controller),
                          ),
                  ),
                ),
              ),
              if (!controller.isSearchMode) ...[
                const SizedBox(width: 8),
                SizedBox(
                  height: 48,
                  width: 48,
                  child: Material(
                    color: theme.colorScheme.secondaryContainer,
                    shape: const CircleBorder(),
                    child: PopupMenuButton<CreateMenuAction>(
                      tooltip: L10n.of(context).create,
                      icon: Icon(
                        Icons.add_outlined,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      onSelected: (action) => _onCreateAction(context, action),
                      itemBuilder: (context) {
                        final roles = Matrix.of(context).userRoleService;
                        final sections = createMenuSections(
                          isDeveloper: roles.isCurrentUserDeveloper,
                        );
                        return [
                          for (final (i, section) in sections.indexed) ...[
                            if (i > 0) const PopupMenuDivider(),
                            for (final action in section)
                              PopupMenuItem(
                                value: action,
                                child: CreateMenuItemLabel(
                                  label: _createMenuLabel(context, action),
                                  highlighted: highlightedActions.contains(
                                    action,
                                  ),
                                  developerMark: developerOnlyActions.contains(
                                    action,
                                  ),
                                ),
                              ),
                          ],
                        ];
                      },
                    ),
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  static String _createMenuLabel(
    BuildContext context,
    CreateMenuAction action,
  ) {
    final l10n = L10n.of(context);
    return switch (action) {
      CreateMenuAction.newRequest => l10n.newLizaRequest,
      CreateMenuAction.group => l10n.createGroup,
      CreateMenuAction.channel => l10n.createChannel,
      CreateMenuAction.developers => l10n.forDevelopers,
      CreateMenuAction.mcp => l10n.settingsMcpAddShort,
      // «Пригласить контакт» дублирует пункт меню аватара — добавление людей
      // рядом с созданием (референс Макса).
      CreateMenuAction.invite => l10n.inviteContact,
    };
  }

  @override
  Size get preferredSize => const Size.fromHeight(56);

  Future<void> _onCreateAction(
    BuildContext context,
    CreateMenuAction action,
  ) async {
    switch (action) {
      case CreateMenuAction.newRequest:
        await openNewLizaRequest(context);
        return;
      case CreateMenuAction.group:
        context.go('/rooms/newgroup');
        return;
      case CreateMenuAction.channel:
        context.go('/rooms/newchannel');
        return;
      case CreateMenuAction.developers:
        await _openBotFatherMenu(context);
        return;
      case CreateMenuAction.mcp:
        context.go(AppRoutes.mcp);
        return;
      case CreateMenuAction.invite:
        // Нативный share-лист приглашения (НЕ QR-визитка из меню аватара —
        // консистентно с настройками/списком/поиском).
        LizaShare.shareInvitePeople(context);
        return;
    }
  }

  static const _botFatherMxid = '@botfather:bots.liza.ru';

  /// «Разработчику»: главное меню BotFather — создание бота, mini-app и
  /// подключение агента живут там. В существующий DM шлём /menu, BotFather
  /// отвечает карточкой меню. Свежему DM /menu не шлём: бот сам присылает
  /// карточку при входе (`send_welcome_on_join`), иначе их было бы две.
  Future<void> _openBotFatherMenu(BuildContext context) async {
    final client = Matrix.of(context).client;
    final existing = findBotDm(client, _botFatherMxid);
    if (existing != null) {
      try {
        await existing.sendTextEvent('/menu');
      } catch (e, s) {
        Logs().w('[CreateMenu] /menu в BotFather не отправлен', e, s);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).oopsSomethingWentWrong)),
          );
        }
      }
      if (!context.mounted) return;
      context.go('/rooms/${existing.id}');
      return;
    }
    final created = await showFutureLoadingDialog(
      context: context,
      future: () async {
        final roomId = await client.ensureDirectChat(_botFatherMxid);
        await waitForMemberJoin(client, roomId, _botFatherMxid);
        return roomId;
      },
    );
    final roomId = created.result;
    if (roomId == null || !context.mounted) return;
    context.go('/rooms/$roomId');
  }
}
