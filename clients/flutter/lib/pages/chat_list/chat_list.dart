import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:app_links/app_links.dart';
import 'package:cross_file/cross_file.dart';
import 'package:flutter_shortcuts_new/flutter_shortcuts_new.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart' as sdk;
import 'package:matrix/matrix.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list_view.dart';
import 'package:liza/utils/localized_exception_extension.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/utils/show_scaffold_dialog.dart';
import 'package:liza/utils/incoming_uri_policy.dart';
import 'package:liza/utils/invite_link_parser.dart';
import 'package:liza/utils/pending_invite_code.dart';
import 'package:liza/utils/show_update_snackbar.dart';
import 'package:liza/utils/voice_recording_guard.dart';
import 'package:liza/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:liza/widgets/avatar.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/share_scaffold_dialog.dart';
import 'package:liza/widgets/update_read_only_bar.dart';
import '../../../utils/account_bundles.dart';
import '../../utils/url_launcher.dart';
import '../../widgets/matrix.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/phone_number.dart';
import 'package:liza/utils/company_deletion.dart';
import 'package:liza/utils/company_membership.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/single_space_service.dart';

enum PopupMenuAction {
  settings,
  invite,
  newGroup,
  newSpace,
  setStatus,
  archive,
}

enum ActiveFilter { allChats, messages, groups, unread, spaces, channels }

extension LocalizedActiveFilter on ActiveFilter {
  String toLocalizedString(BuildContext context) {
    switch (this) {
      case ActiveFilter.allChats:
        return L10n.of(context).all;
      case ActiveFilter.messages:
        return L10n.of(context).messages;
      case ActiveFilter.unread:
        return L10n.of(context).unread;
      case ActiveFilter.groups:
        return L10n.of(context).groups;
      case ActiveFilter.spaces:
        return L10n.of(context).companies;
      case ActiveFilter.channels:
        return L10n.of(context).channels;
    }
  }
}

class ChatList extends StatefulWidget {
  static BuildContext? contextForVoip;
  final String? activeChat;
  final String? activeSpace;
  final bool displayNavigationRail;

  const ChatList({
    super.key,
    required this.activeChat,
    this.activeSpace,
    this.displayNavigationRail = false,
  });

  @override
  ChatListController createState() => ChatListController();
}

