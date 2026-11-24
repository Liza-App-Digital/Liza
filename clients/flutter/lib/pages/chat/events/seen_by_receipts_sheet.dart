import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/utils/reader_profile_resolver.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/date_time_extension.dart';
import 'package:liza/utils/room_status_extension.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/matrix.dart';

/// Окно «кто и когда прочитал сообщение» — по тапу на кластер аватарок
/// прочтения. На десктопе (column mode) это центрированный диалог, на
/// мобильных — bottom sheet (см. [showAdaptiveBottomSheet]).
Future<void> showReadReceiptsSheet(
  BuildContext context,
  List<MessageReadReceipt> receipts,
) {
  return showAdaptiveBottomSheet(
    context: context,
    builder: (context) => ReadReceiptsList(receipts: receipts),
  );
}

class ReadReceiptsList extends StatefulWidget {
  final List<MessageReadReceipt> receipts;
  const ReadReceiptsList({required this.receipts, super.key});

  @override
  State<ReadReceiptsList> createState() => _ReadReceiptsListState();
}

class _ReadReceiptsListState extends State<ReadReceiptsList> {
  // Room.== сравнивает только roomId, в том числе между разными аккаунтами.
  final _users = Map<Room, Map<String, Future<User?>>>.identity();

  Future<User?> _resolveUser(User fallback) {
    final room = fallback.room;
    return _users.putIfAbsent(room, () => {}).putIfAbsent(fallback.id, () {
      if (!fallback.id.isValidMatrixId ||
          fallback.id.sigil != '@' ||
          fallback.id.localpart!.isEmpty) {
        return Future.value();
      }
      var timedOut = false;

      User? currentMember() =>
          room.getState(EventTypes.RoomMember, fallback.id)?.asUser(room);

      Future<User?> load() async {
        final current = currentMember();
        if (current != null) return current;
        if (room.partial) {
          final stored = await room.client.database.getUser(fallback.id, room);
          if (timedOut) return null;
          final current = currentMember();
          if (current != null) return current;
          if (stored != null) return stored;
        }
        try {
          final content = await room.client.getRoomStateWithKey(
            room.id,
            EventTypes.RoomMember,
            fallback.id,
          );
          if (timedOut) return null;
          return currentMember() ??
              User.fromState(
                stateKey: fallback.id,
                senderId: fallback.id,
                typeKey: EventTypes.RoomMember,
                content: content,
                room: room,
              );
        } on MatrixException {
          // Недоступный room member допускает запасной глобальный профиль.
        }
        if (timedOut) return null;
        final currentAfterState = currentMember();
        if (currentAfterState != null) return currentAfterState;
        final profile = await ReaderProfileResolver.of(
          room.client,
        ).fetch(fallback.id);
        if (timedOut) return null;
        return currentMember() ??
            User(
              fallback.id,
              room: room,
              displayName: profile?.displayName,
              avatarUrl: profile?.avatarUrl?.toString(),
            );
      }

      // requestUser записывает ответ в room state и может затереть свежий
      // /sync. Здесь нужны только данные строки, без изменения общего state.
      return load().timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          timedOut = true;
          return null;
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Row(
              children: [
                Icon(
                  Icons.done_all_rounded,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  L10n.of(context).readBy,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                Text(
                  '${widget.receipts.length}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: widget.receipts.length,
              itemBuilder: (context, i) {
                final receipt = widget.receipts[i];
                final user = receipt.user;
                return _ReadReceiptTile(
                  key: ValueKey((ObjectKey(user.room), user.id)),
                  receipt: receipt,
                  resolveUser: _resolveUser,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ReadReceiptTile extends StatefulWidget {
  const _ReadReceiptTile({
    required this.receipt,
    required this.resolveUser,
    super.key,
  });

  final MessageReadReceipt receipt;
  final Future<User?> Function(User) resolveUser;

  @override
  State<_ReadReceiptTile> createState() => _ReadReceiptTileState();
}

class _ReadReceiptTileState extends State<_ReadReceiptTile> {
  late final Future<User?> _user;

  @override
  void initState() {
    super.initState();
    _user = widget.resolveUser(widget.receipt.user);
  }

  @override
  Widget build(BuildContext context) {
    final receipt = widget.receipt;
    final fallback = receipt.user;
    final theme = Theme.of(context);
    return FutureBuilder<User?>(
      future: _user,
      initialData: fallback,
      builder: (context, snapshot) {
        final user =
            fallback.room
                .getState(EventTypes.RoomMember, fallback.id)
                ?.asUser(fallback.room) ??
            snapshot.data ??
            fallback;
        final name = user.calcDisplayname();
        return ListTile(
          leading: Avatar(
            mxContent: user.avatarUrl,
            name: name,
            isHexagonal: Matrix.of(context).isAiUser(user.id),
          ),
          title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: receipt.ts > 0
              ? Text(
                  DateTime.fromMillisecondsSinceEpoch(
                    receipt.ts,
                  ).localizedTime(context),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                )
              : null,
        );
      },
    );
  }
}
