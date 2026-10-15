import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_private_chat/new_private_chat.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/user_identifier.dart';
import 'package:liza/utils/user_role_service.dart';
import 'package:liza/widgets/user_role_badge.dart';
import 'package:liza/widgets/search_people_bots_sections.dart';
import '../../widgets/qr_code_viewer.dart';

class NewPrivateChatView extends StatelessWidget {
  final NewPrivateChatController controller;

  const NewPrivateChatView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final searchResponse = controller.searchResponse;
    final userId = Matrix.of(context).client.userID!;
    return Scaffold(
      appBar: AppBar(
        scrolledUnderElevation: 0,
        leading: const Center(child: BackButton()),
        title: Text(L10n.of(context).newChat),
        backgroundColor: theme.scaffoldBackgroundColor,
      ),
      body: MaxWidthBody(
        withScrolling: false,
        innerPadding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 16.0,
                vertical: 8.0,
              ),
              child: TextField(
                controller: controller.controller,
                onChanged: controller.searchUsers,
                decoration: InputDecoration(
                  hintText: L10n.of(context).searchForUsers,
                  filled: true,
                  fillColor: theme.colorScheme.secondaryContainer,
                  border: OutlineInputBorder(
                    borderSide: BorderSide.none,
                    borderRadius: BorderRadius.circular(99),
                  ),
                  hintStyle: TextStyle(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.normal,
                  ),
                  prefixIcon: searchResponse == null
                      ? const Icon(Icons.search_outlined)
                      : FutureBuilder(
                          future: searchResponse,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState !=
                                ConnectionState.done) {
                              return const Padding(
                                padding: EdgeInsets.all(10.0),
                                child: SizedBox.square(
                                  dimension: 24,
                                  child: CircularProgressIndicator.adaptive(
                                    strokeWidth: 1,
                                  ),
                                ),
                              );
                            }
                            return const Icon(Icons.search_outlined);
                          },
                        ),
                  suffixIcon: controller.controller.text.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_outlined),
                          onPressed: () {
                            controller.controller.clear();
                            controller.searchUsers();
                          },
                        ),
                ),
              ),
            ),
            Expanded(
              child: AnimatedSwitcher(
                duration: LizaThemes.animationDuration,
                child: searchResponse == null
                    ? ListView(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18.0,
                            ),
                            child: SelectableText.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text: L10n.of(context).yourGlobalUserIdIs,
                                  ),
                                  TextSpan(
                                    text: userIdentifier(
                                      Matrix.of(context).client.userID!,
                                      handles: Matrix.of(
                                        context,
                                      ).userHandleService,
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.secondaryContainer,
                              foregroundColor:
                                  theme.colorScheme.onSecondaryContainer,
                              child: Icon(Icons.adaptive.share_outlined),
                            ),
                            title: Text(L10n.of(context).shareInviteLink),
                            onTap: controller.inviteAction,
                          ),
                          ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  theme.colorScheme.tertiaryContainer,
                              foregroundColor:
                                  theme.colorScheme.onTertiaryContainer,
                              child: const Icon(Icons.group_add_outlined),
                            ),
                            title: Text(L10n.of(context).createGroup),
                            onTap: () => context.go('/rooms/newgroup'),
                          ),
                          if (PlatformInfos.isMobile)
                            ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                foregroundColor:
                                    theme.colorScheme.onPrimaryContainer,
                                child: const Icon(
                                  Icons.qr_code_scanner_outlined,
                                ),
                              ),
                              title: Text(L10n.of(context).scanQrCode),
                              onTap: controller.openScannerAction,
                            ),
                          Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 64.0,
                                vertical: 24.0,
                              ),
                              child: Material(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(
                                    AppConfig.borderRadius,
                                  ),
                                  side: BorderSide(
                                    width: 3,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                color: Colors.transparent,
                                clipBehavior: Clip.hardEdge,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(
                                    AppConfig.borderRadius,
                                  ),
                                  onTap: () async {
                                    final client = Matrix.of(context).client;
                                    final result =
                                        await showFutureLoadingDialog(
                                          context: context,
                                          future: () async {
                                            final info =
                                                await AuthProxyService()
                                                    .createUserInvite(
                                                      targetUserId: userId,
                                                      accessToken:
                                                          client.accessToken ??
                                                          '',
                                                    );
                                            return info.url;
                                          },
                                        );
                                    final url = result.result;
                                    if (url == null) return;
                                    if (!context.mounted) return;
                                    showQrCodeViewer(
                                      context,
                                      userId,
                                      inviteLink: url,
                                    );
                                  },
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 200,
                                      ),
                                      child: PrettyQrView.data(
                                        data: 'https://matrix.to/#/$userId',
                                        decoration: PrettyQrDecoration(
                                          shape: PrettyQrSmoothSymbol(
                                            roundFactor: 1,
                                            color: theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      )
                    : FutureBuilder(
                        future: searchResponse,
                        builder: (context, snapshot) {
                          final result = snapshot.data;
                          final error = snapshot.error;
                          if (error != null) {
                            return Column(
                              mainAxisAlignment: .center,
                              children: [
                                Text(
                                  error.toLocalizedString(context),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                OutlinedButton.icon(
                                  onPressed: controller.searchUsers,
                                  icon: const Icon(Icons.refresh_outlined),
                                  label: Text(L10n.of(context).tryAgain),
                                ),
                              ],
                            );
                          }
                          if (result == null) {
                            return const Center(
                              child: CircularProgressIndicator.adaptive(),
                            );
                          }
                          if (result.isEmpty) {
                            return Column(
                              mainAxisAlignment: .center,
                              children: [
                                const Icon(Icons.search_outlined, size: 86),
                                Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Text(
                                    L10n.of(context).noUsersFoundWithQuery(
                                      controller.controller.text,
                                    ),
                                    style: TextStyle(
                                      color: theme.colorScheme.primary,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            );
                          }
                          return ListView(
                            children: peopleAndBotsSections(
                              context,
                              result,
                              buildBody: (profiles) => Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  for (final contact in profiles)
                                    _ContactSearchTile(
                                      key: ValueKey(contact.userId),
                                      contact: contact,
                                      onTap: () =>
                                          controller.openUserModal(contact),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Строка находки в выдаче поиска: имя → @ник → localpart (LABA-2552).
class _ContactSearchTile extends StatelessWidget {
  const _ContactSearchTile({
    required this.contact,
    required this.onTap,
    super.key,
  });

  final Profile contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final handles = Matrix.of(context).userHandleService;
    // Имя → @ник → localpart (LABA-2552).
    final label = searchResultLabel(
      contact,
      handles: handles,
      unknown: contact.userId,
    );
    return ListTile(
      leading: Avatar(
        name: label.avatarName,
        mxContent: contact.avatarUrl,
        presenceUserId: contact.userId,
        isHexagonal: Matrix.of(context).isAiUser(contact.userId),
      ),
      title: Wrap(
        spacing: 6,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(label.title),
          UserRoleBadge(
            userId: contact.userId,
            hideRoleCodes: const {
              UserRoleService.adminRole,
              UserRoleService.moderatorRole,
            },
          ),
        ],
      ),
      subtitle: Text(userIdentifier(contact.userId, handles: handles)),
      onTap: onTap,
    );
  }
}
