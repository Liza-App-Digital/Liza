import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:liza/pages/chat_permissions_settings/permission_list_tile.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';
import 'package:liza/widgets/matrix.dart';

class ChatPermissionsSettingsView extends StatelessWidget {
  final ChatPermissionsSettingsController controller;

  const ChatPermissionsSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final roomId = controller.roomId;
    final appBarRoom = roomId == null
        ? null
        : Matrix.of(context).client.getRoomById(roomId);

    return Scaffold(
      appBar: AppBar(
        leading: const Center(child: BackButton()),
        title: Text(
          appBarRoom != null && appBarRoom.isChannel
              ? L10n.of(context).channelPermissions
              : L10n.of(context).chatPermissions,
        ),
      ),
      body: MaxWidthBody(
        child: StreamBuilder(
          stream: controller.onChanged,
          builder: (context, _) {
            final roomId = controller.roomId;
            final room = roomId == null
                ? null
                : Matrix.of(context).client.getRoomById(roomId);
            if (room == null) {
              return Center(child: Text(L10n.of(context).noRoomsFound));
            }
            final powerLevelsContent = Map<String, Object?>.from(
              room.getState(EventTypes.RoomPowerLevels)?.content ?? {},
            );
            final powerLevels = Map<String, dynamic>.from(powerLevelsContent)
              // `historical` — служебный порог видимости бэкфилла
              // (Synapse-инвариант), не человеко-редактируемый; раньше торчал
              // сырым ключом во всех комнатах. Скрываем.
              ..removeWhere((k, v) => v is! int || k == 'historical');
            final hiddenEventPermissions = {
              EventTypes.RoomTombstone,
              EventTypes.Encryption,
              'm.room.server_acl',
              // Инвариант-ключи канала: работа реакций и СНЯТИЕ своей реакции
              // держатся на порогах `m.reaction:0` и `m.room.redaction:0`
              // ([[RL-channel-reaction-redaction-powerlevel]]). Редактируемый
              // dropdown позволил бы модератору поднять `m.room.redaction`→50 и
              // сломать снятие реакций подписчиками. Скрываем ТОЛЬКО в канале —
              // в обычной (в т.ч. федеративной) группе эти пороги могут быть
              // заданы легитимно и остаются редактируемыми.
              if (room.isChannel) 'm.reaction',
              if (room.isChannel) 'm.room.redaction',
              // Служебный ключ видимости чата, не право человека.
              'com.liza.chat.topology',
              // Пороги создания в компании — своей секцией ниже.
              companyCreateChatKey,
              companyCreateChannelKey,
            };
            // Секция «Создание в компании» — только в главном пространстве
            // своей компании. mainRootSpaceId == null до fetch() — секции нет.
            final isOwnCompanyRoot =
                room.id ==
                Matrix.of(context).singleSpaceService.mainRootSpaceId;
            final eventsPowerLevels =
                Map<String, int?>.from(
                  powerLevelsContent.tryGetMap<String, int?>('events') ?? {},
                )..removeWhere(
                  (k, v) => v is! int || hiddenEventPermissions.contains(k),
                );
            return Column(
              children: [
                ListTile(
                  title: Text(
                    room.isChannel
                        ? L10n.of(context).channelPermissions
                        : L10n.of(context).chatPermissions,
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    room.isChannel
                        ? L10n.of(context).channelPermissionsDescription
                        : L10n.of(context).chatPermissionsDescription,
                    style: TextStyle(color: theme.colorScheme.secondary),
                  ),
                ),
                Column(
                  mainAxisSize: .min,
                  children: [
                    for (final entry in powerLevels.entries)
                      PermissionsListTile(
                        permissionKey: entry.key,
                        permission: entry.value,
                        isChannel: room.isChannel,
                        maxLevel: permissionThresholdMaxLevel(
                          key: entry.key,
                          ownPowerLevel: room.ownPowerLevel,
                        ),
                        onChanged: (level) => controller.editPowerLevel(
                          context,
                          entry.key,
                          entry.value,
                          newLevel: level,
                        ),
                        canEdit: room.canChangePowerLevel,
                      ),
                    Divider(color: theme.dividerColor),
                    ListTile(
                      title: Text(
                        L10n.of(context).notifications,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    Builder(
                      builder: (context) {
                        const key = 'rooms';
                        final value =
                            powerLevelsContent.containsKey('notifications')
                            ? powerLevelsContent
                                      .tryGetMap<String, Object?>(
                                        'notifications',
                                      )
                                      ?.tryGet<int>('rooms') ??
                                  0
                            : 0;
                        return PermissionsListTile(
                          permissionKey: key,
                          permission: value,
                          category: 'notifications',
                          isChannel: room.isChannel,
                          maxLevel: permissionThresholdMaxLevel(
                            key: key,
                            category: 'notifications',
                            ownPowerLevel: room.ownPowerLevel,
                          ),
                          canEdit: room.canChangePowerLevel,
                          onChanged: (level) => controller.editPowerLevel(
                            context,
                            key,
                            value,
                            newLevel: level,
                            category: 'notifications',
                          ),
                        );
                      },
                    ),
                    Divider(color: theme.dividerColor),
                    ListTile(
                      title: Text(
                        room.isChannel
                            ? L10n.of(context).configureChannel
                            : L10n.of(context).configureChat,
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    for (final entry in eventsPowerLevels.entries)
                      PermissionsListTile(
                        permissionKey: entry.key,
                        category: 'events',
                        permission: entry.value ?? 0,
                        isChannel: room.isChannel,
                        maxLevel: permissionThresholdMaxLevel(
                          key: entry.key,
                          category: 'events',
                          ownPowerLevel: room.ownPowerLevel,
                        ),
                        canEdit: room.canChangePowerLevel,
                        onChanged: (level) => controller.editPowerLevel(
                          context,
                          entry.key,
                          entry.value ?? 0,
                          newLevel: level,
                          category: 'events',
                        ),
                      ),
                    if (isOwnCompanyRoot) ...[
                      Divider(color: theme.dividerColor),
                      ListTile(
                        title: Text(
                          L10n.of(context).companyCreationSection,
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      for (final (key, kind) in const [
                        (companyCreateChatKey, CompanyCreateKind.chat),
                        (companyCreateChannelKey, CompanyCreateKind.channel),
                      ])
                        Builder(
                          builder: (context) {
                            // Осознанное исключение из «экран не инъектит
                            // дефолты» (rightsInChannel.md §2): ключа нет —
                            // показываем умолчание, которое держит сервер
                            // (single_space_guard), а не 0.
                            final value = companyCreateThreshold(
                              powerLevelsContent,
                              kind,
                            );
                            return PermissionsListTile(
                              permissionKey: key,
                              category: 'events',
                              permission: value,
                              isChannel: false,
                              maxLevel: permissionThresholdMaxLevel(
                                key: key,
                                category: 'events',
                                ownPowerLevel: room.ownPowerLevel,
                              ),
                              canEdit: room.canChangePowerLevel,
                              onChanged: (level) => controller.editPowerLevel(
                                context,
                                key,
                                value,
                                newLevel: level,
                                category: 'events',
                              ),
                            );
                          },
                        ),
                    ],
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
