import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/access_admin_service.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import '../../widgets/matrix.dart';
import 'chat_members_view.dart';
import 'company_member_entry.dart';
import 'member_role_filter.dart';

class ChatMembersPage extends StatefulWidget {
  final String roomId;

  const ChatMembersPage({required this.roomId, super.key});

  @override
  State<ChatMembersPage> createState() => ChatMembersController();
}

class ChatMembersController extends State<ChatMembersPage> {
  List<User>? members;
  List<User>? filteredMembers;
  Object? error;
  Membership membershipFilter = Membership.join;
  MemberRoleFilter roleFilter = MemberRoleFilter.all;

  /// Чекбоксы под табами ролей. Оба сняты по умолчанию — видно всех, включая
  /// федеративных и тех, кто состоит только в дочерних сущностях.
  bool onServerOnly = false;
  bool inCompanyOnly = false;

  /// Меняет ли чекбокс список (см. [memberFilterUsefulness]). Бесполезный
  /// чекбокс не рисуется; если бесполезны оба — вместо них плашка.
  bool serverFilterUseful = false;
  bool companyFilterUseful = false;

  /// Пуста ли база расчёта пользы — тогда ни чекбоксов, ни плашки.
  bool filterBaseEmpty = true;

  /// Первая загрузка [spaceMembers] завершилась (успехом или ошибкой). До
  /// неё польза «В компании» у админа неизвестна: без флага плашка «все из
  /// компании» мелькала бы и сменялась чекбоксом.
  bool _spaceMembersSettled = false;

  /// Показывать ли скрытых участников (LABA-2381). По умолчанию выключено —
  /// скрытые не видны. Тумблер доступен только тому, кто вправе скрывать
  /// (PL>=99): включив, админ видит скрытых с бейджем «скрыт», чтобы вернуть.
  bool showHiddenMembers = false;

  /// Участники всего поддерева пространства (space_members, Task 7), ключ —
  /// userId. Заполняется отдельно от [members]: включает и тех, кто состоит
  /// ТОЛЬКО в дочерних сущностях (чат/канал/суб-пространство), а не в самом
  /// пространстве — их не видно через requestParticipants(spaceId).
  final Map<String, SpaceMember> spaceMembers = {};

  /// Участники ТОЛЬКО дочерних сущностей — их нет в [members] (нет User-
  /// объекта из SDK, т.к. они не вступали в саму комнату widget.roomId).
  /// Фильтры применяются к ним так же, как к остальным: роль считается по
  /// данным space_members, а не по PL синтетического User (тот всегда 0).
  List<SpaceMember> get childOnlySpaceMembers => spaceMembers.values
      .where((m) => m.membershipInSpace == null)
      .where(
        (m) => matchesCompanyFilters(
          userId: m.userId,
          roomPowerLevel: 0,
          joinedRoom: false,
          spaceMember: m,
        ),
      )
      .toList();

  /// Домен сервера компании — по нему чекбокс «состоит на сервере» отличает
  /// свои аккаунты от федеративных.
  String get companyServerName => _serverNameOf(widget.roomId);

  static String _serverNameOf(String roomId) {
    final separator = roomId.indexOf(':');
    return separator < 0 ? '' : roomId.substring(separator + 1);
  }

  bool get _isSpaceRoom =>
      Matrix.of(context).client.getRoomById(widget.roomId)?.isSpace ?? false;

  bool get _needsSpaceMembers => _isSpaceRoom && canManageAccess;

  /// Можно ли уже решать, какие чекбоксы показывать.
  bool get membershipFiltersReady =>
      _spaceMembersSettled || !_needsSpaceMembers;

  /// Имя открытого пространства для «В компании {имя}» / «В пространстве
  /// {имя}»; вне пространства не нужно. Берём только у самой комнаты: имя
  /// другой комнаты того же домена на общих инстансах было бы чужим.
  String get spaceLabel {
    final room = Matrix.of(context).client.getRoomById(widget.roomId);
    if (room == null || !room.isSpace) return '';
    return room.getLocalizedDisplayname(MatrixLocals(L10n.of(context)));
  }

