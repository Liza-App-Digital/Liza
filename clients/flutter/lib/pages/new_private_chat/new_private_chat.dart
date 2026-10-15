import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/new_private_chat/new_private_chat_view.dart';
import 'package:liza/pages/new_private_chat/qr_scanner_modal.dart';
import 'package:liza/utils/adaptive_bottom_sheet.dart';
import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/liza_share.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/url_launcher.dart';
import 'package:liza/widgets/matrix.dart';
import '../../widgets/adaptive_dialogs/user_dialog.dart';

class NewPrivateChat extends StatefulWidget {
  const NewPrivateChat({super.key});

  @override
  NewPrivateChatController createState() => NewPrivateChatController();
}

class NewPrivateChatController extends State<NewPrivateChat> {
  final TextEditingController controller = TextEditingController();
  final FocusNode textFieldFocus = FocusNode();

  Future<PeopleAndBots>? searchResponse;

  Timer? _searchCoolDown;

  /// Номер актуального поиска: поздние роли переразбивают выдачу, только
  /// если за это время не начался новый поиск (RL-search-people-vs-bots-sections).
  int _searchSeq = 0;

  static const Duration _coolDown = Duration(milliseconds: 500);

  @override
  void dispose() {
    _searchCoolDown?.cancel();
    controller.dispose();
    textFieldFocus.dispose();
    super.dispose();
  }

  void searchUsers([String? input]) async {
    final searchTerm = input ?? controller.text;
    if (searchTerm.isEmpty) {
      _searchCoolDown?.cancel();
      _searchSeq++;
      setState(() {
        searchResponse = _searchCoolDown = null;
      });
      return;
    }

    _searchCoolDown?.cancel();
    _searchCoolDown = Timer(_coolDown, () {
      final seq = ++_searchSeq;
      setState(() {
        searchResponse = _searchUser(searchTerm, seq);
      });
    });
  }

  Future<PeopleAndBots> _searchUser(String searchTerm, int seq) async {
    final matrix = Matrix.of(context);
    final client = matrix.client;

    // Поиск по ПРЕФИКСУ @-ника — третий источник наравне с directory и
    // федерацией, как на главном экране и в приглашении в группу: без него
    // этот экран находил человека по нику только точным `@ник` (ветка
    // resolve ниже), а набор по буквам не давал ничего (LABA-2552 /
    // RL-user-handles AC-33). Стартует параллельно, сервис сам отдаёт
    // пустой список на короткий запрос и любую ошибку.
    final handleFuture = matrix.userHandleService.searchHandles(searchTerm);
    final local = await client.searchUserDirectory(searchTerm);
    // Федеративный поиск по остальным инстансам — только от 2 символов
    // (короче — слишком много шума/нагрузки на федерацию); локальный
    // directory продолжает работать с 1 символа, как раньше.
    final federated = searchTerm.length >= 2
        ? await matrix.federatedUserSearchService.searchUsers(searchTerm)
        : const <FederatedUserEntry>[];
    final handleMatches = await handleFuture;
    final profiles = mergeSearchResults(
      local: local.results,
      federated: [
        ...federated,
        // Дедуп по MXID — внутри mergeSearchResults, побеждает профиль из
        // directory (он полнее).
        ...handleMatches.map((m) => FederatedUserEntry(userId: m.mxid)),
      ],
    );

    if (searchTerm.isValidMatrixId &&
        searchTerm.sigil == '@' &&
        !profiles.any((profile) => profile.userId == searchTerm)) {
      profiles.add(Profile(userId: searchTerm));
    } else if (searchTerm.startsWith('@') && !searchTerm.contains(':')) {
      // Вставленный @-ник (скопирован из диалога/списка участников — см.
      // userIdentifier) без `:server` НЕ проходит isValidMatrixId выше и
      // без этой ветки молча пропадал бы из результатов — регресс
      // «скопировал → вставил → не нашлось». Точный резолв дополняет
      // префиксный поиск выше: тот может быть недоступен (401 без токена,
      // короткий запрос), а резолв — публичный.
      final candidate = normalizeChannelHandle(searchTerm.substring(1));
      if (validateChannelHandle(candidate) == null) {
        final mxid = await matrix.userHandleService.resolve(candidate);
        if (mxid != null &&
            !profiles.any((profile) => profile.userId == mxid)) {
          matrix.userHandleService.rememberHandle(mxid, candidate);
          profiles.add(Profile(userId: mxid));
        }
      }
    }

    // Имя и аватар для находок без профиля (ник / MXID) — общим хелпером с
    // коротким таймаутом; раньше точный резолв ждал getProfileFromUserId с
    // дефолтными 30 с, а префиксные находки не гидратировались вовсе.
    final hydrated = await hydrateProfilesWithoutDisplayName(client, profiles);

    PeopleAndBots partition() => partitionPeopleAndBots(
      hydrated,
      isBotOrAi: matrix.isBotOrAiUser,
      lizaMxid: MatrixState.lizaMxid,
    );

    // Роли решают раздел («Боты и ИИ» — по роли ai) и нужны UserRoleBadge
    // для пользователей вне общих комнат (их нет в mHeroes, префетч
    // matrix.dart их не покрывает). Разбиваем ПОСЛЕ ролей, но ждём не дольше
    // таймаута; поздний ответ переразбивает показанную выдачу, если поиск
    // всё ещё актуален.
    await waitForRolesBounded(
      matrix.userRoleService.fetchRoles(hydrated.map((p) => p.userId)),
      onLate: () {
        if (!mounted || seq != _searchSeq) return;
        // Блочное тело: стрелка вернула бы Future, а setState такое запрещает.
        setState(() {
          searchResponse = Future.value(partition());
        });
      },
    );

    return partition();
  }

  void inviteAction() => LizaShare.shareInviteLink(context);

  void openScannerAction() async {
    if (PlatformInfos.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt < 21) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(L10n.of(context).unsupportedAndroidVersionLong),
          ),
        );
        return;
      }
    }
    await showAdaptiveBottomSheet(
      context: context,
      builder: (_) => QrScannerModal(
        onScan: (link) => UrlLauncher(context, link).openMatrixToUrl(),
      ),
    );
  }

  void copyUserId() async {
    await Clipboard.setData(
      ClipboardData(text: Matrix.of(context).client.userID!),
    );
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(L10n.of(context).copiedToClipboard)));
  }

  void openUserModal(Profile profile) =>
      UserDialog.show(context: context, profile: profile);

  @override
  Widget build(BuildContext context) => NewPrivateChatView(this);
}
