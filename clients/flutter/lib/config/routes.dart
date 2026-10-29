import 'dart:async';

import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';

import 'package:liza/config/themes.dart';
import 'package:liza/config/app_config.dart';
import 'package:liza/pages/demo_auth/demo_auth_flow.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/utils/channel_handle.dart';
import 'package:liza/utils/client_manager.dart';
import 'package:liza/utils/deep_link_target.dart';
import 'package:liza/utils/new_request_transition.dart';
import 'package:liza/utils/open_user_profile.dart';
import 'package:liza/utils/pending_deep_link.dart';
import 'package:liza/utils/stories/open_user_stories.dart';
import 'package:liza/utils/stories/story_link_service.dart';
import 'package:liza/pages/archive/archive.dart';
import 'package:liza/pages/invite/invite_page.dart';
import 'package:liza/pages/opening/opening_page.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/wait_for_room_in_sync.dart';
import 'package:liza/pages/bootstrap/bootstrap_dialog.dart';
import 'package:liza/pages/init_error/init_error_page.dart';
import 'package:liza/pages/chat/chat.dart';
import 'package:liza/pages/chat/draft_chat_page.dart';
import 'package:liza/pages/chat/mini_app_catalog_page.dart';
import 'package:liza/pages/chat_access_settings/chat_access_settings_controller.dart';
import 'package:liza/pages/chat_details/chat_details.dart';
import 'package:liza/pages/chat_encryption_settings/chat_encryption_settings.dart';
import 'package:liza/pages/chat_list/chat_list.dart';
import 'package:liza/pages/chat_list/new_request_empty_page.dart';
import 'package:liza/pages/chat_details/blocked_members.dart';
import 'package:liza/pages/chat_members/chat_members.dart';
import 'package:liza/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:liza/pages/chat_search/chat_search_page.dart';
import 'package:liza/pages/channel_thread/channel_thread_page.dart';
import 'package:liza/pages/device_settings/device_settings.dart';
import 'package:liza/pages/auth_select/auth_select.dart';
import 'package:liza/pages/homeserver_picker/homeserver_picker.dart';
import 'package:liza/pages/invitation_selection/invitation_selection.dart';
import 'package:liza/pages/login/login.dart';
import 'package:liza/pages/new_group/new_group.dart';
import 'package:liza/pages/contacts/contacts_page.dart';
import 'package:liza/pages/new_private_chat/new_private_chat.dart';
import 'package:liza/pages/settings/settings.dart';
import 'package:liza/pages/settings_chat/settings_chat.dart';
import 'package:liza/pages/settings_about/settings_about.dart';
import 'package:liza/pages/settings_email/settings_email.dart';
import 'package:liza/pages/settings_emotes/settings_emotes.dart';
import 'package:liza/pages/settings_handle/settings_handle.dart';
import 'package:liza/pages/settings_homeserver/settings_homeserver.dart';
import 'package:liza/pages/settings_ignore_list/settings_ignore_list.dart';
import 'package:liza/pages/settings_integrations/settings_integrations.dart';
import 'package:liza/pages/settings_notifications/settings_notifications.dart';
import 'package:liza/pages/settings_password/settings_password.dart';
import 'package:liza/pages/settings_security/settings_security.dart';
import 'package:liza/pages/settings_style/settings_style.dart';
import 'package:liza/widgets/config_viewer.dart';
import 'package:liza/widgets/layouts/empty_page.dart';
import 'package:liza/widgets/layouts/two_column_layout.dart';
import 'package:liza/widgets/liza_app.dart';
import 'package:liza/widgets/log_view.dart';
import 'package:liza/widgets/matrix.dart';
import 'package:liza/widgets/share_scaffold_dialog.dart';

