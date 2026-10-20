import 'package:flutter/material.dart';

import 'package:badges/badges.dart' as b;
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/developer_mark.dart';
import 'package:liza/widgets/if_developer.dart';
import '../../widgets/matrix.dart';

class EncryptionButton extends StatelessWidget {
  final Room room;
  const EncryptionButton(this.room, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final button = StreamBuilder<SyncUpdate>(
      stream: Matrix.of(
        context,
      ).client.onSync.stream.where((s) => s.deviceLists != null),
      builder: (context, snapshot) {
        final shouldBeEncrypted = room.joinRules != JoinRules.public;
        return FutureBuilder<EncryptionHealthState>(
          future: room.encrypted
              ? room.calcEncryptionHealthState()
              : Future.value(EncryptionHealthState.allVerified),
          builder: (BuildContext context, snapshot) => IconButton(
            visualDensity: PlatformInfos.isMobile
                ? VisualDensity.compact
                : null,
            tooltip: room.encrypted
                ? L10n.of(context).encrypted
                : L10n.of(context).encryptionNotEnabled,
            icon: b.Badge(
              badgeAnimation: const b.BadgeAnimation.fade(),
              showBadge:
                  snapshot.data == EncryptionHealthState.unverifiedDevices,
              badgeStyle: b.BadgeStyle(
                badgeColor: theme.colorScheme.error,
                elevation: 4,
              ),
              badgeContent: Text(
                '!',
                style: TextStyle(
                  fontSize: 9,
                  color: theme.colorScheme.onError,
                  fontWeight: FontWeight.bold,
                ),
              ),
              child: Icon(
                room.encrypted
                    ? Icons.lock_outlined
                    : Icons.no_encryption_outlined,
                size: 20,
                color: (shouldBeEncrypted && !room.encrypted)
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurface,
              ),
            ),
            onPressed: () => context.go('/rooms/${room.id}/encryption'),
          ),
        );
      },
    );
    // Кнопка в шапке узкая: метку кладём уголком поверх, а не рядом.
    return IfDeveloper(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          button,
          const Positioned(
            right: 0,
            bottom: 2,
            child: IgnorePointer(child: DeveloperMark()),
          ),
        ],
      ),
    );
  }
}
