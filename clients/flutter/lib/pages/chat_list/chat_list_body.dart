import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:async/async.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/create_company_list_tile.dart';
import 'package:liza/pages/chat_list/dummy_chat_list_item.dart';
import 'package:liza/pages/chat_list/install_banner.dart';
import 'package:liza/pages/chat_list/invite_people_list_tile.dart';
import 'package:liza/pages/chat_list/search_carousel_item.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/pages/chat_list/search_users_horizontal_list.dart';
import 'package:liza/pages/chat_list/space_view.dart';
import '../stories/stories_bar.dart';
import 'package:liza/pages/chat_list/update_banner.dart';
import 'package:liza/pages/chat_list/web_update_banner.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/direct_chat_draft.dart';
import 'package:liza/utils/miniapp_room.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/utils/stream_extension.dart';
import 'package:liza/utils/version_gate_service.dart';
import 'package:liza/widgets/adaptive_dialogs/public_room_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/horizontal_mouse_wheel.dart';
import 'package:liza/widgets/search_people_bots_sections.dart';
import '../../config/themes.dart';
import '../../widgets/matrix.dart';
import 'chat_list_header.dart';

class ChatListViewBody extends StatelessWidget {
  final ChatListController controller;

  const ChatListViewBody(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final client = Matrix.of(context).client;
    final activeSpace = controller.activeSpaceId;
    if (activeSpace != null) {
      return SpaceView(
        key: ValueKey(activeSpace),
        spaceId: activeSpace,
        onBack: controller.clearActiveSpace,
        onChatTab: (room) => controller.onChatTap(room),
        activeChat: controller.activeChat,
      );
    }
    final spaces = client.rooms.where((r) => r.isSpace);
    final spaceDelegateCandidates = <String, Room>{};
    for (final space in spaces) {
      for (final spaceChild in space.spaceChildren) {
        final roomId = spaceChild.roomId;
        if (roomId == null) continue;
        spaceDelegateCandidates[roomId] = space;
      }
    }

    // Каналы помечены room_type='com.liza.channel' модулем channel_guard:
    // publicRooms не отдаёт com.liza.chat.type, только стандартный тип.
    final nonSpaceResults = controller.roomSearchResult?.chunk
        .where((room) => room.roomType != 'm.space')
        .toList();
    // Канал, найденный по точному нику, — выше результатов текстового поиска:
    // точное совпадение адреса всегда релевантнее частичного совпадения имени.
    final handleHit = controller.handleSearchResult;
    final handleChunk = handleHit == null
        ? null
        : PublishedRoomsChunk(
            name: handleHit.name ?? handleHit.handle,
            roomId: handleHit.roomId,
            numJoinedMembers: handleHit.membersCount ?? 0,
            avatarUrl: handleHit.avatarUrl != null
                ? Uri.parse(handleHit.avatarUrl!)
                : null,
            // Без roomType элемент не пройдёт фильтр publicChannels ниже.
            roomType: lizaChannelRoomType,
            guestCanJoin: false,
            worldReadable: false,
          );
    final publicChannels = (nonSpaceResults == null && handleChunk == null)
        ? null
        : <PublishedRoomsChunk>[
            if (handleChunk != null) handleChunk,
            ...?nonSpaceResults
                ?.where((room) => room.roomType == lizaChannelRoomType)
                // Дубль: тот же канал мог прийти и из queryPublicRooms.
                .where((room) => room.roomId != handleChunk?.roomId),
          ];
    final publicRooms = nonSpaceResults
        ?.where((room) => room.roomType != lizaChannelRoomType)
        .toList();
    final companies = controller.companySearchResult;
    const dummyChatCount = 4;
    final filter = controller.searchController.text.toLowerCase();
    return StreamBuilder(
      key: ValueKey(client.userID.toString()),
      // Слушаем и /sync (новые комнаты, события), и onRoomState (изменения
      // member-state без sync, например от prefetchDmHeroes — он мержит
      // displayName/avatar партнёра DM через room.setState, что эмитит
      // onRoomState, но не onSync). Без этой подписки имена партнёров
      // подтягивались только после ручной прокрутки списка.
      stream: StreamGroup.merge<Object?>([
        client.onSync.stream.where((s) => s.hasRoomUpdate),
        client.onRoomState.stream,
      ]).rateLimit(const Duration(seconds: 1)),
      builder: (context, _) {
        final rooms = controller.filteredRooms;
        // Строка «Пригласить людей» показывается только на вкладке «Все»
        // (не в поиске) и только под закреплённой первой строкой «Лиза ИИ».
        final showInvitePeopleRow = !controller.isSearchMode &&
            controller.activeFilter == ActiveFilter.allChats &&
            rooms.isNotEmpty &&
            isLizaAssistantRoom(rooms.first, MatrixState.lizaMxid);
        // Плашка «Создать компанию» — последней строкой на чипе «Компании».
        final showCreateCompanyRow = shouldShowCreateCompanyRow(
          controller.activeFilter,
          isSearchMode: controller.isSearchMode,
        );

        return ValueListenableBuilder<String?>(
          // Плеер голосового — это MaterialBanner от app-level ScaffoldMessenger;
          // он уже отступает от статус-бара. Под ним инсет статус-бара повторно
          // добавляют ДВА виджета: SafeArea(top) и SliverAppBar(primary: true) в
          // шапке — отсюда большой пробел до поиска (виден только когда играет
          // аудио). Пока плеер активен, убираем верхний инсет из MediaQuery
          // целиком — тогда его не добавляет ни SafeArea, ни шапка.
          valueListenable: Matrix.of(context).voiceMessageEventId,
          builder: (context, voiceEventId, child) => MediaQuery.removePadding(
            context: context,
            removeTop: voiceEventId != null,
            child: child!,
          ),
          child: SafeArea(
            bottom: false,
            child: CustomScrollView(
              key: const PageStorageKey('chatListScrollView'),
              controller: controller.scrollController,
              slivers: [
                const SliverToBoxAdapter(child: UpdateBanner()),
                SliverToBoxAdapter(
                  child: WebUpdateBanner(
                    updateAvailable:
                        Matrix.of(context).webUpdateChecker.updateAvailable,
                  ),
                ),
                SliverToBoxAdapter(
                  child: ValueListenableBuilder<VersionGateResult>(
                    valueListenable: Matrix.of(context).versionGateResult,
                    builder: (context, result, _) =>
                        InstallBanner(installUrl: result.installUrl),
                  ),
                ),
                ChatListHeader(controller: controller),
                SliverList(
                  delegate: SliverChildListDelegate([
                    if (controller.isSearchMode) ...[
                      // Кнопка приглашения — ПЕРВЫМ пунктом над результатами
                      // поиска: если искомого человека нет в Liza (в т.ч. поиск
                      // по номеру телефона не дал матча), его сразу можно позвать.
                      const InvitePeopleListTile(
                        key: ValueKey('invite_people_row_search'),
                      ),
                      // Секция «Компании» — только если есть что показать.
                      // Компании приватны по умолчанию (опт-ин на публичность),
                      // поэтому у массового пользователя список пуст и раздел
                      // скрыт целиком; опубликованная опт-ином компания всё ещё
                      // всплывёт. Заодно чинит orphan-заголовок над пустым
                      // списком. См. spec 2026-08-25-companies-private-by-default.
                      if (companies.isNotEmpty) ...[
                        SearchTitle(
                          title: L10n.of(context).companies,
                          icon: const Icon(Icons.domain_outlined),
                        ),
                        _CompaniesHorizontalList(companies: companies),
                      ],
                      SearchTitle(
                        title: L10n.of(context).publicRooms,
                        icon: const Icon(Icons.explore_outlined),
                      ),
                      PublicRoomsHorizontalList(publicRooms: publicRooms),
                      SearchTitle(
                        title: L10n.of(context).publicChannels,
                        icon: const Icon(Icons.campaign_outlined),
                      ),
                      PublicRoomsHorizontalList(publicRooms: publicChannels),
                      // Поиск людей видят ВСЕ участники (задача 13): Надежда
                      // ограничивает приглашение, а не поиск. Прежний гейт
                      // по canInvite главного пространства при invite:99
                      // спрятал бы людей от рядовых.
                      // Два раздела «Люди» / «Боты и ИИ»; пустой скрыт
                      // вместе с заголовком (RL-search-people-vs-bots-sections).
                      ...peopleAndBotsSections(
                        context,
                        controller.userSearchSections,
                        buildBody: (profiles) => SearchUsersHorizontalList(
                          profiles: profiles,
                          onItemTap: (userId) =>
                              _openDirectChat(context, client, userId),
                        ),
                      ),
                    ],
                    if (!controller.isSearchMode &&
                        AppSettings.showPresences.value)
                      const StoriesBar(key: ValueKey('storiesBar')),
                    if (client.rooms.isNotEmpty && !controller.isSearchMode)
                      _ChatListFilterRow(controller: controller),
                    if (controller.isSearchMode)
                      SearchTitle(
                        title: L10n.of(context).chats,
                        icon: const Icon(Icons.forum_outlined),
                      ),
                    // На пустых «Компаниях» заглушку «чатов больше нет» не
                    // рисуем: пустое состояние заменяет плашка «Создать компанию».
                    if (client.prevBatch != null &&
                        rooms.isEmpty &&
                        !controller.isSearchMode &&
                        !showCreateCompanyRow) ...[
                      Column(
                        mainAxisAlignment: .center,
                        children: [
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              const Column(
                                mainAxisSize: .min,
                                children: [
                                  DummyChatListItem(
                                    opacity: 0.5,
                                    animate: false,
                                  ),
                                  DummyChatListItem(
                                    opacity: 0.3,
                                    animate: false,
                                  ),
                                ],
                              ),
                              Icon(
                                CupertinoIcons.chat_bubble_text_fill,
                                size: 128,
                                color: theme.colorScheme.secondary,
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text(
                              client.rooms.isEmpty
                                  ? L10n.of(context).noChatsFoundHere
                                  : L10n.of(context).noMoreChatsFound,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 18,
                                color: theme.colorScheme.secondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ]),
                ),
                if (client.prevBatch == null)
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => DummyChatListItem(
                        opacity: (dummyChatCount - i) / dummyChatCount,
                        animate: true,
                      ),
                      childCount: dummyChatCount,
                    ),
                  ),
                if (client.prevBatch != null)
                  SliverList.builder(
                    itemCount:
                        rooms.length +
                        (showInvitePeopleRow ? 1 : 0) +
                        (showCreateCompanyRow ? 1 : 0),
                    itemBuilder: (BuildContext context, int i) {
                      // Строка «Пригласить людей» — ПОСЛЕДНИМ элементом, ПОД
                      // всеми переписками: новичку с пустым списком она видна
                      // сразу, старичка не оттесняет в топе. Комнаты идут по
                      // индексу без сдвига; ключи ChatListItem привязаны к room.id.
                      if (showInvitePeopleRow && i == rooms.length) {
                        return const InvitePeopleListTile(
                          key: ValueKey('invite_people_row'),
                        );
                      }
                      // Хвостовые строки взаимоисключающие: приглашение живёт
                      // только на «Все», плашка компании — только на «Компаниях».
                      if (showCreateCompanyRow && i == rooms.length) {
                        return const CreateCompanyListTile(
                          key: ValueKey('create_company_row'),
                        );
                      }
                      final room = rooms[i];
                      final space = spaceDelegateCandidates[room.id];
                      return ChatListItem(
                        room,
                        space: space,
                        key: Key('chat_list_item_${room.id}'),
                        filter: filter,
                        onTap: () => controller.onChatTap(room),
                        onLongPress: (context) =>
                            controller.chatContextAction(room, context, space),
                        activeChat: controller.activeChat == room.id,
                      );
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class PublicRoomsHorizontalList extends StatefulWidget {
  const PublicRoomsHorizontalList({super.key, required this.publicRooms});

  final List<PublishedRoomsChunk>? publicRooms;

  @override
  State<PublicRoomsHorizontalList> createState() =>
      _PublicRoomsHorizontalListState();
}

class _PublicRoomsHorizontalListState extends State<PublicRoomsHorizontalList> {
  // Собственный контроллер изолирует горизонтальный скролл от родительского
  // CustomScrollView — иначе вертикальный жест по списку чатов мог сдвигать
  // эту карусель.
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final publicRooms = widget.publicRooms;
    return AnimatedContainer(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: publicRooms == null || publicRooms.isEmpty ? 0 : 106,
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
      child: publicRooms == null
          ? null
          : HorizontalMouseWheel(
              controller: _scrollController,
              child: PrimaryScrollController.none(
                child: ListView.builder(
                  primary: false,
                  controller: _scrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  itemCount: publicRooms.length,
                  itemBuilder: (context, i) => SearchCarouselItem(
                    title:
                        publicRooms[i].name ??
                        publicRooms[i].canonicalAlias?.localpart ??
                        L10n.of(context).group,
                    avatar: publicRooms[i].avatarUrl,
                    onPressed: () => _joinAndOpenRoom(context, publicRooms[i]),
                    onLongPress: () {
                      HapticFeedback.heavyImpact();
                      showAdaptiveDialog(
                        context: context,
                        builder: (c) => PublicRoomDialog(
                          roomAlias:
                              publicRooms[i].canonicalAlias ??
                              publicRooms[i].roomId,
                          chunk: publicRooms[i],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
    );
  }
}

class _ChatListFilterRow extends StatefulWidget {
  const _ChatListFilterRow({required this.controller});

  final ChatListController controller;

  @override
  State<_ChatListFilterRow> createState() => _ChatListFilterRowState();
}

class _ChatListFilterRowState extends State<_ChatListFilterRow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return SizedBox(
      height: 64,
      child: HorizontalMouseWheel(
        controller: _scrollController,
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
          shrinkWrap: true,
          scrollDirection: Axis.horizontal,
          children:
              [
                    ActiveFilter.allChats,
                    ActiveFilter.messages,
                    ActiveFilter.spaces,
                    ActiveFilter.groups,
                    ActiveFilter.channels,
                    ActiveFilter.unread,
                  ]
                  .map(
                    (filter) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4.0),
                      child: FilterChip(
                        selected: filter == controller.activeFilter,
                        onSelected: (_) => controller.setActiveFilter(filter),
                        label: Text(filter.toLocalizedString(context)),
                      ),
                    ),
                  )
                  .toList(),
        ),
      ),
    );
  }
}

void _openDirectChat(BuildContext context, Client client, String userId) {
  // Чат/приглашение — только с первым сообщением: существующий DM открываем
  // сразу, иначе ведём в черновик (комната родится при отправке).
  openDirectChatOrDraft(GoRouter.of(context), client, userId);
}

void _joinAndOpenRoom(BuildContext context, PublishedRoomsChunk chunk) async {
  final client = Matrix.of(context).client;
  final existingRoom = client.getRoomById(chunk.roomId);
  if (existingRoom != null && existingRoom.membership != Membership.leave) {
    if (existingRoom.isSpace) {
      GoRouter.of(context).go('/rooms?spaceId=${chunk.roomId}');
    } else {
      GoRouter.of(context).go('/rooms/${chunk.roomId}');
    }
    return;
  }
  final knock = chunk.joinRule == 'knock';
  final result = await showFutureLoadingDialog<String>(
    context: context,
    future: () async {
      final roomId = knock
          ? await client.knockRoom(chunk.roomId)
          : await client.joinRoom(chunk.canonicalAlias ?? chunk.roomId);
      if (!knock && client.getRoomById(roomId) == null) {
        await client.waitForRoomInSync(roomId);
      }
      return roomId;
    },
  );
  if (result.error != null) return;
  final roomId = result.result;
  if (roomId == null) return;
  if (!context.mounted) return;
  if (chunk.roomType == 'm.space' ||
      client.getRoomById(roomId)?.isSpace == true) {
    GoRouter.of(context).go('/rooms?spaceId=$roomId');
  } else {
    GoRouter.of(context).go('/rooms/$roomId');
  }
}

class _CompaniesHorizontalList extends StatefulWidget {
  const _CompaniesHorizontalList({required this.companies});

  final List<CompanyEntry> companies;

  @override
  State<_CompaniesHorizontalList> createState() =>
      _CompaniesHorizontalListState();
}

class _CompaniesHorizontalListState extends State<_CompaniesHorizontalList> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final companies = widget.companies;
    return AnimatedContainer(
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      height: companies.isEmpty ? 0 : 106,
      duration: LizaThemes.animationDuration,
      curve: LizaThemes.animationCurve,
      child: HorizontalMouseWheel(
        controller: _scrollController,
        child: PrimaryScrollController.none(
          child: ListView.builder(
            primary: false,
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            itemCount: companies.length,
            itemBuilder: (context, i) {
              final company = companies[i];
              final displayName = company.name ?? company.roomId;
              return SearchCarouselItem(
                title: displayName,
                avatar: company.avatarUrl != null
                    ? Uri.tryParse(company.avatarUrl!)
                    : null,
                onPressed: () => showAdaptiveDialog(
                  context: context,
                  builder: (_) => PublicRoomDialog(
                    chunk: PublishedRoomsChunk(
                      roomId: company.roomId,
                      numJoinedMembers: company.numJoinedMembers,
                      worldReadable: false,
                      guestCanJoin: false,
                      name: company.name,
                      topic: company.topic,
                      avatarUrl: company.avatarUrl != null
                          ? Uri.tryParse(company.avatarUrl!)
                          : null,
                      roomType: 'm.space',
                    ),
                    via: company.via,
                    isCompany: true,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
