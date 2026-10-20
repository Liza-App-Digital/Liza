import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/chat_topology.dart';

enum PowerLevelPreset {
  user(0),
  moderator(50),
  // 99, а не 100: порог «Администратор» включает и админов (99), и
  // владельца (100). Старые пороги 100 показываются тем же пресетом.
  admin(99);

  const PowerLevelPreset(this.level);

  final int level;

  static PowerLevelPreset fromMatrixLevel(int level) {
    if (level >= admin.level) return admin;
    if (level >= moderator.level) return moderator;
    return user;
  }

  String localized(L10n l10n) => switch (this) {
    user => l10n.user,
    moderator => l10n.moderator,
    admin => l10n.admin,
  };
}

class PermissionsListTile extends StatelessWidget {
  final String permissionKey;
  final int permission;
  final String? category;
  final void Function(int? level)? onChanged;
  final bool canEdit;

  /// В канале часть строк называется «канал», а не «чат/группа». Дефолт `false`
  /// сохраняет прежние формулировки для обычных чатов.
  final bool isChannel;

  /// Потолок выбора ([permissionThresholdMaxLevel]): пресеты выше него в
  /// списке не предлагаются (текущий остаётся, чтобы его было видно).
  final int maxLevel;

  const PermissionsListTile({
    super.key,
    required this.permissionKey,
    required this.permission,
    this.category,
    required this.onChanged,
    required this.canEdit,
    this.isChannel = false,
    this.maxLevel = ownerPowerLevel,
  });

  String getLocalizedPowerLevelString(BuildContext context) {
    final l10n = L10n.of(context);
    if (category == null) {
      switch (permissionKey) {
        case 'users_default':
          return l10n.defaultPermissionLevel;
        case 'events_default':
          return isChannel ? l10n.postToChannel : l10n.sendMessages;
        case 'state_default':
          return isChannel
              ? l10n.changeGeneralChannelSettings
              : l10n.changeGeneralChatSettings;
        case 'ban':
          return isChannel ? l10n.banFromChannel : l10n.banFromChat;
        case 'kick':
          return isChannel ? l10n.kickFromChannel : l10n.kickFromChat;
        case 'redact':
          return isChannel ? l10n.deleteChannelPost : l10n.deleteMessage;
        case 'invite':
          return isChannel
              ? l10n.inviteOtherUsersToChannel
              : l10n.inviteOtherUsers;
      }
    } else if (category == 'notifications') {
      switch (permissionKey) {
        case 'rooms':
          return l10n.sendRoomNotifications;
      }
    } else if (category == 'events') {
      switch (permissionKey) {
        case EventTypes.RoomName:
          return isChannel
              ? l10n.changeTheNameOfTheChannel
              : l10n.changeTheNameOfTheGroup;
        case EventTypes.RoomTopic:
          return isChannel
              ? l10n.changeTheDescriptionOfTheChannel
              : l10n.changeTheDescriptionOfTheGroup;
        case EventTypes.RoomPowerLevels:
          return isChannel
              ? l10n.changeTheChannelPermissions
              : l10n.changeTheChatPermissions;
        case EventTypes.HistoryVisibility:
          return isChannel
              ? l10n.changeTheVisibilityOfChannelHistory
              : l10n.changeTheVisibilityOfChatHistory;
        case EventTypes.RoomCanonicalAlias:
          return isChannel
              ? l10n.changeTheCanonicalChannelAlias
              : l10n.changeTheCanonicalRoomAlias;
        case EventTypes.RoomAvatar:
          return isChannel ? l10n.editChannelAvatar : l10n.editRoomAvatar;
        case EventTypes.RoomTombstone:
          return l10n.replaceRoomWithNewerVersion;
        case EventTypes.Encryption:
          return l10n.enableEncryption;
        case 'm.room.server_acl':
          return l10n.editBlockedServers;
        case EventTypes.SpaceChild:
          return l10n.addRemoveSpaceChildren;
        case EventTypes.SpaceParent:
          return l10n.setSpaceParent;
        case companyCreateChatKey:
          return l10n.createChatsInCompany;
        case companyCreateChannelKey:
          return l10n.createChannelsInCompany;
      }
    }
    return permissionKey;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preset = PowerLevelPreset.fromMatrixLevel(permission);
    final color = switch (preset) {
      PowerLevelPreset.user => Colors.greenAccent,
      PowerLevelPreset.moderator => Colors.blueAccent,
      PowerLevelPreset.admin => Colors.orangeAccent,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            getLocalizedPowerLevelString(context),
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Material(
            color: color.withAlpha(32),
            borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
            child: DropdownButton<PowerLevelPreset>(
              isExpanded: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              borderRadius: BorderRadius.circular(AppConfig.borderRadius / 2),
              underline: const SizedBox.shrink(),
              onChanged: canEdit
                  ? (value) => onChanged?.call(value?.level)
                  : null,
              value: preset,
              items: [
                for (final value in PowerLevelPreset.values)
                  if (value.level <= maxLevel || value == preset)
                    DropdownMenuItem(
                      value: value,
                      child: Text(value.localized(L10n.of(context))),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
