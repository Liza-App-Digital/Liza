import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_members/access_admin_panel.dart';
import 'package:liza/utils/access_admin_service.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import '../../widgets/layouts/max_width_body.dart';
import '../../widgets/matrix.dart';
import '../chat_details/participant_list_item.dart';
import 'chat_members.dart';
import 'member_filter_checkboxes.dart';
import 'member_role_filter.dart';

class ChatMembersView extends StatelessWidget {
  final ChatMembersController controller;

  const ChatMembersView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final room = Matrix.of(
      context,
    ).client.getRoomById(controller.widget.roomId);
    if (room == null) {
      return Scaffold(
        appBar: AppBar(title: Text(L10n.of(context).oopsSomethingWentWrong)),
        body: Center(
          child: Text(L10n.of(context).youAreNoLongerParticipatingInThisChat),
        ),
      );
    }

    final members = controller.filteredMembers;

    // Участники ТОЛЬКО дочерних сущностей (нет User-объекта из SDK — не
    // вступали в саму комнату widget.roomId) добавляем отдельной веткой,
    // только на вкладке "участники". Фильтры ролей и чекбоксов к ним уже
    // применены в контроллере (childOnlySpaceMembers), здесь остаётся поиск.
    //
    // Ищем и по MXID, и по отображаемому имени: на экране у child-only
    // рисуется calcDisplayname() синтетического User (ParticipantListItem
    // ниже строит такой же), а не сырой userId — иначе строка, найденная
    // глазами по имени, не находится поиском по нему же.
    final childOnlyMembers =
        members == null || controller.membershipFilter != Membership.join
        ? const <SpaceMember>[]
        : controller.childOnlySpaceMembers.where((m) {
            final filterText = controller.filterController.text
                .toLowerCase()
                .trim();
            if (filterText.isEmpty) return true;
            if (m.userId.toLowerCase().contains(filterText)) return true;
            final displayName = User(
              m.userId,
              membership: 'join',
              room: room,
            ).calcDisplayname().toLowerCase();
            return displayName.contains(filterText);
          }).toList();

    // Счётчик заголовка вычитает скрытых ДЛЯ ЗРИТЕЛЯ (M6): «N участников» должно
    // совпадать с числом видимых строк, иначе «10 участников / 8 строк» само
    // выдаёт факт и число скрытых. Себя зритель видит → его не вычитаем. При
    // включённом тумблере скрытые снова в списке, счётчик — полный.
    //
    // Вычитаем ТОЛЬКО тех скрытых, кто РЕАЛЬНО состоит в комнате: room state
    // hidden_members не чистится при kick/leave — stale id скрытого, которого
    // потом кикнули, занижал бы счётчик (mJoinedMemberCount уже без него).
    final myId = Matrix.of(context).client.userID ?? '';
    final hiddenIds = room.hiddenMemberIds;
    final currentMemberIds = room.getParticipants().map((u) => u.id).toSet();
    final hiddenForViewer = controller.showHiddenMembers
        ? 0
        : hiddenIds
              .where((id) => id != myId && currentMemberIds.contains(id))
              .length;
    final rawRoomCount =
        (room.summary.mJoinedMemberCount ?? 0) +
        (room.summary.mInvitedMemberCount ?? 0);
    final roomCount = (rawRoomCount - hiddenForViewer).clamp(0, rawRoomCount);

