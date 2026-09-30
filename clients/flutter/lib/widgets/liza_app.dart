import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:liza/config/routes.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/config/themes.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/chat/mini_app_overlay.dart';
import 'package:liza/utils/adaptive_orientation.dart';
import 'package:liza/utils/invite_link_parser.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/app_lock.dart';
import 'package:liza/widgets/theme_builder.dart';
import 'package:liza/widgets/update_gate.dart';
import '../utils/custom_scroll_behaviour.dart';
import 'matrix.dart';

class LizaApp extends StatelessWidget {
  final Widget? testWidget;
  final List<Client> clients;
  final String? pincode;
  final SharedPreferences store;

  const LizaApp({
    super.key,
    this.testWidget,
    required this.clients,
    required this.store,
    this.pincode,
  });

  /// getInitialLink may rereturn the value multiple times if this view is
  /// opened multiple times for example if the user logs out after they logged
  /// in with qr code or magic link.
  static bool gotInitialLink = false;

  // Router must be outside of build method so that hot reload does not reset
  // the current path.
  //
  // На вебе стартовый маршрут берём из path-формы URL (`web.liza.ru/i/<code>`
  // — так ведёт лендинг «Открыть в браузере»): роутер на hash-стратегии сам
  // видит только `#…`, и залогиненный пользователь попадал в список чатов
  // вместо цели (LABA-2551). go_router применяет initialLocation лишь при
  // пустом hash, поэтому перезагрузка на `#/rooms/…` его не перетриггерит.
  static final GoRouter router = buildAppRouter(
    initialLocation: kIsWeb ? webInitialLocation(Uri.base) : null,
  );

  /// Фабрика роутера. Вынесена из статика, чтобы стартовый маршрут был
  /// тестируем: статик инициализируется один раз на изолят и `Uri.base` в нём
  /// не подменить.
  static GoRouter buildAppRouter({String? initialLocation}) => GoRouter(
        routes: AppRoutes.routes,
        initialLocation: initialLocation,
        debugLogDiagnostics: true,
        onException: (context, state, router) {
          // Auth/register deep links (liza://auth/callback,
          // liza://register-callback) are handled by HomeserverPickerController
          // via FlutterWebAuth2 / app_links. Silently ignore them so GoRouter
          // doesn't reset the navigation stack.
          if (state.uri.host == 'auth' ||
              state.uri.path.startsWith('/auth/') ||
              state.uri.host == 'register-callback') {
            return;
          }
          // Other unmatched routes — go to root which redirects appropriately.
          router.go('/');
        },
      );

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      builder: (context, themeMode, primaryColor) => MaterialApp.router(
        title: AppSettings.applicationName.value,
        themeMode: themeMode,
        theme: LizaThemes.buildTheme(context, Brightness.light, primaryColor),
        darkTheme: LizaThemes.buildTheme(
          context,
          Brightness.dark,
          primaryColor,
        ),
        scrollBehavior: CustomScrollBehavior(),
        // Интерфейс всегда русский: без явной локали Flutter берёт язык
        // браузера/системы и на нерусской локали (в вебе — почти всегда)
        // подставляет первый supportedLocales, то есть английский.
        locale: const Locale('ru'),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        routerConfig: router,
        builder: (context, child) {
          // На macOS Flutter рендерит UI крупнее нативных приложений.
          // Уменьшаем глобальный масштаб текста для более нативного вида.
          Widget result = AdaptiveOrientation(
            child: AppLockWidget(
              pincode: pincode,
              clients: clients,
              // Need a navigator above the Matrix widget for
              // displaying dialogs
              child: Matrix(
                clients: clients,
                store: store,
                child: UpdateGate(
                  child: MiniAppOverlay(
                    child: testWidget ?? child!,
                  ),
                ),
              ),
            ),
          );
          if (PlatformInfos.isMacOS) {
            final data = MediaQuery.of(context);
            result = MediaQuery(
              data: data.copyWith(
                textScaler: TextScaler.linear(
                  data.textScaler.scale(1.0) * 1.0,
                ),
              ),
              child: result,
            );
          }
          return result;
        },
      ),
    );
  }
}
