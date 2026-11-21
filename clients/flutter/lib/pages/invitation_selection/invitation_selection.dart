import 'dart:async';

import 'package:flutter/material.dart';

import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/invitation_selection/invitation_selection_view.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/invite_contacts.dart';
import 'package:liza/utils/stories/frequent_contacts.dart';
import 'package:liza/utils/bot_interactive_api.dart';
import 'package:liza/widgets/interactive_bot_permissions.dart';
import 'package:liza/utils/user_handle_service.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/localized_exception_extension.dart';

class InvitationSelection extends StatefulWidget {
  final String roomId;
  const InvitationSelection({super.key, required this.roomId});

  @override
  InvitationSelectionController createState() =>
      InvitationSelectionController();
}

class InvitationSelectionController extends State<InvitationSelection> {
  TextEditingController controller = TextEditingController();
  late String currentSearchTerm;
  bool loading = false;

  /// Выдача поиска, разбитая на «Люди» / «Боты и ИИ»
  /// (RL-search-people-vs-bots-sections).
  PeopleAndBots foundProfiles = const PeopleAndBots();
  Timer? coolDown;

  String? get roomId => widget.roomId;

  /// Сообщений за окно по собеседникам — снимок кэша частых контактов на
  /// момент открытия экрана. Не пересчитывается, пока экран открыт: иначе
  /// порядок строк прыгал бы под пальцем. Пустой кэш = порядок по свежести.
  Map<String, int> _activity = const {};

  @override
  void initState() {
    super.initState();
    final client = Matrix.of(context).client;
    final snapshot = <String, int>{};
    for (final a in FrequentContactsCache.instance.cached(client.userID)) {
      snapshot[a.userId] = (snapshot[a.userId] ?? 0) + a.messageCount;
    }
    _activity = snapshot;
    // Прогрев для СЛЕДУЮЩЕГО открытия; без setState — текущий порядок не трогаем.
    unawaited(
      FrequentContactsCache.instance
          .refreshIfStale(client)
          .then((_) {}, onError: (_) {}),
    );
  }

  @override
  void dispose() {
    coolDown?.cancel();
    controller.dispose();
    super.dispose();
  }

  List<InviteContact> getContacts(BuildContext context) {
    final matrix = Matrix.of(context);
    final contacts = inviteContactPeers(
      matrix.client.rooms,
      lizaMxid: MatrixState.lizaMxid,
      isAi: matrix.isAiUser,
      isBotOrAi: matrix.isBotOrAiUser,
      activity: _activity,
    );
    // Префетч ролей для шильдиков (актуально для пользователей вне общих комнат).
    unawaited(matrix.userRoleService.fetchRoles(contacts.map((c) => c.userId)));
    return contacts;
  }

