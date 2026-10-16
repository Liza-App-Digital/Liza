import 'package:flutter/material.dart' hide Visibility;

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_access_settings/chat_access_settings_page.dart';
import 'package:liza/pages/chat_details/chat_details.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/company_membership.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';

class ChatAccessSettings extends StatefulWidget {
  final String roomId;
  const ChatAccessSettings({required this.roomId, super.key});

  @override
  State<ChatAccessSettings> createState() => ChatAccessSettingsController();
}

class ChatAccessSettingsController extends State<ChatAccessSettings> {
  bool joinRulesLoading = false;
  bool visibilityLoading = false;
  bool historyVisibilityLoading = false;
  bool guestAccessLoading = false;
  final AuthProxyService _authProxyService = AuthProxyService();

  /// Канал ли это. Ник и тип «публичный/частный» — только для каналов;
  /// у обычных чатов и групп экран остаётся прежним.
  bool get isChannel => room.lizaChatType == channelChatType;

  String? channelHandle;
  String? channelHandleUrl;
  bool channelHandleLoading = false;
  bool channelHandleEditing = false;
  String? channelHandleError;
  final TextEditingController handleController = TextEditingController();

  /// Публичный ли КАНАЛ. Наружу это ОДНО понятие, внутри — два состояния
  /// Matrix: join_rules и видимость в directory. Пишем оба разом.
  ///
  /// ⚠️ Гейт `isChannel` ОБЯЗАТЕЛЕН: иначе геттер = «join_rules публичный» для
  /// ЛЮБОЙ комнаты, и раздел видимости истории (`enabled: !isPublicChannel`)
  /// стал бы read-only у публичной ГРУППЫ — а её история редактируема (у группы
  /// нет peek-ленты, ради которой канал форсит world_readable). Для публичности
  /// обычной группы есть отдельный [isPublicGroup].
  bool get isPublicChannel => isChannel && room.joinRules == JoinRules.public;

  /// Переключает поле ввода ника из режима «готовая ссылка» в режим
  /// редактирования — используется кнопкой «Изменить» на виде.
  void startEditingChannelHandle() {
    final handle = channelHandle;
    if (handle != null) handleController.text = handle;
    setState(() => channelHandleEditing = true);
  }

  @override
  void initState() {
    super.initState();
    if (isChannel) _loadChannelHandle();
  }

  @override
  void dispose() {
    handleController.dispose();
    super.dispose();
  }

  Future<void> _loadChannelHandle() async {
    // Ник канала зарегистрирован в auth-proxy под доменом КАНАЛА, не
    // пользователя — у подписчика с чужого хоумсервера userID.domain даёт
    // не тот сервер (см. serverNameForRoom в chat_details.dart).
    final serverName = serverNameForRoom(room.id);
    final accessToken = room.client.accessToken;
    if (serverName == null || accessToken == null) {
      // Фоновая загрузка при открытии экрана — молчаливый выход допустим,
      // но должен быть виден в логах (иначе неотличим от «ника нет»).
      Logs().w(
        'Не удалось загрузить ник канала: нет serverName или accessToken',
      );
      return;
    }
    setState(() => channelHandleLoading = true);
    try {
      final resolved = await _authProxyService.resolveChannelHandleForRoom(
        serverName: serverName,
        roomId: room.id,
        accessToken: accessToken,
      );
      if (!mounted) return;
      setState(() {
        channelHandle = resolved?.handle;
        channelHandleUrl = resolved?.url;
      });
    } catch (e, s) {
      Logs().w('Не удалось загрузить ник канала', e, s);
    } finally {
      if (mounted) setState(() => channelHandleLoading = false);
    }
  }

