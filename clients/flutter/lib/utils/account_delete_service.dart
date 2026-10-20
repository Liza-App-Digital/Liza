import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart' show Result;
import 'package:http/http.dart' as http;
import 'package:matrix/matrix.dart' show Logs;

/// Почему удаление не состоялось — экран выбирает по нему текст из L10n.
enum AccountDeleteFailure {
  /// 409 `company_owner`: человек — владелец главного пространства компании.
  companyOwner,

  /// Всё остальное: сеть, таймаут, 401/404 (старый auth-proxy без эндпоинта),
  /// 5xx, 409 служебного аккаунта.
  other,
}

class AccountDeleteException implements Exception {
  const AccountDeleteException(this.failure, {this.statusCode});

  final AccountDeleteFailure failure;
  final int? statusCode;

  @override
  String toString() => 'AccountDeleteException($failure, $statusCode)';
}

/// Самоудаление аккаунта через auth-proxy (`POST /api/account/delete`).
///
/// Штатный `/account/deactivate` Synapse требует UIA `m.login.password`, а
/// пароля у ProdamusID/OTP-пользователя нет — поэтому удаление идёт через
/// auth-proxy: он подтверждает токен и деактивирует аккаунт admin API со
/// стиранием данных (App Store Review Guideline 5.1.1(v)).
class AccountDeleteService {
  AccountDeleteService({
    required this.baseUrl,
    required String? Function() accessTokenProvider,
    required String Function() serverNameProvider,
    http.Client? httpClient,
  })  : _accessTokenProvider = accessTokenProvider,
        _serverNameProvider = serverNameProvider,
        _httpClient = httpClient ?? http.Client();

  /// ХОСТ auth-proxy без схемы (`AppConfig.authProxyBaseUrl`), см.
  /// `UserHandleService.baseUrl`.
  final String baseUrl;
  final String? Function() _accessTokenProvider;
  final String Function() _serverNameProvider;
  final http.Client _httpClient;

  /// Не 10 с, как у прочих вызовов auth-proxy: деактивация со стиранием на
  /// старом аккаунте идёт заметно дольше, а оборванный по таймауту запрос
  /// показал бы «не удалось» при уже удалённом аккаунте.
  static const requestTimeout = Duration(seconds: 60);

  /// Бросает [AccountDeleteException] на любой исход, кроме 200.
  Future<void> delete() async {
    final http.Response response;
    try {
      response = await _httpClient
          .post(
            Uri.https(baseUrl, '/api/account/delete'),
            headers: {
              'Authorization': 'Bearer ${_accessTokenProvider() ?? ''}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'server_name': _serverNameProvider()}),
          )
          .timeout(requestTimeout);
    } catch (e, s) {
      Logs().w('[AccountDeleteService] delete failed', e, s);
      throw const AccountDeleteException(AccountDeleteFailure.other);
    }
    if (response.statusCode == 200) return;
    Logs().w('[AccountDeleteService] delete status ${response.statusCode}');
    throw AccountDeleteException(
      _errorCode(response) == 'company_owner'
          ? AccountDeleteFailure.companyOwner
          : AccountDeleteFailure.other,
      statusCode: response.statusCode,
    );
  }

  static String? _errorCode(http.Response response) {
    if (response.statusCode != 409) return null;
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      return body is Map ? body['error'] as String? : null;
    } catch (_) {
      return null;
    }
  }
}

/// Удаление после обоих подтверждений. Возвращает `true`, если аккаунт удалён.
///
/// [runWithProgress] показывает диалог прогресса и, при ошибке, её текст
/// (см. `showFutureLoadingDialog`); [isMounted] спрашивается ПОСЛЕ удаления.
///
/// `markExplicitLogout` — ДО запроса: как только сервер погасит токен, sync
/// словит M_UNKNOWN_TOKEN и SDK сам выйдет, и без пометки этот выход был бы
/// принят за «мягкий» с попыткой восстановить мёртвую сессию из бэкапа.
Future<bool> deleteAccountAndLogout({
  required Future<void> Function() delete,
  required void Function() markExplicitLogout,
  required void Function() unmarkExplicitLogout,
  required Future<void> Function() logout,
  required Future<Result<void>> Function(Future<void> Function() action)
      runWithProgress,
  required bool Function() isMounted,
}) async {
  markExplicitLogout();
  final resp = await runWithProgress(delete);
  if (resp.isError) {
    // Сервер ответил отказом (есть HTTP-код) — аккаунт жив, пометку снимаем,
    // иначе любой позднейший протухший токен сочтётся явным выходом и сессия не
    // восстановится. Обрыв без ответа — пометку держим: сервер мог успеть
    // удалить аккаунт, и выход по M_UNKNOWN_TOKEN тогда действительно явный.
    final error = resp.asError?.error;
    if (error is AccountDeleteException && error.statusCode != null) {
      unmarkExplicitLogout();
    }
    return false;
  }
  // Аккаунт уже стёрт на сервере — локально остаться залогиненным нельзя.
  // Экран могли закрыть (тот же выход по M_UNKNOWN_TOKEN уносит роутер) —
  // тогда выходим молча, без диалога.
  if (!isMounted()) {
    await logout();
    return true;
  }
  await runWithProgress(logout);
  return true;
}
