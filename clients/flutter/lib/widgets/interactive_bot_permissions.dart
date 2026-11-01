import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/bot_interactive_consent.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/utils/chat_topology.dart';

Future<int?> chooseBotInvitePermissions({
  required BuildContext context,
  required Room room,
  required String botMxid,
  RegisteredBot? bot,
  required bool Function() isCurrent,
}) => showInteractiveConsent<int>(
  context: context,
  isCurrent: isCurrent,
  builder: (context) => SimpleDialog(
    title: Text(L10n.of(context).botInvitePermissions(botMxid)),
    children: [
      if (bot?.requestsAdministratorRights(isChannel: room.isChannel) == true)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Text(L10n.of(context).botRequestsPermissions),
        ),
      SimpleDialogOption(
        onPressed: () => Navigator.of(context).pop(0),
        child: Text(L10n.of(context).normalUser),
      ),
      if (room.canChangePowerLevel &&
          assignableRoleMaxLevel(room.ownPowerLevel) >= moderatorPowerLevel)
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(moderatorPowerLevel),
          child: Text(L10n.of(context).moderator),
        ),
      if (room.canChangePowerLevel &&
          assignableRoleMaxLevel(room.ownPowerLevel) >= adminPowerLevel)
        SimpleDialogOption(
          onPressed: () => Navigator.of(context).pop(adminPowerLevel),
          child: Text(L10n.of(context).admin),
        ),
    ],
  ),
);

/// Повторно проверяет свежий state. Сначала ограничивает старые привилегии
/// покинувшего комнату бота, а повышение выполняет лишь после успешного invite.
/// Никакой default-administrator-rights не превращается в автоматический grant.
Future<void> inviteBotWithPermissions(
  Room room,
  String botMxid,
  int selectedLevel,
) async {
  if (![0, moderatorPowerLevel, adminPowerLevel].contains(selectedLevel)) {
    throw ArgumentError.value(selectedLevel);
  }
  final client = room.client;
  final token = client.accessToken;
  final userId = client.userID;
  Future<void> setLevel({required bool beforeInvite}) async {
    final raw = await client.getRoomStateWithKey(
      room.id,
      EventTypes.RoomPowerLevels,
      '',
    );
    if (client.accessToken != token || client.userID != userId) {
      throw StateError('Session changed');
    }
    final users = Map<String, dynamic>.from(
      raw['users'] is Map ? raw['users'] as Map : const {},
    );
    final defaultLevel = raw['users_default'] is int
        ? raw['users_default'] as int
        : 0;
    final own = users[userId] is int ? users[userId] as int : defaultLevel;
    final previous = users[botMxid] is int
        ? users[botMxid] as int
        : defaultLevel;
    if (selectedLevel > assignableRoleMaxLevel(own)) {
      throw StateError('Insufficient permissions');
    }
    if (beforeInvite && previous <= selectedLevel ||
        !beforeInvite && previous == selectedLevel) {
      return;
    }
    if (selectedLevel > assignableRoleMaxLevel(own) ||
        previous >= own ||
        botMxid == userId) {
      throw StateError('Insufficient permissions');
    }
    users[botMxid] = selectedLevel;
    await client.setRoomStateWithKey(room.id, EventTypes.RoomPowerLevels, '', {
      ...raw,
      'users': users,
    });
  }

  await setLevel(beforeInvite: true);
  if (client.accessToken != token || client.userID != userId) {
    throw StateError('Session changed');
  }
  await room.invite(botMxid);
  await setLevel(beforeInvite: false);
}