  /// Сохраняет ник канала. При первом сохранении удаляет старые
  /// Matrix-alias'ы — с подтверждением: ссылки с ними перестанут работать.
  Future<void> saveChannelHandle() async {
    final raw = handleController.text;
    final formatError = validateChannelHandle(raw);
    if (formatError != null) {
      setState(() => channelHandleError = _handleErrorText(formatError));
      return;
    }

    // Как и в _loadChannelHandle — сохраняем ник на СЕРВЕРЕ КАНАЛА, а не
    // пользователя.
    final serverName = serverNameForRoom(room.id);
    final accessToken = room.client.accessToken;
    if (serverName == null || accessToken == null) {
      // В отличие от фоновой загрузки — это явное действие пользователя
      // («Сохранить»), молчаливый выход недопустим: нужен видимый ответ.
      Logs().w(
        'Не удалось сохранить ник канала: нет serverName или accessToken',
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).channelHandleSaveFailed)),
      );
      return;
    }

    final oldAliases = _collectOldAliases();
    if (oldAliases.isNotEmpty) {
      final consent = await showOkCancelAlertDialog(
        context: context,
        title: L10n.of(context).channelOldAliasesTitle,
        message: L10n.of(context).channelOldAliasesBody(oldAliases.join(', ')),
        okLabel: L10n.of(context).yes,
        cancelLabel: L10n.of(context).cancel,
        isDestructive: true,
      );
      if (consent != OkCancelResult.ok) return;
    }

    setState(() {
      channelHandleLoading = true;
      channelHandleError = null;
    });
    try {
      final info = await _authProxyService.setChannelHandle(
        serverName: serverName,
        roomId: room.id,
        handle: normalizeChannelHandle(raw),
        accessToken: accessToken,
      );
      for (final alias in oldAliases) {
        try {
          await room.client.deleteRoomAlias(alias);
        } catch (e, s) {
          // Ник уже занят — падать на чистке легаси нельзя.
          Logs().w('Не удалось удалить старый alias $alias', e, s);
        }
      }
      if (!mounted) return;
      setState(() {
        channelHandle = info.handle;
        channelHandleUrl = info.url;
        channelHandleEditing = false;
      });
    } on ChannelHandleTakenException {
      if (mounted) {
        setState(
          () => channelHandleError = L10n.of(context).channelHandleTaken,
        );
      }
    } catch (e, s) {
      Logs().w('Не удалось сохранить ник канала', e, s);
      if (mounted) {
        setState(
          () => channelHandleError = L10n.of(context).channelHandleSaveFailed,
        );
      }
    } finally {
      if (mounted) setState(() => channelHandleLoading = false);
    }
  }

  List<String> _collectOldAliases() {
    final aliases = <String>[];
    if (room.canonicalAlias.isNotEmpty) aliases.add(room.canonicalAlias);
    aliases.addAll(
      room
              .getState(EventTypes.RoomCanonicalAlias)
              ?.content
              .tryGetList<String>('alt_aliases') ??
          [],
    );
    return aliases;
  }

  String _handleErrorText(ChannelHandleError error) => switch (error) {
    ChannelHandleError.tooShort => L10n.of(context).channelHandleTooShort,
    ChannelHandleError.tooLong => L10n.of(context).channelHandleTooLong,
    ChannelHandleError.badFormat => L10n.of(context).channelHandleBadFormat,
    ChannelHandleError.reserved => L10n.of(context).channelHandleReserved,
  };

  /// Переключает тип канала. Пишет ОБА состояния Matrix: join_rules и
  /// видимость в directory — снаружи это одно понятие.
  ///
  /// Ник при уходе в «Частный» НЕ освобождается: он остаётся за каналом и
  /// просто перестаёт резолвиться. Вернувшись в «Публичный», канал получает
  /// прежнюю ссылку.
  Future<void> setChannelPublic(bool makePublic) async {
    setState(() => joinRulesLoading = true);
    try {
      if (makePublic) {
        // Инвариант «публичный ⇒ world_readable» ОБЯЗАН держаться и при
        // частичном сбое: публичный канал без world_readable рвёт лента-peek
        // неучастника (channel_peek.dart → 403 «room previews disabled»), а
        // вернуть world_readable из UI уже нельзя (раздел read-only). Поэтому
        // если любой из трёх шагов упал — откатываем канал обратно в приватный
        // (консистентное состояние), а не оставляем «публичный без превью».
        await room.setJoinRules(JoinRules.public);
        try {
          await room.client.setRoomVisibilityOnDirectory(
            room.id,
            visibility: Visibility.public,
          );
          await room.setHistoryVisibility(HistoryVisibility.worldReadable);
        } catch (_) {
          // best-effort откат публичности — не оставляем public без world_readable
          await room.setJoinRules(JoinRules.invite);
          await room.client.setRoomVisibilityOnDirectory(
            room.id,
            visibility: Visibility.private,
          );
          rethrow;
        }
      } else {
        await room.setJoinRules(JoinRules.invite);
        await room.client.setRoomVisibilityOnDirectory(
          room.id,
          visibility: Visibility.private,
        );
      }
    } catch (e, s) {
      Logs().w('Не удалось сменить тип канала', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) setState(() => joinRulesLoading = false);
    }
  }

  /// Публичная ли ГРУППА (обычный чат, не канал). Наружу — одно понятие
  /// «Публичная/Частная», внутри — `join_rules` (`public`/`invite`) + видимость
  /// в directory. В отличие от [isPublicChannel] семантически то же чтение
  /// `join_rules`, но применяется к обычной группе.
  bool get isPublicGroup => room.joinRules == JoinRules.public;

  /// Виден ли выбор «Кто может вступить» (radio join_rules). У чата обсуждения
  /// канала правило ведёт сервер (`channel_sync`): restricted по членству в
  /// канале; ручная смена записала бы allow без канала.
  bool get showJoinRulesPicker => !room.isChannelDiscussion;

  /// Виден ли простой тумблер «Тип группы» для этой комнаты. Только обычная
  /// группа (не канал/обсуждение/личка/пространство) И только в бинарных
  /// состояниях `join_rules` ∈ {public, invite}: тумблер бинарен и не может
  /// честно отобразить `knock`/`restricted`/`knockRestricted` (группа в
  /// пространстве) — там остаётся сырой radio join_rules, а тумблер скрыт,
  /// чтобы UI не врал и `setGroupPublic` не затёр restricted-доступ.
  bool get showGroupTypeToggle =>
      !isChannel &&
      !room.isChannelDiscussion &&
      !room.isDirectChat &&
      !room.isSpace &&
      (room.joinRules == JoinRules.public ||
          room.joinRules == JoinRules.invite);

  /// Переключает тип обычной ГРУППЫ. Пишет `join_rules` + видимость в directory.
  ///
  /// В отличие от [setChannelPublic] НЕ форсит `world_readable`: у группы нет
  /// peek-ленты, публичная группа = «войти может любой», а не «читается без
  /// вступления». Форс `world_readable` раскрыл бы историю переписки анонимно.
  /// Видимость истории остаётся дефолтной (`shared`) и редактируемой в UI.
  ///
  /// Отката НЕТ (в отличие от канала, где public без world_readable рвёт peek).
  /// Порядок шагов: сначала `setJoinRules(public)`, затем публикация в directory.
  /// Если упал ВТОРОЙ шаг (directory), группа УЖЕ публична по join_rules — просто
  /// не попала в каталог поиска: консистентно-деградированное состояние (войти по
  /// ссылке можно, `invite:50` держит приглашения), не сломанное. Снекбар + повтор
  /// повторной публикации. На проде directory-публикация не падает
  /// (`room_list_publication_rules: allow`); M_UNKNOWN бывает лишь на dev-стеке.
  Future<void> setGroupPublic(bool makePublic) async {
    setState(() => joinRulesLoading = true);
    try {
      if (makePublic) {
        await room.setJoinRules(JoinRules.public);
        if (!mounted) return;
        await room.client.setRoomVisibilityOnDirectory(
          room.id,
          visibility: Visibility.public,
        );
      } else {
        await room.setJoinRules(JoinRules.invite);
        if (!mounted) return;
        await room.client.setRoomVisibilityOnDirectory(
          room.id,
          visibility: Visibility.private,
        );
      }
    } catch (e, s) {
      Logs().w('Не удалось сменить тип группы', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) setState(() => joinRulesLoading = false);
    }
  }

  /// Является ли комната ПРОСТРАНСТВОМ-КОМПАНИЕЙ этого пользователя (root-space
  /// на СВОЁМ homeserver). Компания = top-level space (нет входящего
  /// m.space.child) на своём домене.
  ///
  /// Базовый предикат — канонический [isCompanySpace] (`chat_topology.dart`),
  /// которым пользуется остальной код экрана участников. Он отсекает
  /// СУБ-пространство (у него есть родитель-space), но вернул бы `true` и для
  /// ЧУЖОЙ (foreign) подписанной компании — тоже top-level space, но на другом
  /// домене, где у пользователя нет прав. Поэтому дополнительно требуем
  /// [CompanyMembershipKind.own] (совпадение доменов userID и roomID), иначе
  /// тумблер отрисовался бы на чужой компании и дал бы M_FORBIDDEN.
  bool get isCompany =>
      isCompanySpace(space: room, allRooms: room.client.rooms) &&
      foreignCompanyKind(
            userId: room.client.userID,
            roomId: room.id,
            isTopLevelSpace: true,
          ) ==
          CompanyMembershipKind.own;

  /// Публичная ли КОМПАНИЯ. Гейт [isCompany] ОБЯЗАТЕЛЕН (как [isChannel] у
  /// [isPublicChannel]): без него геттер = «join_rules публичный» для любой
  /// комнаты и логика компании протекла бы на обычную группу/канал.
  bool get isPublicCompany => isCompany && room.joinRules == JoinRules.public;

  /// Виден ли простой тумблер «Тип компании». Только СВОЯ компания И только в
  /// бинарных состояниях join_rules ∈ {public, invite}: тумблер бинарен и не
  /// может честно отобразить knock/restricted — там он врал бы и
  /// [setCompanyPublic] затёр бы нестандартный доступ.
  bool get showCompanyTypeToggle =>
      isCompany &&
      (room.joinRules == JoinRules.public ||
          room.joinRules == JoinRules.invite);

  /// Переключает тип КОМПАНИИ. Зеркало [setGroupPublic]: пишет join_rules +
  /// видимость в directory. Directory-видимость (`rooms.is_public`) — то, что
  /// серверный модуль `single_space_guard` читает вживую, решая, отдавать ли
  /// компанию в поиск «Компании» (свой HS немедленно, федеративный — TTL ≤45c).
  ///
  /// В отличие от [setChannelPublic] НЕ форсит world_readable (у пространства
  /// нет peek-ленты неучастника, ради которой канал раскрывает историю) и НЕ
  /// откатывает: если упал второй шаг (directory), компания уже публична по
  /// join_rules — консистентно-деградированное состояние (вступить можно, в
  /// каталог не попала), лечится повтором. Порядок: сначала join_rules, потом
  /// directory (как у группы).
  Future<void> setCompanyPublic(bool makePublic) async {
    setState(() => joinRulesLoading = true);
    try {
      if (makePublic) {
        await room.setJoinRules(JoinRules.public);
        if (!mounted) return;
        await room.client.setRoomVisibilityOnDirectory(
          room.id,
          visibility: Visibility.public,
        );
      } else {
        await room.setJoinRules(JoinRules.invite);
        if (!mounted) return;
        await room.client.setRoomVisibilityOnDirectory(
          room.id,
          visibility: Visibility.private,
        );
      }
    } catch (e, s) {
      Logs().w('Не удалось сменить тип компании', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) setState(() => joinRulesLoading = false);
    }
  }

  bool noForwardsLoading = false;

  /// Пишет state запрета копирования/пересылки/скриншотов контента. Работает
  /// и в канале, и в групповом чате — событие одно и то же.
  /// Модераторы и админы (PL >= 50) на себя запрет не распространяют — см.
  /// `contentProtected` в `chat_topology.dart`.
  Future<void> setNoForwards(bool enabled) async {
    setState(() => noForwardsLoading = true);
    try {
      await room.client.setRoomStateWithKey(
        room.id,
        channelNoForwardsState,
        '',
        {'enabled': enabled},
      );
    } catch (e, s) {
      Logs().w('Не удалось сменить запрет копирования', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) setState(() => noForwardsLoading = false);
    }
  }

  Room get room => Matrix.of(context).client.getRoomById(widget.roomId)!;
  Set<Room> get knownSpaceParents => {
    ...room.client.rooms.where(
      (space) =>
          space.isSpace &&
          space.spaceChildren.any((child) => child.roomId == room.id),
    ),
    ...room.spaceParents
        .map((parent) => room.client.getRoomById(parent.roomId ?? ''))
        .whereType<Room>(),
  };

  String get roomVersion =>
      room
          .getState(EventTypes.RoomCreate)!
          .content
          .tryGet<String>('room_version') ??
      'Unknown';

  /// Calculates which join rules are available based on the information on
  /// https://spec.matrix.org/v1.11/rooms/#feature-matrix
  List<JoinRules> get availableJoinRules {
    final joinRules = Set<JoinRules>.from(JoinRules.values);

    final roomVersionInt = int.tryParse(roomVersion);

    // Knock is only supported for rooms up from version 7:
    if (roomVersionInt != null && roomVersionInt <= 6) {
      joinRules.remove(JoinRules.knock);
    }

    // Restricted is only supported for rooms up from version 8:
    if (roomVersionInt != null && roomVersionInt <= 7) {
      joinRules.remove(JoinRules.restricted);
    }

    // Knock-Restricted is only supported for rooms up from version 10:
    if (roomVersionInt != null && roomVersionInt <= 9) {
      joinRules.remove(JoinRules.knockRestricted);
    }

    if (knownSpaceParents.isEmpty) {
      joinRules.remove(JoinRules.restricted);
      joinRules.remove(JoinRules.knockRestricted);
    }

    // If an unsupported join rule is the current join rule, display it:
    final currentJoinRule = room.joinRules;
    if (currentJoinRule != null) joinRules.add(currentJoinRule);

    return joinRules.toList();
  }

  void setJoinRule(JoinRules? newJoinRules) async {
    if (newJoinRules == null) return;
    setState(() {
      joinRulesLoading = true;
    });

    try {
      await room.setJoinRules(
        newJoinRules,
        allowConditionRoomIds:
            {
              JoinRules.restricted,
              JoinRules.knockRestricted,
            }.contains(newJoinRules)
            ? knownSpaceParents.map((parent) => parent.id).toList()
            : null,
      );
    } catch (e, s) {
      Logs().w('Unable to change join rules', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          joinRulesLoading = false;
        });
      }
    }
  }

  void setHistoryVisibility(HistoryVisibility? historyVisibility) async {
    if (historyVisibility == null) return;
    setState(() {
      historyVisibilityLoading = true;
    });

    try {
      await room.setHistoryVisibility(historyVisibility);
    } catch (e, s) {
      Logs().w('Unable to change history visibility', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          historyVisibilityLoading = false;
        });
      }
    }
  }

  void setGuestAccess(GuestAccess? guestAccess) async {
    if (guestAccess == null) return;
    setState(() {
      guestAccessLoading = true;
    });

    try {
      await room.setGuestAccess(guestAccess);
    } catch (e, s) {
      Logs().w('Unable to change guest access', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          guestAccessLoading = false;
        });
      }
    }
  }

  void updateRoomAction() async {
    final roomVersion = room
        .getState(EventTypes.RoomCreate)!
        .content
        .tryGet<String>('room_version');
    final capabilitiesResult = await showFutureLoadingDialog(
      context: context,
      future: () => room.client.getCapabilities(),
    );
    final capabilities = capabilitiesResult.result;
    if (capabilities == null) return;
    final newVersion = await showModalActionPopup<String>(
      context: context,
      title: L10n.of(context).replaceRoomWithNewerVersion,
      cancelLabel: L10n.of(context).cancel,
      actions: capabilities.mRoomVersions!.available.entries
          .where((r) => r.key != roomVersion)
          .map(
            (version) => AdaptiveModalAction(
              value: version.key,
              label:
                  '${version.key} (${version.value.toString().split('.').last})',
            ),
          )
          .toList(),
    );
    if (newVersion == null ||
        OkCancelResult.cancel ==
            await showOkCancelAlertDialog(
              context: context,
              okLabel: L10n.of(context).yes,
              cancelLabel: L10n.of(context).cancel,
              title: L10n.of(context).areYouSure,
              message: L10n.of(context).roomUpgradeDescription,
              isDestructive: true,
            )) {
      return;
    }
    final result = await showFutureLoadingDialog(
      context: context,
      futureWithProgress: (onProgress) async {
        final newRoomId = await room.client.upgradeRoom(room.id, newVersion);
        var newRoom = room.client.getRoomById(newRoomId);
        while (newRoom == null) {
          await room.client.onSync.stream.first;
          newRoom = room.client.getRoomById(newRoomId);
        }

        if ({
          JoinRules.invite,
          JoinRules.knock,
          JoinRules.knockRestricted,
        }.contains(room.joinRules)) {
          final users = await room.requestParticipants([
            Membership.join,
            Membership.invite,
          ]);
          users.removeWhere((user) => user.id == room.client.userID);
          for (final (i, user) in users.indexed) {
            try {
              Logs().v('Inviting...', user.id);
              await newRoom.invite(user.id);
              onProgress(i / users.length);
            } on MatrixException catch (e) {
              final retryAfterMs = e.retryAfterMs;
              if (e.error != MatrixError.M_LIMIT_EXCEEDED ||
                  retryAfterMs == null) {
                rethrow;
              }
              Logs().d('Limit exceeded. Retry after $retryAfterMs');
              await Future.delayed(Duration(milliseconds: retryAfterMs));
              await newRoom.invite(user.id);
              onProgress(i / users.length);
            }
          }
        }
      },
    );
    if (result.error != null) return;
    if (!mounted) return;
    context.go('/rooms/${room.id}');
  }

  Future<void> addAlias() async {
    final domain = room.client.userID?.domain;
    if (domain == null) {
      throw Exception('userID or domain is null! This should never happen.');
    }

    final input = await showTextInputDialog(
      context: context,
      title: L10n.of(context).editRoomAliases,
      prefixText: '#',
      suffixText: domain,
      hintText: L10n.of(context).alias,
    );
    final aliasLocalpart = input?.trim();
    if (aliasLocalpart == null || aliasLocalpart.isEmpty) return;
    final alias = '#$aliasLocalpart:$domain';

    final result = await showFutureLoadingDialog(
      context: context,
      future: () => room.client.setRoomAlias(alias, room.id),
    );
    if (result.error != null) return;
    setState(() {});

    if (!room.canChangeStateEvent(EventTypes.RoomCanonicalAlias)) return;

    final canonicalAliasConsent = await showOkCancelAlertDialog(
      context: context,
      title: L10n.of(context).setAsCanonicalAlias,
      message: alias,
      okLabel: L10n.of(context).yes,
      cancelLabel: L10n.of(context).no,
    );

    final altAliases =
        room
            .getState(EventTypes.RoomCanonicalAlias)
            ?.content
            .tryGetList<String>('alt_aliases')
            ?.toSet() ??
        {};
    if (room.canonicalAlias.isNotEmpty) altAliases.add(room.canonicalAlias);
    altAliases.add(alias);
    if (canonicalAliasConsent == OkCancelResult.ok) {
      altAliases.remove(alias);
    } else {
      altAliases.remove(room.canonicalAlias);
    }

    await showFutureLoadingDialog(
      context: context,
      future: () => room.client
          .setRoomStateWithKey(room.id, EventTypes.RoomCanonicalAlias, '', {
            'alias': canonicalAliasConsent == OkCancelResult.ok
                ? alias
                : room.canonicalAlias,
            if (altAliases.isNotEmpty) 'alt_aliases': altAliases.toList(),
          }),
    );
  }

  void deleteAlias(String alias) async {
    await showFutureLoadingDialog(
      context: context,
      future: () => room.client.deleteRoomAlias(alias),
    );
    setState(() {});
  }

  void setChatVisibilityOnDirectory(bool? visibility) async {
    if (visibility == null) return;
    setState(() {
      visibilityLoading = true;
    });

    try {
      await room.client.setRoomVisibilityOnDirectory(
        room.id,
        visibility: visibility == true ? Visibility.public : Visibility.private,
      );
      if (mounted) setState(() {});
    } catch (e, s) {
      Logs().w('Unable to change visibility', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    } finally {
      if (mounted) {
        setState(() {
          visibilityLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChatAccessSettingsPageView(this);
  }
}