abstract class AppRoutes {
  /// Канонический адрес витрины MCP-подключений.
  ///
  /// Три точки входа (меню «+», раздел настроек, «⋮» в чате с Лизой) обязаны
  /// вести СЮДА одной константой, а не тремя литералами: иначе адрес разъедется
  /// при первой же правке, и `settings_routes_test.dart` этого не заметит —
  /// он сверяет литералы меню с деревом маршрутов, а не входы между собой.
  ///
  /// Витрина живёт вне ветки настроек (Надежда, В5 18.10: «оставить только
  /// вот это одно окно … чтобы не было видно, что это в настройках»): в
  /// колоночном режиме слева список чатов, колонки настроек нет. Маршрут —
  /// в общем `ShellRoute` списка чатов рядом с `apps`, до `:roomid`.
  static const String mcp = '/rooms/mcp';

  static FutureOr<String?> loggedInRedirect(
    BuildContext context,
    GoRouterState state,
  ) => Matrix.of(context).widget.clients.any((client) => client.isLogged())
      ? '/rooms'
      : null;

  static FutureOr<String?> loggedOutRedirect(
    BuildContext context,
    GoRouterState state,
  ) => Matrix.of(context).widget.clients.any((client) => client.isLogged())
      ? null
      : '/home';

  AppRoutes();

