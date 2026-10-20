import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher_string.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/if_developer.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/navigation_rail.dart';
import 'package:liza/widgets/user_identifier.dart';
import '../../widgets/mxc_image_viewer.dart';
import 'settings.dart';

class SettingsView extends StatelessWidget {
  final SettingsController controller;

  const SettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showChatBackupBanner = controller.showChatBackupBanner;
    final activeRoute = GoRouter.of(
      context,
    ).routeInformationProvider.value.uri.path;
    final accountManageUrl = Matrix.of(context)
        .client
        .wellKnown
        ?.additionalProperties
        .tryGetMap<String, Object?>('org.matrix.msc2965.authentication')
        ?.tryGet<String>('account');
    return Row(
      children: [
        if (LizaThemes.isColumnMode(context)) ...[
          SpacesNavigationRail(
            activeSpaceId: null,
            onGoToChats: () => context.go('/rooms'),
            onGoToSpaceId: (spaceId) => context.go('/rooms?spaceId=$spaceId'),
          ),
          Container(color: Theme.of(context).dividerColor, width: 1),
        ],
        Expanded(
          child: Scaffold(
            appBar: LizaThemes.isColumnMode(context)
                ? null
                : AppBar(
                    title: Text(L10n.of(context).settings),
                    leading: Center(
                      child: BackButton(onPressed: () => context.go('/rooms')),
                    ),
                  ),
            body: ListTileTheme(
              iconColor: theme.colorScheme.onSurface,
              child: ListView(
                key: const Key('SettingsListViewContent'),
                children: <Widget>[
                  FutureBuilder<Profile>(
                    future: controller.profileFuture,
                    builder: (context, snapshot) {
                      final profile = snapshot.data;
                      final avatar = profile?.avatarUrl;
                      final mxid =
                          Matrix.of(context).client.userID ??
                          L10n.of(context).user;
                      final identifier = userIdentifier(
                        mxid,
                        handles: Matrix.of(context).userHandleService,
                        handle: controller.ownHandle,
                      );
                      final displayname =
                          profile?.displayName ?? mxid.localpart ?? mxid;
                      return Row(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(32.0),
                            child: Stack(
                              children: [
                                Avatar(
                                  mxContent: avatar,
                                  name: displayname,
                                  size: Avatar.defaultSize * 2.5,
                                  onTap: avatar != null
                                      ? () => showDialog(
                                          context: context,
                                          builder: (_) =>
                                              MxcImageViewer(avatar),
                                        )
                                      : null,
                                ),
                                if (profile != null)
                                  Positioned(
                                    bottom: 0,
                                    right: 0,
                                    child: FloatingActionButton.small(
                                      elevation: 2,
                                      onPressed: controller.setAvatarAction,
                                      heroTag: null,
                                      child: const Icon(
                                        Icons.camera_alt_outlined,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: .center,
                              crossAxisAlignment: .start,
                              children: [
                                TextButton.icon(
                                  onPressed: controller.setDisplaynameAction,
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                  ),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        theme.colorScheme.onSurface,
                                    iconColor: theme.colorScheme.onSurface,
                                  ),
                                  label: Text(
                                    displayname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 18),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      LizaShare.share(identifier, context),
                                  icon: const Icon(
                                    Icons.copy_outlined,
                                    size: 14,
                                  ),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        theme.colorScheme.secondary,
                                    iconColor: theme.colorScheme.secondary,
                                  ),
                                  label: Text(identifier, softWrap: true),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  if (accountManageUrl != null)
                    ListTile(
                      leading: const Icon(Icons.account_circle_outlined),
                      title: Text(L10n.of(context).manageAccount),
                      trailing: const Icon(Icons.open_in_new_outlined),
                      onTap: () => launchUrlString(
                        accountManageUrl,
                        mode: LaunchMode.inAppBrowserView,
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.link_outlined),
                    title: Text(L10n.of(context).invitePeople),
                    onTap: () => LizaShare.shareInvitePeople(context),
                  ),
                  // «Пригласить людей» — разовое действие наружу, а почта и
                  // никнейм ниже — параметры аккаунта; разделяем группы.
                  Divider(color: theme.dividerColor),
                  // Подпись «Ваш ID», а не «Почта»: это вход в Prodamus ID, но
                  // имя стороннего сервиса не пишем из-за модерации Apple
                  // (Надежда, В5 18.10). Экран почты не меняется.
                  ListTile(
                    leading: const Icon(Icons.person_outline),
                    title: Text(L10n.of(context).settingsYourId),
                    onTap: () => context.go('/rooms/settings/email'),
                  ),
                  if (controller.handleGateAvailable)
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text(L10n.of(context).handleSettingsTitle),
                      onTap: () => context.go('/rooms/settings/handle'),
                    ),
                  IfDeveloper(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Divider(color: theme.dividerColor),
                        if (showChatBackupBanner == null)
                          ListTile(
                            leading: const Icon(Icons.backup_outlined),
                            title: _developerTitle(L10n.of(context).chatBackup),
                            trailing:
                                const CircularProgressIndicator.adaptive(),
                          )
                        else
                          SwitchListTile.adaptive(
                            controlAffinity: ListTileControlAffinity.trailing,
                            value: controller.showChatBackupBanner == false,
                            secondary: const Icon(Icons.backup_outlined),
                            title: _developerTitle(L10n.of(context).chatBackup),
                            onChanged: controller.firstRunBootstrapAction,
                          ),
                      ],
                    ),
                  ),
                  Divider(color: theme.dividerColor),
                  ListTile(
                    leading: const Icon(Icons.format_paint_outlined),
                    title: Text(L10n.of(context).changeTheme),
                    tileColor: activeRoute.startsWith('/rooms/settings/style')
                        ? theme.colorScheme.surfaceContainerHigh
                        : null,
                    onTap: () => context.go('/rooms/settings/style'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.notifications_outlined),
                    title: Text(L10n.of(context).notifications),
                    tileColor:
                        activeRoute.startsWith('/rooms/settings/notifications')
                        ? theme.colorScheme.surfaceContainerHigh
                        : null,
                    onTap: () => context.go('/rooms/settings/notifications'),
                  ),
                  // «Приватность» — перед «Сеансами» (Надежда, В5 18.10). Без
                  // этого пункта «Удалить аккаунт» недоступен из интерфейса —
                  // отказ App Store по Guideline 5.1.1(v).
                  ListTile(
                    leading: const Icon(Icons.shield_outlined),
                    title: Text(L10n.of(context).privacy),
                    onTap: () => context.go('/rooms/settings/security'),
                    tileColor:
                        activeRoute.startsWith('/rooms/settings/security')
                        ? theme.colorScheme.surfaceContainerHigh
                        : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: Text(L10n.of(context).devices),
                    onTap: () => context.go('/rooms/settings/devices'),
                    tileColor: activeRoute.startsWith('/rooms/settings/devices')
                        ? theme.colorScheme.surfaceContainerHigh
                        : null,
                  ),
                  // Витрина MCP — только developer и отдельным окном вне
                  // настроек (Надежда, В5 18.10): подсветки активного пункта
                  // нет, экран не открывается в колонке настроек.
                  IfDeveloper(
                    child: ListTile(
                      leading: const Icon(Icons.extension_outlined),
                      title: Text(L10n.of(context).settingsMcpTitle),
                      trailing: const DeveloperMark(),
                      onTap: () => context.go(AppRoutes.mcp),
                    ),
                  ),
                  IfDeveloper(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Divider(color: theme.dividerColor),
                        ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: _developerTitle(
                            L10n.of(context).aboutHomeserver(
                              Matrix.of(context).client.userID?.domain ??
                                  'homeserver',
                            ),
                          ),
                          onTap: () => context.go('/rooms/settings/homeserver'),
                          tileColor:
                              activeRoute.startsWith(
                                '/rooms/settings/homeserver',
                              )
                              ? theme.colorScheme.surfaceContainerHigh
                              : null,
                        ),
                      ],
                    ),
                  ),
                  // «О проекте» доступен всем (снят IfDeveloper) и ведёт на
                  // собственный экран, а не в системный showAboutDialog: тот
                  // навязывает кнопку «Посмотреть лицензии».
                  ListTile(
                    leading: const Icon(Icons.info_outline_rounded),
                    title: Text(L10n.of(context).about),
                    onTap: () => context.go('/rooms/settings/about'),
                    tileColor: activeRoute.startsWith('/rooms/settings/about')
                        ? theme.colorScheme.surfaceContainerHigh
                        : null,
                  ),
                  ListTile(
                    leading: const Icon(Icons.bug_report_outlined),
                    title: Text(L10n.of(context).appLogs),
                    onTap: () => controller.logsMenuAction(context),
                  ),
                  Divider(color: theme.dividerColor),
                  ListTile(
                    leading: const Icon(Icons.logout_outlined),
                    title: Text(L10n.of(context).logout),
                    onTap: controller.logoutAction,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Подпись developer-пункта с меткой «Р» в заголовке: у `SwitchListTile`
/// слот `trailing` занят переключателем.
Widget _developerTitle(String text) => Row(
  children: [
    Flexible(child: Text(text)),
    const SizedBox(width: 6),
    const DeveloperMark(),
  ],
);
