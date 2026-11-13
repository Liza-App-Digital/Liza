import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// `app_id` мини-аппа капсул в реестре портала разработчика — постоянный
/// (liza-memory `CAPSULES_APP_ID`, по умолчанию тот же «capsules»).
const capsulesMiniAppId = 'capsules';

/// Мини-апп, которому разрешён микрофон: только наш first-party мини-апп капсул
/// (запись созвона). Остальным — ни микрофона, ни камеры, ни геолокации.
bool miniAppMayUseMicrophone({
  required String appId,
  required String appType,
}) => appType == 'first_party' && appId == capsulesMiniAppId;

/// Ответ WebView на запрос прав страницы (getUserMedia и т.п.).
///
/// GRANT — только если мини-апп капсул ([miniAppMayUseMicrophone]), страница
/// всё ещё на origin приложения из каталога (а не ушла по ссылке на чужой сайт)
/// и просит исключительно MICROPHONE. Микрофон вместе с камерой — DENY целиком:
/// частичную выдачу WKWebView не умеет.
PermissionResponseAction miniAppPermissionDecision({
  required String appId,
  required String appType,
  required String appUrl,
  required Uri requestOrigin,
  required List<PermissionResourceType> resources,
}) {
  if (!miniAppMayUseMicrophone(appId: appId, appType: appType) ||
      resources.isEmpty ||
      resources.any((r) => r != PermissionResourceType.MICROPHONE) ||
      !_sameOrigin(requestOrigin, appUrl)) {
    return PermissionResponseAction.DENY;
  }
  return PermissionResponseAction.GRANT;
}

bool _sameOrigin(Uri origin, String appUrl) {
  final app = Uri.tryParse(appUrl);
  if (app == null || app.scheme != 'https' || origin.scheme != 'https') {
    return false;
  }
  return app.origin == origin.origin;
}