  void inviteAction(BuildContext context, String id, String displayname) async {
    final room = Matrix.of(context).client.getRoomById(roomId!)!;

    final api = BotInteractiveApi(room.client);
    RegisteredBot? bot;
    try {
      bot = await api.resolve(mxid: id, force: true);
    } catch (_) {
      /* Обычное приглашение без новых прав. */
    }
    if (!mounted || !context.mounted || !api.isCurrent) {
      api.dispose();
      return;
    }
    int? selectedLevel;
    if (bot != null) {
      selectedLevel = await chooseBotInvitePermissions(
        context: context,
        room: room,
        botMxid: id,
        bot: bot,
        isCurrent: () => mounted && context.mounted && api.isCurrent,
      );
      if (selectedLevel == null ||
          !mounted ||
          !context.mounted ||
          !api.isCurrent) {
        api.dispose();
        return;
      }
    }
    api.dispose();
    final success = await showFutureLoadingDialog(
      context: context,
      future: () => bot == null
          ? room.invite(id)
          : inviteBotWithPermissions(room, id, selectedLevel!),
    );
    if (!mounted || !context.mounted) return;
    if (success.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).contactHasBeenInvitedToTheGroup),
        ),
      );
    }
  }

  void searchUserWithCoolDown(String text) async {
    coolDown?.cancel();
    coolDown = Timer(
      const Duration(milliseconds: 500),
      () => searchUser(context, text),
    );
  }

  void searchUser(BuildContext context, String text) async {
    coolDown?.cancel();
    if (text.isEmpty) {
      setState(() => foundProfiles = const PeopleAndBots());
    }
    currentSearchTerm = text;
    if (currentSearchTerm.isEmpty) return;
    if (loading) return;
    setState(() => loading = true);
    final matrix = Matrix.of(context);
    SearchUserDirectoryResponse response;
    List<FederatedUserEntry> federated;
    List<UserHandleMatch> handleMatches;
    try {
      final localFuture = matrix.client.searchUserDirectory(text, limit: 10);
      // Федеративный поиск по остальным инстансам — только от 2 символов
      // (короче — слишком много шума/нагрузки на федерацию); локальный
      // directory продолжает работать с 1 символа, как раньше.
      final federatedFuture = text.length >= 2
          ? matrix.federatedUserSearchService.searchUsers(text)
          : Future.value(const <FederatedUserEntry>[]);
      // Поиск по @-нику — третий источник наравне с directory и федерацией:
      // user_directory ищет по displayname/localpart и про ники auth-proxy
      // не знает, поэтому без этого приглашение по нику не находило никого.
      // Стартует параллельно остальным, а не после них.
      final handleFuture = matrix.userHandleService.searchHandles(text);
      response = await localFuture;
      federated = await federatedFuture;
      handleMatches = await handleFuture;
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text((e).toLocalizedString(context))));
      return;
    } finally {
      if (mounted) setState(() => loading = false);
    }

    final merged = mergeSearchResults(
      local: response.results,
      federated: [
        ...federated,
        // Дедуп по MXID — внутри mergeSearchResults: найденный и по нику, и
        // в directory человек показывается один раз, побеждает профиль из
        // directory (он полнее).
        ...handleMatches.map((m) => FederatedUserEntry(userId: m.mxid)),
      ],
    );

    // Полный MXID ДОБАВЛЯЕМ к результатам, а не заменяем ими список: прежняя
    // версия схлопывала выдачу до одного стаб-профиля и теряла реальные
    // совпадения (в chat_list и new_private_chat тот же случай — через .add).
    if (text.isValidMatrixId &&
        merged.indexWhere((profile) => text == profile.userId) == -1) {
      merged.add(Profile.fromJson({'user_id': text}));
    }

    // Находки по нику и введённый MXID приходят без имени/аватара — догружаем
    // профиль ДО публикации (экран публикует одним setState; второй стадии,
    // как на главном экране, здесь некуда публиковаться). Идёт уже ВНЕ окна
    // `loading`, так что новый ввод не глотается, а устаревший результат
    // отсекает гейт `currentSearchTerm != text` ниже.
    final hydrated = await hydrateProfilesWithoutDisplayName(
      matrix.client,
      merged,
    );

    PeopleAndBots partition() => partitionPeopleAndBots(
      hydrated,
      isBotOrAi: matrix.isBotOrAiUser,
      lizaMxid: MatrixState.lizaMxid,
    );

    // Роли решают раздел («Боты и ИИ» — по роли ai) и шильдик. Ждём их перед
    // публикацией, но не дольше таймаута; поздний ответ переразбивает уже
    // показанную выдачу, если запрос всё ещё актуален.
    await waitForRolesBounded(
      matrix.userRoleService.fetchRoles(hydrated.map((p) => p.userId)),
      onLate: () {
        if (!mounted || currentSearchTerm != text) return;
        setState(() => foundProfiles = partition());
      },
    );

    // Пока шли запросы, пользователь мог дописать символы — результат
    // устаревшего запроса не показываем, иначе он затрёт более свежий
    // (тот же приём, что в chat_list.dart).
    if (!mounted || currentSearchTerm != text) return;
    setState(() {
      foundProfiles = partition();
    });
  }

  @override
  Widget build(BuildContext context) => InvitationSelectionView(this);
}
