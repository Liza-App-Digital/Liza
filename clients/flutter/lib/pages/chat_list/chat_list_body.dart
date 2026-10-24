import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:async/async.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/chat_list_filter_row.dart';
import 'package:liza/pages/chat_list/chat_list_item.dart';
import 'package:liza/pages/chat_list/compact_chat_list_column.dart';
import 'package:liza/pages/chat_list/create_company_list_tile.dart';
import 'package:liza/pages/chat_list/dummy_chat_list_item.dart';
import 'package:liza/pages/chat_list/install_banner.dart';
import 'package:liza/pages/chat_list/new_liza_request_list_tile.dart';
import 'package:liza/pages/chat_list/search_carousel_item.dart';
import 'package:liza/pages/chat_list/search_title.dart';
import 'package:liza/pages/chat_list/search_users_horizontal_list.dart';
import 'package:liza/pages/chat_list/space_view.dart';
import '../stories/stories_bar.dart';
import 'package:liza/pages/chat_list/update_banner.dart';
import 'package:liza/pages/chat_list/web_update_banner.dart';
import 'package:liza/pages/chat/mini_app_manager.dart';
import 'package:liza/utils/chat_topology.dart';
import 'package:liza/utils/direct_chat_draft.dart';
import 'package:liza/utils/federated_user_search_service.dart';
import 'package:liza/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:liza/utils/single_space_service.dart';
import 'package:liza/utils/stream_extension.dart';
import 'package:liza/utils/version_gate_service.dart';
import 'package:liza/widgets/adaptive_dialogs/public_room_dialog.dart';
import 'package:liza/widgets/future_loading_dialog.dart';
import 'package:liza/widgets/horizontal_mouse_wheel.dart';
import 'package:liza/widgets/layouts/mini_app_host_scope.dart';
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

    // Рядом широкая панель mini App — список свёрнут до аватарок. Тот же
    // controller.scrollController: полный список в этот момент размонтирован,
    // так что к контроллеру прикреплён ровно один scroll view. Чип и поиск
    // живут в контроллере и переживают свёртку.
    if (MiniAppHostScope.compactChatListOf(context) &&
        !controller.isSearchMode) {
      return StreamBuilder(
        stream: client.onSync.stream
            .where((s) => s.hasRoomUpdate)
            .rateLimit(const Duration(seconds: 1)),
        builder: (context, _) => CompactChatListColumn(
          rooms: controller.filteredRooms,
          activeChat: controller.activeChat,
          filterActive: controller.activeFilter != ActiveFilter.allChats,
          scrollController: controller.scrollController,
          onTap: controller.onChatTap,
          onContextAction: (room, ctx) => controller.chatContextAction(
            room,
            ctx,
            spaceDelegateCandidates[room.id],
          ),
          onExpand: MiniAppManager.instance.expandChatList,
        ),
      );
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
    Widget buildList() => StreamBuilder(
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
        final showNewRequestRow = shouldShowNewRequestRow(
          controller.activeFilter,
          isSearchMode: controller.isSearchMode,
          synced: client.prevBatch != null,
        );
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
                    if (controller.isSearchMode)
                      ...chatListSearchSections(
                        context,
                        query: controller.searchController.text,
                        people: controller.userSearchSections,
                        companies: companies,
                        publicRooms: publicRooms,
                        publicChannels: publicChannels,
                        hasChats: rooms.any(
                          (room) => room
                              .getLocalizedDisplayname(
                                MatrixLocals(L10n.of(context)),
                              )
                              .toLowerCase()
                              .contains(filter),
                        ),
                        onUserTap: (userId) =>
                            _openDirectChat(context, client, userId),
                      ),
                    if (!controller.isSearchMode &&
                        AppSettings.showPresences.value)
                      const StoriesBar(key: ValueKey('storiesBar')),
                    if (client.rooms.isNotEmpty && !controller.isSearchMode)
                      ChatListFilterRow(
                        activeFilter: controller.activeFilter,
                        onSelected: controller.setActiveFilter,
                        store: Matrix.of(context).store,
                        userId: Matrix.of(context).client.userID,
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
                        (showNewRequestRow ? 1 : 0) +
                        (showCreateCompanyRow ? 1 : 0),
                    itemBuilder: (BuildContext context, int i) {
                      // Строка «+ Новый запрос» — ПОСЛЕДНИМ элементом, ПОД
                      // всеми переписками: новичку с пустым списком она видна
                      // сразу, старичка не оттесняет в топе. Комнаты идут по
                      // индексу без сдвига; ключи ChatListItem привязаны к room.id.
                      if (showNewRequestRow && i == rooms.length) {
                        return const NewLizaRequestListTile(
                          key: ValueKey('new_request_row'),
                        );
                      }
                      // Хвостовые строки взаимоисключающие: «Новый запрос» живёт
                      // на «Все»/«Агентах», плашка компании — только на «Компаниях».
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

    // Роль `ai` собеседника может прийти уже после рендера (префетч ролей
    // DM-партнёров) — тогда DM бота компании переезжает из «Люди» в «Агенты»
    // без /sync. Перестраиваемся по rolesVersion только на этих двух чипах:
    // на остальных `child` отдаётся тем же инстансом и Flutter пропускает
    // ребилд. Дерево при этом одно и то же — состояние StreamBuilder и ряда
    // чипов не теряется при переключении фильтра.
    final splitsByRole =
        controller.activeFilter == ActiveFilter.agents ||
        controller.activeFilter == ActiveFilter.people;
    return ValueListenableBuilder<int>(
      valueListenable: Matrix.of(context).userRoleService.rolesVersion,
      child: splitsByRole ? null : buildList(),
      builder: (context, _, child) => child ?? buildList(),
    );
  }
}

enum SearchSection {
  agentsAndBots,
  people,
  companies,
  publicRooms,
  publicChannels,
  chats,
}

/// Порядок разделов поиска главного экрана — тот же, что у чипов списка
/// чатов (задание Надежды 18.10: «порядок должен быть таким же… чтобы у нас
/// было единообразие»). [chatListSearchSections] строит разметку обходом
/// этого списка, так что порядок задан ровно здесь.
/// ledger:RL-chat-list-search-empty-and-order
List<SearchSection> searchSectionOrder() => const [
  SearchSection.agentsAndBots,
  SearchSection.people,
  SearchSection.companies,
  SearchSection.publicRooms,
  SearchSection.publicChannels,
  SearchSection.chats,
];

const companiesSectionKey = ValueKey('search_section_companies');
const publicRoomsSectionKey = ValueKey('search_section_public_rooms');
const publicChannelsSectionKey = ValueKey('search_section_public_channels');
const chatsSectionKey = ValueKey('search_section_chats');

/// Выдача поиска главного экрана над списком своих чатов. Пустой запрос —
/// ни одного раздела (видны только свои чаты); пустой раздел скрыт вместе с
/// заголовком. Кнопки «Пригласить людей» здесь нет: приглашение живёт в «+».
List<Widget> chatListSearchSections(
  BuildContext context, {
  required String query,
  required PeopleAndBots? people,
  required List<CompanyEntry> companies,
  required List<PublishedRoomsChunk>? publicRooms,
  required List<PublishedRoomsChunk>? publicChannels,
  required bool hasChats,
  required void Function(String userId) onUserTap,
}) {
  if (!shouldRunGlobalSearch(query)) return const [];
  final l10n = L10n.of(context);
  Widget users(List<Profile> profiles) =>
      SearchUsersHorizontalList(profiles: profiles, onItemTap: onUserTap);
  return [
    for (final section in searchSectionOrder())
      ...switch (section) {
        // Поиск людей видят ВСЕ участники (задача 13): Надежда ограничивает
        // приглашение, а не поиск (RL-search-people-vs-bots-sections).
        SearchSection.agentsAndBots => botsSearchSection(
          context,
          people,
          buildBody: users,
        ),
        SearchSection.people => peopleSearchSection(
          context,
          people,
          buildBody: users,
        ),
        // Компании приватны по умолчанию (опт-ин на публичность), поэтому у
        // массового пользователя раздел обычно скрыт целиком. См. spec
        // 2026-08-25-companies-private-by-default.
        SearchSection.companies => [
          if (companies.isNotEmpty) ...[
            SearchTitle(
              key: companiesSectionKey,
              title: l10n.companies,
              icon: const Icon(Icons.domain_outlined),
            ),
            _CompaniesHorizontalList(companies: companies),
          ],
        ],
        SearchSection.publicRooms => [
          if (publicRooms != null && publicRooms.isNotEmpty) ...[
            SearchTitle(
              key: publicRoomsSectionKey,
              title: l10n.publicRooms,
              icon: const Icon(Icons.explore_outlined),
            ),
            PublicRoomsHorizontalList(publicRooms: publicRooms),
          ],
        ],
        SearchSection.publicChannels => [
          if (publicChannels != null && publicChannels.isNotEmpty) ...[
            SearchTitle(
              key: publicChannelsSectionKey,
              title: l10n.publicChannels,
              icon: const Icon(Icons.campaign_outlined),
            ),
            PublicRoomsHorizontalList(publicRooms: publicChannels),
          ],
        ],
        // Сами строки чатов идут ниже отдельным sliver'ом — здесь только
        // заголовок над ними.
        SearchSection.chats => [
          if (hasChats)
            SearchTitle(
              key: chatsSectionKey,
              title: l10n.chats,
              icon: const Icon(Icons.forum_outlined),
            ),
        ],
      },
  ];
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