  static final List<RouteBase> routes = [
    GoRoute(
      path: '/',
      redirect: (context, state) {
        final hasLoggedInClient = Matrix.of(
          context,
        ).widget.clients.any((client) => client.isLogged());
        if (hasLoggedInClient) return '/rooms';
        // If no client is logged in AND initialization failed, show error
        // page instead of the homeserver picker to prevent a confusing
        // gray/black screen.
        if (ClientManager.initializationError != null) return '/init-error';
        return '/home';
      },
    ),
    GoRoute(
      path: '/home',
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        const HomeserverPicker(addMultiAccount: false),
      ),
      redirect: loggedInRedirect,
      routes: [
        GoRoute(
          path: 'login',
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            Login(client: state.extra as Client),
          ),
          redirect: loggedInRedirect,
        ),
        GoRoute(
          path: 'select',
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            AuthSelectPage(extra: state.extra as AuthSelectExtra),
          ),
          redirect: loggedInRedirect,
        ),
      ],
    ),
    if (AppConfig.phoneAuthEnabled)
      GoRoute(
        path: '/auth/phone',
        pageBuilder: (context, state) => defaultPageBuilder(
          context,
          state,
          // Телефон приходит с первого экрана через extra. Email-код —
          // следующий шаг того же защищённого auth-флоу.
          DemoAuthFlow(phone: state.extra as String? ?? ''),
        ),
        redirect: loggedInRedirect,
      ),
    GoRoute(
      path: '/init-error',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const InitErrorPage()),
      redirect: loggedInRedirect,
    ),
    GoRoute(
      path: '/logs',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const LogViewer()),
    ),
    GoRoute(
      path: '/configs',
      pageBuilder: (context, state) =>
          defaultPageBuilder(context, state, const ConfigViewer()),
    ),
    GoRoute(
      path: '/backup',
      redirect: (context, state) {
        final loggedOut = loggedOutRedirect(context, state);
        if (loggedOut is String) return loggedOut;
        // Bootstrap / recovery key flow is hidden from regular users — only
        // accounts with the "developer" role get to see and manage E2EE keys.
        if (!Matrix.of(context).isCurrentUserDeveloper) return '/rooms';
        return null;
      },
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        BootstrapDialog(wipe: state.uri.queryParameters['wipe'] == 'true'),
      ),
    ),
    GoRoute(
      path: '/i/:code',
      redirect: (context, state) async {
        final code = state.pathParameters['code']!;
        return _handleInviteCode(context, code);
      },
    ),
    GoRoute(
      path: '/opening/:code',
      // Достижим напрямую (адресная строка, история, перезагрузка вкладки в
      // вебе), а не только редиректом из _handleInviteCode — своя проверка
      // логина обязательна. Без неё firstWhere в resolve() кидает StateError
      // на пустом списке клиентов, и пользователь упирался в тупик экрана
      // ошибки без предложения войти.
      redirect: (context, state) {
        final isLogged = Matrix.of(
          context,
        ).widget.clients.any((client) => client.isLogged());
        if (isLogged) return null;
        final code = state.pathParameters['code']!;
        PendingDeepLinkStore.set(DeepLinkKind.invite, code);
        return '/home';
      },
      pageBuilder: (context, state) => noTransitionPageBuilder(
        context,
        state,
        OpeningPage(
          code: state.pathParameters['code']!,
          resolve: () async {
            final client = Matrix.of(
              context,
            ).widget.clients.firstWhere((client) => client.isLogged());
            final target = await resolveInviteTarget(
              client: client,
              service: AuthProxyService(),
              code: state.pathParameters['code']!,
            );
            // Путь не несёт информации о цели (user-инвайт → нейтральный
            // /rooms + карточка поверх), поэтому побочный эффект — отдельно,
            // как у /u/<ник>. Post-frame внутри переживёт навигацию.
            _runDeepLinkSideEffect(client, target);
            return deepLinkRoutePath(target);
          },
        ),
      ),
    ),
    GoRoute(
      path: '/invite/:code',
      redirect: (ctx, state) => '/i/${state.pathParameters['code']!}',
    ),
    GoRoute(
      path: '/s/:code',
      redirect: (context, state) async {
        final code = state.pathParameters['code']!;
        return _handleStoryLinkCode(context, code);
      },
    ),
    GoRoute(
      path: '/c/:handle',
      redirect: (context, state) async {
        final handle = state.pathParameters['handle']!;
        return _handleChannelHandle(context, handle);
      },
    ),
    GoRoute(
      path: '/u/:handle',
      redirect: (context, state) async {
        final handle = state.pathParameters['handle']!;
        return _handleUserHandle(context, handle);
      },
    ),
    GoRoute(
      path: '/invite/:code/:state',
      pageBuilder: (context, state) => defaultPageBuilder(
        context,
        state,
        InvitePage(
          code: state.pathParameters['code']!,
          state: state.pathParameters['state']!,
        ),
      ),
    ),
    ShellRoute(
      // Never use a transition on the shell route. Changing the PageBuilder
      // here based on a MediaQuery causes the child to briefly be rendered
      // twice with the same GlobalKey, blowing up the rendering.
      pageBuilder: (context, state, child) => noTransitionPageBuilder(
        context,
        state,
        LizaThemes.isColumnMode(context) &&
                state.fullPath?.startsWith('/rooms/settings') == false
            ? TwoColumnLayout(
                compactable: true,
                mainView: ChatList(
                  activeChat: state.pathParameters['roomid'],
                  activeSpace: state.uri.queryParameters['spaceId'],
                  displayNavigationRail:
                      state.path?.startsWith('/rooms/settings') != true,
                ),
                sideView: child,
              )
            : child,
      ),
      routes: [
        GoRoute(
          path: '/rooms',
          redirect: loggedOutRedirect,
          pageBuilder: (context, state) => defaultPageBuilder(
            context,
            state,
            LizaThemes.isColumnMode(context)
                ? const NewRequestEmptyPage()
                : ChatList(
                    activeChat: state.pathParameters['roomid'],
                    activeSpace: state.uri.queryParameters['spaceId'],
                  ),
          ),
          routes: [
            GoRoute(
              path: 'archive',
              pageBuilder: (context, state) =>
                  defaultPageBuilder(context, state, const Archive()),
              routes: [
                GoRoute(
                  path: ':roomid',
                  pageBuilder: (context, state) => chatPageBuilder(
                    context,
                    state,
                    ChatPage(
                      roomId: state.pathParameters['roomid']!,
                      eventId: state.uri.queryParameters['event'],
                    ),
                  ),
                  redirect: loggedOutRedirect,
                ),
              ],
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'apps',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const MiniAppCatalogPage(),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'mcp',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const SettingsIntegrationsPage(),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newprivatechat',
              pageBuilder: (context, state) =>
                  defaultPageBuilder(context, state, const NewPrivateChat()),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'contacts',
              pageBuilder: (context, state) =>
                  defaultPageBuilder(context, state, ContactsPage()),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newgroup',
              pageBuilder: (context, state) =>
                  defaultPageBuilder(context, state, const NewGroup()),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newspace',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const NewGroup(createGroupType: CreateGroupType.space),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: 'newchannel',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                const NewGroup(createGroupType: CreateGroupType.channel),
              ),
              redirect: loggedOutRedirect,
            ),
            ShellRoute(
              pageBuilder: (context, state, child) => defaultPageBuilder(
                context,
                state,
                LizaThemes.isColumnMode(context)
                    ? TwoColumnLayout(
                        mainView: Settings(key: state.pageKey),
                        sideView: child,
                      )
                    : child,
              ),
              routes: [
                GoRoute(
                  path: 'settings',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    LizaThemes.isColumnMode(context)
                        ? const EmptyPage()
                        : const Settings(),
                  ),
                  routes: [
                    GoRoute(
                      path: 'notifications',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsNotifications(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'style',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsStyle(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'devices',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const DevicesSettings(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'chat',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsChat(),
                      ),
                      routes: [
                        GoRoute(
                          path: 'emotes',
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            EmotesSettings(
                              roomId: state.pathParameters['roomid'],
                            ),
                          ),
                        ),
                      ],
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'addaccount',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const HomeserverPicker(addMultiAccount: true),
                      ),
                      routes: [
                        GoRoute(
                          path: 'login',
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            Login(client: state.extra as Client),
                          ),
                          redirect: loggedOutRedirect,
                        ),
                        GoRoute(
                          path: 'select',
                          pageBuilder: (context, state) => defaultPageBuilder(
                            context,
                            state,
                            AuthSelectPage(
                              extra: state.extra as AuthSelectExtra,
                            ),
                          ),
                          redirect: loggedOutRedirect,
                        ),
                        // Вход вторым аккаунтом по телефону. Не /auth/phone:
                        // тот под loggedInRedirect и уводил уже вошедшего
                        // в список чатов, не заказав код.
                        if (AppConfig.phoneAuthEnabled)
                          GoRoute(
                            path: 'phone',
                            pageBuilder: (context, state) => defaultPageBuilder(
                              context,
                              state,
                              DemoAuthFlow(
                                phone: state.extra as String? ?? '',
                                addMultiAccount: true,
                              ),
                            ),
                            redirect: loggedOutRedirect,
                          ),
                      ],
                    ),
                    GoRoute(
                      path: 'homeserver',
                      pageBuilder: (context, state) {
                        return defaultPageBuilder(
                          context,
                          state,
                          const SettingsHomeserver(),
                        );
                      },
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'about',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsAbout(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      // На уровне `settings`, а НЕ внутри `security`: меню
                      // ведёт на /rooms/settings/email, и вложенный маршрут
                      // дал бы /rooms/settings/security/email — go_router не
                      // нашёл бы адрес и увёл в список чатов.
                      path: 'email',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsEmailPage(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'handle',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsHandlePage(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'security',
                      redirect: loggedOutRedirect,
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const SettingsSecurity(),
                      ),
                      routes: [
                        GoRoute(
                          path: 'password',
                          pageBuilder: (context, state) {
                            return defaultPageBuilder(
                              context,
                              state,
                              const SettingsPassword(),
                            );
                          },
                          redirect: loggedOutRedirect,
                        ),
                        GoRoute(
                          path: 'ignorelist',
                          pageBuilder: (context, state) {
                            return defaultPageBuilder(
                              context,
                              state,
                              SettingsIgnoreList(
                                initialUserId: state.extra?.toString(),
                              ),
                            );
                          },
                          redirect: loggedOutRedirect,
                        ),
                      ],
                    ),
                  ],
                  redirect: loggedOutRedirect,
                ),
              ],
            ),
            GoRoute(
              path: 'newchat/:userid',
              pageBuilder: (context, state) => defaultPageBuilder(
                context,
                state,
                DraftChatPage(
                  Uri.decodeComponent(state.pathParameters['userid']!),
                  initialProfile: state.extra is Profile
                      ? state.extra as Profile
                      : null,
                ),
              ),
              redirect: loggedOutRedirect,
            ),
            GoRoute(
              path: ':roomid',
              pageBuilder: (context, state) {
                final body = state.uri.queryParameters['body'];
                var shareItems = state.extra is List<ShareItem>
                    ? state.extra as List<ShareItem>
                    : null;
                if (body != null && body.isNotEmpty) {
                  shareItems ??= [];
                  shareItems.add(TextShareItem(body));
                }
                return chatPageBuilder(
                  context,
                  state,
                  ChatPage(
                    roomId: state.pathParameters['roomid']!,
                    shareItems: shareItems,
                    eventId: state.uri.queryParameters['event'],
                  ),
                );
              },
              redirect: loggedOutRedirect,
              routes: [
                GoRoute(
                  path: 'search',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChatSearchPage(roomId: state.pathParameters['roomid']!),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'post/:postid/comments',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChannelThreadPage(
                      channelId: state.pathParameters['roomid']!,
                      postEventId: state.pathParameters['postid']!,
                    ),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'encryption',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    const ChatEncryptionSettings(),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'invite',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    InvitationSelection(
                      roomId: state.pathParameters['roomid']!,
                    ),
                  ),
                  redirect: loggedOutRedirect,
                ),
                GoRoute(
                  path: 'details',
                  pageBuilder: (context, state) => defaultPageBuilder(
                    context,
                    state,
                    ChatDetails(roomId: state.pathParameters['roomid']!),
                  ),
                  routes: [
                    GoRoute(
                      path: 'info',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        ChatDetails(
                          roomId: state.pathParameters['roomid']!,
                          detailsOnly: true,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'access',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        ChatAccessSettings(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'members',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        ChatMembersPage(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'blocked-members',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        BlockedMembersPage(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'permissions',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        const ChatPermissionsSettings(),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'invite',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        InvitationSelection(
                          roomId: state.pathParameters['roomid']!,
                        ),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                    GoRoute(
                      path: 'emotes',
                      pageBuilder: (context, state) => defaultPageBuilder(
                        context,
                        state,
                        EmotesSettings(roomId: state.pathParameters['roomid']),
                      ),
                      redirect: loggedOutRedirect,
                    ),
                  ],
                  redirect: loggedOutRedirect,
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  ];

  static Page noTransitionPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) => NoTransitionPage(
    key: state.pageKey,
    restorationId: state.pageKey.value,
    child: child,
  );

  static Page defaultPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) => LizaThemes.isColumnMode(context)
      ? noTransitionPageBuilder(context, state, child)
      : MaterialPage(
          key: state.pageKey,
          restorationId: state.pageKey.value,
          child: child,
        );

  /// Страница чата (`/rooms/:roomid` и архив) — в обоих режимах один класс
  /// [ChatRoutePage]. go_router зовёт pageBuilder на каждый ресайз, и смена
  /// `runtimeType` (раньше MaterialPage ↔ CustomTransitionPage на пороге
  /// колонок) пересоздавала ChatPage: обрывалась запись голосового, терялись
  /// черновик и прокрутка. В column-mode — кроссфейд из пустой панели
  /// «Новый запрос», для остальных чатов 0.
  @visibleForTesting
  static Page chatPageBuilder(
    BuildContext context,
    GoRouterState state,
    Widget child,
  ) {
    final columnMode = LizaThemes.isColumnMode(context);
    return ChatRoutePage(
      key: state.pageKey,
      restorationId: state.pageKey.value,
      columnMode: columnMode,
      fadeDuration: !columnMode || MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : NewRequestTransition.durationFor(state.pathParameters['roomid']!),
      child: child,
    );
  }
}

/// Страница чата, класс которой не зависит от режима колонок: [Page.canUpdate]
/// сравнивает `runtimeType`, и маршрут переживает пересечение порога, а режим
/// маршрут читает из текущей страницы на лету. Тело страницы держит
/// `ModalRoute._subtreeKey`, поэтому смена обёртки перехода State не сбрасывает.
class ChatRoutePage<T> extends Page<T> {
  final Widget child;
  final bool columnMode;

  /// Кроссфейд в column-mode; в узком режиме не используется.
  final Duration fadeDuration;

  const ChatRoutePage({
    required this.child,
    required this.columnMode,
    required this.fadeDuration,
    super.key,
    super.restorationId,
  });

  @override
  Route<T> createRoute(BuildContext context) => _ChatRoute<T>(this);
}

class _ChatRoute<T> extends PageRoute<T> with MaterialRouteTransitionMixin<T> {
  _ChatRoute(ChatRoutePage<T> page) : super(settings: page);

  ChatRoutePage<T> get _page => settings as ChatRoutePage<T>;

  @override
  Widget buildContent(BuildContext context) => _page.child;

  @override
  bool get maintainState => true;

  @override
  bool get fullscreenDialog => false;

  // didPush/didPop миксина перечитывают длительности из этих геттеров.
  @override
  Duration get transitionDuration =>
      _page.columnMode ? _page.fadeDuration : super.transitionDuration;

  @override
  Duration get reverseTransitionDuration =>
      _page.columnMode ? Duration.zero : super.reverseTransitionDuration;

  // Cupertino-переход миксина нижний маршрут берёт себе через didChangeNext:
  // в column-mode пустая панель под кроссфейдом съезжала бы влево.
  @override
  DelegatedTransitionBuilder? get delegatedTransition =>
      _page.columnMode ? null : super.delegatedTransition;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _page.columnMode
      ? FadeTransition(opacity: animation, child: child)
      : super.buildTransitions(context, animation, secondaryAnimation, child);

  @override
  String get debugLabel => '${super.debugLabel}(${_page.name})';
}

/// Обрабатывает инвайт-код: если сессия не установлена — сохраняет ссылку и
/// уводит на логин, иначе резолвит цель общим резолвером.
///
/// Логика резолва (ожидание sync, различение space, mini-app, user-invite)
/// живёт в deep_link_target.dart и переиспользуется post-login хелпером —
/// раньше у них были свои копии, и post-login-копия не ждала sync, из-за чего
/// открывался пустой экран.
// ignore: use_build_context_synchronously
Future<String> _handleInviteCode(BuildContext context, String code) async {
  final isLogged = Matrix.of(
    context,
  ).widget.clients.any((client) => client.isLogged());
  if (!isLogged) {
    PendingDeepLinkStore.set(DeepLinkKind.invite, code);
    return '/home';
  }
  return '/opening/$code';
}

/// Короткая ссылка на сторис. go_router сам матчит входящий App Link
/// `.../s/<code>` на этот роут раньше, чем сработает chat_list-стрим ссылок,
/// поэтому резолвим ЗДЕСЬ (как _handleInviteCode). Вьюер открывается императивно
/// (Navigator.push), а не как go_router-маршрут, поэтому нельзя вернуть путь на
/// него: уводим на /rooms, а вьюер пушим сами через глобальный navigatorKey.
///
/// Почему через navigatorKey, а не через отложенный ref + ChatList (регрессия
/// «ссылка показывает список чатов»): резолв асинхронный (round-trip к
/// auth-proxy), а в column-mode ChatList смонтирован постоянно (ShellRoute) и на
/// /rooms НЕ ремаунтится — его initState-консумент pending-ref не запускался, а
/// стрим-консумент ненадёжен (go_router уже съел App Link). Пуш из глобального
/// navigator не зависит ни от гонки резолва, ни от ремаунта.
Future<String> _handleStoryLinkCode(BuildContext context, String code) async {
  final isLogged = Matrix.of(
    context,
  ).widget.clients.any((client) => client.isLogged());
  // Незалогинен: сохраняем ссылку, чтобы после входа открыть сторис, а не
  // бросить пользователя в списке чатов.
  if (!isLogged) {
    PendingDeepLinkStore.set(DeepLinkKind.story, code);
    return '/home';
  }

  final activeClient = Matrix.of(
    context,
  ).widget.clients.firstWhere((client) => client.isLogged());
  final accessToken = activeClient.accessToken ?? '';
  try {
    final ref = await StoryLinkService().resolveLink(
      code: code,
      accessToken: accessToken,
    );
    if (ref != null) {
      // Cold start: комната автора могла ещё не прийти из /sync - без ожидания
      // openStoryByRef сразу упрётся в getRoomById==null → «История недоступна».
      await waitForRoomInSync(activeClient, ref.roomId);
      // Пушим вьюер после того как навигация уйдёт на /rooms (под вьюером -
      // список чатов). Глобальный navigator (не context этого redirect,
      // который может быть уже размонтирован после навигации).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navContext =
            LizaApp.router.routerDelegate.navigatorKey.currentContext;
        if (navContext != null) openStoryByRef(navContext, ref);
      });
    }
  } catch (e, s) {
    Logs().w('[StoryLinkRoute] resolve failed: $e', e, s);
  }
  return '/rooms';
}

/// Ссылка на канал `me.liza.ru/c/<ник>` (и deep-link `liza://channel/<ник>`).
///
/// Резолвим ЗДЕСЬ, как `_handleStoryLinkCode`: go_router матчит App Link раньше,
/// чем сработает стрим ссылок в ChatList. Ник — не Matrix-идентификатор (без
/// сигила), поэтому раньше ссылка проваливалась в fallback `openMatrixToUrl`,
/// который трактовал голый ник как user-id и открывал карточку пользователя
/// (ЛС) вместо канала — [[RL-channel-link-open]].
///
/// Уже подписан → сразу в канал. Не подписан → тоже сразу в комнату: ChatPage
/// при отсутствии членства сам включит peek-режим (живая лента + кнопка
/// «Подписаться»), как это уже устроено для входа через поиск. Прежний
/// диалог-превью `PublicRoomDialog` заставлял вступать в канал ради
/// просмотра, из-за чего канал попадал в список чатов до того, как человек
/// решил подписываться.
Future<String> _handleChannelHandle(BuildContext context, String handle) async {
  final normalized = normalizeChannelHandle(handle);
  final isLogged = Matrix.of(
    context,
  ).widget.clients.any((client) => client.isLogged());
  if (!isLogged) {
    PendingDeepLinkStore.set(DeepLinkKind.channel, handle);
    return '/home';
  }

  if (validateChannelHandle(normalized) != null) {
    Logs().w('[ChannelLinkRoute] невалидный ник: $handle');
    _showChannelLinkError((l10n) => l10n.channelLinkNotFound);
    return '/rooms';
  }

  final ChannelHandleResolved? resolved;
  try {
    resolved = await AuthProxyService().resolveChannelHandle(normalized);
  } catch (e, s) {
    Logs().w('[ChannelLinkRoute] resolve failed: $e', e, s);
    _showChannelLinkError((l10n) => l10n.channelLinkOpenFailed);
    return '/rooms';
  }
  if (resolved == null) {
    // 404: ник свободен ИЛИ канал стал непубличным — наружу это неотличимо.
    _showChannelLinkError((l10n) => l10n.channelLinkNotFound);
    return '/rooms';
  }

  final roomId = resolved.roomId;
  // Неподписанный пользователь идёт СРАЗУ в ленту (Liza-модель): ChatPage
  // при отсутствии комнаты включит peek-режим и покажет кнопку «Подписаться».
  return '/rooms/${Uri.encodeComponent(roomId)}';
}

/// Показывает ошибку открытия канал-ссылки поверх текущего экрана.
/// Через глобальный navigatorKey: собственный context redirect'а к моменту
/// показа уже размонтирован навигацией на /rooms.
void _showChannelLinkError(String Function(L10n l10n) message) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final navContext =
        LizaApp.router.routerDelegate.navigatorKey.currentContext;
    if (navContext == null) return;
    ScaffoldMessenger.of(
      navContext,
    ).showSnackBar(SnackBar(content: Text(message(L10n.of(navContext)))));
  });
}

/// Ссылка на публичный @-ник пользователя `me.liza.ru/u/<ник>` (и deep-link
/// `liza://user/<ник>`).
///
/// В отличие от канала резолв ника в MXID НЕ требует логина: auth-proxy
/// отдаёт `GET /api/handles/<ник>` без токена (см. global-constraints.md —
/// «резолв работает ВСЕГДА»), поэтому его делаем ДО проверки сессии, чтобы
/// открывающий ссылку неавторизованный человек тоже увидел «пользователь не
/// найден» вместо экрана логина без объяснений. Логин требуется только для
/// показа профиля/перехода в чат — если сессии нет, ник сохраняем как
/// pending и уводим на /home, ровно как остальные типы ссылок.
///
/// Неизвестный ник — мягкий исход (`profileNotFound`), а не экран битой
/// ссылки: ник мог быть свободен или уже освобождён владельцем, ссылка сама
/// по себе валидна.
Future<String> _handleUserHandle(BuildContext context, String handle) async {
  final normalized = normalizeChannelHandle(handle);
  if (validateChannelHandle(normalized) != null) {
    Logs().w('[UserLinkRoute] невалидный ник: $handle');
    _showChannelLinkError((l10n) => l10n.profileNotFound);
    return '/rooms';
  }

  final matrix = Matrix.of(context);
  final isLogged = matrix.widget.clients.any((client) => client.isLogged());

  final String? mxid;
  try {
    mxid = await matrix.userHandleService.resolve(normalized);
  } catch (e, s) {
    Logs().w('[UserLinkRoute] resolve failed: $e', e, s);
    if (!isLogged) {
      PendingDeepLinkStore.set(DeepLinkKind.user, handle);
      return '/home';
    }
    _showChannelLinkError((l10n) => l10n.channelLinkOpenFailed);
    return '/rooms';
  }
  if (mxid == null) {
    _showChannelLinkError((l10n) => l10n.profileNotFound);
    return '/rooms';
  }
  matrix.userHandleService.rememberHandle(mxid, normalized);

  if (!isLogged) {
    PendingDeepLinkStore.set(DeepLinkKind.user, handle);
    return '/home';
  }

  // Карточка — через глобальный navigatorKey (utils/open_user_profile.dart),
  // тот же паттерн, что и [_showChannelLinkError]: собственный context
  // redirect'а к моменту показа уже размонтирован навигацией.
  openUserProfile(matrix.client, mxid);
  return '/rooms';
}

/// Выполняет побочный эффект цели ссылки (карточка профиля для user-инвайта)
/// — вызывается из `/opening` после резолва, до навигации на путь цели.
void _runDeepLinkSideEffect(Client client, DeepLinkTarget target) {
  switch (deepLinkSideEffect(target)) {
    case OpenUserProfile(:final userId):
      openUserProfile(client, userId);
    case null:
      break;
  }
}

// waitForRoomInSync вынесена в utils/wait_for_room_in_sync.dart —
// переиспользуется здесь и в new_group.dart (создание канала).
