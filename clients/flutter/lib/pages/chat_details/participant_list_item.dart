import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/access_admin_service.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/stories/active_stories_provider.dart';
import 'package:liza/utils/stories/open_user_stories.dart';
import 'package:liza/utils/stories/stories_seen_store.dart';
import 'package:liza/pages/chat_details/participant_row_actions.dart';
import 'package:liza/widgets/member_actions_popup_menu_button.dart';
import '../../widgets/avatar.dart';
import '../../widgets/matrix.dart';
import '../../widgets/story_avatar_ring.dart';
import '../../widgets/user_identifier.dart';
import '../../widgets/user_role_badge.dart';

/// Бейдж роли в строке участника: «Владелец» (100) / «Администратор» (99) /
/// «Модератор» (50) / пусто. Пустая строка — бейдж не рисуется.
String memberRoleLabel(L10n l10n, int powerLevel) => isOwnerLevel(powerLevel)
    ? l10n.roomOwner
    : powerLevel >= adminPowerLevel
    ? l10n.admin
    : powerLevel >= moderatorPowerLevel
    ? l10n.moderator
    : '';

class ParticipantListItem extends StatelessWidget {
  final User user;

  /// Панель управления доступами под строкой. Null — шеврон не показываем.
  final Widget? accessPanel;

  /// Раскрыта ли панель. Игнорируется, если accessPanel == null.
  final bool accessExpanded;

  /// Нажатие на шеврон.
  final VoidCallback? onToggleAccess;

  /// Данные членства в пространстве компании и её дочерних сущностях (Task 7
  /// / space_members). Null — участник обычной комнаты, бейдж роли не рисуем.
  final SpaceMember? spaceMember;

  /// Открыт ли список участников из корневого пространства-компании (а не
  /// суб-пространства) — влияет на подпись «компании» vs «пространства».
  final bool isCompanyRoom;

  /// Скрыт ли участник из витрины списка (LABA-2381). Строка рисуется только
  /// при включённом тумблере «показать скрытых» — тогда показываем бейдж
  /// «скрыт», чтобы админ отличал скрытых и мог их вернуть.
  final bool isHidden;

  const ParticipantListItem(
    this.user, {
    this.accessPanel,
    this.accessExpanded = false,
    this.onToggleAccess,
    this.spaceMember,
    this.isCompanyRoom = false,
    this.isHidden = false,
    super.key,
  });