  /// База расчёта пользы чекбоксов: участники текущей вкладки членства (и
  /// на вкладке join — участники только дочерних сущностей, как во вьюхе),
  /// без скрытых для зрителя. Роль, чекбоксы и поиск НЕ учитываются.
  /// childOnlySpaceMembers не годится — он уже прогнан через чекбоксы.
  List<MemberFilterFacts> _filterBase() {
    final serverName = companyServerName;
    return [
      for (final m in members ?? const <User>[])
        if (m.membership == membershipFilter && !_isHiddenForViewer(m.id))
          (
            belongsToServer: memberBelongsToServer(
              userId: m.id,
              serverName: serverName,
            ),
            joinedCompany: memberJoinedCompany(
              joinedRoom: m.membership == Membership.join,
              spaceMember: spaceMembers[m.id],
            ),
          ),
      if (membershipFilter == Membership.join)
        for (final m in spaceMembers.values)
          if (m.membershipInSpace == null && !_isHiddenForViewer(m.userId))
            (
              belongsToServer: memberBelongsToServer(
                userId: m.userId,
                serverName: serverName,
              ),
              joinedCompany: false,
            ),
    ];
  }

  /// Пересчёт пользы чекбоксов. Скрытый чекбокс сбрасывается ДО фильтрации:
  /// иначе отмеченный, а затем скрытый (смена вкладки, догрузка) фильтр
  /// продолжал бы сужать список, и снять его было бы нечем.
  void _updateFilterUsefulness() {
    final base = _filterBase();
    final useful = memberFilterUsefulness(
      base: base,
      hasServerName: companyServerName.isNotEmpty,
      isSpace: _isSpaceRoom,
    );
    filterBaseEmpty = base.isEmpty;
    serverFilterUseful = useful.server;
    companyFilterUseful = useful.company;
    if (!serverFilterUseful) onServerOnly = false;
    if (!companyFilterUseful) inCompanyOnly = false;
  }

  /// Единый предикат для ВСЕХ участников — и тех, кто состоит в самой комнате,
  /// и тех, кто виден только через дочерние сущности. Раньше вторые обходили
  /// фильтр ролей и попадали в таб «Модераторы» с нулевым PL.
  /// Скрыт ли участник из витрины для ТЕКУЩЕГО зрителя. При включённом тумблере
  /// «показать скрытых» не скрываем никого (видим всех, скрытых — с бейджем).
  bool _isHiddenForViewer(String userId) {
    if (showHiddenMembers) return false;
    final room = Matrix.of(context).client.getRoomById(widget.roomId);
    return room?.isMemberHiddenForMe(userId) ?? false;
  }

  bool matchesCompanyFilters({
    required String userId,
    required int roomPowerLevel,
    required bool joinedRoom,
    SpaceMember? spaceMember,
  }) {
    // Скрытие — ДОБАВЛЕННЫЙ конъюнктивный предикат поверх роли/сервера/компании
    // и ЕДИНСТВЕННАЯ точка фильтрации: закрывает и обычных [members], и
    // childOnlySpaceMembers (у последних нет SDK-User, иначе бы обошли скрытие).
    if (_isHiddenForViewer(userId)) return false;
    final power = effectiveMemberPowerLevel(
      roomPowerLevel: roomPowerLevel,
      spaceMember: spaceMember,
    );
    if (!matchesRoleFilter(power, roleFilter)) return false;
    return matchesMembershipCheckboxes(
      onServerOnly: onServerOnly,
      inCompanyOnly: inCompanyOnly,
      belongsToServer: memberBelongsToServer(
        userId: userId,
        serverName: companyServerName,
      ),
      joinedCompany: memberJoinedCompany(
        joinedRoom: joinedRoom,
        spaceMember: spaceMember,
      ),
    );
  }

  /// Открыт ли список участников из корневого пространства-компании, а не
  /// суб-пространства — влияет на подпись бейджа роли («компании» vs
  /// «пространства»). См. isCompanySpace (chat_topology.dart) — почему не
  /// spaceParents.
  bool get isCompanyRoom {
    final client = Matrix.of(context).client;
    final room = client.getRoomById(widget.roomId);
    if (room == null) return false;
    return isCompanySpace(space: room, allRooms: client.rooms);
  }

  final TextEditingController filterController = TextEditingController();

