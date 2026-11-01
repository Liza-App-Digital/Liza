import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:app_links/app_links.dart';
import 'package:collection/collection.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:go_router/go_router.dart';
import 'package:matrix/matrix.dart';
import 'package:universal_html/html.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'package:liza/config/app_config.dart';
import 'package:liza/config/setting_keys.dart';
import 'package:liza/l10n/l10n.dart';
import 'package:liza/pages/auth_select/auth_select.dart';
import 'package:liza/pages/demo_auth/demo_auth_flow.dart' show addAccountPath;
import 'package:liza/pages/homeserver_picker/auth_outcome_view.dart';
import 'package:liza/pages/homeserver_picker/homeserver_picker_view.dart';
import 'package:liza/utils/auth_diagnostics.dart';
import 'package:liza/utils/auth_proxy_login_helper.dart';
import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/deep_link_target.dart';
import 'package:liza/utils/invite_link_parser.dart';
import 'package:liza/utils/bot_deep_link.dart';
import 'package:liza/utils/pending_deep_link.dart';
import 'package:liza/utils/phone_country_resolver.dart';
import 'package:liza/utils/pending_invite_code.dart';
import 'package:liza/utils/pending_invite_gate.dart';
import 'package:liza/utils/version_gate_service.dart';
import 'package:liza/utils/web_auth_redirect_url.dart';
import 'package:liza/utils/file_selector.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:liza/widgets/matrix.dart';
import '../../utils/localized_exception_extension.dart';

/// Cancellation token for coordinating parallel redirect + polling paths.
class _CancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Result from the polling loop, used by parallel auth flows.
class _PollResult {
  final String status;
  final AuthTokenResponse? tokenResponse;
  final String? action;
  final String sessionState;

  /// Распознанный исход при `status == 'error'`. Нераспознанные коды сюда не
  /// доходят — они остаются исключением, чтобы не глотать чужие ошибки.
  final AuthOutcome? outcome;

  const _PollResult({
    required this.status,
    required this.sessionState,
    this.tokenResponse,
    this.action,
    this.outcome,
  });
}

/// Переход к подтверждению номера. Из «Добавить аккаунт» — вложенным
/// маршрутом: верхний /auth/phone под loggedInRedirect уводил уже вошедшего
/// в список чатов, не заказав код.
void openPhoneAuth(
  BuildContext context,
  String phone, {
  required bool addMultiAccount,
}) {
  if (addMultiAccount) {
    context.push('$addAccountPath/phone', extra: phone);
  } else {
    context.go('/auth/phone', extra: phone);
  }
}

class HomeserverPicker extends StatefulWidget {
  final bool addMultiAccount;
  const HomeserverPicker({required this.addMultiAccount, super.key});

  @override
  HomeserverPickerController createState() => HomeserverPickerController();
}

class HomeserverPickerController extends State<HomeserverPicker> {
  bool isLoading = false;

  final TextEditingController homeserverController = TextEditingController(
    text: AppSettings.defaultHomeserver.value,
  );

  final AuthProxyService _authProxyService = AuthProxyService();

  /// Уточнение страны по IP для префикса телефона на первом экране.
  /// Держим в контроллере, а не создаём в `build()`: иначе каждый rebuild
  /// заводил бы новый `http.Client`.
  final PhoneCountryResolver countryResolver = HttpPhoneCountryResolver();

  String? error;

  /// Исход авторизации, когда аккаунта в Liza нет (сирота после OIDC или
  /// недействительная инвайт-ссылка). Не `error`: это не сбой, а нормальный
  /// исход со своим экраном — [AuthOutcomeView].
  AuthOutcome? authOutcome;

  /// Показать исход [outcome] вместо обычного содержимого экрана.
  void _showAuthOutcome(AuthOutcome outcome) {
    if (!mounted) return;
    setState(() {
      authOutcome = outcome;
      error = null;
    });
  }

  void dismissAuthOutcome() => setState(() {
    authOutcome = null;
    error = null;
  });

  /// Background listener for legacy liza://register-callback deep-link
  /// (macOS/Windows). Триггерится в двух случаях:
  /// 1. Сервер отдал 501 на /api/auth/registration (нет registration_endpoint),
  ///    мы откатились на legacy-флоу с прямым URL к ProdamusID.
  /// 2. На машине устаревший инсталлер/закэшированный schema-handler, или
  ///    OS вернула старый callback вне зависимости от текущего флоу.
  ///
  /// В обоих случаях получаем session_state/code от ProdamusID, но обменять
  /// их сами не можем (нет PKCE-verifier'а и client_secret) — поэтому
  /// просто запускаем чистый OIDC-логин: у юзера уже есть сессия в
  /// ProdamusID, второй проход проходит без UI.
  StreamSubscription<Uri>? _legacyRegisterLink;

  /// Подписка на deep-link до логина: ловим liza://invite/<code> или
  /// https://me.liza.ru/i/<code> и сохраняем код в [PendingInviteCode],
  /// чтобы при следующем шаге authProxyLoginAction передал invite_code и
  /// после login-а сработал _redeemPendingInvite. Без этого слушателя
  /// deep-link до логина пропадал в никуда: ChatList (где живёт основной
  /// стрим) не маунтится для неавторизованного юзера.
  StreamSubscription<Uri>? _preLoginInviteLink;

