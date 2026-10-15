import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/stories/story_media_picker.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/create_menu_sections.dart';
import 'package:liza/utils/direct_chat_ensure.dart';
import 'package:liza/utils/liza_dm.dart';
import 'package:liza/pages/chat_list/client_chooser_button.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/platform_infos.dart';
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
                      tooltip: L10n.of(context).createGroup,
                      icon: Icon(
                        Icons.add_outlined,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                      onSelected: (action) => _onCreateAction(context, action),
                      itemBuilder: (context) {
                        final roles = Matrix.of(context).userRoleService;
                        final sections = createMenuSections(
                          isAdmin: roles.isCurrentUserAdmin,
                          isDeveloper: roles.isCurrentUserDeveloper,
                          isMobile: PlatformInfos.isMobile,
                        );
                        return [
                          for (final (i, section) in sections.indexed) ...[
                            if (i > 0) const PopupMenuDivider(),
                            for (final action in section)
                              PopupMenuItem(
                                value: action,
                                child: Text(_createMenuLabel(context, action)),
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
      CreateMenuAction.story => l10n.createStory,
      CreateMenuAction.bot => l10n.createBot,
      CreateMenuAction.miniApp => l10n.createMiniApp,
      CreateMenuAction.agent => l10n.connectAiAgent,
      CreateMenuAction.mcp => l10n.settingsMcpAddShort,
      // «Пригласить контакт» и «Контакты» дублируют пункты меню аватара —
      // единое место добавления людей рядом с созданием (референс Макса).
      CreateMenuAction.invite => l10n.inviteContact,
      CreateMenuAction.contacts => l10n.contactsTitle,
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
        await _openNewLizaRequest(context);
        return;
      case CreateMenuAction.group:
        context.go('/rooms/newgroup');
        return;
      case CreateMenuAction.channel:
        context.go('/rooms/newchannel');
        return;
      case CreateMenuAction.story:
        final composer = await pickStoryMediaComposer(context);
        if (composer == null || !context.mounted) return;
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => composer));
      case CreateMenuAction.bot:
      case CreateMenuAction.miniApp:
        final client = Matrix.of(context).client;
        const botFatherId = '@botfather:bots.liza.ru';
        final existing = client.getDirectChatFromUserId(botFatherId);
        final roomId =
            existing ??
            (await showFutureLoadingDialog(
              context: context,
              future: () => client.ensureDirectChat(botFatherId),
            )).result;
        if (roomId == null || !context.mounted) return;
        context.go('/rooms/$roomId');
        return;
      case CreateMenuAction.agent:
        await _openAgentConnect(context);
        return;
      case CreateMenuAction.mcp:
        context.go(AppRoutes.settingsMcp);
      case CreateMenuAction.invite:
        // Нативный share-лист приглашения (НЕ QR-визитка из меню аватара —
        // консистентно с настройками/списком/поиском).
        LizaShare.shareInvitePeople(context);
        return;
      case CreateMenuAction.contacts:
        context.go('/rooms/contacts');
        return;
    }
  }

  /// «Новый запрос»: отдельный чат с Лизой (P1 встречи 05.10). Название
  /// «Лиза: <суть>» ставит бот после первого сообщения; до того — «Новый
  /// запрос». Двойной тап: барьер диалога + single-flight `forceNew`.
  Future<void> _openNewLizaRequest(BuildContext context) async {
    final client = Matrix.of(context).client;
    final title = L10n.of(context).newLizaRequest;
    final created = await showFutureLoadingDialog(
      context: context,
      future: () =>
          startLizaRequestChat(client, MatrixState.lizaMxid, title: title),
    );
    final result = created.result;
    if (result == null || !context.mounted) return;
    context.go('/rooms/${result.$1}');
  }

  /// Открывает Лизу ИИ с карточкой «Подключить своего агента».
  ///
  /// Шлём callback кнопки `agent.start` (контракт карточек бота, как
  /// `BotFatherPanel._handoff`), а НЕ текст-фразу: на шаге «название чата» мастер
  /// принял бы фразу за название и создал бота, а открытая сессия подбора товара
  /// забрала бы её себе. Кнопка всегда начинает мастер заново.
  Future<void> _openAgentConnect(BuildContext context) async {
    final client = Matrix.of(context).client;
    final lizaMxid = MatrixState.lizaMxid;
    final body = L10n.of(context).connectAiAgent;
    var roomId = findLizaAssistantDm(client, lizaMxid)?.id;
    if (roomId == null) {
      final created = await showFutureLoadingDialog(
        context: context,
        future: () async {
          final id = await ensureLizaAssistantDm(client, lizaMxid);
          return (id, await waitForMemberJoin(client, id, lizaMxid));
        },
      );
      final result = created.result;
      if (result == null || !context.mounted) return;
      final (id, joined) = result;
      // Лиза не вступила за таймаут — callback пришёл бы ей вперемешку с
      // историей и приветствием; просто открываем чат, приветствие придёт само.
      if (!joined) {
        context.go('/rooms/$id');
        return;
      }
      roomId = id;
    }
    final errorText = L10n.of(context).oopsSomethingWentWrong;
    final messenger = ScaffoldMessenger.of(context);
    var sent = false;
    try {
      await client.getRoomById(roomId)?.sendEvent({
        'msgtype': 'com.liza.miniapp.callback',
        'body': body,
        'button_id': 'agent.start',
      });
      sent = true;
    } catch (e, s) {
      Logs().w('[CreateMenu] agent.start не отправлен', e, s);
    }
    // В чат переходим и при сбое, но не молча: без карточки пользователь иначе
    // решил бы, что пункт меню не работает.
    if (!sent) messenger.showSnackBar(SnackBar(content: Text(errorText)));
    if (!context.mounted) return;
    context.go('/rooms/$roomId');
  }
}
