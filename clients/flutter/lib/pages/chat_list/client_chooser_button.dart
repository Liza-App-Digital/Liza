import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/support_chat.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/liza_share.dart';
import 'chat_list.dart';

/// Что показать в нижней части меню аватара. С одним аккаунтом строка со своим
/// именем ни на что не переключает и читается как дубль (задание Надежды 18.10,
/// В4), поэтому строки аккаунтов — только при двух и более вошедших.
({bool accounts, bool divider}) accountMenuBlock({
  required int loggedInClients,
  required bool canAddAccount,
}) {
  final accounts = loggedInClients > 1;
  return (accounts: accounts, divider: accounts || canAddAccount);
}

class ClientChooserButton extends StatelessWidget {
  final ChatListController controller;

  const ClientChooserButton(this.controller, {super.key});

  List<PopupMenuEntry<Object>> _bundleMenuItems(BuildContext context) {
    final matrix = Matrix.of(context);
    final bundles = matrix.accountBundles.keys.toList()
      ..sort(
        (a, b) => a!.isValidMatrixId == b!.isValidMatrixId
            ? 0
            : a.isValidMatrixId && !b.isValidMatrixId
            ? -1
            : 1,
      );
    // В локальной сборке (APP_ENV=local) тоже показываем «Добавить аккаунт»:
    // нужно, чтобы залогиниться в локальный Synapse (testuser) рядом с dev-аккаунтом.
    final canAddAccount = matrix.isCurrentUserDeveloper || AppConfig.isLocal;
    final block = accountMenuBlock(
      loggedInClients: matrix.widget.clients.where((c) => c.isLogged()).length,
      canAddAccount: canAddAccount,
    );
    return <PopupMenuEntry<Object>>[
      PopupMenuItem(
        value: SettingsAction.invite,
        child: Row(
          children: [
            Icon(Icons.adaptive.share_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).inviteContact),
          ],
        ),
      ),
      // Экран контактов доступен только на мобильных: flutter_contacts
      // поддерживает лишь Android/iOS (на Web/десктопе — MissingPluginException).
      if (PlatformInfos.isMobile)
        PopupMenuItem(
          value: SettingsAction.contacts,
          child: Row(
            children: [
              const Icon(Icons.contacts_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).contactsTitle),
            ],
          ),
        ),
      PopupMenuItem(
        value: SettingsAction.archive,
        child: Row(
          children: [
            const Icon(Icons.archive_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).archive),
          ],
        ),
      ),
      if (matrix.isCurrentUserDeveloper)
        PopupMenuItem(
          value: SettingsAction.apps,
          child: Row(
            children: [
              const Icon(Icons.apps_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).miniAppCatalogTitle),
              const SizedBox(width: 8),
              const DeveloperMark(),
            ],
          ),
        ),
      PopupMenuItem(
        value: SettingsAction.settings,
        child: Row(
          children: [
            const Icon(Icons.settings_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).settings),
          ],
        ),
      ),
      PopupMenuItem(
        value: SettingsAction.support,
        child: Row(
          children: [
            const Icon(Icons.support_agent_outlined),
            const SizedBox(width: 18),
            Text(L10n.of(context).supportPage),
          ],
        ),
      ),
      if (block.divider) const PopupMenuDivider(),
      if (block.accounts)
        for (final bundle in bundles) ...[
          if (matrix.accountBundles[bundle]!.length != 1 ||
              matrix.accountBundles[bundle]!.single!.userID != bundle)
            PopupMenuItem(
              value: null,
              child: Column(
                crossAxisAlignment: .start,
                mainAxisSize: .min,
                children: [
                  Text(
                    bundle!,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.titleMedium!.color,
                      fontSize: 14,
                    ),
                  ),
                  const Divider(height: 1),
                ],
              ),
            ),
          ...matrix.accountBundles[bundle]!
              .whereType<Client>()
              .where((client) => client.isLogged())
              .map(
                (client) => PopupMenuItem(
                  value: client,
                  child: FutureBuilder<Profile?>(
                    future: client.fetchOwnProfile(),
                    builder: (context, snapshot) => Row(
                      children: [
                        Avatar(
                          mxContent: snapshot.data?.avatarUrl,
                          name:
                              snapshot.data?.displayName ??
                              client.userID!.localpart,
                          size: 32,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            snapshot.data?.displayName ??
                                client.userID!.localpart!,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      if (canAddAccount)
        PopupMenuItem(
          value: SettingsAction.addAccount,
          child: Row(
            children: [
              const Icon(Icons.person_add_outlined),
              const SizedBox(width: 18),
              Text(L10n.of(context).addAccount),
              const SizedBox(width: 8),
              const DeveloperMark(),
            ],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix.of(context);

    return FutureBuilder<Profile>(
      future: matrix.client.isLogged() ? matrix.client.fetchOwnProfile() : null,
      builder: (context, snapshot) => Material(
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.circular(99),
        color: Colors.transparent,
        child: PopupMenuButton<Object>(
          popUpAnimationStyle: LizaThemes.isColumnMode(context)
              ? AnimationStyle.noAnimation
              : null, // https://github.com/flutter/flutter/issues/167180
          onSelected: (o) => _clientSelected(o, context),
          itemBuilder: _bundleMenuItems,
          child: Center(
            child: Avatar(
              mxContent: snapshot.data?.avatarUrl,
              name:
                  snapshot.data?.displayName ?? matrix.client.userID?.localpart,
              size: 32,
            ),
          ),
        ),
      ),
    );
  }

  void _clientSelected(Object object, BuildContext context) async {
    if (object is Client) {
      controller.setActiveClient(object);
    } else if (object is String) {
      controller.setActiveBundle(object);
    } else if (object is SettingsAction) {
      switch (object) {
        case SettingsAction.addAccount:
          context.go('/rooms/settings/addaccount');
          break;
        case SettingsAction.invite:
          LizaShare.shareInviteLink(context);
          break;
        case SettingsAction.contacts:
          context.go('/rooms/contacts');
          break;
        case SettingsAction.support:
          openSupportChat(context);
          break;
        case SettingsAction.settings:
          context.go('/rooms/settings');
          break;
        case SettingsAction.archive:
          context.go('/rooms/archive');
          break;
        case SettingsAction.apps:
          context.go('/rooms/apps');
          break;
      }
    }
  }
}

enum SettingsAction {
  addAccount,
  invite,
  contacts,
  support,
  settings,
  archive,
  apps,
}