  AccessAdminService? _accessService;
  final Map<String, AccessDossier> _dossiers = {};
  final Set<String> _loadingDossiers = {};
  String? expandedAccessUserId;
  final Map<String, Object?> accessErrors = {};

  /// Доступна ли панель управления доступами: только в пространстве и только
  /// администратору сервера (роль) либо администратору этого пространства.
  bool get canManageAccess {
    final room = Matrix.of(context).client.getRoomById(widget.roomId);
    if (room == null || !room.isSpace) return false;
    if (Matrix.of(context).userRoleService.isCurrentUserAdmin) return true;
    return room.ownPowerLevel >= adminPowerLevel;
  }

  AccessDossier? dossierFor(String userId) => _dossiers[userId];

  bool isDossierLoading(String userId) => _loadingDossiers.contains(userId);

  AccessAdminService get _access =>
      _accessService ??= AccessAdminService(() => Matrix.of(context).client);

  void toggleAccessPanel(String userId) {
    setState(() {
      expandedAccessUserId = expandedAccessUserId == userId ? null : userId;
      accessErrors.remove(userId);
    });
    if (expandedAccessUserId == userId && !_dossiers.containsKey(userId)) {
      _loadDossier(userId);
    }
  }

  Future<void> _loadDossier(String userId) async {
    setState(() => _loadingDossiers.add(userId));
    try {
      final dossier = await _access.fetchDossier(userId);
      if (!mounted) return;
      setState(() => _dossiers[userId] = dossier);
    } catch (e, s) {
      Logs().w('Не удалось загрузить досье доступов', e, s);
      if (!mounted) return;
      setState(() => accessErrors[userId] = e);
    } finally {
      if (mounted) setState(() => _loadingDossiers.remove(userId));
    }
  }

  Future<void> toggleAccountActive(String userId) async {
    final dossier = _dossiers[userId];
    if (dossier == null) return;

    final l10n = L10n.of(context);
    final name = dossier.displayName ?? userId;
    final reactivating = dossier.deactivated;

    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: reactivating
          ? l10n.accessReactivateConfirmTitle
          : l10n.accessDeactivateConfirmTitle,
      message: reactivating
          ? l10n.accessReactivateConfirmMessage(name)
          : l10n.accessDeactivateConfirmMessage(name),
      okLabel: reactivating
          ? l10n.accessReactivateAccount
          : l10n.accessDeactivateAccount,
      cancelLabel: l10n.cancel,
      isDestructive: !reactivating,
    );
    if (confirmed != OkCancelResult.ok) return;

    final messenger = ScaffoldMessenger.of(context);
    final successLabel = reactivating
        ? l10n.accessAccountReactivated
        : l10n.accessAccountDeactivated;

    final result = await showFutureLoadingDialog(
      context: context,
      future: () => _access.setActive(userId, active: reactivating),
    );
    if (result.error != null || !mounted) return;

