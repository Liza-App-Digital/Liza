import 'package:flutter/material.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_group/new_group.dart';
import 'package:liza/utils/create_group_in_space.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/room_name_limit.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/if_developer.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';

class NewGroupView extends StatelessWidget {
  final NewGroupController controller;

  const NewGroupView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final avatar = controller.avatar;
    final error = controller.error;
    return Scaffold(
      appBar: AppBar(
        leading: Center(
          child: BackButton(
            onPressed: controller.loading ? null : Navigator.of(context).pop,
          ),
        ),
        title: Text(
          switch (controller.createGroupType) {
            CreateGroupType.space => L10n.of(context).createCompany,
            CreateGroupType.channel => L10n.of(context).createChannel,
            CreateGroupType.group => L10n.of(context).createGroup,
          },
        ),
      ),
      body: MaxWidthBody(
        child: Column(
          mainAxisSize: .min,
          children: <Widget>[
            const SizedBox(height: 16),
            InkWell(
              borderRadius: BorderRadius.circular(90),
              onTap: controller.loading ? null : controller.selectPhoto,
              child: CircleAvatar(
                radius: Avatar.defaultSize,
                child: avatar == null
                    ? const Icon(Icons.add_a_photo_outlined)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(90),
                        child: Image.memory(
                          avatar,
                          width: Avatar.defaultSize * 2,
                          height: Avatar.defaultSize * 2,
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 32),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: TextField(
                autofocus: true,
                controller: controller.nameController,
                autocorrect: false,
                readOnly: controller.loading,
                maxLength: maxRoomNameLength,
                decoration: InputDecoration(
                  prefixIcon: Icon(
                    controller.createGroupType == CreateGroupType.channel
                        ? Icons.campaign_outlined
                        : Icons.people_outlined,
                  ),
                  labelText: switch (controller.createGroupType) {
                    CreateGroupType.space => L10n.of(context).companyName,
                    CreateGroupType.channel => L10n.of(context).channelName,
                    CreateGroupType.group => L10n.of(context).groupName,
                  },
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (controller.showPlacePicker)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                child: DropdownButtonFormField<GroupPlace?>(
                  key: const ValueKey('newGroupPlacePicker'),
                  initialValue: controller.place,
                  isExpanded: true,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.workspaces_outlined),
                    labelText: L10n.of(context).groupPlace,
                  ),
                  onChanged: controller.loading ? null : controller.setPlace,
                  items: [
                    DropdownMenuItem<GroupPlace?>(
                      value: null,
                      child: Text(L10n.of(context).groupPlaceAuto),
                    ),
                    for (final p in controller.places)
                      DropdownMenuItem<GroupPlace?>(
                        value: p,
                        child: Text(
                          [
                            if (p.company != null)
                              p.company!.getLocalizedDisplayname(),
                            p.space.getLocalizedDisplayname(),
                          ].join(' › '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
            if (controller.createGroupType == CreateGroupType.space) ...[
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 32),
                secondary: const Icon(Icons.public_outlined),
                title: Text(L10n.of(context).publicCompany),
                value: controller.publicGroup,
                onChanged: controller.loading ? null : controller.setPublicGroup,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 4,
                ),
                child: Text(
                  controller.publicGroup
                      ? L10n.of(context).companyPublicHint
                      : L10n.of(context).companyPrivateHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            // Группа в выбранном месте всегда приватная (задача 00, LABA-2539).
            if (controller.createGroupType != CreateGroupType.space &&
                controller.place == null) ...[
              SwitchListTile.adaptive(
                contentPadding: const EdgeInsets.symmetric(horizontal: 32),
                secondary: const Icon(Icons.public_outlined),
                title: Text(
                  controller.createGroupType == CreateGroupType.channel
                      ? L10n.of(context).channelIsPublic
                      : L10n.of(context).groupIsPublic,
                ),
                value: controller.publicGroup,
                onChanged: controller.loading ? null : controller.setPublicGroup,
              ),
              AnimatedSize(
                duration: LizaThemes.animationDuration,
                curve: LizaThemes.animationCurve,
                child: controller.publicGroup
                    ? SwitchListTile.adaptive(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 32,
                        ),
                        secondary: const Icon(Icons.search_outlined),
                        title: Text(
                          controller.createGroupType == CreateGroupType.channel
                              ? L10n.of(context).channelCanBeFoundViaSearch
                              : L10n.of(context).groupCanBeFoundViaSearch,
                        ),
                        value: controller.groupCanBeFound,
                        onChanged: controller.loading
                            ? null
                            : controller.setGroupCanBeFound,
                      )
                    : const SizedBox.shrink(),
              ),
            ],
            IfDeveloper(
              child: AnimatedSize(
                duration: LizaThemes.animationDuration,
                curve: LizaThemes.animationCurve,
                // Шифрование только для обычных групп: канал — broadcast (не
                // шифруется, _createChannel это поле и не использует),
                // пространство — контейнер.
                child: controller.createGroupType != CreateGroupType.group
                    ? const SizedBox.shrink()
                    : SwitchListTile.adaptive(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 32,
                        ),
                        secondary: Icon(
                          Icons.lock_outlined,
                          color: theme.colorScheme.onSurface,
                        ),
                        title: Text(
                          L10n.of(context).enableEncryption,
                          style: TextStyle(color: theme.colorScheme.onSurface),
                        ),
                        subtitle: controller.publicGroup
                            ? Text(L10n.of(context).noEncryptionForPublicRooms)
                            : null,
                        value:
                            controller.enableEncryption &&
                            !controller.publicGroup,
                        onChanged: controller.loading || controller.publicGroup
                            ? null
                            : controller.setEnableEncryption,
                      ),
              ),
            ),
            // Ошибка стоит НАД кнопкой: снизу, последним элементом Column, её
            // выдавливало за экран и пользователь жал «Создать» вслепую.
            AnimatedSize(
              duration: LizaThemes.animationDuration,
              curve: LizaThemes.animationCurve,
              child: error == null
                  ? const SizedBox.shrink()
                  : ListTile(
                      leading: Icon(
                        Icons.warning_outlined,
                        color: theme.colorScheme.error,
                      ),
                      title: Text(
                        error.toLocalizedString(context),
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: controller.loading
                      ? null
                      : controller.submitAction,
                  child: controller.loading
                      ? const LinearProgressIndicator()
                      : Text(
                          switch (controller.createGroupType) {
                            CreateGroupType.space =>
                              L10n.of(context).createCompany,
                            CreateGroupType.channel =>
                              L10n.of(context).createChannel,
                            CreateGroupType.group =>
                              L10n.of(context).createGroupAndInviteUsers,
                          },
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
