import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart';

import 'package:liza/utils/auth_proxy_service.dart';
import 'package:liza/utils/deep_link_target.dart';
import 'package:liza/utils/pending_deep_link.dart';
import 'package:liza/utils/platform_infos.dart';
import 'package:liza/widgets/liza_app.dart';

/// Completes Matrix login using token response from auth proxy.
/// Shared by homeserver_picker and auth_select pages.
///
/// When [sessionState] and [authProxyService] are provided, attempts to
/// refresh the token via [AuthProxyService.refreshToken] if Synapse rejects
/// the original token (M_UNKNOWN_TOKEN / M_FORBIDDEN).
Future<void> completeAuthProxyLogin({
  required Client client,
  required AuthTokenResponse tokenResponse,
  String? sessionState,
  AuthProxyService? authProxyService,
}) async {
  final serverName = tokenResponse.serverName;
  if (serverName.isNotEmpty) {
    final targetHomeserver = Uri.https(serverName, '');
    if (client.homeserver != targetHomeserver) {
      await client.checkHomeserver(targetHomeserver);
    }
  }

  var token = tokenResponse.loginToken;
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

      // Token rejected — try to get a fresh one from auth proxy
      if (e is MatrixException &&
          (e.errcode == 'M_UNKNOWN_TOKEN' ||
              e.error == MatrixError.M_FORBIDDEN) &&
          sessionState != null &&
          authProxyService != null) {
        Logs().w(
          '[AuthProxy] login token rejected (attempt ${attempt + 1}), '
          'requesting fresh token',
        );
        try {
          final fresh = await authProxyService.refreshToken(
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
          e is http.ClientException || e is SocketException || e is IOException;
      if (isLastAttempt || !isTransient) rethrow;
      Logs().w(
        '[AuthProxy] login attempt ${attempt + 1} failed, '
        'retrying in ${retryDelays[attempt].inSeconds}s: $e',
      );
      await Future.delayed(retryDelays[attempt]);
    }
  }
}

/// После успешного login проверяет, есть ли ожидающая ссылка в
/// [PendingDeepLinkStore], и если да — маршрутизирует по её типу. Возвращает
/// true если навигация произошла (вызывающий не должен делать свою). Всегда
/// сбрасывает [PendingDeepLinkStore] до возврата.
///
/// Используется из всех путей завершения OIDC-логина: homeserver_picker
/// (WebView/polling/deep-link) и auth_select (выбор сервера).
///
/// Навигация идёт через [LizaApp.router] напрямую (а не через
/// BuildContext.mounted), чтобы переживать ремаунт страницы: после
/// [Client.login] onLoginStateChanged триггерит перестройку дерева, и
/// исходный AuthSelectPage/HomeserverPicker может анмаунтнуться раньше,
/// чем мы дошли до navigation.
///
/// Без параметров client/authProxyService: сам redeem-запрос теперь делает
/// OpeningPage (через resolveInviteTarget) — здесь только маршрутизация по
/// типу pending-ссылки.
Future<bool> redeemPendingInviteAfterLogin() async {
  final pending =
      PendingDeepLinkStore.current ?? await PendingDeepLinkStore.restore();
  if (pending == null) {
    Logs().i('[InviteRedeem] no pending deep link, skipping');
    return false;
  }
  PendingDeepLinkStore.clear();

  final router = LizaApp.router;
  switch (pending.kind) {
    case DeepLinkKind.invite:
      // Резолв идёт на экране ожидания: он показывает прогресс, пока
      // отрабатывает авто-инвайт и комната доезжает в sync.
      router.go('/opening/${pending.code}');
    case DeepLinkKind.story:
      router.go('/s/${pending.code}');
    case DeepLinkKind.channel:
      router.go('/c/${pending.code}');
    case DeepLinkKind.user:
      router.go('/u/${pending.code}');
    case DeepLinkKind.bot:
      router.go(pending.code);
  }
  return true;
}
