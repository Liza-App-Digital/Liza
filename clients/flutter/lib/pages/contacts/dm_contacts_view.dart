import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/direct_chat_draft.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/widgets/matrix.dart';
import 'contact_list_tile.dart';

/// Собеседник из личного чата — строка «Контактов» на десктопе и web.
class DmContact {
  final String userId;
  final String displayName;
  final DateTime lastActivity;

  const DmContact({
    required this.userId,
    required this.displayName,
    required this.lastActivity,
  });
}

/// Люди, с которыми есть личный чат: телефонной книги на десктопе и web нет
/// (flutter_contacts — только Android/iOS), поэтому «Контакты» там — адресный
/// список собеседников, как в Telegram Desktop.
///
/// Комнаты — тот же фильтр, что у ленты частых собеседников
/// ([isFrequentContactCandidateRoom]: join, собеседник не вышел, не сторис,
/// не канал, не запрос к Лизе), но без её окна в 30 дней и лимита 15: старый
/// или молчаливый собеседник из контактов не пропадает. Боты отсеиваются
/// [isBotOrAi]; несколько DM с одним человеком дают одну строку, свежие сверху.
/// ledger:RL-contacts-entry-avatar-all-platforms
List<DmContact> dmContactPeers(
  Iterable<Room> rooms, {
  required bool Function(String userId) isBotOrAi,
}) {
  final byUser = <String, DmContact>{};
  for (final room in rooms) {
    if (!isFrequentContactCandidateRoom(room)) continue;
    final peer = room.directChatMatrixID!;
    if (isBotOrAi(peer)) continue;
    final activity = room.latestEventReceivedTime;
    final prev = byUser[peer];
    if (prev != null && !activity.isAfter(prev.lastActivity)) continue;
    // Имя — из стейта участника, без сети: unsafeGetUserFromMemoryOrFallback
    // дёргает requestUser на каждого (шторм запросов, RL-stories-bar-avatar).
    final name = room
        .getState(EventTypes.RoomMember, peer)
        ?.content
        .tryGet<String>('displayname');
    byUser[peer] = DmContact(
      userId: peer,
      displayName: (name == null || name.trim().isEmpty)
          ? peer.localpart ?? peer
          : name,
      lastActivity: activity,
    );
  }
  return byUser.values.toList()
    ..sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
}

class DmContactsView extends StatefulWidget {
  const DmContactsView({super.key});

  @override
  State<DmContactsView> createState() => _DmContactsViewState();
}

class _DmContactsViewState extends State<DmContactsView> {
  List<DmContact>? _contacts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  List<DmContact> _collect(MatrixState matrix) =>
      dmContactPeers(matrix.client.rooms, isBotOrAi: matrix.isBotOrAiUser);

  Future<void> _load() async {
    if (!mounted) return;
    final matrix = Matrix.of(context);
    // Бот компании узнаётся только по роли ai из каталога: ждём её коротко,
    // чтобы он не мелькнул среди людей; поздний ответ пересоберёт список.
    final candidates = _collect(matrix).map((c) => c.userId);
    await waitForRolesBounded(
      matrix.userRoleService.fetchRoles(candidates),
      onLate: () {
        if (mounted) setState(() => _contacts = _collect(matrix));
      },
    );
    if (mounted) setState(() => _contacts = _collect(matrix));
  }

  @override
  Widget build(BuildContext context) {
    final contacts = _contacts;
    if (contacts == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final client = Matrix.of(context).client;
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            l10n.contactsPhoneBookOnMobile,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        ListTile(
          leading: Icon(Icons.adaptive.share_outlined),
          title: Text(l10n.inviteContact),
          onTap: () => LizaShare.shareInvitePeople(context),
        ),
        const Divider(),
        if (contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(l10n.noContactsToShow)),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              l10n.contactsChatPeers,
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          for (final c in contacts)
            ContactListTile(
              displayName: c.displayName,
              subtitle: c.userId,
              mxid: c.userId,
              onWrite: (mxid) =>
                  openDirectChatOrDraft(GoRouter.of(context), client, mxid),
              onInvite: () => LizaShare.shareInvitePeople(context),
            ),
        ],
      ],
    );
  }
}
