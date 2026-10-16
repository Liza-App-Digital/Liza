import 'package:flutter/material.dart' hide Visibility;

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/layouts/max_width_body.dart';

class ChatAccessSettingsPageView extends StatelessWidget {
  final ChatAccessSettingsController controller;
  const ChatAccessSettingsPageView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final room = controller.room;
    return Scaffold(
      appBar: AppBar(
        leading: const Center(child: BackButton()),
        title: Text(L10n.of(context).accessAndVisibility),
      ),
      body: MaxWidthBody(
        child: StreamBuilder<Object>(
          stream: room.client.onRoomState.stream.where(
            (update) => update.roomId == controller.room.id,
          ),
          builder: (context, snapshot) {
            final canonicalAlias = room.canonicalAlias;
            final altAliases =
                room
                    .getState(EventTypes.RoomCanonicalAlias)
                    ?.content
                    .tryGetList<String>('alt_aliases') ??
                [];
            return Column(
              mainAxisSize: .min,
              children: [
                // «Тип канала» — ПЕРВЫЙ блок: тип канала первичен, от него
                // зависят и видимость истории, и ссылка. Виден ВСЕГДА для
                // канала, независимо от join_rules: он и есть контрол, который
                // управляет публичностью (внешнего гейта {public,knock} тут
                // быть не должно — иначе «Частный» скрыл бы сам переключатель
                // и запер канал в приватном режиме без пути назад).
                if (controller.isChannel) ...[
                  ListTile(
                    title: Text(
                      L10n.of(context).channelType,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(L10n.of(context).channelTypePublic),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(L10n.of(context).channelTypePrivate),
                        ),
                      ],
                      selected: {controller.isPublicChannel},
                      onSelectionChanged: controller.joinRulesLoading
                          ? null
                          : (selected) =>
                                controller.setChannelPublic(selected.first),
                    ),
                  ),
                  ListTile(
                    subtitle: Text(
                      controller.isPublicChannel
                          ? L10n.of(context).channelTypePublicHint
                          : L10n.of(context).channelTypePrivateHint,
                    ),
                  ),
                  if (controller.isPublicChannel) ...[
                    Divider(color: theme.dividerColor),
                    ListTile(
                      title: Text(
                        L10n.of(context).channelLink,
                        style: TextStyle(
                          color: theme.colorScheme.secondary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    _ChannelHandleTile(controller: controller),
                  ],
                  Divider(color: theme.dividerColor),
                ],
                // «Тип группы» — простой тумблер публичности для ОБЫЧНОЙ группы
                // (аналог «Тип канала»). Виден только в бинарных состояниях
                // join_rules ∈ {public, invite}; при knock/restricted (группа в
                // пространстве) скрыт — там управляет сырой radio ниже, а
                // тумблер бинарен и врал бы. Directory/адреса-блок и radio НЕ
                // трогаем — они дают полный контроль.
                if (controller.showGroupTypeToggle) ...[
                  ListTile(
                    title: Text(
                      L10n.of(context).groupType,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(L10n.of(context).groupTypePublic),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(L10n.of(context).groupTypePrivate),
                        ),
                      ],
                      selected: {controller.isPublicGroup},
                      // Гейт по фактическому праву смены join_rules (обычно
                      // state_default: 50), симметрично сырому radio ниже. Иначе
                      // рядовой участник (PL 0) видел бы активный тумблер и ловил
                      // M_FORBIDDEN в снекбаре — «скрыто в UI ≠ снято право».
                      onSelectionChanged:
                          controller.joinRulesLoading ||
                              !room.canChangeJoinRules
                          ? null
                          : (selected) =>
                                controller.setGroupPublic(selected.first),
                    ),
                  ),
                  ListTile(
                    subtitle: Text(
                      controller.isPublicGroup
                          ? L10n.of(context).groupTypePublicHint
                          : L10n.of(context).groupTypePrivateHint,
                    ),
                  ),
                  Divider(color: theme.dividerColor),
                ],
                // «Тип компании» — тумблер публичности для пространства-компании
                // (root-space). Аналог «Тип группы»: у компании, как у группы,
                // нет peek-ленты, поэтому directory-видимость управляется этим
                // тумблером, а отдельный switch «Найти в поиске» и «Публичные
                // адреса» для компании скрыты (гейт !isCompany ниже), чтобы не
                // было двух контролов одной directory-видимости.
                if (controller.showCompanyTypeToggle) ...[
                  ListTile(
                    title: Text(
                      L10n.of(context).companyType,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(
                          value: true,
                          label: Text(L10n.of(context).companyTypePublic),
                        ),
                        ButtonSegment(
                          value: false,
                          label: Text(L10n.of(context).companyTypePrivate),
                        ),
                      ],
                      selected: {controller.isPublicCompany},
                      // Гейт по фактическому праву смены join_rules (state_default
                      // обычно 50). Иначе рядовой участник видел бы активный
                      // тумблер и ловил M_FORBIDDEN — «скрыто в UI ≠ снято право».
                      onSelectionChanged:
                          controller.joinRulesLoading ||
                              !room.canChangeJoinRules
                          ? null
                          : (selected) =>
                                controller.setCompanyPublic(selected.first),
                    ),
                  ),
                  ListTile(
                    subtitle: Text(
                      controller.isPublicCompany
                          ? L10n.of(context).companyTypePublicHint
                          : L10n.of(context).companyTypePrivateHint,
                    ),
                  ),
                  Divider(color: theme.dividerColor),
                ],
                ListTile(
                  title: Text(
                    room.isChannel
                        ? L10n.of(context).visibilityOfTheChannelHistory
                        : L10n.of(context).visibilityOfTheChatHistory,
                    style: TextStyle(
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                RadioGroup<HistoryVisibility>(
                  groupValue: room.historyVisibility,
                  // Публичный канал ОБЯЗАН быть world_readable (иначе рвётся
                  // лента-peek неучастника — channel_peek.dart). Поэтому для
                  // публичного канала раздел read-only: текущее значение
                  // показано выбранным, но менять его из UI нельзя — иначе
                  // один тап убил бы публичную ленту без пути назад.
                  onChanged:
                      controller.historyVisibilityLoading ||
                          !room.canChangeHistoryVisibility ||
                          controller.isPublicChannel
                      ? (_) {}
                      : controller.setHistoryVisibility,
                  child: Column(
                    mainAxisSize: .min,
                    children: [
                      for (final historyVisibility in HistoryVisibility.values)
                        RadioListTile<HistoryVisibility>.adaptive(
                          enabled: !controller.isPublicChannel,
                          title: Text(
                            historyVisibility.getLocalizedString(
                              MatrixLocals(L10n.of(context)),
                            ),
                          ),
                          value: historyVisibility,
                        ),
                    ],
                  ),
                ),
                // Чат обсуждения закрытого канала пускает по членству в канале
                // (restricted + allow на канал, задаёт сервер channel_sync).
                // Radio записал бы allow = родители-пространства без канала и
                // молча закрыл бы вход всем подписчикам — поэтому прячем.
                if (controller.showJoinRulesPicker) ...[
                  Divider(color: theme.dividerColor),
                  ListTile(
                    title: Text(
                      room.isChannel
                          ? L10n.of(context).whoIsAllowedToJoinThisChannel
                          : L10n.of(context).whoIsAllowedToJoinThisGroup,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  RadioGroup(
                    groupValue: room.joinRules,
                    onChanged: controller.setJoinRule,
                    child: Column(
                      mainAxisSize: .min,
                      children: [
                        for (final joinRule in controller.availableJoinRules)
                          if (joinRule != JoinRules.private)
                            RadioListTile<JoinRules>.adaptive(
                              enabled:
                                  !controller.joinRulesLoading &&
                                  room.canChangeJoinRules,
                              title: Text(
                                joinRule.localizedString(
                                  L10n.of(context),
                                  controller.knownSpaceParents,
                                ),
                              ),
                              value: joinRule,
                            ),
                      ],
                    ),
                  ),
                ],
                // Публичные адреса/directory — ТОЛЬКО для НЕ-канала (у канала
                // публичность управляется блоком «Тип канала» + ником выше).
                // После переноса «Тип канала» наверх единый if/else-if
                // расщеплён на два независимых if, поэтому гейт !isChannel
                // обязателен — иначе адреса протекут в канал. Divider внутри
                // блока (а не снаружи) — чтобы не висел при отсутствии блока.
                // Для компании directory-видимость управляется тумблером «Тип
                // компании» выше — здесь скрываем (!isCompany), иначе два
                // контрола одного setRoomVisibilityOnDirectory + утечка
                // «Публичных адресов» на экран компании.
                if (!controller.isChannel &&
                    !controller.isCompany &&
                    {
                      JoinRules.public,
                      JoinRules.knock,
                    }.contains(room.joinRules)) ...[
                  Divider(color: theme.dividerColor),
                  ListTile(
                    title: Text(
                      L10n.of(context).publicChatAddresses,
                      style: TextStyle(
                        color: theme.colorScheme.secondary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.add_outlined),
                      tooltip: L10n.of(context).createNewAddress,
                      onPressed: controller.addAlias,
                    ),
                  ),
                  if (canonicalAlias.isNotEmpty)
                    _AliasListTile(
                      alias: canonicalAlias,
                      onDelete:
                          room.canChangeStateEvent(
                            EventTypes.RoomCanonicalAlias,
                          )
                          ? () => controller.deleteAlias(canonicalAlias)
                          : null,
                      isCanonicalAlias: true,
                    ),
                  for (final alias in altAliases)
                    _AliasListTile(
                      alias: alias,
                      onDelete:
                          room.canChangeStateEvent(
                            EventTypes.RoomCanonicalAlias,
                          )
                          ? () => controller.deleteAlias(alias)
                          : null,
                    ),
                  FutureBuilder(
                    future: room.client.getLocalAliases(room.id),
                    builder: (context, snapshot) {
                      final localAddresses = snapshot.data;
                      if (localAddresses == null) {
                        return const SizedBox.shrink();
                      }
                      localAddresses.remove(room.canonicalAlias);
                      localAddresses.removeWhere(
                        (alias) => altAliases.contains(alias),
                      );
                      return Column(
                        mainAxisSize: .min,
                        children: localAddresses
                            .map(
                              (alias) => _AliasListTile(
                                alias: alias,
                                published: false,
                                onDelete: () => controller.deleteAlias(alias),
                              ),
                            )
                            .toList(),
                      );
                    },
                  ),
                  Divider(color: theme.dividerColor),
                  FutureBuilder(
                    future: room.client.getRoomVisibilityOnDirectory(room.id),
                    builder: (context, snapshot) => SwitchListTile.adaptive(
                      value: snapshot.data == Visibility.public,
                      title: Text(
                        L10n.of(context).chatCanBeDiscoveredViaSearchOnServer(
                          room.client.userID!.domain!,
                        ),
                      ),
                      onChanged: controller.setChatVisibilityOnDirectory,
                    ),
                  ),
                ],
                // Запрет сохранения контента — общий для каналов и групповых
                // чатов: state-событие одно и то же, тексты разные (в канале
                // «подписчики»/«посты», в группе «участники»/«сообщения»).
                // В личном чате настройка бессмысленна — собеседник всё равно
                // видит переписку, поэтому тумблера там нет.
                //
                // В ПРОСТРАНСТВЕ у настройки нет предмета: сообщений там не
                // живёт, а дочерние чаты флаг не наследуют — тумблер только
                // вводил в заблуждение (ровно с этого начался LABA-2541).
                // Гейт `!isSpace` — та же идиома, что у `showGroupTypeToggle`.
                // Клапан `|| room.noForwards`: пространство, где флаг уже
                // включён, обязано сохранить способ его выключить, иначе
                // получаем необратимую для пользователя ловушку.
                if (!room.isDirectChat &&
                    (!room.isSpace || room.noForwards)) ...[
                  Divider(color: theme.dividerColor),
                  SwitchListTile.adaptive(
                    value: room.noForwards,
                    title: Text(
                      controller.isChannel
                          ? L10n.of(context).channelProtectContent
                          : L10n.of(context).groupProtectContent,
                    ),
                    subtitle: Text(
                      controller.isChannel
                          ? L10n.of(context).channelProtectContentDescription
                          : L10n.of(context).groupProtectContentDescription,
                    ),
                    // Гейт по фактическому праву записи state (обычно
                    // state_default: 50). Иначе участник без прав дёргал бы
                    // тумблер и ловил M_FORBIDDEN в снекбаре.
                    onChanged:
                        controller.noForwardsLoading ||
                            !room.canChangeStateEvent(channelNoForwardsState)
                        ? null
                        : controller.setNoForwards,
                  ),
                  // Включивший запрет обычно модератор или админ — то есть сам
                  // из-под запрета освобождён и НИКАКОГО эффекта у себя не
                  // увидит. Без этой строки настройка выглядит сломанной (так и
                  // родился LABA-2541). Поэтому здесь не констатация (она уже
                  // есть в подписи выше), а инструкция, как убедиться.
                  //
                  // Условие — через готовый предикат `isContentProtected`, а не
                  // сравнением power level в виджете: порог живёт в одном месте
                  // (`contentProtected`), и дублировать его здесь — регресс.
                  if (room.noForwards && !room.isContentProtected)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: Text(
                        L10n.of(context).protectContentExemptHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
                /* ListTile(
                  title: Text(L10n.of(context).globalChatId),
                  subtitle: SelectableText(room.id),
                  trailing: IconButton(
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () => LizaShare.share(room.id, context),
                  ),
                ),
                ListTile(
                  title: Text(L10n.of(context).roomVersion),
                  subtitle: SelectableText(
                    room
                            .getState(EventTypes.RoomCreate)!
                            .content
                            .tryGet<String>('room_version') ??
                        'Unknown',
                  ),
                  trailing: room.canSendEvent(EventTypes.RoomTombstone)
                      ? IconButton(
                          icon: const Icon(Icons.upgrade_outlined),
                          onPressed: controller.updateRoomAction,
                        )
                      : null,
                ), */
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AliasListTile extends StatelessWidget {
  const _AliasListTile({
    required this.alias,
    required this.onDelete,
    this.isCanonicalAlias = false,
    this.published = true,
  });

  final String alias;
  final void Function()? onDelete;
  final bool isCanonicalAlias;
  final bool published;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      leading: isCanonicalAlias
          ? const Icon(Icons.star)
          : const Icon(Icons.link_outlined),
      title: InkWell(
        onTap: () => LizaShare.share('https://matrix.to/#/$alias', context),
        child: SelectableText(
          alias,
          style: TextStyle(
            decoration: TextDecoration.underline,
            decorationColor: theme.colorScheme.primary,
            color: theme.colorScheme.primary,
            fontSize: 14,
          ),
        ),
      ),
      trailing: onDelete != null
          ? IconButton(
              color: theme.colorScheme.error,
              icon: const Icon(Icons.delete_outlined),
              onPressed: onDelete,
            )
          : null,
    );
  }
}

class _ChannelHandleTile extends StatelessWidget {
  const _ChannelHandleTile({required this.controller});

  final ChatAccessSettingsController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final handle = controller.channelHandle;
    final url = controller.channelHandleUrl;

    if (handle != null && url != null && !controller.channelHandleEditing) {
      return ListTile(
        leading: const Icon(Icons.link_outlined),
        title: SelectableText(
          url,
          style: TextStyle(color: theme.colorScheme.primary, fontSize: 14),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: L10n.of(context).channelLinkCopied,
              onPressed: () => LizaShare.share(url, context),
            ),
            TextButton(
              onPressed: controller.startEditingChannelHandle,
              child: Text(L10n.of(context).channelLinkEdit),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller.handleController,
            enabled: !controller.channelHandleLoading,
            autocorrect: false,
            decoration: InputDecoration(
              prefixText: channelLinkDisplayPrefix,
              hintText: suggestHandleFrom(
                controller.room.getLocalizedDisplayname(),
              ),
              errorText: controller.channelHandleError,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            L10n.of(context).channelLinkHint,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: controller.channelHandleLoading
                ? null
                : controller.saveChannelHandle,
            child: Text(L10n.of(context).channelLinkSave),
          ),
        ],
      ),
    );
  }
}

extension JoinRulesDisplayString on JoinRules {
  String localizedString(L10n l10n, Set<Room> spaceParents) {
    switch (this) {
      case JoinRules.public:
        return l10n.anyoneCanJoin;
      case JoinRules.invite:
        return l10n.invitedUsersOnly;
      case JoinRules.knock:
        return l10n.usersMustKnock;
      case JoinRules.private:
        return l10n.noOneCanJoin;
      case JoinRules.restricted:
        return l10n.spaceMemberOf(
          spaceParents
              .map((space) => space.getLocalizedDisplayname(MatrixLocals(l10n)))
              .join(', '),
        );
      case JoinRules.knockRestricted:
        return l10n.spaceMemberOfCanKnock(
          spaceParents
              .map((space) => space.getLocalizedDisplayname(MatrixLocals(l10n)))
              .join(', '),
        );
    }
  }
}