    final error = controller.error;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        leading: const Center(child: BackButton()),
        title: Text(L10n.of(context).countParticipants(roomCount)),
        actions: [
          if (room.canInvite)
            IconButton(
              onPressed: () => context.go('/rooms/${room.id}/invite'),
              icon: const Icon(Icons.person_add_outlined),
            ),
        ],
      ),
      body: MaxWidthBody(
        withScrolling: false,
        innerPadding: const EdgeInsets.symmetric(vertical: 8),
        child: error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      const Icon(Icons.error_outline),
                      Text(error.toLocalizedString(context)),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: controller.refreshMembers,
                        icon: const Icon(Icons.refresh_outlined),
                        label: Text(L10n.of(context).tryAgain),
                      ),
                    ],
                  ),
                ),
              )
            : members == null
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator.adaptive(),
                ),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: members.length + childOnlyMembers.length + 1,
                itemBuilder: (context, i) {
                  if (i == 0) {
                    final availableFilters = Membership.values
                        .where(
                          (membership) =>
                              controller.members?.any(
                                (member) => member.membership == membership,
                              ) ??
                              false,
                        )
                        .toList();
                    availableFilters.sort(
                      (a, b) => a == Membership.join ? -1 : 1,
                    );
                    return Column(
                      mainAxisSize: .min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: TextField(
                            controller: controller.filterController,
                            onChanged: controller.setFilter,
                            decoration: InputDecoration(
                              filled: true,
                              fillColor: theme.colorScheme.secondaryContainer,
                              border: OutlineInputBorder(
                                borderSide: BorderSide.none,
                                borderRadius: BorderRadius.circular(99),
                              ),
                              hintStyle: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.normal,
                              ),
                              prefixIcon: const Icon(Icons.search_outlined),
                              hintText: L10n.of(context).search,
                            ),
                          ),
                        ),
                        if (availableFilters.length > 1)
                          SizedBox(
                            height: 64,
                            child: ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12.0,
                                vertical: 12.0,
                              ),
                              scrollDirection: Axis.horizontal,
                              itemCount: availableFilters.length,
                              itemBuilder: (context, i) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4.0,
                                ),
                                child: FilterChip(
                                  label: Text(switch (availableFilters[i]) {
                                    Membership.ban => L10n.of(context).banned,
                                    Membership.invite =>
                                      L10n.of(context).countInvited(
                                        room.summary.mInvitedMemberCount ??
                                            controller.members
                                                ?.where(
                                                  (member) =>
                                                      member.membership ==
                                                      Membership.invite,
                                                )
                                                .length ??
                                            0,
                                      ),
                                    Membership.join =>
                                      L10n.of(context).countParticipants(
                                        room.summary.mJoinedMemberCount ??
                                            controller.members
                                                ?.where(
                                                  (member) =>
                                                      member.membership ==
                                                      Membership.join,
                                                )
                                                .length ??
                                            0,
                                      ),
                                    Membership.knock => L10n.of(
                                      context,
                                    ).knocking,
                                    Membership.leave => L10n.of(
                                      context,
                                    ).leftTheChat,
                                  }),
                                  selected:
                                      controller.membershipFilter ==
                                      availableFilters[i],
                                  onSelected: (_) => controller
                                      .setMembershipFilter(availableFilters[i]),
                                ),
                              ),
                            ),
                          ),
                        SizedBox(
                          height: 52,
                          child: ListView(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12.0,
                            ),
                            scrollDirection: Axis.horizontal,
                            children: MemberRoleFilter.values
                                .map(
                                  (filter) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4.0,
                                    ),
                                    child: FilterChip(
                                      label: Text(switch (filter) {
                                        MemberRoleFilter.all => L10n.of(
                                          context,
                                        ).roleFilterAll,
                                        MemberRoleFilter.admins => L10n.of(
                                          context,
                                        ).roleFilterAdmins,
                                        MemberRoleFilter.moderators => L10n.of(
                                          context,
                                        ).roleFilterModerators,
                                        MemberRoleFilter.users => L10n.of(
                                          context,
                                        ).roleFilterUsers,
                                      }),
                                      selected: controller.roleFilter == filter,
                                      onSelected: (_) =>
                                          controller.setRoleFilter(filter),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                        if (controller.membershipFiltersReady &&
                            !controller.filterBaseEmpty)
                          MemberFilterCheckboxes(
                            serverName: controller.companyServerName,
                            spaceName: controller.spaceLabel,
                            isSpace: room.isSpace,
                            isCompanyRoot: controller.isCompanyRoom,
                            showServer: controller.serverFilterUseful,
                            showCompany: controller.companyFilterUseful,
                            onServerOnly: controller.onServerOnly,
                            inCompanyOnly: controller.inCompanyOnly,
                            onServerChanged: controller.setOnServerOnly,
                            onCompanyChanged: controller.setInCompanyOnly,
                          ),
                        // Тумблер «показать скрытых» — только тому, кто вправе
                        // скрывать (PL>=99), и только если скрытые вообще есть.
                        if (room.canHideMembers && hiddenIds.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16.0,
                            ),
                            child: MembershipCheckbox(
                              label: L10n.of(context).showHiddenMembers,
                              value: controller.showHiddenMembers,
                              onChanged: controller.setShowHiddenMembers,
                            ),
                          ),
                      ],
                    );
                  }
                  i--;
                  if (i < members.length) {
                    final member = members[i];
                    return ParticipantListItem(
                      member,
                      spaceMember: controller.spaceMembers[member.id],
                      isCompanyRoom: controller.isCompanyRoom,
                      isHidden: hiddenIds.contains(member.id),
                      accessExpanded:
                          controller.expandedAccessUserId == member.id,
                      onToggleAccess:
                          controller.canManageAccess &&
                              member.id != Matrix.of(context).client.userID
                          ? () => controller.toggleAccessPanel(member.id)
                          : null,
                      accessPanel: _accessPanel(context, controller, member.id),
                    );
                  }

                  // Участник только дочерних сущностей: нет User-объекта
                  // из SDK (не состоит в widget.roomId), строим синтетический
                  // — ParticipantListItem рисует его по данным SpaceMember.
                  final spaceMember = childOnlyMembers[i - members.length];
                  final syntheticUser = User(
                    spaceMember.userId,
                    membership: 'join',
                    room: room,
                  );
                  // Шеврон нужен и здесь: кнопка деактивации аккаунта живёт
                  // только в раскрывающейся панели доступов.
                  return ParticipantListItem(
                    syntheticUser,
                    spaceMember: spaceMember,
                    isCompanyRoom: controller.isCompanyRoom,
                    isHidden: hiddenIds.contains(spaceMember.userId),
                    accessExpanded:
                        controller.expandedAccessUserId == spaceMember.userId,
                    onToggleAccess:
                        controller.canManageAccess &&
                            spaceMember.userId !=
                                Matrix.of(context).client.userID
                        ? () => controller.toggleAccessPanel(spaceMember.userId)
                        : null,
                    accessPanel: _accessPanel(
                      context,
                      controller,
                      spaceMember.userId,
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget? _accessPanel(
    BuildContext context,
    ChatMembersController controller,
    String userId,
  ) {
    if (controller.isDossierLoading(userId)) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(72, 4, 16, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    final dossier = controller.dossierFor(userId);
    if (dossier == null) {
      if (controller.accessErrors[userId] == null) return null;
      return Padding(
        padding: const EdgeInsets.fromLTRB(72, 4, 16, 12),
        child: Row(
          children: [
            Expanded(child: Text(L10n.of(context).accessDossierLoadFailed)),
            TextButton(
              onPressed: () => controller.toggleAccessPanel(userId),
              child: Text(L10n.of(context).tryAgain),
            ),
          ],
        ),
      );
    }

    return AccessAdminPanel(
      dossier: dossier,
      onToggleActive: () => controller.toggleAccountActive(userId),
    );
  }
}