  /// Future восстановления pending-диплинка из SharedPreferences.
  ///
  /// Держим в поле, а не `unawaited`: без него кнопка, нажатая до окончания
  /// чтения, отправляла `inviteCode: null` — сервер не видел инвайта,
  /// `register_via_invite` не вызывался, и человек с ВАЛИДНОЙ ссылкой получал
  /// ошибку сироты. Особенно уязвим путь «сирота -> потом инвайт»: код там
  /// приходит из персиста, а не из свежего deep-link.
  late final Future<void> _pendingRestore;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && (PlatformInfos.isMacOS || PlatformInfos.isWindows)) {
      _legacyRegisterLink = AppLinks().uriLinkStream.listen((uri) {
        final scheme = AppConfig.appOpenUrlScheme.toLowerCase();
        if (uri.scheme.toLowerCase() != scheme ||
            uri.host != 'register-callback') {
          return;
        }
        Logs().w(
          '[Register] Legacy register-callback received, '
          'falling back to login: $uri',
        );
        if (!mounted) return;
        final errParam = uri.queryParameters['error'];
        if (errParam != null && errParam.isNotEmpty) {
          setState(() {
            error = AuthProxyServerException(
              serverError: errParam,
            ).toLocalizedString(context);
          });
          return;
        }
        authProxyLoginAction();
      });
    }

    if (!kIsWeb) {
      final appLinks = AppLinks();
      _preLoginInviteLink = appLinks.uriLinkStream.listen(_handlePreLoginUri);
      appLinks.getInitialLink().then(_handlePreLoginUri);
      // Cold start без initial-link (юзер закрыл приложение на форме логина
      // и вернулся): код уже лежит в хранилище — поднимаем его оттуда.
      // Ссылка, если она есть, перетрёт значение через _handlePreLoginUri.
      _pendingRestore = PendingInviteCode.restore().then((_) {
        if (!mounted) return;
        // Перерисовка нужна, иначе экран остаётся на состоянии первого кадра.
        setState(() {});
      });
    } else {
      // В вебе AppLinks не работает, а переход `/i/<code>` → форма логина —
      // полная перезагрузка страницы: статика PendingInviteCode обнуляется.
      // Берём код из адресной строки, иначе — из SharedPreferences.
      _pendingRestore = _restoreInviteCodeForWeb().then((_) {
        if (!mounted) return;
        // Перерисовка нужна, иначе экран остаётся на состоянии первого кадра.
        setState(() {});
      });
    }

    unawaited(_loadRequestAccessUrl());
  }

  /// До ответа version-gate — фолбэк-константа: без инвайта пользователь
  /// обязан видеть кнопку заявки сразу, а не после сетевого round-trip
  /// (и тем более не «ничего», если сервис недоступен). Когда ответ придёт
  /// (`_loadRequestAccessUrl`), он ПЕРЕЗАПИШЕТ это значение — в том числе
  /// на null, если version-gate явно решил кнопку скрыть: это осознанное
  /// решение сервера, отличное от «ещё не загрузили», и его нужно уважать.
  String? requestAccessUrl = AppConfig.defaultRequestAccessUrl;

  Future<void> _loadRequestAccessUrl() async {
    final url = await VersionGateService(
      baseUrl: AppConfig.versionGateBaseUrl,
    ).fetchRequestAccessUrl();
    if (!mounted) return;
    setState(() => requestAccessUrl = url);
  }

  void requestAccessAction() {
    final url = requestAccessUrl;
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !{'https', 'http'}.contains(uri.scheme)) return;
    launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  /// Web-only: восстановить invite-код после перезагрузки страницы.
  Future<void> _restoreInviteCodeForWeb() async {
    final botLink = parseWebBotLink(Uri.base);
    if (botLink != null) {
      PendingDeepLinkStore.set(DeepLinkKind.bot, botLink.route);
      return;
    }
    final fromUrl = parseWebInviteCode(Uri.base);
    if (fromUrl != null) {
      Logs().i(
        '[InviteRedeem] web: invite-код из URL '
        '${fromUrl.substring(0, fromUrl.length.clamp(0, 4))}...',
      );
      PendingInviteCode.set(fromUrl);
      return;
    }
    final storyFromUrl = parseWebStoryCode(Uri.base);
    if (storyFromUrl != null) {
      PendingDeepLinkStore.set(DeepLinkKind.story, storyFromUrl);
      return;
    }
    final channelFromUrl = parseWebChannelHandle(Uri.base);
    if (channelFromUrl != null) {
      PendingDeepLinkStore.set(DeepLinkKind.channel, channelFromUrl);
      return;
    }
    final userFromUrl = parseWebUserHandle(Uri.base);
    if (userFromUrl != null) {
      PendingDeepLinkStore.set(DeepLinkKind.user, userFromUrl);
      return;
    }
    final code = await PendingInviteCode.restore();
    if (code == null) return;
    Logs().i(
      '[InviteRedeem] web: invite-код восстановлен из хранилища '
      '${code.substring(0, code.length.clamp(0, 4))}...',
    );
  }

  void _handlePreLoginUri(Uri? uri) {
    if (uri == null) return;
    final botLink = parseBotLink(uri);
    if (botLink != null) {
      PendingDeepLinkStore.set(DeepLinkKind.bot, botLink.route);
      return;
    }
    final code = parseInviteCode(uri);
    if (code == null) return;
    if (PendingInviteCode.current == code) return;
    Logs().i(
      '[InviteRedeem] pre-login deep-link, caching invite code '
      '${code.substring(0, code.length.clamp(0, 4))}...',
    );
    PendingInviteCode.set(code);
  }

  @override
  void dispose() {
    _legacyRegisterLink?.cancel();
    _legacyRegisterLink = null;
    _preLoginInviteLink?.cancel();
    _preLoginInviteLink = null;
    super.dispose();
  }

  /// Current route base path (e.g. '/home' or '/rooms/settings/addaccount').
  /// Used to build sub-route paths that work for both fresh login and
  /// multi-account flows.
  String get _basePath =>
      GoRouter.of(context).routeInformationProvider.value.uri.path;

  void submitPhoneAction(String phone) =>
      openPhoneAuth(context, phone, addMultiAccount: widget.addMultiAccount);

  /// Starts an analysis of the given homeserver. It uses the current domain and
  /// makes sure that it is prefixed with https. Then it searches for the
  /// well-known information and forwards to the login page depending on the
  /// login type.
  Future<void> checkHomeserverAction({bool legacyPasswordLogin = false}) async {
    final homeserverInput = homeserverController.text
        .trim()
        .toLowerCase()
        .replaceAll(' ', '-');

    if (homeserverInput.isEmpty) {
      final client = await Matrix.of(context).getLoginClient();
      setState(() {
        error = loginFlows = null;
        isLoading = false;
        client.homeserver = null;
      });
      return;
    }
    setState(() {
      error = loginFlows = null;
      isLoading = true;
    });

    final l10n = L10n.of(context);

    try {
      var homeserver = Uri.parse(homeserverInput);
      if (homeserver.scheme.isEmpty) {
        homeserver = Uri.https(homeserverInput, '');
      }
      final client = await Matrix.of(context).getLoginClient();
      final (_, _, loginFlows, _) = await client.checkHomeserver(homeserver);
      this.loginFlows = loginFlows;
      if (supportsSso && !legacyPasswordLogin) {
        if (!PlatformInfos.isMobile) {
          final consent = await showOkCancelAlertDialog(
            context: context,
            title: l10n.appWantsToUseForLogin(homeserverInput),
            message: l10n.appWantsToUseForLoginDescription,
            okLabel: l10n.continueText,
          );
          if (consent != OkCancelResult.ok) return;
        }
        return ssoLoginAction();
      }
      context.push('$_basePath/login', extra: client);
    } catch (e) {
      setState(
        () => error = (e).toLocalizedString(
          context,
          ExceptionContext.checkHomeserver,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  List<LoginFlow>? loginFlows;

  bool _supportsFlow(String flowType) =>
      loginFlows?.any((flow) => flow.type == flowType) ?? false;

  bool get supportsSso => _supportsFlow('m.login.sso');

  bool isDefaultPlatform =
      (PlatformInfos.isMobile || PlatformInfos.isWeb || PlatformInfos.isMacOS);

  bool get supportsPasswordLogin => _supportsFlow('m.login.password');

  /// URL страницы-приёмника OIDC-результата — всегда абсолютный `/auth.html`.
  /// Разбор и мотивация — в [webAuthRedirectUrl].
  static String get _webRedirectUrl =>
      webAuthRedirectUrl(html.window.location.href);

  void ssoLoginAction() async {
    final redirectUrl = kIsWeb
        ? _webRedirectUrl
        : isDefaultPlatform
        ? '${AppConfig.appOpenUrlScheme.toLowerCase()}://login'
        : 'https://${AppConfig.authProxyBaseUrl}/done';
    final client = await Matrix.of(context).getLoginClient();
    final url = client.homeserver!.replace(
      path: '/_matrix/client/v3/login/sso/redirect',
      queryParameters: {'redirectUrl': redirectUrl},
    );

    final urlScheme = isDefaultPlatform
        ? Uri.parse(redirectUrl).scheme
        : 'https://${AppConfig.authProxyBaseUrl}';
    final result = await FlutterWebAuth2.authenticate(
      url: url.toString(),
      callbackUrlScheme: urlScheme,
      options: FlutterWebAuth2Options(useWebview: PlatformInfos.isMobile),
    );
    final token = Uri.parse(result).queryParameters['loginToken'];
    if (token?.isEmpty ?? false) return;

    setState(() {
      error = null;
      isLoading = true;
    });
    try {
      await client.login(
        LoginType.mLoginToken,
        token: token,
        initialDeviceDisplayName: PlatformInfos.clientName,
      );
    } catch (e) {
      setState(() {
        error = e.toLocalizedString(context);
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  /// Builds the legacy direct-to-ProdamusID registration URL.
  /// Используется только в [_registerLegacyFallback] — основной поток
  /// идёт через auth-proxy `/api/auth/registration`.
  String _buildRegistrationUrl(String returnUrl) {
    return '${AppConfig.registrationBaseUrl}/registration'
        '?client_id=${AppConfig.oauthClientId}'
        '&return_url=${Uri.encodeComponent(returnUrl)}'
        '&auth_feature_flag=mobile_application'
        '&ui_mode_feature_flag=without_navigation_without_bottom_links';
  }

  /// Симметричный логину флоу регистрации через auth-proxy.
  ///
  /// 1. `GET /api/auth/registration` → `authorization_url` к форме
  ///    регистрации ProdamusID + наш `session_state`.
  /// 2. Открываем URL так же, как при логине: webview (iOS/Android),
  ///    внешний браузер + AppLinks (macOS/Windows), браузер + polling
  ///    (Web/Linux). После регистрации ProdamusID редиректит на
  ///    `liza://auth/callback` с loginToken — один OIDC-проход.
  ///
  /// Fallback-сценарии:
  /// - Сервер вернул 501/404 → [_registerLegacyFallback]: открываем
  ///   прямой URL к ProdamusID и после `liza://register-callback`
  ///   стартуем чистый OIDC-логин.
  /// - В любой момент пришёл `liza://register-callback` (старый
  ///   инсталлер, OS-кеш) — глобальный [_legacyRegisterLink] listener
  ///   в `initState` подхватит его и стартует `authProxyLoginAction`.
  void registerAction() async {
    Logs().i('[Register] === Registration flow started ===');
    setState(() {
      error = null;
      isLoading = true;
    });

    try {
      final urlScheme = AppConfig.appOpenUrlScheme.toLowerCase();
      final supportsDeepLink =
          !kIsWeb &&
          (PlatformInfos.isMobile ||
              PlatformInfos.isMacOS ||
              PlatformInfos.isWindows);
      final redirectUrl = kIsWeb
          ? _webRedirectUrl
          : supportsDeepLink
          ? '$urlScheme://auth/callback'
          : 'https://${AppConfig.authProxyBaseUrl}/done';

      final client = await Matrix.of(context).getLoginClient();
      final homeserver = AppSettings.defaultHomeserver.value;
      await client.checkHomeserver(Uri.https(homeserver, ''));

      AuthLoginResponse authResponse;
      try {
        final pendingInvite = await inviteCodeAfterRestore(_pendingRestore);
        Logs().i(
          '[Register] Initiating via auth-proxy, redirect_url=$redirectUrl'
          '${pendingInvite != null ? ', invite_code=${pendingInvite.substring(0, pendingInvite.length.clamp(0, 4))}...' : ''}',
        );
        authResponse = await _authProxyService.initiateRegistration(
          redirectUrl,
          inviteCode: pendingInvite,
        );
      } on AuthProxyException catch (e) {
        if (e.statusCode == 501 || e.statusCode == 404) {
          Logs().w(
            '[Register] Server has no /api/auth/registration '
            '(${e.statusCode}), falling back to legacy flow',
          );
          await _registerLegacyFallback();
          return;
        }
        rethrow;
      }
      Logs().i(
        '[Register] Got registration URL: ${authResponse.authorizationUrl}',
      );

      if (PlatformInfos.isAndroid) {
        final sdk = await AuthDiagnostics.getAndroidSdkVersion();
        if (AuthDiagnostics.shouldUsePollingFallback(sdk)) {
          await _authViaPolling(authResponse, client);
        } else {
          await _authViaWebView(authResponse, redirectUrl, client);
        }
      } else if (PlatformInfos.isIOS) {
        await _authViaWebView(authResponse, redirectUrl, client);
      } else if (PlatformInfos.isMacOS || PlatformInfos.isWindows) {
        await _authViaDesktopDeepLink(authResponse, client);
      } else {
        // Web/Linux
        await _authViaPolling(authResponse, client);
      }
    } catch (e, s) {
      Logs().e('[Register] Failed', e, s);
      if (mounted) {
        setState(() => error = e.toLocalizedString(context));
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  /// Legacy registration flow для случая, когда auth-proxy ещё не задеплоен
  /// с эндпоинтом `/api/auth/registration`. Открывает прямой URL ProdamusID
  /// и ждёт `liza://register-callback` (или закрытия webview), после чего
  /// стартует чистый OIDC-логин — у юзера уже есть ProdamusID-сессия.
  Future<void> _registerLegacyFallback() async {
    final urlScheme = AppConfig.appOpenUrlScheme.toLowerCase();
    final returnUrl = kIsWeb
        ? _webRedirectUrl
        : '$urlScheme://register-callback';
    final regUrl = _buildRegistrationUrl(returnUrl);

    if (!kIsWeb && (PlatformInfos.isIOS || PlatformInfos.isAndroid)) {
      try {
        Logs().i('[Register/legacy] Opening webview, returnUrl=$returnUrl');
        final result = await FlutterWebAuth2.authenticate(
          url: regUrl,
          callbackUrlScheme: urlScheme,
          options: const FlutterWebAuth2Options(useWebview: true),
        );
        final errParam = Uri.parse(result).queryParameters['error'];
        if (errParam != null && errParam.isNotEmpty) {
          throw AuthProxyServerException(serverError: errParam);
        }
        Logs().i('[Register/legacy] Webview ok, chaining to login');
      } catch (e, s) {
        if (e.toString().toLowerCase().contains('canceled')) {
          Logs().i('[Register/legacy] Webview cancelled by user');
          return;
        }
        Logs().e('[Register/legacy] Webview failed', e, s);
        if (mounted) setState(() => error = e.toLocalizedString(context));
        return;
      }
      authProxyLoginAction();
      return;
    }

    // macOS/Windows: глобальный _legacyRegisterLink listener (initState)
    // уже слушает liza://register-callback и сам стартует
    // authProxyLoginAction. Здесь только открываем браузер.
    Logs().i('[Register/legacy] Opening external browser');
    try {
      await launchUrl(
        Uri.parse(regUrl),
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
      );
    } catch (e, s) {
      Logs().e('[Register/legacy] Failed to open registration URL', e, s);
      if (mounted) setState(() => error = e.toLocalizedString(context));
    }
  }

  void authProxyLoginAction() async {
    setState(() {
      error = null;
      isLoading = true;
    });
    try {
      Logs().i(
        '[AuthProxy] === Auth flow started '
        '(android=${PlatformInfos.isAndroid}, '
        'ios=${PlatformInfos.isIOS}, '
        'web=${PlatformInfos.isWeb}) ===',
      );

      // Android: connectivity pre-check before any network calls
      if (PlatformInfos.isAndroid) {
        Logs().i('[AuthProxy] Running connectivity pre-check');
        final checkResult = await AuthDiagnostics.checkConnectivity(
          hosts: [
            AppSettings.defaultHomeserver.value,
            AppConfig.authProxyBaseUrl,
          ],
        );
        if (!checkResult.isOk) {
          Logs().w(
            '[AuthProxy] Pre-check failed: ${checkResult.failureReason}',
          );
          throw ConnectivityCheckException(
            host: checkResult.failedHost ?? 'unknown',
            reason: checkResult.failureReason ?? 'unknown',
            failureType:
                checkResult.failureType ?? ConnectivityFailureType.unknown,
          );
        }
        Logs().i('[AuthProxy] Connectivity pre-check passed');
      }

      final client = await Matrix.of(context).getLoginClient();
      Logs().i('[AuthProxy] Login client obtained');

      final homeserver = AppSettings.defaultHomeserver.value;
      Logs().i('[AuthProxy] Checking homeserver: $homeserver');
      await client.checkHomeserver(Uri.https(homeserver, ''));
      Logs().i('[AuthProxy] Homeserver OK, homeserver=${client.homeserver}');

      // macOS/Windows тоже используют deep-link (liza://auth/callback) —
      // схема liza:// зарегистрирована в Info.plist (macOS) и в реестре
      // через Inno Setup инсталлер (Windows). На Linux схемы нет, поэтому
      // там оставляем https-redirect на /done и поллинг.
      final supportsDeepLink =
          !kIsWeb &&
          (PlatformInfos.isMobile ||
              PlatformInfos.isMacOS ||
              PlatformInfos.isWindows);
      final redirectUrl = kIsWeb
          ? _webRedirectUrl
          : supportsDeepLink
          ? '${AppConfig.appOpenUrlScheme.toLowerCase()}://auth/callback'
          : 'https://${AppConfig.authProxyBaseUrl}/done';

      // Если юзер пришёл по инвайт-ссылке — передаём invite_code в auth-proxy,
      // чтобы тот после OIDC-callback вызвал register_via_invite.
      final pendingInvite = await inviteCodeAfterRestore(_pendingRestore);
      Logs().i(
        '[AuthProxy] Initiating login, redirect_url=$redirectUrl'
        '${pendingInvite != null ? ', invite_code=${pendingInvite.substring(0, pendingInvite.length.clamp(0, 4))}...' : ''}',
      );
      final authResponse = await _authProxyService.initiateLogin(
        redirectUrl,
        inviteCode: pendingInvite,
      );
      Logs().i(
        '[AuthProxy] Got authorization URL: '
        '${authResponse.authorizationUrl}',
      );

      if (PlatformInfos.isAndroid) {
        final sdkVersion = await AuthDiagnostics.getAndroidSdkVersion();
        if (AuthDiagnostics.shouldUsePollingFallback(sdkVersion)) {
          // Old Android — skip WebView, use polling directly
          Logs().i('[AuthProxy] Old Android SDK $sdkVersion, using polling');
          await _authViaPolling(authResponse, client);
        } else {
          // Modern Android — WebView with parallel polling built-in
          await _authViaWebView(authResponse, redirectUrl, client);
        }
      } else if (PlatformInfos.isIOS) {
        await _authViaWebView(authResponse, redirectUrl, client);
      } else if (PlatformInfos.isMacOS || PlatformInfos.isWindows) {
        await _authViaDesktopDeepLink(authResponse, client);
      } else {
        // Web/Linux: system browser + poll (нет регистрации liza://-схемы)
        await _authViaPolling(authResponse, client);
      }
    } catch (e, s) {
      Logs().e('[AuthProxy] Auth flow failed', e, s);
      setState(() {
        error = e.toLocalizedString(context);
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  Future<void> _authViaWebView(
    AuthLoginResponse authResponse,
    String redirectUrl,
    Client client,
  ) async {
    final cancellation = _CancellationToken();

    // Start polling in background using the same session
    final pollFuture = _pollForToken(
      sessionState: authResponse.sessionState,
      cancellation: cancellation,
    );

    final urlScheme = Uri.parse(redirectUrl).scheme;
    Logs().i(
      '[AuthProxy] Opening webview, callbackScheme=$urlScheme, '
      'url=${authResponse.authorizationUrl}',
    );

    final webViewFuture = FlutterWebAuth2.authenticate(
      url: authResponse.authorizationUrl,
      callbackUrlScheme: urlScheme,
      options: const FlutterWebAuth2Options(useWebview: true),
    );

    try {
      // Race: WebView callback vs polling — whoever finishes first wins
      final winner = await Future.any<Object>([
        webViewFuture.then<Object>((result) => result),
        pollFuture.then<Object>((result) => result),
      ]);

      if (winner is String) {
        // WebView callback arrived first
        Logs().i('[AuthProxy] WebView won: $winner');

        final callbackData = AuthCallbackData.fromUri(Uri.parse(winner));
        Logs().i('[AuthProxy] Callback action: ${callbackData.action}');

        // 'processing' — сервер ещё обменивает code→token в фоне.
        // WebView закрылся, но токен будет позже — ждём polling.
        if (callbackData.action == 'processing') {
          Logs().i('[AuthProxy] Server processing async, waiting for poll');
          final pollResult = await pollFuture;
          await _handlePollResult(pollResult, client);
          return;
        }

        cancellation.cancel();

        if (callbackData.action == 'complete') {
          try {
            await _handleAuthCallback(
              callbackData,
              authResponse.sessionState,
              client,
            );
            return;
          } on MatrixException {
            Logs().w('[AuthProxy] Redirect token expired, trying refresh');
            try {
              final fresh = await _authProxyService.refreshToken(
                sessionState: authResponse.sessionState,
              );
              await _loginWithRetry(
                client,
                fresh.loginToken,
                sessionState: authResponse.sessionState,
              );
              return;
            } catch (refreshErr) {
              Logs().w('[AuthProxy] Refresh failed too', refreshErr);
              // Both redirect token and refresh failed — wait for poll
              final pollResult = await pollFuture;
              await _handlePollResult(pollResult, client);
              return;
            }
          }
        } else {
          // action_required or other
          await _handleAuthCallback(
            callbackData,
            authResponse.sessionState,
            client,
          );
          return;
        }
      } else if (winner is _PollResult) {
        // Polling finished first
        cancellation.cancel();
        Logs().i('[AuthProxy] Poll won, status=${winner.status}');
        await _handlePollResult(winner, client);
        return;
      }
    } catch (e) {
      if (e is AuthProxyServerException) {
        cancellation.cancel();
        rethrow;
      }
      // WebView or polling failure — try the other path
      Logs().w('[AuthProxy] WebView/poll race failed, trying fallback', e);
      try {
        final pollResult = await pollFuture;
        await _handlePollResult(pollResult, client);
      } catch (_) {
        // Both paths failed — rethrow original error
        rethrow;
      }
    }
  }

  /// Poll-only flow: opens system browser then polls until complete.
  /// Used by Web/Linux/Windows and old Android.
  Future<void> _authViaPolling(
    AuthLoginResponse authResponse,
    Client client,
  ) async {
    final authUri = Uri.parse(authResponse.authorizationUrl);
    Logs().i('[AuthProxy] Opening system browser for auth');
    await launchUrl(authUri, mode: LaunchMode.externalApplication);

    final cancellation = _CancellationToken();
    final result = await _pollForToken(
      sessionState: authResponse.sessionState,
      cancellation: cancellation,
    );
    await _handlePollResult(result, client);
  }

  /// Core polling loop — does NOT open a browser, just polls /api/auth/status.
  /// Returns a [_PollResult] when the session reaches a terminal state.
  /// Checks [cancellation] each iteration so a parallel redirect path can
  /// stop it early.
  Future<_PollResult> _pollForToken({
    required String sessionState,
    required _CancellationToken cancellation,
  }) async {
    Logs().i('[AuthProxy] Starting polling for session_state');
    const basePollInterval = Duration(seconds: 2);
    const maxPollInterval = Duration(seconds: 16);
    const maxAttempts = 180; // 6 minutes max
    const maxConsecutiveErrors = 5;

    String? lastPollError;
    var consecutiveErrorCount = 0;

    for (var i = 0; i < maxAttempts; i++) {
      final delay = consecutiveErrorCount > 0
          ? Duration(
              milliseconds: min(
                basePollInterval.inMilliseconds *
                    (1 << (consecutiveErrorCount - 1)),
                maxPollInterval.inMilliseconds,
              ),
            )
          : basePollInterval;
      await Future.delayed(delay);
      if (!mounted || cancellation.isCancelled) {
        throw Exception('Polling cancelled');
      }

      try {
        final statusData = await _authProxyService.getStatus(
          sessionState: sessionState,
        );
        consecutiveErrorCount = 0;
        lastPollError = null;

        final status = statusData['status'] as String?;

        if (status == 'pending') continue;

        Logs().i('[AuthProxy] Poll result status: $status');

        if (status == 'completed') {
          return _PollResult(
            status: 'completed',
            sessionState:
                statusData['session_state'] as String? ?? sessionState,
            tokenResponse: AuthTokenResponse.fromJson(statusData),
          );
        }

        if (status == 'action_required') {
          final action = statusData['action'] as String?;
          return _PollResult(
            status: 'action_required',
            sessionState:
                statusData['session_state'] as String? ?? sessionState,
            action: action,
          );
        }

        // Терминальный отказ: аккаунта в Liza нет. Ветвимся ПО КОДУ `error`,
        // не по человекочитаемому `message`. Нераспознанный код — не наш
        // случай: падаем ниже обычным исключением, чтобы не выдавать чужую
        // ошибку за «нет доступа».
        if (status == 'error') {
          final outcome = authOutcomeFromErrorCode(
            statusData['error'] as String?,
          );
          if (outcome != null) {
            return _PollResult(
              status: 'error',
              sessionState:
                  statusData['session_state'] as String? ?? sessionState,
              outcome: outcome,
            );
          }
          throw AuthProxyServerException(
            serverError:
                statusData['error'] as String? ??
                statusData['message'] as String? ??
                'unknown_auth_error',
          );
        }

        throw Exception('Unexpected auth status: $status');
      } on AuthProxyException catch (e) {
        if (e.statusCode == 404) {
          throw Exception(e.serverError ?? 'Session expired');
        }

        if (e.isNonTransient) {
          Logs().e('[AuthProxy] Non-transient server error, stopping poll: $e');
          throw AuthProxyServerException(
            serverError: e.serverError ?? e.message,
            statusCode: e.statusCode,
          );
        }

        final currentError = '${e.statusCode}:${e.serverError}';
        if (currentError == lastPollError) {
          consecutiveErrorCount++;
        } else {
          consecutiveErrorCount = 1;
          lastPollError = currentError;
        }

        if (consecutiveErrorCount >= maxConsecutiveErrors) {
          Logs().e(
            '[AuthProxy] $consecutiveErrorCount consecutive identical '
            'errors, stopping poll',
          );
          throw AuthProxyServerException(
            serverError: e.serverError ?? e.message,
            statusCode: e.statusCode,
          );
        }

        Logs().w('[AuthProxy] Poll error ($consecutiveErrorCount): $e');
      }
    }

    throw Exception('Authentication timed out');
  }

  /// Handle terminal [_PollResult]: login on completed, navigate on
  /// action_required.
  Future<void> _handlePollResult(_PollResult result, Client client) async {
    if (result.status == 'completed' && result.tokenResponse != null) {
      final tr = result.tokenResponse!;
      if (tr.serverName.isNotEmpty) {
        final targetHomeserver = Uri.https(tr.serverName, '');
        if (client.homeserver != targetHomeserver) {
          Logs().i(
            '[AuthProxy] switching homeserver: '
            '${client.homeserver} → $targetHomeserver',
          );
          await client.checkHomeserver(targetHomeserver);
        }
      }
      Logs().i(
        '[AuthProxy] logging in with token against ${client.homeserver}',
      );
      await _loginWithRetry(
        client,
        tr.loginToken,
        sessionState: result.sessionState,
      );
      // Для invite-сессий: backend возвращает inviteCode в polling-ответе.
      // Если он есть — устанавливаем как pending, redeem сделает навигацию.
      if (tr.inviteCode != null) {
        PendingInviteCode.set(tr.inviteCode);
      }
      await _redeemPendingInvite(client);
      return;
    }

    final outcome = result.outcome;
    if (result.status == 'error' && outcome != null) {
      Logs().i('[AuthProxy] Terminal outcome: $outcome');
      _showAuthOutcome(outcome);
      return;
    }

    if (result.status == 'action_required') {
      if (!mounted) return;
      Logs().i(
        '[AuthProxy] action_required: action=${result.action}, '
        'session_state=${result.sessionState}',
      );
      if (result.action == 'select') {
        context.push(
          '$_basePath/select',
          extra: AuthSelectExtra(
            sessionState: result.sessionState,
            authProxyService: _authProxyService,
          ),
        );
        return;
      }
      // Старые auth-proxy могли возвращать action=register — само-регистрация
      // задепрекейчена, отдаём пользователю понятную ошибку.
      throw AuthProxyServerException(
        serverError: L10n.of(context).accountNotFound,
      );
    }

    throw Exception('Unexpected poll result status: ${result.status}');
  }

  /// Desktop (macOS / Windows): открываем внешний браузер на authorization URL,
  /// параллельно запускаем polling и слушаем AppLinks. Кто первый закончит —
  /// тот и побеждает. На Windows схема liza:// регистрируется Inno Setup
  /// инсталлером (см. windows/installer.iss, HKCU\Software\Classes\liza).
  Future<void> _authViaDesktopDeepLink(
    AuthLoginResponse authResponse,
    Client client,
  ) async {
    final authUri = Uri.parse(authResponse.authorizationUrl);
    Logs().i('[AuthProxy] desktop: opening system browser for auth');
    await launchUrl(authUri, mode: LaunchMode.externalApplication);

    final cancellation = _CancellationToken();

    final pollFuture = _pollForToken(
      sessionState: authResponse.sessionState,
      cancellation: cancellation,
    );

    Logs().i('[AuthProxy] desktop: waiting for deep link or poll result');
    final deepLinkCompleter = Completer<Uri>();

    final sub = AppLinks().uriLinkStream.listen((uri) {
      if (!deepLinkCompleter.isCompleted &&
          uri.scheme == AppConfig.appOpenUrlScheme.toLowerCase()) {
        Logs().i('[AuthProxy] desktop: received deep link: $uri');
        deepLinkCompleter.complete(uri);
      }
    });

    try {
      final winner = await Future.any<Object>([
        deepLinkCompleter.future.then<Object>((uri) => uri),
        pollFuture.then<Object>((result) => result),
      ]);

      if (winner is Uri) {
        final callbackData = AuthCallbackData.fromUri(winner);
        Logs().i(
          '[AuthProxy] desktop: deep link won, action=${callbackData.action}',
        );

        if (callbackData.action == 'processing') {
          Logs().i(
            '[AuthProxy] desktop: server processing async, waiting for poll',
          );
          final pollResult = await pollFuture;
          await _handlePollResult(pollResult, client);
          return;
        }

        cancellation.cancel();

        if (callbackData.action == 'complete') {
          try {
            await _handleAuthCallback(
              callbackData,
              authResponse.sessionState,
              client,
            );
            return;
          } on MatrixException {
            Logs().w(
              '[AuthProxy] desktop: redirect token expired, trying refresh',
            );
            try {
              final fresh = await _authProxyService.refreshToken(
                sessionState: authResponse.sessionState,
              );
              await _loginWithRetry(
                client,
                fresh.loginToken,
                sessionState: authResponse.sessionState,
              );
              return;
            } catch (refreshErr) {
              Logs().w('[AuthProxy] desktop: refresh failed too', refreshErr);
              final pollResult = await pollFuture;
              await _handlePollResult(pollResult, client);
              return;
            }
          }
        } else {
          await _handleAuthCallback(
            callbackData,
            authResponse.sessionState,
            client,
          );
          return;
        }
      } else if (winner is _PollResult) {
        cancellation.cancel();
        Logs().i('[AuthProxy] desktop: poll won, status=${winner.status}');
        await _handlePollResult(winner, client);
        return;
      }
    } catch (e) {
      if (e is AuthProxyServerException) {
        cancellation.cancel();
        rethrow;
      }
      Logs().w('[AuthProxy] desktop: auth failed', e);
      rethrow;
    } finally {
      await sub.cancel();
    }
  }

  /// Retry [client.login] with exponential backoff on transient network errors.
  /// When [sessionState] is provided and the token is rejected with
  /// M_UNKNOWN_TOKEN, attempts to obtain a fresh token via
  /// [AuthProxyService.refreshToken] before retrying.
  Future<void> _loginWithRetry(
    Client client,
    String token, {
    String? sessionState,
  }) async {
    const maxRetries = 3;
    const retryDelays = [
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ];
    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        await client.login(
          LoginType.mLoginToken,
          token: token,
          initialDeviceDisplayName: PlatformInfos.clientName,
        );
        return;
      } catch (e) {
        final isLastAttempt = attempt == maxRetries;

        // Token expired — try to get a fresh one from auth proxy
        if (e is MatrixException &&
            e.errcode == 'M_UNKNOWN_TOKEN' &&
            sessionState != null) {
          Logs().w(
            '[AuthProxy] login token expired (attempt ${attempt + 1}), '
            'requesting fresh token',
          );
          try {
            final fresh = await _authProxyService.refreshToken(
              sessionState: sessionState,
            );
            token = fresh.loginToken;
            if (!isLastAttempt) {
              await Future.delayed(retryDelays[attempt]);
            }
            continue;
          } catch (refreshErr) {
            Logs().e('[AuthProxy] refreshToken failed', refreshErr);
            if (isLastAttempt) rethrow;
          }
        }

        final isTransient =
            e is http.ClientException ||
            e is SocketException ||
            e is IOException;
        if (isLastAttempt || !isTransient) rethrow;
        Logs().w(
          '[AuthProxy] login attempt ${attempt + 1} failed, '
          'retrying in ${retryDelays[attempt].inSeconds}s: $e',
        );
        await Future.delayed(retryDelays[attempt]);
      }
    }
  }

  Future<void> _handleAuthCallback(
    AuthCallbackData callback,
    String sessionState,
    Client client,
  ) async {
    switch (callback.action) {
      case 'complete':
        final token = callback.loginToken;
        final serverName = callback.serverName;
        if (token == null || token.isEmpty) {
          throw Exception('No login token received');
        }
        if (serverName != null && serverName.isNotEmpty) {
          final targetHomeserver = Uri.https(serverName, '');
          if (client.homeserver != targetHomeserver) {
            await client.checkHomeserver(targetHomeserver);
          }
        }
        await _loginWithRetry(client, token, sessionState: sessionState);

        // Инвайт через deep-link: backend прокидывает inviteRoomId напрямую.
        // Если он есть — навигируем без лишнего redeem-запроса.
        final inviteRoomId = callback.inviteRoomId;
        if (inviteRoomId != null && inviteRoomId.isNotEmpty) {
          Logs().i(
            '[InviteRedeem] Deep-link provided inviteRoomId: $inviteRoomId',
          );
          PendingInviteCode.clear();
          if (mounted) {
            context.go('/rooms/${Uri.encodeComponent(inviteRoomId)}');
          }
          return;
        }
        // Иначе — если есть pending invite-код, делаем redeem.
        await _redeemPendingInvite(client);

      case 'register':
        // Само-регистрация задепрекейчена — отдаём ошибку.
        throw AuthProxyServerException(
          serverError: L10n.of(context).accountNotFound,
        );

      case 'select':
        if (!mounted) return;
        context.push(
          '$_basePath/select',
          extra: AuthSelectExtra(
            sessionState: callback.sessionState ?? sessionState,
            authProxyService: _authProxyService,
          ),
        );

      case 'error':
        // Второй путь к тому же исходу: на deep-link/WebView-колбэке сервер
        // отдаёт action=error&error=access_not_granted. Если бы ветвился
        // только поллинг, на macOS/Windows/мобильных выигравший гонку колбэк
        // показывал бы сырой код ошибки вместо экрана исхода.
        final outcome = authOutcomeFromErrorCode(callback.error);
        if (outcome != null) {
          _showAuthOutcome(outcome);
          return;
        }
        throw AuthProxyServerException(
          serverError:
              callback.error ?? L10n.of(context).oopsSomethingWentWrong,
        );

      default:
        throw Exception('Unknown auth action: ${callback.action}');
    }
  }

  Future<bool> _redeemPendingInvite(Client client) {
    return redeemPendingInviteAfterLogin();
  }

  @override
  Widget build(BuildContext context) => HomeserverPickerView(this);

  Future<void> restoreBackup() async {
    final picked = await selectFiles(context);
    final file = picked.firstOrNull;
    if (file == null) return;
    setState(() {
      error = null;
      isLoading = true;
    });
    try {
      final client = await Matrix.of(context).getLoginClient();
      await client.importDump(String.fromCharCodes(await file.readAsBytes()));
      Matrix.of(context).initMatrix();
    } catch (e) {
      setState(() {
        error = e.toLocalizedString(context);
      });
    } finally {
      if (mounted) {
        setState(() {
          isLoading = false;
        });
      }
    }
  }

  void onMoreAction(MoreLoginActions action) {
    switch (action) {
      case MoreLoginActions.importBackup:
        restoreBackup();
      case MoreLoginActions.privacy:
        launchUrl(AppConfig.privacyUrl);
      case MoreLoginActions.about:
        PlatformInfos.showDialog(context);
    }
  }
}

enum MoreLoginActions { importBackup, privacy, about }

class IdentityProvider {
  final String? id;
  final String? name;
  final String? icon;
  final String? brand;

  IdentityProvider({this.id, this.name, this.icon, this.brand});

  factory IdentityProvider.fromJson(Map<String, dynamic> json) =>
      IdentityProvider(
        id: json['id'],
        name: json['name'],
        icon: json['icon'],
        brand: json['brand'],
      );
}