    messenger.showSnackBar(SnackBar(content: Text(successLabel)));
    await _loadDossier(userId);
  }

  void setMembershipFilter(Membership membership) {
    membershipFilter = membership;
    setFilter();
  }

  void setRoleFilter(MemberRoleFilter filter) {
    roleFilter = filter;
    setFilter();
  }

  void setOnServerOnly(bool value) {
    onServerOnly = value;
    setFilter();
  }

  void setInCompanyOnly(bool value) {
    inCompanyOnly = value;
    setFilter();
  }

  void setShowHiddenMembers(bool value) {
    showHiddenMembers = value;
    setFilter();
  }

  /// Сортировка по убыванию эффективного PL (тот же расчёт, что и в
  /// фильтре — иначе участник, попавший в таб «Администраторы» по PL из
  /// дочерней сущности, проваливается в конец списка по сырому PL комнаты,
  /// который у него всегда 0), при равенстве — по id по возрастанию.
  int _compareByEffectivePowerLevel(User a, User b) {
    final powerA = effectiveMemberPowerLevel(
      roomPowerLevel: a.powerLevel,
      spaceMember: spaceMembers[a.id],
    );
    final powerB = effectiveMemberPowerLevel(
      roomPowerLevel: b.powerLevel,
      spaceMember: spaceMembers[b.id],
    );
    final byPower = powerB.compareTo(powerA);
    if (byPower != 0) return byPower;
    return a.id.compareTo(b.id);
  }

  void setFilter([dynamic _]) async {
    _updateFilterUsefulness();
    final filter = filterController.text.toLowerCase().trim();

    final members = this.members
        ?.where(
          (member) =>
              member.membership == membershipFilter &&
              matchesCompanyFilters(
                userId: member.id,
                roomPowerLevel: member.powerLevel,
                joinedRoom: member.membership == Membership.join,
                spaceMember: spaceMembers[member.id],
              ),
        )
        .toList();

    if (filter.isEmpty) {
      setState(() {
        filteredMembers = members?..sort(_compareByEffectivePowerLevel);
      });
      return;
    }
    setState(() {
      filteredMembers =
          members
              ?.where(
                (user) =>
                    user.displayName?.toLowerCase().contains(filter) ??
                    user.id.toLowerCase().contains(filter),
              )
              .toList()
            ?..sort(_compareByEffectivePowerLevel);
    });
  }

  void refreshMembers([dynamic _]) async {
    Logs().d('Load room members from', widget.roomId);
    try {
      setState(() {
        error = null;
      });
      final participants = await Matrix.of(context).client
          .getRoomById(widget.roomId)
          ?.requestParticipants(
            [...Membership.values]..remove(Membership.leave),
          );

      if (!mounted) return;

      setState(() {
        members = participants;
      });
      setFilter();
      _loadSpaceMembers();
    } catch (e, s) {
      Logs().d(
        'Unable to request participants. Try again in 3 seconds...',
        e,
        s,
      );
      setState(() {
        error = e;
      });
    }
  }

  /// Подтягивает участников всего поддерева пространства (Task 7). Только
  /// для space-комнат и только у того, кто вправе управлять доступами —
  /// эндпоинт админский, обычному участнику пространства он вернёт 403.
  ///
  /// Список участников самой комнаты ([members]) уже показан обычным путём —
  /// сбой этого запроса не должен ломать экран, поэтому ошибка только
  /// логируется.
  Future<void> _loadSpaceMembers() async {
    final room = Matrix.of(context).client.getRoomById(widget.roomId);
    if (room == null || !room.isSpace || !canManageAccess) return;
    try {
      final loaded = await _access.fetchSpaceMembers(widget.roomId);
      if (!mounted) return;
      spaceMembers
        ..clear()
        ..addEntries(loaded.map((m) => MapEntry(m.userId, m)));
    } catch (e, s) {
      Logs().w('Не удалось загрузить участников поддерева', e, s);
      if (!mounted) return;
    }
    // Ошибка тоже «завершает» загрузку: видимый список правдив и без
    // поддерева, а держать строку чекбоксов скрытой навсегда нельзя.
    _spaceMembersSettled = true;
    setFilter();
  }

  StreamSubscription? _updateSub;
  StreamSubscription? _hiddenSub;

  @override
  void initState() {
    super.initState();
    refreshMembers();

    _updateSub = Matrix.of(context).client.onSync.stream
        .where(
          (syncUpdate) =>
              syncUpdate.rooms?.join?[widget.roomId]?.timeline?.events?.any(
                (state) => state.type == EventTypes.RoomMember,
              ) ??
              false,
        )
        .listen(refreshMembers);

    // Скрытие участника (LABA-2381) — это room state [hiddenMembersState], оно
    // приходит НЕ в timeline (где ловит _updateSub), а в state-секции /sync.
    // Слушаем onRoomState: он срабатывает и на оптимистичный локальный setState
    // (у скрывшего — мгновенно), и на sync-эхо у остальных админов. Пере-
    // фильтровываем список без повторного requestParticipants (состав тот же).
    _hiddenSub = Matrix.of(context).client.onRoomState.stream
        .where(
          (update) =>
              update.roomId == widget.roomId &&
              update.state.type == hiddenMembersState,
        )
        .listen((_) {
          if (mounted) setFilter();
        });
  }

  @override
  void dispose() {
    _updateSub?.cancel();
    _hiddenSub?.cancel();
    _accessService?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatMembersView(this);
}
