import 'package:liza/utils/push_contract_frame.dart';
import 'package:liza/utils/confirmed_read_state.dart';
import 'package:flutter/material.dart';

import 'package:badges/badges.dart' as b;
import 'package:matrix/matrix.dart';

import '../utils/chat_topology.dart';
import 'matrix.dart';

class UnreadRoomsBadge extends StatelessWidget {
  final bool Function(Room) filter;
  final String scope;
  final String? scopeRoomId;
  final b.BadgePosition? badgePosition;
  final Widget? child;

  const UnreadRoomsBadge({
    super.key,
    required this.filter,
    this.scope = 'filtered',
    this.scopeRoomId,
    this.badgePosition,
    this.child,
  });

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: ConfirmedReadState.forClient(
      Matrix.of(context).client,
    ).revision,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);

    // Единый источник истины со счётчиком бейджа приложения
    // (`countsTowardAppBadge = !isHiddenChat && isUnreadOrInvited`): скрытые
    // (stories/topology-hidden) комнаты пользователь не может открыть и
    // «прочитать», поэтому их непрочитанность не должна оставлять неснимаемый
    // бейдж на кнопке «назад» / в nav-rail — так же, как их не показывают
    // список чатов и иконка приложения.
    final client = Matrix.of(context).client;
    final unreadCount = client.rooms
        .where(filter)
        .where((r) => r.countsTowardAppBadge)
        .length;
    return PushContractFrame.nav(
      client,
      scope,
      scopeRoomId,
      filter,
      unreadCount,
      b.Badge(
        badgeStyle: b.BadgeStyle(
          badgeColor: theme.colorScheme.primary,
          elevation: 4,
          borderSide: BorderSide(color: theme.colorScheme.surface, width: 2),
        ),
        badgeContent: Text(
          unreadCount.toString(),
          style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 12),
        ),
        showBadge: unreadCount != 0,
        badgeAnimation: const b.BadgeAnimation.scale(),
        position: badgePosition ?? b.BadgePosition.bottomEnd(),
        child: child,
      ),
    );
  }
}