  /// Подпись роли под именем участника: сначала членство в самом
  /// пространстве (компания/суб-пространство), затем — сводка по дочерним
  /// сущностям, где у участника повышенный PL (см. Task 7 elevatedRooms,
  /// уже отфильтрован по PL >= 50 на сервере).
  String? _roleLabel(BuildContext context) {
    final member = spaceMember;
    if (member == null) return null;
    final l10n = L10n.of(context);
    final inSpace = member.membershipInSpace != null;
    final ownPl = user.powerLevel;

    // Владелец (100) — отдельная роль механики ВК: «Админ компании» под ним
    // путал бы, кто может снимать админов. Не голое «Владелец» — его уже
    // рисует бейдж роли в заголовке строки.
    if (inSpace && isOwnerLevel(ownPl)) {
      return isCompanyRoom ? l10n.roleOwnerOfCompany : l10n.roleOwnerOfSpace;
    }
    if (inSpace && ownPl >= adminPowerLevel) {
      return isCompanyRoom ? l10n.roleAdminOfCompany : l10n.roleAdminOfSpace;
    }
    if (inSpace && ownPl >= moderatorPowerLevel) {
      return isCompanyRoom
          ? l10n.roleModeratorOfCompany
          : l10n.roleModeratorOfSpace;
    }

    final admin = member.elevatedRooms
        .where((r) => r.powerLevel >= adminPowerLevel)
        .length;
    if (admin > 0) return l10n.roleAdminInRooms(admin);

    final moderator = member.elevatedRooms
        .where((r) => r.powerLevel >= moderatorPowerLevel)
        .length;
    if (moderator > 0) return l10n.roleModeratorInRooms(moderator);

    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final membershipBatch = switch (user.membership) {
      Membership.ban => L10n.of(context).banned,
      Membership.invite => L10n.of(context).invited,
      Membership.join => null,
      Membership.knock => L10n.of(context).knocking,
      Membership.leave =>
        user.room.isChannel
            ? L10n.of(context).leftTheChannel
            : L10n.of(context).leftTheChat,
    };

    final permissionBatch = memberRoleLabel(L10n.of(context), user.powerLevel);

    // Баг №4 (Android): используем ОДНУ переменную и для условия тапа, и
    // для Avatar.storyRing ниже - конфликт двух GestureDetector решаем
    // заранее, а не полагаясь на gesture arena.
    final storyRing = Matrix.of(context).isAiUser(user.id)
        ? null
        : ActiveStoriesProvider.instance.ringForUser(
            user.id,
            Matrix.of(context).client,
            StoriesSeenStore(
              Matrix.of(context).store,
              scope: Matrix.of(context).client.userID,
            ),
          );
    final hasActiveRing = storyRing != null && storyRing != StoryRingState.none;

    final showChevron = onToggleAccess != null;

    final roleLabel = _roleLabel(context);
    final childRoomsOnly =
        spaceMember != null && spaceMember!.membershipInSpace == null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          trailing: showChevron
              ? IconButton(
                  icon: Icon(
                    accessExpanded
                        ? Icons.keyboard_arrow_up_outlined
                        : Icons.keyboard_arrow_down_outlined,
                  ),
                  tooltip: L10n.of(context).accessManagement,
                  onPressed: onToggleAccess,
                )
              : null,
          // Выбор колбэка идёт через participantRowTapCallback (чистая функция,
          // покрыта юнит-тестом participant_row_actions_test.dart) — так регресс
          // «строка снова открывает истории при активном кольце» ловится тестом
          // даже без возможности смонтировать ParticipantListItem целиком.
          onTap: participantRowTapCallback(
            hasActiveRing: hasActiveRing,
            openContextMenu: () =>
                showMemberActionsPopupMenu(context: context, user: user),
            openStories: () => openUserStories(context, user.id),
          ),
          title: Wrap(
            spacing: 6,
            runSpacing: 2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                user.calcDisplayname(),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
              UserRoleBadge(userId: user.id),
              if (isHidden)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        L10n.of(context).memberHiddenBadge,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              if (permissionBatch.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: user.powerLevel >= adminPowerLevel
                        ? theme.colorScheme.tertiary
                        : theme.colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    permissionBatch,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: user.powerLevel >= adminPowerLevel
                          ? theme.colorScheme.onTertiary
                          : theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                ),
              if (membershipBatch != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    membershipBatch,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                userIdentifier(
                  user.id,
                  handles: Matrix.of(context).userHandleService,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (roleLabel != null)
                Text(
                  roleLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (childRoomsOnly)
                Text(
                  L10n.of(context).memberViaChildRoomsOnly,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          leading: Opacity(
            opacity: user.membership == Membership.join ? 1 : 0.5,
            child: Avatar(
              mxContent: user.avatarUrl,
              name: user.calcDisplayname(),
              presenceUserId: user.stateKey,
              isHexagonal: Matrix.of(context).isAiUser(user.id),
              storyRing: storyRing,
              // Истории открываются ТОЛЬКО отсюда: строка выше всегда ведёт
              // в контекстное меню, иначе участнику с активной историей нельзя
              // было бы выдать права.
              onStoryTap: hasActiveRing
                  ? () => openUserStories(context, user.id)
                  : null,
            ),
          ),
        ),
        if (accessExpanded && accessPanel != null) accessPanel!,
      ],
    );
  }
}