class ChatListController extends State<ChatList>
    with TickerProviderStateMixin, RouteAware {
  StreamSubscription? _intentDataStreamSubscription;

  StreamSubscription? _intentFileStreamSubscription;

  StreamSubscription? _intentUriStreamSubscription;

  late ActiveFilter activeFilter;

  String? _activeSpaceId;
  String? get activeSpaceId => _activeSpaceId;

  void setActiveSpace(String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();

    setState(() {
      _activeSpaceId = spaceId;
    });
  }

  void clearActiveSpace() => setState(() {
    _activeSpaceId = null;
  });

  void onChatTap(Room room) async {
    // В двухпанельном режиме тап по другому чату сразу пересобирает правую
    // колонку и молча обрывает идущую запись голосового — сначала спросим.
    if (!await VoiceRecordingGuard.confirmLeave(context)) return;
    if (!mounted) return;

    if (room.membership == Membership.invite) {
      final joinResult = await showFutureLoadingDialog(
        context: context,
        future: () async {
          final waitForRoom = room.client.waitForRoomInSync(
            room.id,
            join: true,
          );
          await room.join();
          await waitForRoom;
        },
        exceptionContext: ExceptionContext.joinRoom,
      );
      if (joinResult.error != null) return;
    }

    if (room.membership == Membership.ban) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L10n.of(context).youHaveBeenBannedFromThisChat)),
      );
      return;
    }

    if (room.membership == Membership.leave) {
      context.go('/rooms/archive/${room.id}');
      return;
    }

    if (room.isSpace) {
      setActiveSpace(room.id);
      return;
    }

    context.go('/rooms/${room.id}');
  }

  bool Function(Room) getRoomFilterByActiveFilter(ActiveFilter activeFilter) {
    switch (activeFilter) {
      case ActiveFilter.allChats:
        return (room) => true;
      case ActiveFilter.messages:
        return (room) => !room.isSpace && room.isDirectChat;
      case ActiveFilter.groups:
        return (room) =>
            !room.isSpace && !room.isDirectChat && !room.isChannel;
      case ActiveFilter.unread:
        return (room) => room.isUnreadOrInvited;
      case ActiveFilter.spaces:
        return (room) => room.isSpace;
      case ActiveFilter.channels:
        return (room) => room.isChannel;
    }
  }

  List<Room> get filteredRooms {
    final rooms = Matrix.of(context)
        .client
        .rooms
        .where((r) => !r.isHiddenChat)
        .where(getRoomFilterByActiveFilter(activeFilter))
        .toList();
    // Pin @liza assistant chat to top without disturbing SDK sort order.
    final lizaIndex = rooms.indexWhere(
      (r) => isLizaAssistantRoom(r, MatrixState.lizaMxid),
    );
    if (lizaIndex > 0) {
      rooms.insert(0, rooms.removeAt(lizaIndex));
    }
    return rooms;
  }

  bool isSearchMode = false;
  Future<QueryPublicRoomsResponse>? publicRoomsResponse;
  String? searchServer;
  Timer? _coolDown;
  SearchUserDirectoryResponse? userSearchResult;
  QueryPublicRoomsResponse? roomSearchResult;
  List<CompanyEntry> companySearchResult = const [];

  /// Канал, найденный по точному нику через auth-proxy. Отдельно от
  /// queryPublicRooms: тот ищет по своему HS, а ник глобален.
  ChannelHandleResolved? handleSearchResult;

  bool isSearching = false;
  static const String _serverStoreNamespace = 'im.fluffychat.search.server';

  void setServer() async {
    final newServer = await showTextInputDialog(
      useRootNavigator: false,
      title: L10n.of(context).changeTheHomeserver,
      context: context,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      prefixText: 'https://',
      hintText: Matrix.of(context).client.homeserver?.host,
      initialText: searchServer,
      keyboardType: TextInputType.url,
      autocorrect: false,
      validator: (server) => server.contains('.') == true
          ? null
          : L10n.of(context).invalidServerName,
    );
    if (newServer == null) return;
    Matrix.of(context).store.setString(_serverStoreNamespace, newServer);
    setState(() {
      searchServer = newServer;
    });
    _coolDown?.cancel();
    _coolDown = Timer(const Duration(milliseconds: 500), _search);
  }

  final TextEditingController searchController = TextEditingController();
  final FocusNode searchFocusNode = FocusNode();

  void _search() async {
    // Захватываем ОДИН раз до первого await: ниже цепочка из нескольких
    // сетевых ожиданий, а Matrix.of(context) на размонтированном State бросает.
    final matrix = Matrix.of(context);
    final client = matrix.client;
    if (!isSearching) {
      setState(() {
        isSearching = true;
      });
    }
    SearchUserDirectoryResponse? userSearchResult;
    QueryPublicRoomsResponse? roomSearchResult;
    final searchQuery = searchController.text.trim();
    // Поиск компаний не зависит от queryPublicRooms/searchUserDirectory —
    // запускаем параллельно и применяем результат отдельным setState, как
    // только он готов, а не ждём его в общей цепочке ниже. Раньше companies
    // дожидались ПОСЛЕ queryPublicRooms/searchUserDirectory в одном try, из-за
    // чего медленная/подвисшая федерация блокировала показ уже готовых
    // результатов остальных разделов поиска.
    matrix.singleSpaceService.fetchCompanies(searchQuery).then((
      companyResults,
    ) {
      if (!mounted || !isSearchMode) return;
      setState(() {
        companySearchResult = companyResults;
      });
    });
    // Резолв ника канала — независимый источник результатов. Ставим
    // параллельно queryPublicRooms/searchUserDirectory и применяем отдельным
    // setState, как только готов. В общей цепочке ниже он бы блокировал
    // остальные разделы поиска при подвисшем auth-proxy — тот же урок, что с
    // fetchCompanies выше.
    setState(() => handleSearchResult = null);
    if (validateChannelHandle(searchQuery) == null) {
      AuthProxyService()
          .resolveChannelHandle(normalizeChannelHandle(searchQuery))
          .then((resolved) {
        if (!mounted || !isSearchMode) return;
        // Пока резолв шёл, пользователь мог дописать символы — не показываем
        // результат для устаревшего запроса.
        if (searchController.text.trim() != searchQuery) return;
        setState(() => handleSearchResult = resolved);
      }).catchError((Object e, StackTrace s) {
        Logs().v('Резолв ника канала не удался', e, s);
      });
    }
    // Комнаты и люди ищутся независимо: раньше searchUserDirectory стоял в
    // одном try ПОСЛЕ queryPublicRooms, и упавший/зависший поиск комнат
    // вообще не давал дойти до поиска людей.
    try {
      roomSearchResult = await client.queryPublicRooms(
        server: searchServer,
        filter: PublicRoomQueryFilter(genericSearchTerm: searchQuery),
        limit: 20,
      );

      if (searchQuery.isValidMatrixId &&
          searchQuery.sigil == '#' &&
          roomSearchResult.chunk.any(
                (room) => room.canonicalAlias == searchQuery,
              ) ==
              false) {
        final response = await client.getRoomIdByAlias(searchQuery);
        final roomId = response.roomId;
        if (roomId != null) {
          roomSearchResult.chunk.add(
            PublishedRoomsChunk(
              name: searchQuery,
              guestCanJoin: false,
              numJoinedMembers: 0,
              roomId: roomId,
              worldReadable: false,
              canonicalAlias: searchQuery,
            ),
          );
        }
      }
    } catch (e, s) {
      Logs().w('Room search has crashed', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    }
    // Поиск по @-нику стартует ДО await'ов ниже, чтобы идти параллельно
    // локальному directory и федерации (тот же приём, что у fetchCompanies
    // и резолва ника канала выше). Сервис сам возвращает пустой список при
    // коротком запросе и при любой ошибке — гейта здесь не нужно.
    final handleSearchFuture =
        matrix.userHandleService.searchHandles(searchQuery);
    try {
      userSearchResult = await client.searchUserDirectory(
        searchController.text,
        limit: 20,
      );
      // Федеративный поиск по остальным инстансам — только от 2 символов
      // (короче — слишком много шума/нагрузки на федерацию); локальный
      // directory продолжает работать с 1 символа, как раньше.
      final federated = searchQuery.length >= 2
          ? await matrix.federatedUserSearchService.searchUsers(searchQuery)
          : const <FederatedUserEntry>[];
      // Поиск по @-нику — третий источник людей наравне с локальным
      // directory и федерацией. Без него человек, набравший чужой ник
      // (или '@ник'), не находил НИЧЕГО: user_directory ищет по
      // displayname/localpart и про ники auth-proxy не знает вовсе.
      // Пускаем параллельно федерации, а не после неё, чтобы подвисший
      // auth-proxy не задерживал уже готовые результаты.
      final handleMatches = await handleSearchFuture;
      final merged = mergeSearchResults(
        local: userSearchResult.results,
        federated: [
          ...federated,
          // Дедуп по MXID делает сам mergeSearchResults — человек,
          // найденный и по нику, и в directory, показывается один раз, и
          // побеждает более полный профиль из directory.
          ...handleMatches.map((m) => FederatedUserEntry(userId: m.mxid)),
        ],
      );
      // user_directory/search по спеке ищет только локальных юзеров + тех, с
      // кем уже есть общая комната — федеративный поиск выше добирает
      // остальных, но тоже не гарантирует полноту (напр. свежий бот на только
      // что добавленном инстансе). Если введён валидный MXID и его нет ни в
      // одном источнике — подставляем как есть, тем же паттерном, что и для
      // алиаса комнаты (#) выше. Существование резолвится позже, при старте
      // чата (createRoom/invite), который обязан сходить в federation.
      if (searchQuery.isValidMatrixId &&
          searchQuery.sigil == '@' &&
          merged.any((profile) => profile.userId == searchQuery) == false) {
        merged.add(Profile(userId: searchQuery));
      }
      final pinned = pinAiProfilesFirst(
        merged,
        isAi: (p) => matrix.isAiUser(p.userId),
        lizaMxid: MatrixState.lizaMxid,
      );
      userSearchResult.results
        ..clear()
        ..addAll(pinned);
      // Поиск по телефону: если весь ввод — полный номер, спрашиваем auth-proxy
      // (POST /contacts/v1/lookup), кто из них уже в Liza. Гейт полноты номера
      // (≥10 цифр) не даёт слать lookup на частичный ввод и жечь суточную квоту
      // (howItWoks/addContacts.md §5). Матч добавляем как Profile(mxid) в общий
      // список людей — тап откроет DM тем же путём, что MXID-fallback выше.
      // Несовпавший номер покрыт строкой «Пригласить людей» первым пунктом поиска.
      final phone = completePhoneOrNull(searchQuery);
      if (phone != null) {
        final matches = await AuthProxyService().lookupContacts(
          phones: [phone],
          accessToken: client.accessToken ?? '',
        );
        final mxid = matches[phone];
        if (mxid != null &&
            userSearchResult.results.every((p) => p.userId != mxid)) {
          userSearchResult.results.insert(0, Profile(userId: mxid));
        }
      }
      // Префетч ролей для шильдика и соты в горизонтальной карусели поиска.
      unawaited(
        matrix.userRoleService.fetchRoles(
          userSearchResult.results.map((p) => p.userId),
        ),
      );
    } catch (e, s) {
      Logs().w('User search has crashed', e, s);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toLocalizedString(context))));
      }
    }
    if (!mounted || !isSearchMode) return;
    // Пока шли запросы, пользователь мог дописать символы — результат
    // устаревшего запроса не показываем, иначе он затрёт более свежий
    // (тот же приём, что у резолва ника канала выше).
    if (searchController.text.trim() != searchQuery) return;
    setState(() {
      isSearching = false;
      this.roomSearchResult = roomSearchResult;
      this.userSearchResult = userSearchResult;
    });
    // Стадия 2: находки по нику / MXID / телефону опубликованы выше голым
    // Profile(userId) (карусель показывает их по `@ник`), имя и аватар
    // догружаем уже поверх показанного списка — как резолв ника канала выше,
    // отдельным setState, не задерживая остальные разделы поиска.
    if (userSearchResult != null) {
      unawaited(
        _hydrateUserSearchResult(client, userSearchResult, searchQuery),
      );
    }
  }

  /// Догружает профили в УЖЕ опубликованный [published] и перерисовывает
  /// карусель. Список подменяется по индексу, а не пересоздаётся: карусель
  /// читает именно `published.results`, а `pinAiProfilesFirst`/дедуп/телефон
  /// на индексе 0 уже выполнены стадией 1 и не перезапускаются.
  Future<void> _hydrateUserSearchResult(
    Client client,
    SearchUserDirectoryResponse published,
    String searchQuery,
  ) async {
    final snapshot = List<Profile>.of(published.results);
    if (snapshot.every((p) => p.displayName?.isNotEmpty ?? false)) return;
    final hydrated = await hydrateProfilesWithoutDisplayName(client, snapshot);
    // Те же гейты, что у стадии 1: экран ушёл, поиск закрыт, пользователь
    // дописал символы или результат уже заменён более свежим запросом —
    // ничего не трогаем.
    if (!mounted || !isSearchMode) return;
    if (searchController.text.trim() != searchQuery) return;
    if (!identical(userSearchResult, published)) return;
    if (applyHydratedProfiles(published.results, hydrated)) {
      setState(() {});
    }
  }

  void onSearchEnter(String text, {bool globalSearch = true}) {
    if (text.isEmpty) {
      cancelSearch(unfocus: false);
      return;
    }

    setState(() {
      isSearchMode = true;
    });
    _coolDown?.cancel();
    if (globalSearch) {
      _coolDown = Timer(const Duration(milliseconds: 500), _search);
    }
  }

  void startSearch() {
    setState(() {
      isSearchMode = true;
    });
    searchFocusNode.requestFocus();
    _coolDown?.cancel();
    _coolDown = Timer(const Duration(milliseconds: 500), _search);
  }

  void cancelSearch({bool unfocus = true}) {
    setState(() {
      searchController.clear();
      isSearchMode = false;
      roomSearchResult = userSearchResult = null;
      companySearchResult = const [];
      isSearching = false;
    });
    if (unfocus) searchFocusNode.unfocus();
  }

  BoxConstraints? snappingSheetContainerSize;

  final ScrollController scrollController = ScrollController();
  final ValueNotifier<bool> scrolledToTop = ValueNotifier(true);

  final StreamController<Client> _clientStream = StreamController.broadcast();

  Stream<Client> get clientStream => _clientStream.stream;

  void addAccountAction() => context.go('/rooms/settings/account');

  void _onScroll() {
    final newScrolledToTop = scrollController.position.pixels <= 0;
    if (newScrolledToTop != scrolledToTop.value) {
      scrolledToTop.value = newScrolledToTop;
    }
  }

  void editSpace(BuildContext context, String spaceId) async {
    await Matrix.of(context).client.getRoomById(spaceId)!.postLoad();
    if (mounted) {
      context.push('/rooms/$spaceId/details');
    }
  }

  // Needs to match GroupsSpacesEntry for 'separate group' checking.
  List<Room> get spaces => Matrix.of(context).client.rooms
      .where((r) => r.isSpace && r.membership != Membership.leave)
      .toList();

  String? get activeChat => widget.activeChat;

  void _processIncomingSharedMedia(List<SharedMediaFile> files) {
    if (!mounted) return;
    if (files.isEmpty) return;

    // Ссылка Liza (`me.liza.ru/{c,s,i,u}/…` или `liza://…`), отданная ОС каналу
    // как shared-url, должна ОТКРЫТЬ цель внутри приложения, а не попадать в
    // форвард-пикер. Плагин помечает такой одиночный элемент `SharedMediaType.url`
    // (ветка ACTION_VIEW-без-type), тогда как форвард текста приходит как
    // `SharedMediaType.text` — по этому типу мы и различаем «открыть» vs
    // «переслать». Резолвер — тот же `resolveInternalRoute`, что у in-app-тапа
    // (`UrlLauncher`) и deep-link (`_processIncomingUris`), не третий парсер.
    // [[RL-share-intent-opens-channel]]
    if (files.length == 1 && files.single.type == SharedMediaType.url) {
      final uri = Uri.tryParse(files.single.path);
      final route = uri == null ? null : resolveInternalRoute(uri);
      if (route != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          context.go(route);
        });
        return;
      }
    }
    // Режим чтения обязательного обновления: переслать в Liza нельзя.
    // Ссылки Liza выше — это навигация, их пропускаем.
    if (blockedByUpdateReadOnly(context)) return;

    showScaffoldDialog(
      context: context,
      builder: (context) => ShareScaffoldDialog(
        items: files.map((file) {
          if ({SharedMediaType.text, SharedMediaType.url}.contains(file.type)) {
            return TextShareItem(file.path);
          }
          return FileShareItem(
            XFile(
              file.path.replaceFirst('file://', ''),
              mimeType: file.mimeType,
            ),
          );
        }).toList(),
      ),
    );
  }

  void _processIncomingUris(Uri? uri, {bool isInitialLink = false}) async {
    if (uri == null) return;
    // На вебе initial-link — URL самой страницы, уже разобранный роутером
    // (webInitialLocation); иначе fallback ниже уводил бы с /opening в /rooms.
    if (!shouldHandleIncomingUri(isWeb: kIsWeb, isInitialLink: isInitialLink)) {
      return;
    }
    // Все три типа ссылок разбираются ЗДЕСЬ по scheme+host и переводятся во
    // ВНУТРЕННИЙ путь роутера. Полагаться на то, что go_router сам съест App
    // Link раньше этого колбэка, нельзя: платформенный deep-linking выключен
    // на всех платформах (Android — meta-data flutter_deeplinking_enabled,
    // iOS/macOS — дефолт), потому что go_router матчит только uri.path и
    // теряет host у custom-scheme (`liza://story/<code>` → path `/<code>`).
    // См. [[RL-deeplink-single-path]].
    final storyCode = parseStoryLinkCode(uri);
    if (storyCode != null) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/s/$storyCode');
      });
      return;
    }
    final inviteCode = parseInviteCode(uri);
    if (inviteCode != null) {
      // AppLinks.getInitialLink() возвращает один и тот же URL при каждом
      // монтировании ChatList, hot reload и cold start — без persistent
      // guard-а юзер на /invite/<code>/error или после revoke зацикливается.
      // Помечаем код как обработанный (персист в SharedPreferences) при
      // ЛЮБОМ канале. Initial-link при ремаунте пропускает уже-виденные
      // коды; runtime-стрим (сознательный тап) пропускает всегда.
      final firstTime = await PendingInviteCode.markDeepLinkHandled(inviteCode);
      if (isInitialLink && !firstTime) return;
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/i/$inviteCode');
      });
      return;
    }
    // Ссылка на канал `me.liza.ru/c/<ник>` (и deep-link `liza://channel/<ник>`).
    // Без этой ветки ник (строка без сигила) проваливался в fallback ниже, где
    // openMatrixToUrl трактовал его как user-id и открывал ЛС вместо канала
    // — [[RL-channel-link-open]].
    final channelHandle = parseChannelHandle(uri);
    if (channelHandle != null) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/c/$channelHandle');
      });
      return;
    }
    // Ссылка на профиль `me.liza.ru/u/<ник>` (и deep-link `liza://user/<ник>`).
    // Та же причина, что у канала: без этой ветки ник провалился бы в
    // fallback ниже и openMatrixToUrl трактовал бы его как user-id.
    final userHandle = parseUserHandle(uri);
    if (userHandle != null) {
      if (!mounted) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        context.go('/u/$userHandle');
      });
      return;
    }
    context.go('/rooms');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      UrlLauncher(context, uri.toString()).openMatrixToUrl();
    });
  }

  void _initReceiveSharingIntent() {
    // AppLinks подписан на всех платформах, чтобы invite-ссылки работали и на
    // desktop (macOS принимает liza://invite/<code> через URL scheme).
    // ReceiveSharingIntent остаётся mobile-only.
    if (PlatformInfos.isMobile) {
      _intentFileStreamSubscription = ReceiveSharingIntent.instance
          .getMediaStream()
          .listen(_processIncomingSharedMedia, onError: print);
      ReceiveSharingIntent.instance.getInitialMedia().then(
        _processIncomingSharedMedia,
      );
    }

    final appLinks = AppLinks();
    _intentUriStreamSubscription = appLinks.uriLinkStream.listen(
      _processIncomingUris,
    );
    appLinks.getInitialLink().then(
      (uri) => _processIncomingUris(uri, isInitialLink: true),
    );

    if (PlatformInfos.isAndroid) {
      final shortcuts = FlutterShortcuts();
      shortcuts.initialize().then(
        (_) => shortcuts.listenAction((action) {
          if (!mounted) return;
          UrlLauncher(context, action).launchUrl();
        }),
      );
    }
  }

  @override
  void initState() {
    activeFilter = ActiveFilter.allChats;
    _initReceiveSharingIntent();
    _activeSpaceId = widget.activeSpace;

    scrollController.addListener(_onScroll);
    _waitForFirstSync();
    _hackyWebRTCFixForWeb();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        searchServer = Matrix.of(
          context,
        ).store.getString(_serverStoreNamespace);
        Matrix.of(context).backgroundPush?.setupPush();
        UpdateNotifier.showUpdateSnackBar(context);
      }

      // Workaround for system UI overlay style not applied on app start
      SystemChrome.setSystemUIOverlayStyle(
        Theme.of(context).appBarTheme.systemOverlayStyle!,
      );
    });

    super.initState();
  }

  @override
  void dispose() {
    _intentDataStreamSubscription?.cancel();
    _intentFileStreamSubscription?.cancel();
    _intentUriStreamSubscription?.cancel();
    // Отменяем дебаунс-таймер поиска: иначе после размонтирования он выстрелит
    // на мёртвом State и (с добавленным сетевым lookup) уйдёт лишний запрос.
    _coolDown?.cancel();
    scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void chatContextAction(
    Room room,
    BuildContext posContext, [
    Room? space,
  ]) async {
    final overlay =
        Overlay.of(posContext).context.findRenderObject() as RenderBox;

    final button = posContext.findRenderObject() as RenderBox;

    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(const Offset(0, -65), ancestor: overlay),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(-50, 0),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final displayname = room.getLocalizedDisplayname(
      MatrixLocals(L10n.of(context)),
    );

    final spacesWithPowerLevels = room.client.rooms
        .where(
          (space) =>
              space.isSpace &&
              space.membership != Membership.leave &&
              space.canChangeStateEvent(EventTypes.SpaceChild) &&
              !space.spaceChildren.any((c) => c.roomId == room.id),
        )
        .toList();

    final leaveKind = leaveActionKindFor(context, room);

    final action = await showMenu<ChatContextAction>(
      context: posContext,
      position: position,
      items: [
        PopupMenuItem(
          value: ChatContextAction.open,
          child: Row(
            mainAxisSize: .min,
            spacing: 12.0,
            children: [
              Avatar(mxContent: room.avatar, name: displayname),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 128),
                child: Text(
                  displayname,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        if (space != null)
          PopupMenuItem(
            value: ChatContextAction.goToSpace,
            child: Row(
              mainAxisSize: .min,
              children: [
                Avatar(
                  mxContent: space.avatar,
                  size: Avatar.defaultSize / 2,
                  name: space.getLocalizedDisplayname(),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    L10n.of(context).goToSpace(space.getLocalizedDisplayname()),
                  ),
                ),
              ],
            ),
          ),
        if (room.membership == Membership.join) ...[
          PopupMenuItem(
            value: ChatContextAction.mute,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.pushRuleState == PushRuleState.notify
                      ? Icons.notifications_off_outlined
                      : Icons.notifications_off,
                ),
                const SizedBox(width: 12),
                Text(
                  room.pushRuleState == PushRuleState.notify
                      ? L10n.of(context).muteChat
                      : L10n.of(context).unmuteChat,
                ),
              ],
            ),
          ),
          PopupMenuItem(
            value: ChatContextAction.markUnread,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  room.markedUnread
                      ? Icons.mark_as_unread
                      : Icons.mark_as_unread_outlined,
                ),
                const SizedBox(width: 12),
                Text(
                  room.markedUnread
                      ? L10n.of(context).markAsRead
                      : L10n.of(context).markAsUnread,
                ),
              ],
            ),
          ),
          if (room.directChatMatrixID?.localpart != 'liza')
            PopupMenuItem(
              value: ChatContextAction.favorite,
              child: Row(
                mainAxisSize: .min,
                children: [
                  Icon(
                    room.isFavourite ? Icons.push_pin : Icons.push_pin_outlined,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    room.isFavourite
                        ? L10n.of(context).unpin
                        : L10n.of(context).pin,
                  ),
                ],
              ),
            ),
          if (spacesWithPowerLevels.isNotEmpty)
            PopupMenuItem(
              value: ChatContextAction.addToSpace,
              child: Row(
                mainAxisSize: .min,
                children: [
                  const Icon(Icons.group_work_outlined),
                  const SizedBox(width: 12),
                  Text(L10n.of(context).addToSpace),
                ],
              ),
            ),
        ],
        if (shouldShowBlockAction(isDirectChat: room.isDirectChat))
          PopupMenuItem(
            value: ChatContextAction.block,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  Icons.block_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Text(
                  L10n.of(context).block,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        // LABA-2540: подпись пункта = то, что реально произойдёт. Раньше все
        // три ветви вели в один диалог «чат переместится в архив», хотя у
        // приглашения чата ещё нет, а у компании выход — это отписка.
        // LABA-2533: админу своей компании — заявка в поддержку, не корзина.
        if (leaveKind == LeaveActionKind.deleteCompanyViaSupport)
          PopupMenuItem(
            value: ChatContextAction.deleteCompanyViaSupport,
            child: Row(
              mainAxisSize: .min,
              children: [
                const Icon(Icons.support_agent_outlined),
                const SizedBox(width: 12),
                Text(leaveActionLabel(L10n.of(context), leaveKind)),
              ],
            ),
          )
        else if (leaveKind != LeaveActionKind.hidden)
          PopupMenuItem(
            value: ChatContextAction.leave,
            child: Row(
              mainAxisSize: .min,
              children: [
                Icon(
                  leaveKind == LeaveActionKind.declineInvite
                      ? Icons.delete_outlined
                      : Icons.logout_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 12),
                Text(
                  leaveActionLabel(L10n.of(context), leaveKind),
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (action == null) return;
    if (!mounted) return;

    switch (action) {
      case ChatContextAction.open:
        onChatTap(room);
        return;
      case ChatContextAction.goToSpace:
        setActiveSpace(space!.id);
        return;
      case ChatContextAction.favorite:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.setFavourite(!room.isFavourite),
        );
        return;
      case ChatContextAction.markUnread:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.markUnread(!room.markedUnread),
        );
        return;
      case ChatContextAction.mute:
        await showFutureLoadingDialog(
          context: context,
          future: () => room.setPushRuleState(
            room.pushRuleState == PushRuleState.notify
                ? PushRuleState.mentionsOnly
                : PushRuleState.notify,
          ),
        );
        return;
      case ChatContextAction.block:
        final targetId = room.directChatMatrixID;
        if (targetId == null) return;
        context.go(
          '/rooms/settings/security/ignorelist',
          extra: targetId,
        );
        return;
      case ChatContextAction.leave:
        final leaveLabel = leaveActionLabel(L10n.of(context), leaveKind);
        final confirmed = await showOkCancelAlertDialog(
          context: context,
          title: leaveLabel,
          message: leaveActionMessage(L10n.of(context), leaveKind),
          okLabel: leaveLabel,
          cancelLabel: L10n.of(context).cancel,
          isDestructive: true,
        );
        if (confirmed == OkCancelResult.cancel) return;
        if (!mounted) return;

        await showFutureLoadingDialog(context: context, future: room.leave);

        return;
      case ChatContextAction.deleteCompanyViaSupport:
        await requestCompanyDeletion(context, room);
        return;
      case ChatContextAction.addToSpace:
        final space = await showModalActionPopup(
          context: context,
          title: L10n.of(context).space,
          actions: spacesWithPowerLevels
              .map(
                (space) => AdaptiveModalAction(
                  value: space,
                  label: space.getLocalizedDisplayname(
                    MatrixLocals(L10n.of(context)),
                  ),
                ),
              )
              .toList(),
        );
        if (space == null) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => space.setSpaceChild(room.id),
        );
    }
  }

  void setStatus() async {
    final client = Matrix.of(context).client;
    final currentPresence = await client.fetchCurrentPresence(client.userID!);
    final input = await showTextInputDialog(
      useRootNavigator: false,
      context: context,
      title: L10n.of(context).setStatus,
      message: L10n.of(context).leaveEmptyToClearStatus,
      okLabel: L10n.of(context).ok,
      cancelLabel: L10n.of(context).cancel,
      hintText: L10n.of(context).statusExampleMessage,
      maxLines: 6,
      minLines: 1,
      maxLength: 255,
      initialText: currentPresence.statusMsg,
    );
    if (input == null) return;
    if (!mounted) return;
    await showFutureLoadingDialog(
      context: context,
      future: () => client.setPresence(
        client.userID!,
        PresenceType.online,
        statusMsg: input,
      ),
    );
  }

  bool waitForFirstSync = false;

  Future<void> _waitForFirstSync() async {
    final router = GoRouter.of(context);
    final client = Matrix.of(context).client;
    await client.roomsLoading;
    await client.accountDataLoading;
    await client.userDeviceKeysLoading;
    if (client.prevBatch == null) {
      await client.onSyncStatus.stream.firstWhere(
        (status) => status.status == SyncStatus.finished,
      );

      if (!mounted) return;
      setState(() {
        waitForFirstSync = true;
      });
    }
    if (!mounted) return;
    setState(() {
      waitForFirstSync = true;
    });

    if (Matrix.of(context).isCurrentUserDeveloper &&
        (client.userDeviceKeys[client.userID!]?.deviceKeys.values.any(
              (device) => !device.verified && !device.blocked,
            ) ??
            false)) {
      late final ScaffoldFeatureController controller;
      final theme = Theme.of(context);
      controller = ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 15),
          showCloseIcon: true,
          backgroundColor: theme.colorScheme.errorContainer,
          closeIconColor: theme.colorScheme.onErrorContainer,
          content: Text(
            L10n.of(context).oneOfYourDevicesIsNotVerified,
            style: TextStyle(color: theme.colorScheme.onErrorContainer),
          ),
          action: SnackBarAction(
            onPressed: () {
              controller.close();
              router.go('/rooms/settings/devices');
            },
            textColor: theme.colorScheme.onErrorContainer,
            label: L10n.of(context).settings,
          ),
        ),
      );
    }
  }

  void setActiveFilter(ActiveFilter filter) {
    setState(() {
      activeFilter = filter;
    });
  }

  void setActiveClient(Client client) {
    context.go('/rooms');
    setState(() {
      activeFilter = ActiveFilter.allChats;
      _activeSpaceId = null;
      Matrix.of(context).setActiveClient(client);
    });
    _clientStream.add(client);
  }

  void setActiveBundle(String bundle) {
    context.go('/rooms');
    setState(() {
      _activeSpaceId = null;
      Matrix.of(context).activeBundle = bundle;
      final bundleClients = Matrix.of(context).currentBundle;
      if (bundleClients.isNotEmpty &&
          !bundleClients.any((client) => client == Matrix.of(context).client)) {
        Matrix.of(context).setActiveClient(bundleClients.first);
      }
    });
  }

  void editBundlesForAccount(String? userId, String? activeBundle) async {
    final l10n = L10n.of(context);
    final client = Matrix.of(
      context,
    ).widget.clients[Matrix.of(context).getClientIndexByMatrixId(userId!)];
    final action = await showModalActionPopup<EditBundleAction>(
      context: context,
      title: L10n.of(context).editBundlesForAccount,
      cancelLabel: L10n.of(context).cancel,
      actions: [
        AdaptiveModalAction(
          value: EditBundleAction.addToBundle,
          label: L10n.of(context).addToBundle,
        ),
        if (activeBundle != client.userID)
          AdaptiveModalAction(
            value: EditBundleAction.removeFromBundle,
            label: L10n.of(context).removeFromBundle,
          ),
      ],
    );
    // Между диалогами цепочки контроллер может быть размонтирован (логаут,
    // уход с экрана) — тогда context мёртв и showDialog падает.
    if (action == null || !mounted) return;
    switch (action) {
      case EditBundleAction.addToBundle:
        final bundle = await showTextInputDialog(
          context: context,
          title: l10n.bundleName,
          hintText: l10n.bundleName,
        );
        if (bundle == null || bundle.isEmpty || !mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => client.setAccountBundle(bundle),
        );
        break;
      case EditBundleAction.removeFromBundle:
        await showFutureLoadingDialog(
          context: context,
          future: () => client.removeFromAccountBundle(activeBundle!),
        );
    }
  }

  void resetActiveBundle() {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        Matrix.of(context).activeBundle = null;
      });
    });
  }

  @override
  Widget build(BuildContext context) => ChatListView(this);

  void _hackyWebRTCFixForWeb() {
    ChatList.contextForVoip = context;
  }

  Future<void> dehydrate() => Matrix.of(context).dehydrateAction(context);
}

enum EditBundleAction { addToBundle, removeFromBundle }

enum InviteActions { accept, decline, block }

enum ChatContextAction {
  open,
  goToSpace,
  favorite,
  markUnread,
  mute,
  leave,
  deleteCompanyViaSupport,
  addToSpace,
  block,
}

bool shouldShowBlockAction({required bool isDirectChat}) => isDirectChat;
